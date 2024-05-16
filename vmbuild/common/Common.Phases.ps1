
function Write-JobProgress {
    param($Job, $AdditionalData)

    try {
        if (-not $global:JobProgressHistory) {
            $global:JobProgressHistory = @()
        }
        $latestActivity = $null
        $latestStatus = $null
        #Make sure the first child job exists
        if ($null -ne $job -and $null -ne $Job.ChildJobs -and $null -ne $Job.ChildJobs[0].Progress) {
            #Extracts the latest progress of the job and writes the progress
            $latestPercentComplete = 0
            # Notes: "Preparing modules for first use" is translated when other than en-US
            $lastProgress = $Job.ChildJobs[0].Progress | Where-Object { $_.Activity -ne "Preparing modules for first use." } | Select-Object -Last 1
            if ($lastProgress) {
                $latestPercentComplete = $lastProgress | Select-Object -expand PercentComplete;
                $latestActivity = $lastProgress | Select-Object -expand Activity;
                $latestStatus = $lastProgress | Select-Object -expand StatusDescription;
                $jobName = $job.Name
                if ($latestActivity) {
                    $latestActivity = $latestActivity.Replace("$jobName`: ", "").Trim()
                }
                if (-not $latestStatus) {
                    $latestStatus = ""
                }
            }

            if ($latestActivity -and $latestStatus.Trim().Length) {
                #When adding multiple progress bars, a unique ID must be provided. Here I am providing the JobID as this
                if ($latestPercentComplete -gt 0 -and $latestPercentComplete -lt 101) {

                }
                else {
                    $latestPercentComplete = 0
                }
                try {
                    $padding = 0
                    $jobName2 = "[Unknown]"
                    if ($jobName) {
                        $jobName2 = "  $($jobName.PadRight($padding," "))"
                    }
                    else {
                        $jobName = "[Unknown VM] [Unkown Role]"
                    }

                    if ($Common.PS7) {
                        if ($AdditionalData) {
                            $padding1 = $AdditionalData.MaxVmNameLength
                            $padding2 = $AdditionalData.MaxRoleNameLength
                            $vmName = ($jobName -split " ")[0]
                            $roleName = ($jobName -split " ")[1]
                            $jobName2 = "  $($vmName.PadRight($padding1," ")) $($roleName.PadRight($padding2," "))"
                        }

                        # $latestActivity = "$($latestActivity.PadRight($Common.ScreenWidth/2 - 10," "))"
                    }
                    $CurrentActivity = "$jobName2`: $latestActivity"
                    $HistoryLine = $Job.Id.ToString() + $CurrentActivity + $latestStatus
                    if ($global:JobProgressHistory -notcontains $HistoryLine) {
                        $global:JobProgressHistory += $HistoryLine
                        Write-Progress2 -Activity $CurrentActivity -Id $Job.Id -Status $latestStatus -PercentComplete $latestPercentComplete -force
                        write-host -NoNewline "$hideCursor"
                        # start-sleep -seconds 1
                    }
                }
                catch {
                    Write-Log "[$jobName] Exception during job progress reporting. $vmName; $roleName; $AdditionalData. $_" -failure
                }
            }
        }
    }
    catch {
        Write-Log "[$jobName] Exception during job progress reporting. $vmName; $roleName; $AdditionalData. $_" -failure
    }
    finally {
    }
}

function Start-Phase {

    param(
        [int]$Phase,
        [object]$deployConfig,
        [switch]$WhatIf
    )

    if ($WhatIf) {
        Write-Log "[WhatIf] Will Start Phase $Phase"
        return $true
    }

    # Remove DNS records for VM's in this config, if existing DC
    if ($deployConfig.parameters.ExistingDCName -and $Phase -eq 1) {
        Write-Log "[Phase $Phase] Attempting to remove existing DNS Records"
        $existingDC = $deployConfig.parameters.ExistingDCName
        foreach ($item in $deployConfig.virtualMachines | Where-Object { -not ($_.hidden) } ) {
            if ($existingDC) {
                Remove-DnsRecord -DCName $existingDC -Domain $deployConfig.vmOptions.domainName -RecordToDelete $item.vmName
            }
        }
    }

    # Start Phase
    $start = Start-PhaseJobs -Phase $Phase -deployConfig $deployConfig
    if (-not $start.Applicable) {
        Write-OrangePoint "[Phase $Phase] Not Applicable. Skipping." -ForegroundColor Yellow -WriteLog
        $global:PhaseSkipped = $true
        return $true
    }
    $global:PhaseSkipped = $false
    $result = Wait-Phase -Phase $Phase -Jobs $start.Jobs -AdditionalData $start.AdditionalData
    Write-Log "[Phase $Phase] Jobs completed; $($result.Success) success, $($result.Warning) warnings, $($result.Failed) failures."

    if ($result.Failed -gt 0) {
        return $false
    }

    return $true
}

