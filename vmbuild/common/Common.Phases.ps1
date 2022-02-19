
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
                Write-Progress -Id $Job.Id -Activity "$jobName`: $latestActivity" -Status $latestStatus -PercentComplete $latestPercentComplete;
            }
            catch {}
        }
    }
}

function Start-Phase {

    param(
        [int]$Phase,
        [object]$deployConfig
    )

    switch ($Phase) {
        0 {
            Write-Log "Phase $Phase - Preparing existing Virtual Machines" -Activity
        }

        1 {
            Write-Log "Phase $Phase - Creating Virtual Machines" -Activity
        }

        2 {
            Write-Log "Phase $Phase - Setup and Join Domain" -Activity
        }

        3 {
            Write-Log "Phase $Phase - Configure Virtual Machine" -Activity
        }

        4 {
            Write-Log "Phase $Phase - Install SQL" -Activity
        }

        5 {
            Write-Log "Phase $Phase - Configuring SQL Always On" -Activity
        }

        6 {
            Write-Log "Phase $Phase - Setup ConfigMgr" -Activity
        }
    }

    # Start Phase
    $start = Start-PhaseJobs -Phase $Phase -deployConfig $deployConfig
    if (-not $start.Applicable) {
        Write-Log "`n Phase $Phase was not found applicable. Skipping."
        return $true
    }

    $result = Wait-Phase -Phase $Phase -Jobs $start.Jobs
    Write-Log "`n$($result.Success) Phase $Phase jobs completed successfully; $($result.Warning) warnings, $($result.Failed) failures."

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

    # Track all VM's for removal, if failures encountered
    $global:vm_remove_list = @()

    foreach ($currentItem in $deployConfig.virtualMachines) {

        # Don't touch non-hidden VM's in Phase 0
        if ($Phase -eq 0 -and -not $currentItem.hidden) {
            continue
        }

        # Don't touch hidden VM's in Phase 1
        if ($Phase -eq 1 -and $currentItem.hidden) {
            continue
        }

        # Add non-hidden VM's to removal list, in case Phase 1 fails. TODO: Re-evaluate phase
        if ($Phase -eq 1 -and -not $currentItem.hidden) {
            $global:vm_remove_list += $currentItem.vmName
        }

        # Skip everything for OSDClient, nothing for us to do
        if ($Phase -gt 1 -and $currentItem.role -eq "OSDClient") {
            continue
        }

        # Skip multi-node DSC (& monitoring) for all machines except those in the ConfigurationData.AllNodes
        if ($multiNodeDsc -and $currentItem.vmName -notin $ConfigurationData.AllNodes.NodeName) {
            continue
        }

        $deployConfigCopy = ConvertTo-DeployConfigEx -deployConfig $deployConfig
        $deployConfigCopy.parameters.ThisMachineName = $currentItem.vmName
        Add-PerVMSettings -deployConfig $deployConfigCopy -thisVM $currentItem

        if ($WhatIf) {
            Write-Log "Will start a Phase $Phase job for VM $($currentItem.vmName)"
            continue
        }

        $jobName = $currentItem.vmName

        if ($Phase -eq 0 -or $Phase -eq 1) {
            # Create/Prepare VM
            $job = Start-Job -ScriptBlock $global:VM_Create -Name $jobName -ErrorAction Stop -ErrorVariable Err
            if (-not $job) {
                Write-Log "Failed to create Phase $Phase job for VM $($currentItem.vmName). $Err" -Failure
                $job_created_no++
            }
        }
        else {
            $job = Start-Job -ScriptBlock $global:VM_Config -Name $jobName -ErrorAction Stop -ErrorVariable Err
            if (-not $job) {
                Write-Log "Failed to create Phase $Phase job for VM $($currentItem.vmName). $Err" -Failure
                $job_created_no++
            }
        }

        if ($Err.Count -ne 0) {
            Write-Log "Failed to start Phase $Phase job for VM $($currentItem.vmName). $Err" -Failure
            $job_created_no++
        }
        else {
            Write-Log "Created Phase $Phase job $($job.Id) for VM $($currentItem.vmName)" -LogOnly
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
        Write-Log "Created $job_created_yes jobs for Phase $Phase. Waiting for jobs."
    }
    else {
        Write-Log "Created $job_created_yes jobs for Phase $Phase. Failed to create $job_created_no jobs."
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
                Write-Log "Job failed: $jobJson" -LogOnly
                Write-RedX "Job failed: $jobOutput" -ForegroundColor Red
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
                Write-RedX "Job $jobName completed with no output" -ForegroundColor Red
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
        write-Log -Failure "Could not get Netbios name from 'deployConfig.vmOptions.domainName' "
        return
    }

    switch ($Phase) {
        "2" { $cd = Get-Phase2ConfigurationData -deployConfig $deployConfig }
        "3" { $cd = Get-Phase3ConfigurationData -deployConfig $deployConfig }
        "5" { $cd = Get-AOandSCCMConfigurationData -deployConfig $deployConfig }
        Default { return }
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

    #TODO: Fix this after implementing Phase 3
    return $null
    return $cd
}

function Get-AOandSCCMConfigurationData {
    param (
        [object]$deployConfig
    )

    $primaryNode = $deployConfig.virtualMachines | Where-Object { $_.role -eq "SQLAO" -and $_.OtherNode }
    $netbiosName = $deployConfig.vmOptions.domainName.Split(".")[0]
    $domainNameSplit = ($deployConfig.vmOptions.domainName).Split(".")

    $NumberOfNodesAdded = 0
    # Configuration Data
    $cd = @{
        AllNodes = @(
            @{
                NodeName = $currentItem.vmName
                Role     = 'DC'
            }
        )
    }

    if ($primaryNode) {
        $SqlAgentServiceAccount = $netbiosName + "\" + $deployConfig.SQLAO.SqlAgentServiceAccount
        $SqlServiceAccount = $netbiosName + "\" + $deployConfig.SQLAO.SqlServiceAccount
        if (-not $primaryNode.fileServerVM) {
            write-Log -Failure "Could not get fileServerVM name from primaryNode.fileServerVM"
            return
        }

        $ADAccounts = @()
        $ADAccounts += $primaryNode.vmName + "$"
        $ADAccounts += $primaryNode.OtherNode + "$"
        $ADAccounts += $primaryNode.ClusterName + "$"

        $ADAccounts2 = @()
        $ADAccounts2 += $($domainNameSplit[0]) + "\" + $primaryNode.vmName + "$"
        $ADAccounts2 += $($domainNameSplit[0]) + "\" + $primaryNode.OtherNode + "$"
        $ADAccounts2 += $($domainNameSplit[0]) + "\" + $primaryNode.ClusterName + "$"
        $ADAccounts2 += $($domainNameSplit[0]) + "\" + $deployConfig.vmOptions.adminName

        #$siteServer = $deployConfig.virtualMachines | Where-Object { $_.remoteSQLVM -eq $primaryNode.vmName }
        #$db_name = $null
        #if ($siteServer -and ($deployConfig.cmOptions.install)) {
        #    $db_name = "CM_" + $siteServer.SiteCode
        #}
        $primary = @{
            # Replace with the name of the actual target node.
            NodeName        = $primaryNode.vmName

            # This is used in the configuration to know which resource to compile.
            Role            = 'ClusterNode1'
            CheckModuleName = 'SqlServer'
            Address         = $deployConfig.vmOptions.network
            AddressMask     = '255.255.255.0'
            Name            = 'Domain Network'
            Address2        = '10.250.250.0'
            AddressMask2    = '255.255.255.0'
            Name2           = 'Cluster Network'
            InstanceName    = $primaryNode.sqlInstanceName

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
        $NumberOfNodesAdded = $NumberOfNodesAdded + 2
        $all = @{
            NodeName                    = "*"
            PSDscAllowDomainUser        = $true
            PSDscAllowPlainTextPassword = $true
            ClusterName                 = $primaryNode.ClusterName
            ClusterIPAddress            = $deployConfig.SQLAO.ClusterIPAddress + "/24"
            AGIPAddress                 = $deployConfig.SQLAO.AGIPAddress + "/255.255.255.0"
            PrimaryReplicaServerName    = $primaryNode.vmName + "." + $deployConfig.vmOptions.DomainName
            SecondaryReplicaServerName  = $primaryNode.OtherNode + "." + $deployConfig.vmOptions.DomainName
            SqlAgentServiceAccount      = $SqlAgentServiceAccount
            SqlServiceAccount           = $SqlServiceAccount
            ClusterNameAoG              = $deployConfig.SQLAO.AlwaysOnName
            ClusterNameAoGFQDN          = $deployConfig.SQLAO.AlwaysOnName + "." + $deployConfig.vmOptions.DomainName
            WitnessShare                = "\\" + $primaryNode.fileServerVM + "\" + $deployConfig.SQLAO.WitnessShare
            BackupShare                 = "\\" + $primaryNode.fileServerVM + "\" + $deployConfig.SQLAO.BackupShare
            #Dont pass DBName, or DSC will create the database and add it to Ao.. In this new method, we install SCCM direct to AO
            #DBName                      = $db_name
            #ClusterIPAddress            = '10.250.250.30/24'
        }
        $cd.AllNodes += $all

    }

    foreach ($vm in $deployConfig.virtualMachines | Where-Object { $_.role -in ("Primary", "CAS", "PassiveSite", "Secondary") }) {
        $newItem = @{
            NodeName = $vm.vmName
            Role     = $vm.Role
        }
        $cd.AllNodes += $newItem
        $NumberOfNodesAdded = $NumberOfNodesAdded + 1
    }

    if (-not $primaryNode) {
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