
function Write-JobProgress {
    param($Job)

    #Make sure the first child job exists
    if ($null -ne $Job.ChildJobs[0].Progress) {
        #Extracts the latest progress of the job and writes the progress
        $latestPercentComplete = 0
        $lastProgress = $Job.ChildJobs[0].Progress | Where-Object { $_.Activity -ne "Preparing modules for first use." } | Select-Object -Last 1
        if ($lastProgress) {
            $latestPercentComplete = $lastProgress | Select-Object -expand PercentComplete;
            $latestActivity = $lastProgress | Select-Object -expand Activity;
            $latestStatus = $lastProgress | Select-Object -expand StatusDescription;
            $jobName = $job.Name
            $latestActivity = $latestActivity.Replace("$jobName`: ", "")
        }

        if ($latestActivity -and $latestStatus) {
            #When adding multiple progress bars, a unique ID must be provided. Here I am providing the JobID as this
            if ($latestPercentComplete -gt 0 -and $latestPercentComplete -lt 101) {

            }
            else {
                $latestPercentComplete = 0
            }
            try {
                if ($Common.PS7) {
                    $jobName = "  $($jobName.PadRight(15," "))"
                    # $latestActivity = "$($latestActivity.PadRight($Common.ScreenWidth/2 - 10," "))"
                }
                Write-Progress -Id $Job.Id -Activity "$jobName`: $latestActivity" -Status $latestStatus -PercentComplete $latestPercentComplete;
            }
            catch {}
        }
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
        foreach ($item in $deployConfig.virtualMachines | Where-Object { -not ($_.hidden) } ) {
            if ($existingDC) {
                Remove-DnsRecord -DCName $existingDC -Domain $deployConfig.vmOptions.domainName -RecordToDelete $item.vmName
            }
        }
    }

    # Start Phase
    $start = Start-PhaseJobs -Phase $Phase -deployConfig $deployConfig
    if (-not $start.Applicable) {
        Write-Log "`n [Phase $Phase] Not Applicable. Skipping."
        return $true
    }

    $result = Wait-Phase -Phase $Phase -Jobs $start.Jobs
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
                Failed     = 0
                Success    = 0
                Jobs       = 0
                Applicable = $false
            }
        }

        if ($ConfigurationData.AllNodes.NodeName -contains "LOCALHOST") {
            $multiNodeDsc = $false
        }
    }
    else {
        $multiNodeDsc = $false
    }

    foreach ($currentItem in $deployConfig.virtualMachines) {

        # Don't touch non-hidden VM's in Phase 0
        if ($Phase -eq 0 -and -not $currentItem.hidden) {
            continue
        }

        # Don't touch hidden VM's in Phase 1
        if ($Phase -eq 1 -and $currentItem.hidden) {
            continue
        }

        # Skip everything for OSDClient, nothing for us to do
        if ($Phase -gt 1 -and $currentItem.role -eq "OSDClient") {
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

        $jobName = $currentItem.vmName

        if ($Phase -eq 0 -or $Phase -eq 1) {
            # Create/Prepare VM
            $job = Start-Job -ScriptBlock $global:VM_Create -Name $jobName -ErrorAction Stop -ErrorVariable Err
            if (-not $job) {
                Write-Log "[Phase $Phase] Failed to create job for VM $($currentItem.vmName). $Err" -Failure
                $job_created_no++
            }
        }
        else {
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

    # Create return object
    $return = [PSCustomObject]@{
        Failed     = $job_created_no
        Success    = $job_created_yes
        Jobs       = $jobs
        Applicable = $true
    }

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
        $Jobs
    )

    # Create return object
    $return = [PSCustomObject]@{
        Failed  = 0
        Success = 0
        Warning = 0
    }

    # Add VM's that started jobs in phase 1 (VM Creation) to global remove list.
    $global:vm_remove_list = @()
    if ($Phase -eq 1) {
        foreach ($job in $jobs) {
            $jobName = $job | Select-Object -ExpandProperty Name
            $global:vm_remove_list += $jobName
        }
    }

    $FailRetry = 0
    do {

        $runningJobs = $jobs | Where-Object { $_.State -ne "Completed" -and - $_State -ne "Failed" } | Sort-Object -Property Id
        foreach ($job in $runningJobs) {
            Write-JobProgress($job)
        }

        $failedJobs = $jobs | Where-Object { $_.State -eq "Failed" } | Sort-Object -Property Id
        foreach ($job in $failedJobs) {
            $FailRetry = $FailRetry + 1
            if ($FailRetry -gt 30) {
                $jobOutput = $job | Select-Object -ExpandProperty childjobs | Select-Object -ExpandProperty Error
                $jobJson = $job | convertTo-Json -depth 5
                Write-Log "[Phase $Phase] Job failed: $jobJson" -LogOnly
                Write-RedX "[Phase $Phase] Job failed: $jobOutput" -ForegroundColor Red
                Write-Progress -Id $job.Id -Activity $job.Name -Completed
                $jobs.Remove($job)

                $return.Failed++
            }
        }
        $completedJobs = $jobs | Where-Object { $_.State -eq "Completed" } | Sort-Object -Property Id
        foreach ($job in $completedJobs) {

            Write-JobProgress($job)

            $jobOutput = $job | Select-Object -ExpandProperty childjobs | Select-Object -ExpandProperty Output
            if (-not $jobOutput) {
                $jobName = $job | Select-Object -ExpandProperty Name
                Write-RedX "[Phase $Phase] Job $jobName completed with no output" -ForegroundColor Red
                $jobJson = $job | ConvertTo-Json -Depth 5
                write-log -LogOnly $jobJson
                $return.Failed++
            }

            $incrementCount = $true
            foreach ($line in $jobOutput) {
                $line = $line.ToString().Trim()

                if ($line.StartsWith("ERROR")) {
                    Write-RedX $line -ForegroundColor Red
                    if ($incrementCount) {
                        $return.Failed++
                    }
                }
                elseif ($line.StartsWith("WARNING")) {
                    Write-OrangePoint $line -ForegroundColor Yellow
                    if ($incrementCount) { $return.Warning++ }
                }
                else {
                    if ($line.StartsWith("SUCCESS")) {
                        Write-GreenCheck $line -ForegroundColor Green
                    }
                    else {
                        Write-GreenCheck $line -ForegroundColor White
                    }
                    # Assume no error/warning was a success
                    if ($incrementCount) { $return.Success++ }
                }

                $incrementCount = $false
            }

            Write-Progress -Id $job.Id -Activity $job.Name -Completed
            $jobs.Remove($job)
        }

        # Sleep
        Start-Sleep -Seconds 1

    } until (($runningJobs.Count -eq 0) -and ($failedJobs.Count -eq 0))
    return $return
}

function Get-ConfigurationData {
    param (
        [int]$Phase,
        [object]$deployConfig
    )

    $netbiosName = $deployConfig.vmOptions.domainName.Split(".")[0]
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
        Default { return }
    }
    if ($global:Common.VerboseEnabled) {
        $cd | ConvertTo-Json | out-host
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

    return $cd
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

        # Filter out workgroup machines
        if ($vm.role -in "WorkgroupMember", "AADClient", "InternetClient", "OSDClient") {
            continue
        }

        $newItem = @{
            NodeName = $vm.vmName
            Role     = $vm.Role
        }
        $cd.AllNodes += $newItem
        $NumberOfNodesAdded = $NumberOfNodesAdded + 1
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
    foreach ($vm in $deployConfig.virtualMachines | Where-Object { $_.SqlVersion -or $_.Role -eq "DC" }) {

        # Filter out workgroup machines
        if ($vm.role -in "WorkgroupMember", "AADClient", "InternetClient", "OSDClient") {
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

    $primaryNodes = $deployConfig.virtualMachines | Where-Object { $_.role -eq "SQLAO" -and $_.OtherNode }
    $netbiosName = $deployConfig.vmOptions.domainName.Split(".")[0]
    $domainNameSplit = ($deployConfig.vmOptions.domainName).Split(".")
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

    if ($deployConfig.cmOptions.Install) {

        foreach ($vm in $deployConfig.virtualMachines | Where-Object { $_.role -in ("Primary", "CAS", "PassiveSite", "Secondary") }) {
            $newItem = @{
                NodeName = $vm.vmName
                Role     = $vm.Role
            }
            $cd.AllNodes += $newItem
            $NumberOfNodesAdded = $NumberOfNodesAdded + 1
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