function Start-PhaseJobs {
    param (
        [int]$Phase,
        [object]$deployConfig
    )

    $global:preparePhasePercent = 5
    Write-Progress2 "Preparing Phase $Phase" -Status "Getting configuration data" -PercentComplete $global:preparePhasePercent

    [System.Collections.ArrayList]$jobs = @()
    $job_created_yes = 0
    $job_created_no = 0

    # Determine single vs. multi-DSC
    $multiNodeDsc = $true
    $ConfigurationData = $null
    if ($Phase -gt 1) {
        $ConfigurationData = Get-ConfigurationData -Phase $Phase -deployConfig $deployConfig
        if (-not $ConfigurationData) {
            # Nothing applicable for this phase
            return [PSCustomObject]@{
                Failed         = 0
                Success        = 0
                Jobs           = 0
                Applicable     = $false
                AdditionalData = $null
            }
        }

        if ($ConfigurationData.AllNodes.NodeName -contains "LOCALHOST") {
            $multiNodeDsc = $false
        }
    }
    else {
        $multiNodeDsc = $false
    }

    $global:preparePhasePercent = 50
    Write-Progress2 "Preparing Phase $Phase" -Status "Updating VM List" -PercentComplete $global:preparePhasePercent

    $global:vm_remove_list = @()
    $maxVmNameLength = 0
    $maxRoleNameLength = 0
    $existingVMs = Get-List -Type VM -SmartUpdate
    foreach ($currentItem in $deployConfig.virtualMachines) {

        $global:preparePhasePercent++
        Write-Progress2 "Preparing Phase $Phase" -Status "Evaluating virtual machine $($currentItem.vmName)" -PercentComplete $global:preparePhasePercent

        # Don't touch non-hidden VM's in Phase 0
        if ($Phase -eq 0 -and -not $currentItem.hidden) {
            continue
        }

        # Don't touch hidden VM's in Phase 1
        if ($Phase -eq 1 -and $currentItem.hidden) {
            continue
        }

        # Skip Phase 1 for machines that exist - should never hit this
        if ($Phase -eq 1 -and $currentItem.vmName -in $existingVMs.vmName) {
            continue
        }

        # Skip everything for OSDClient, nothing for us to do
        if ($Phase -gt 1 -and $currentItem.role -in ("OSDClient", "Linux")) {
            continue
        }

        # Skip multi-node DSC (& monitoring) for all machines except those in the ConfigurationData.AllNodes
        if ($multiNodeDsc -and $currentItem.vmName -notin $ConfigurationData.AllNodes.NodeName) {
            continue
        }

        $deployConfigCopy = $deployConfig | ConvertTo-Json -depth 5 | ConvertFrom-Json
        $deployConfigCopy.parameters.ThisMachineName = $currentItem.vmName

        if ($WhatIf) {
            Write-Log "[Phase $Phase] Will start a job for VM $($currentItem.vmName)"
            continue
        }

        $jobName = "$($currentItem.vmName) [$($currentItem.role)] "
        if ($currentItem.vmName.Length -gt $maxVmNameLength) {
            $maxVmNameLength = $currentItem.vmName.Length
        }
        if ($currentItem.role.Length -gt $maxRoleNameLength) {
            $maxRoleNameLength = $currentItem.role.Length
        }

        if ($Phase -eq 0 -or $Phase -eq 1) {
            # Create/Prepare VM
            $job = Start-Job -ScriptBlock $global:VM_Create -Name $jobName -ErrorAction Stop -ErrorVariable Err
            if (-not $job) {
                Write-Log "[Phase $Phase] Failed to create job for VM $($currentItem.vmName). $Err" -Failure
                $job_created_no++
            }
            else {
                if ($Phase -eq 1) {
                    # Add VM's that started jobs in phase 1 (VM Creation) to global remove list.
                    if (-not $Migrate) {
                        $global:vm_remove_list += ($jobName -split " ")[0]
                    }
                }
            }
        }
        else {
            $reservation = $null
            if ($Phase -eq 5) {
                $reservation = (Get-DhcpServerv4Reservation -ScopeId 10.250.250.0 -ea SilentlyContinue).ClientID
                $reservation = $reservation -replace "-", ""
            }
            $job = Start-Job -ScriptBlock $global:VM_Config -Name $jobName -ErrorAction Stop -ErrorVariable Err
            if (-not $job) {
                Write-Log "[Phase $Phase] Failed to create job for VM $($currentItem.vmName). $Err" -Failure
                $job_created_no++
            }
        }

        if ($Err.Count -ne 0) {
            Write-Log "[Phase $Phase] Failed to start job for VM $($currentItem.vmName). $Err" -Failure
            $job_created_no++
        }
        else {
            Write-Log "[Phase $Phase] Created job $($job.Id) for VM $($currentItem.vmName)" -LogOnly
            $jobs += $job
            $job_created_yes++
        }
    }

    $additionalData = [PSCustomObject]@{
        MaxVmNameLength   = $maxVmNameLength
        MaxRoleNameLength = $maxRoleNameLength + 2
    }

    # Create return object
    $return = [PSCustomObject]@{
        Failed         = $job_created_no
        Success        = $job_created_yes
        Jobs           = $jobs
        Applicable     = $true
        AdditionalData = $additionalData
    }

    Write-Progress2 "Preparing Phase $Phase" -Status "Created $job_created_yes jobs." -PercentComplete 100 -Completed

    if ($job_created_no -eq 0) {
        Write-Log "[Phase $Phase] Created $job_created_yes jobs. Waiting for jobs."
    }
    else {
        Write-Log "[Phase $Phase] Created $job_created_yes jobs. Failed to create $job_created_no jobs."
    }

    return $return

}

function Wait-Phase {

    param(
        [int]$Phase,
        $Jobs,
        $AdditionalData
    )
    $OriginalProgressPreference = $Global:ProgressPreference
    $Global:ProgressPreference = 'SilentlyContinue'

    $esc = [char]27
    $hideCursor = "$esc[?25l"
    $showCursor = "$esc[?25h"

    try {

        Write-Host -NoNewline "$hideCursor" # Reduce flickering in Progress bars

        # Create return object
        $return = [PSCustomObject]@{
            Failed  = 0
            Success = 0
            Warning = 0
        }

        $global:JobProgressHistory = @()

        $FailRetry = 0
        do {
            $runningJobs = $jobs | Where-Object { $_.State -ne "Completed" -and - $_State -ne "Failed" } | Sort-Object -Property Id
            foreach ($job in $runningJobs) {
                Write-JobProgress -Job $job -AdditionalData $AdditionalData
            }

            $failedJobs = $jobs | Where-Object { $_.State -eq "Failed" } | Sort-Object -Property Id
            foreach ($job in $failedJobs) {
                $FailRetry = $FailRetry + 1
                if ($FailRetry -gt 30) {
                    $jobOutput = $job | Select-Object -ExpandProperty childjobs | Select-Object -ExpandProperty Error
                    $jobJson = $job | convertTo-Json -depth 5 -WarningAction SilentlyContinue
                    Write-Log "[Phase $Phase] Job failed: $jobJson" -LogOnly
                    Write-RedX "[Phase $Phase] Job failed: $jobOutput" -ForegroundColor Red
                    Write-Progress2 -Id $job.Id -Activity $job.Name -Completed -force
                    $jobs.Remove($job)
                    $return.Failed++
                }
            }
            $completedJobs = $jobs | Where-Object { $_.State -eq "Completed" } | Sort-Object -Property Id
            foreach ($job in $completedJobs) {
                Write-Progress2 -Id $job.Id -Activity $job.Name -Completed -force
                #Write-JobProgress -Job $job -AdditionalData $AdditionalData
                $jobName = $job | Select-Object -ExpandProperty Name
                $jobOutput = $job | Select-Object -ExpandProperty childjobs | Select-Object -ExpandProperty Output
                if (-not $jobOutput) {
                    $jobError = $job | Select-Object -ExpandProperty childjobs | Select-Object -ExpandProperty Error

                    if ($jobError) {
                        Write-RedX "[Phase $Phase] Job $jobName completed with error: $jobError" -ForegroundColor Red
                    }
                    else {
                        Write-RedX "[Phase $Phase] Job $jobName completed with no output" -ForegroundColor Red
                    }
                    $jobJson = $job | ConvertTo-Json -Depth 5 -WarningAction SilentlyContinue
                    write-log -LogOnly $jobJson
                    $return.Failed++
                }
                #$logLevel = 1    # 0 = Verbose, 1 = Info, 2 = Warning, 3 = Error
                $incrementCount = $true
                foreach ($OutputObject in $jobOutput) {
                    $line = $OutputObject.text
                    if (-not $line) {
                        continue
                    }
                    $line = $line.ToString().Trim()
                    if ($OutputObject.LogLevel -eq 3) {
                        Write-RedX $line -ForegroundColor $OutputObject.ForegroundColor
                        if ($incrementCount) {
                            $return.Failed++
                        }
                        if ($phase -gt 2 -and $jobName.Contains("[DC]")) {
                            Write-RedX "DC failed. Stopping Phase." -ForegroundColor $OutputObject.ForegroundColor
                            try {
                                $jobs | Stop-Job
                            }
                            catch {}
                            return $return
                        }
                    }
                    elseif ($OutputObject.LogLevel -eq 2) {
                        Write-OrangePoint $line -ForegroundColor $OutputObject.ForegroundColor
                        if ($incrementCount) { $return.Warning++ }
                    }
                    else {
                        Write-GreenCheck $line -ForegroundColor $OutputObject.ForegroundColor
                        # Assume no error/warning was a success
                        if ($incrementCount) { $return.Success++ }
                    }

                    $incrementCount = $false
                }

                #Write-Progress2 -Id $job.Id -Activity $job.Name -Completed
                $jobs.Remove($job)
            }

            # Sleep
            Start-Sleep -Milliseconds 200

        } until (($runningJobs.Count -eq 0) -and ($failedJobs.Count -eq 0))

        return $return
    }
    catch {
        Write-Exception -ExceptionInfo $_
    }
    finally {
        $Global:ProgressPreference = $OriginalProgressPreference
        Write-Host -NoNewline "$showCursor" # Show cursor again
    }
}

function Get-ConfigurationData {
    param (
        [int]$Phase,
        [object]$deployConfig
    )

    #$netbiosName = $deployConfig.vmOptions.domainName.Split(".")[0]
    $netbiosName = $deployConfig.vmOptions.domainNetBiosName
    if (-not $netbiosName) {
        write-Log -Failure "[Phase $Phase] Could not get Netbios name from 'deployConfig.vmOptions.domainName' "
        return
    }

    switch ($Phase) {
        "2" { $cd = Get-Phase2ConfigurationData -deployConfig $deployConfig }
        "3" { $cd = Get-Phase3ConfigurationData -deployConfig $deployConfig }
        "4" { $cd = Get-Phase4ConfigurationData -deployConfig $deployConfig }
        "5" { $cd = Get-Phase5ConfigurationData -deployConfig $deployConfig }
        "6" { $cd = Get-Phase6ConfigurationData -deployConfig $deployConfig }
        "7" { $cd = Get-Phase7ConfigurationData -deployConfig $deployConfig }
        "8" {
            $cd = Get-Phase8ConfigurationData -deployConfig $deployConfig
            if ($cd) {
                $autoSnapshotName = "MemLabs Phase 8 AutoSnapshot " + $Configuration
                $snapshot = $null
                $dc = get-list2 -deployConfig $deployConfig | Where-Object { $_.role -eq "DC" }
                if ($dc) {
                    $snapshot = Get-VMCheckpoint2 -VMName $dc.vmName -ErrorAction SilentlyContinue | where-object { $_.Name -like "*$autoSnapshotName*" } | Sort-Object CreationTime | Select-Object -ExpandProperty Name
                }

                if (-not $snapshot) {
                    $response = Read-YesorNoWithTimeout -timeout 30 -prompt "Automatically take snapshot of domain? (Y/n)" -HideHelp -Default "y"
                    if (-not ($response -eq "n")) {
                        Invoke-AutoSnapShotDomain -domain $deployConfig.vmOptions.DomainName -comment $autoSnapshotName
                        write-log -HostOnly ""
                        write-log "Auto Snapshot $autoSnapshotName completed."
                    }
                }
            }
        }
        Default { return }
    }
    if ($global:Common.VerboseEnabled) {
        $cd | ConvertTo-Json | out-host
    }

    if ($cd) {

        $global:preparePhasePercent++
        Start-Sleep -Milliseconds 201
        Write-Progress2 "Preparing Phase $Phase" -Status "Verifying all required VM's are running" -PercentComplete $global:preparePhasePercent

        $nodes = $cd.AllNodes.NodeName | Where-Object { $_ -ne "*" -and ($_ -ne "LOCALHOST") }
        if ($nodes) {
            $critlist = Get-CriticalVMs -domain $deployConfig.vmOptions.domainName -vmNames $nodes
        }

        $global:preparePhasePercent++
        Start-Sleep -Milliseconds 201
        Write-Progress2 "Preparing Phase $Phase" -Status "Starting required VMs (if needed)" -PercentComplete $global:preparePhasePercent

        if ($critlist) {
            $failures = Invoke-SmartStartVMs -CritList $critlist
            if ($failures -ne 0) {
                write-log "$failures VM(s) could not be started" -Failure
            }
        }

        $dc = $cd.AllNodes | Where-Object { $_.Role -eq "DC" }
        if ($dc) {

            $global:preparePhasePercent++
            Start-Sleep -Milliseconds 201
            Write-Progress2 "Preparing Phase $Phase" -Status "Testing net connection on $($dc.NodeName)" -PercentComplete $global:preparePhasePercent

            $OriginalProgressPreference = $Global:ProgressPreference
            try {
                $Global:ProgressPreference = 'SilentlyContinue'
                $testNet = Test-NetConnection -ComputerName $dc.NodeName -Port 3389 -ErrorAction SilentlyContinue -WarningAction SilentlyContinue -InformationLevel Quiet
                $Global:ProgressPreference = $OriginalProgressPreference

                if (-not $testNet) {
                    Write-Log "[Phase $Phase]: $($dc.NodeName): Could not verify if RDP is enabled. Restarting the computer." -Warning
                    Invoke-VmCommand -VmName $dc.NodeName -VmDomainName $deployConfig.vmOptions.domainName -ScriptBlock { Restart-Computer -Force } | Out-Null
                    Start-Sleep -Seconds 20
                }
            }
            catch {}
            finally {
                $Global:ProgressPreference = $OriginalProgressPreference
            }
        }

    }

    return $cd
}

function Get-Phase2ConfigurationData {
    param (
        [object]$deployConfig
    )

    $cd = @{
        AllNodes = @(
            @{
                NodeName                    = 'LOCALHOST'
                PSDscAllowDomainUser        = $true
                PSDscAllowPlainTextPassword = $true
            }
        )
    }

    foreach ($vm in $deployConfig.virtualMachines) {

        $global:preparePhasePercent++

        # Filter out workgroup machines
        if ($vm.role -notin "AADClient", "OSDClient", "Linux") {
            if (-not $vm.Hidden) {
                return $cd
            }
        }
    }
    return $null
}

function Get-Phase3ConfigurationData {
    param (
        [object]$deployConfig
    )

    $cd = @{
        AllNodes = @(
            @{
                NodeName                    = '*'
                PSDscAllowDomainUser        = $true
                PSDscAllowPlainTextPassword = $true
            }
        )
    }

    $NumberOfNodesAdded = 0
    foreach ($vm in $deployConfig.virtualMachines) {

        $global:preparePhasePercent++

        # Filter out workgroup machines
        if ($vm.role -in "WorkgroupMember", "InternetClient", "OSDClient", "Linux") {
            continue
        }

        $newItem = @{
            NodeName = $vm.vmName
            Role     = $vm.Role
        }
        $cd.AllNodes += $newItem
        if ($vm.Role -ne "DC") {
            $NumberOfNodesAdded = $NumberOfNodesAdded + 1
        }
    }


    if ($NumberOfNodesAdded -eq 0) {
        return
    }

    return $cd
}

function Get-Phase4ConfigurationData {
    param (
        [object]$deployConfig
    )

    $cd = @{
        AllNodes = @(
            @{
                NodeName                    = '*'
                PSDscAllowDomainUser        = $true
                PSDscAllowPlainTextPassword = $true
            }
        )
    }

    $NumberOfNodesAdded = 0
    #foreach ($vm in $deployConfig.virtualMachines | Where-Object { ($_.SqlVersion -and -not ($_.Hidden)) -or $_.Role -eq "DC" }) {
    foreach ($vm in $deployConfig.virtualMachines | Where-Object { $_.SqlVersion -or $_.Role -eq "DC" }) {

        $global:preparePhasePercent++

        # Filter out workgroup machines
        if ($vm.role -in "WorkgroupMember", "AADClient", "InternetClient", "OSDClient" , "Linux") {
            continue
        }

        $newItem = @{
            NodeName = $vm.vmName
            Role     = $vm.Role
        }
        $cd.AllNodes += $newItem
        if ($vm.Role -ne "DC") {
            $NumberOfNodesAdded = $NumberOfNodesAdded + 1
        }
    }

    if ($NumberOfNodesAdded -eq 0) {
        return
    }

    return $cd
}

function Get-Phase5ConfigurationData {
    param (
        [object]$deployConfig
    )

    $primaryNodes = $deployConfig.virtualMachines | Where-Object { $_.role -eq "SQLAO" -and $_.OtherNode -and -not ($_.hidden) }
    $dc = $deployConfig.virtualMachines | Where-Object { $_.role -eq "DC" }


    $NumberOfNodesAdded = 0
    # Configuration Data
    $cd = @{
        AllNodes = @(
            @{
                NodeName = $dc.vmName
                Role     = 'DC'
            }
        )
    }

    $fileServersAdded = @()
    if ($primaryNodes) {

        foreach ($primaryNode in $primaryNodes) {

            $global:preparePhasePercent++

            $primary = @{
                # Replace with the name of the actual target node.
                NodeName = $primaryNode.vmName
                # This is used in the configuration to know which resource to compile.
                Role     = 'ClusterNode1'
            }

            $cd.AllNodes += $primary
            $secondary = @{
                # Replace with the name of the actual target node.
                NodeName = $primaryNode.OtherNode
                # This is used in the configuration to know which resource to compile.
                Role     = 'ClusterNode2'
            }
            $cd.AllNodes += $secondary
            #added Primary And Secondary

            if ($fileServersAdded -notcontains ( $primaryNode.fileServerVM)) {
                $fileServer = @{
                    # Replace with the name of the actual target node.
                    NodeName = $primaryNode.fileServerVM
                    # This is used in the configuration to know which resource to compile.
                    Role     = 'FileServer'
                }
                $cd.AllNodes += $fileServer
                $NumberOfNodesAdded = $NumberOfNodesAdded + 1
                $fileServersAdded += $primaryNode.fileServerVM
            }
            $NumberOfNodesAdded = $NumberOfNodesAdded + 2
        }

        $all = @{
            NodeName                    = "*"
            PSDscAllowDomainUser        = $true
            PSDscAllowPlainTextPassword = $true
        }
        $cd.AllNodes += $all

    }

    if ($NumberOfNodesAdded -eq 0) {
        return
    }
    return $cd
}

function Get-Phase6ConfigurationData {
    param (
        [object]$deployConfig
    )

    $dc = $deployConfig.virtualMachines | Where-Object { $_.role -eq "DC" }

    # Configuration Data
    $cd = @{
        AllNodes = @(
            @{
                NodeName = $dc.vmName
                Role     = 'DC'
            }
        )
    }

    $NumberOfNodesAdded = 0
    foreach ($vm in $deployConfig.virtualMachines | Where-Object { $_.Role -eq "WSUS" -or $_.installSUP -eq $true }) {

        $global:preparePhasePercent++

        # Filter out workgroup machines
        if ($vm.role -in "WorkgroupMember", "AADClient", "InternetClient", "OSDClient" , "Linux") {
            continue
        }

        $newItem = @{
            NodeName = $vm.vmName
            Role     = "WSUS"
        }
        $cd.AllNodes += $newItem
        if ($vm.Role -ne "DC") {
            $NumberOfNodesAdded = $NumberOfNodesAdded + 1
        }
    }

    $all = @{
        NodeName                    = "*"
        PSDscAllowDomainUser        = $true
        PSDscAllowPlainTextPassword = $true
    }
    $cd.AllNodes += $all

    if ($NumberOfNodesAdded -eq 0) {
        return
    }

    return $cd
}

function Get-Phase7ConfigurationData {
    param (
        [object]$deployConfig
    )
    $dc = $deployConfig.virtualMachines | Where-Object { $_.role -eq "DC" }

    # Configuration Data
    $cd = @{
        AllNodes = @(
            @{
                NodeName = $dc.vmName
                Role     = 'DC'
            }
        )
    }

    $NumberOfNodesAdded = 0
    foreach ($vm in $deployConfig.virtualMachines | Where-Object { $_.installRP -eq $true }) {

        $global:preparePhasePercent++

        # Filter out workgroup machines
        if ($vm.role -in "WorkgroupMember", "AADClient", "InternetClient", "OSDClient" , "Linux") {
            continue
        }

        $newItem = @{
            NodeName = $vm.vmName
            Role     = "PBIRS"
        }
        $cd.AllNodes += $newItem
        if ($vm.Role -ne "DC") {
            $NumberOfNodesAdded = $NumberOfNodesAdded + 1
        }
    }

    $all = @{
        NodeName                    = "*"
        PSDscAllowDomainUser        = $true
        PSDscAllowPlainTextPassword = $true
    }
    $cd.AllNodes += $all

    if ($NumberOfNodesAdded -eq 0) {
        return
    }

    return $cd
}
function Get-Phase8ConfigurationData {
    param (
        [object]$deployConfig
    )

    $dc = $deployConfig.virtualMachines | Where-Object { $_.role -eq "DC" }
    $NumberOfNodesAdded = 0
    # Configuration Data
    $cd = @{
        AllNodes = @(
            @{
                NodeName = $dc.vmName
                Role     = 'DC'
            }
        )
    }

    if ($deployConfig.cmOptions.Install -ne $false) {

        $fsVMsAdded = @()
        foreach ($vm in $deployConfig.virtualMachines | Where-Object { $_.role -in ("Primary", "CAS", "PassiveSite", "Secondary", "SiteSystem", "WSUS") }) {

            $global:preparePhasePercent++

            if ($vm.Role -eq "WSUS" -and -not $vm.InstallSUP) {
                continue
            }

            $newItem = @{
                NodeName = $vm.vmName
                Role     = $vm.Role
            }
            $cd.AllNodes += $newItem
            $NumberOfNodesAdded = $NumberOfNodesAdded + 1

            if ($vm.PassiveSite) {
                if ($fsVMsAdded -notcontains $vm.remoteContentLibVM) {
                    $newItem = @{
                        NodeName = $vm.remoteContentLibVM
                        Role     = "FileServer"
                    }
                    $fsVMsAdded += $vm.remoteContentLibVM
                    $cd.AllNodes += $newItem
                    $NumberOfNodesAdded = $NumberOfNodesAdded + 1
                }
            }


            if ($vm.RemoteSQLVM) {
                $remoteSQL = $deployConfig.virtualMachines | Where-Object { $_.vmName -eq $vm.RemoteSQLVM }
                $newItem = @{
                    NodeName = $remoteSQL.vmName
                    Role     = "SqlServer"
                }
                if ($cd.AllNodes.NodeName -notcontains $($newItem.NodeName)) {
                    $cd.AllNodes += $newItem
                    $NumberOfNodesAdded = $NumberOfNodesAdded + 1
                }
                if ($remoteSQL.OtherNode) {

                    if ($fsVMsAdded -notcontains $remoteSQL.fileServerVM) {
                        $newItem = @{
                            NodeName = $remoteSQL.fileServerVM
                            Role     = "FileServer"
                        }
                        $fsVMsAdded += $remoteSQL.fileServerVM
                        $cd.AllNodes += $newItem
                        $NumberOfNodesAdded = $NumberOfNodesAdded + 1
                    }

                    $newItem = @{
                        NodeName = $remoteSQL.OtherNode
                        Role     = "SqlServer"
                    }
                    if ($cd.AllNodes.NodeName -notcontains $($newItem.NodeName)) {
                        $cd.AllNodes += $newItem
                        $NumberOfNodesAdded = $NumberOfNodesAdded + 1
                    }
                }
            }
        }

        $all = @{
            NodeName                    = "*"
            PSDscAllowDomainUser        = $true
            PSDscAllowPlainTextPassword = $true
        }
        $cd.AllNodes += $all

    }
    if ($NumberOfNodesAdded -eq 0) {
        return
    }
    return $cd
}