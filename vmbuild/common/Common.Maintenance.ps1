
function Start-Maintenance {

    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false, HelpMessage = "If present, maintenance runs only for machines in DeployConfig")]
        [object]$DeployConfig
    )

    $applyNewOnly = $false
    if ($DeployConfig) {
        Write-log "Start-Maintenance called with DeployConfig"
        $allVMs = $DeployConfig.virtualMachines | Where-Object { -not $_.hidden }
        $vmsNeedingMaintenance = $DeployConfig.virtualMachines | Where-Object { -not $_.hidden } | Sort-Object vmName
        $applyNewOnly = $true
    }
    else {
        Write-log -verbose "Start-Maintenance called without DeployConfig"
        $allVMs = Get-List -Type VM | Where-Object { $_.vmBuild -eq $true -and $_.inProgress -ne $true }
        $vmsNeedingMaintenance = $allVMs | Where-Object { -not $_.memLabsVersion -or $_.memLabsVersion -lt $Common.LatestHotfixVersion } | Sort-Object vmName
    }

    Write-Log -Verbose "Latest Hotfix Version: $($Common.LatestHotfixVersion)"
    $countWorked = $countFailed = $countSkipped = 0
    # Filter in-progress
    $vmsNeedingMaintenance = $vmsNeedingMaintenance | Where-Object { $_.inProgress -ne $true -and -not ($_.Role -in @("OSDClient", "Linux", "AADClient")) }
    $newVmsNeedingMaintenance = @()
    foreach ($vm in $vmsNeedingMaintenance) {
        Write-Log -Verbose "VM Name: $($vm.vmName) Version: $($vm.memLabsVersion)"
        $mutexName = $vm.vmName

        try {
            $Mutex = [System.Threading.Mutex]::OpenExisting($MutexName)
        }
        catch {
            Write-Log -Verbose "Mutex $mutexName does not exist.. VM not in use."
            #Mutex does not exist.
            $newVmsNeedingMaintenance = $newVmsNeedingMaintenance + $vm
            continue
        }
        if ($Mutex) {
            Write-Log -Verbose "Mutex $mutexName exists.. VM in use."
            $countSkipped++
            try {
                [void]$Mutex.ReleaseMutex()
            }
            catch {}
        }
    }
    $vmCount = ($newVmsNeedingMaintenance | Measure-Object).Count
    $countNotNeeded = $allVMs.Count - $vmCount

    $text = "Performing maintenance"
    $maintenanceDoNotStart = $false
    Write-Log $text -Activity
    $stoppedCount = 0
    $stoppedVms = @()
    if ($applyNewOnly -eq $false) {
        if ($vmCount -gt 0) {
            $response = Read-YesorNoWithTimeout -Prompt "$($newVmsNeedingMaintenance.Count) VM(s) [$($newVmsNeedingMaintenance.vmName -join ",")] need memlabs maintenance. Run now? (y/N)" -HideHelp -Default "n" -timeout 15
            if ($response -eq "n") {
                return
            }
            foreach ($vm in $newVmsNeedingMaintenance) {
                if ($vm.State -ne "Running") {
                    $stoppedCount++
                    $stoppedVms += $vm.vmName                
                }
            }
            if ($stoppedCount -gt 0) {
                $response = Read-YesorNoWithTimeout -Prompt "$stoppedCount VMs stopped. Start [$($stoppedVms-join ",")] for Maintenance (y/N)" -HideHelp -Default "n" -timeout 15
                if ($response -eq "y") {
                    Write-Log "$vmCount VM's need maintenance. VM's will be started (if stopped) and shut down post-maintenance."
                }
                else {
                    Write-Log "$vmCount VM's need maintenance. VM's will NOT be started (if stopped)."
                    $maintenanceDoNotStart = $true
                }
            }
        }
        else {
            Write-Log "No maintenance required." -Success
            return
        }
    }

    foreach ($vm in $newVmsNeedingMaintenance) {
        if ($maintenanceDoNotStart) {
            if ($vm.State -ne "Running") {
                $newVmsNeedingMaintenance = $newVmsNeedingMaintenance | Where-Object { $_.vmName -ne $vm.vmName }
                $countSkipped++
                continue
            }
        }
    }

    $start = Start-NormalJobs -machines $newVmsNeedingMaintenance -ScriptBlock $global:Phase10Job -Phase "Maintenance"

    $result = Wait-Phase -Phase "Maintenance" -Jobs $start.Jobs -AdditionalData $start.AdditionalData

    #foreach ($vm in $newVmsNeedingMaintenance | Where-Object { $_.role -eq "DC" }) {
    #    $i++
    #    Write-Progress2 -Id $progressId -Activity $text -Status "Performing maintenance on VM $i/$vmCount`: $($vm.vmName)" -PercentComplete (($i / $vmCount) * 100)
    #    $worked = Start-VMMaintenance -VMName $vm.vmName -ApplyNewOnly:$applyNewOnly
    #    if ($worked) { $countWorked++ } else {
    #        $failedDomains += $vm.domain
    #        $countFailed++
    #    }
    #}

    $countWorked = $result.Success
    $countFailed = $result.Failed
          

    Write-Host
    Write-Log "Finished maintenance. Success: $countWorked; Failures: $countFailed; Skipped: $countSkipped; Already up-to-date: $countNotNeeded" -SubActivity
    Start-Sleep -seconds 3
    clear-host

    if ($global:MaintenanceActivity) {
        Write-Progress2 -Activity $global:MaintenanceActivity -Completed
    }
}

function Show-FailedDomains {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Failed Domains")]
        [object] $failedDomains
    )

    $failedDCs = Get-List -Type VM | Where-Object { $_.role -eq "DC" -and $_.domain -in $failedDomains }
    $dcList = ($failedDCs | Select-Object vmName, domain, @{Name = "accountsToUpdate"; Expression = { @("vmbuildadmin", $_.adminName, "cm_svc") } }, @{ Name = "desiredPassword"; Expression = { $($Common.LocalAdmin.GetNetworkCredential().Password) } } | Out-String).Trim()
    $dcList = $dcList -split "`r`n"

    Write-Log "Displaying the failed domains message for ($($failedDomains -join ','))." -LogOnly

    $longest = 130
    $longestMinus1 = $longest - 1
    $longestMinus2 = $longest - 2

    Write-Host
    Write-Host2 "  #".PadRight($longest, "#") -ForegroundColor Yellow
    Write-Host2 "  # DC Maintenance failed for below domains. This may be because the passwords for the required accounts (listed below) expired. #" -ForegroundColor Yellow
    Write-Host2 ("  #".PadRight($longestMinus1, " ") + "#") -ForeGroundColor Yellow
    foreach ($line in $dcList) {
        $newLine = $line -replace '\x1b\[[0-9;]*m'
        Write-Host2 -ForegroundColor Yellow "  #" -NoNewLine
        #subtract the 3 chars displayed above
        $Len = $longestMinus1 - 3
        Write-Host2 " $newLine".PadRight($len, " ").Replace($newLine, $line) -ForegroundColor Turquoise -NoNewLine
        Write-Host2 -ForeGroundColor Yellow "#"
    }
    Write-Host2 ("  #".PadRight($longestMinus1, " ") + "#") -ForegroundColor Yellow
    Write-Host2 ("  # Please perform manual remediation steps listed below to keep VMBuild functional.".PadRight($longestMinus1, " ") + "#") -ForegroundColor Yellow
    Write-Host2 ("  #".PadRight($longestMinus1, " ") + "#") -ForegroundColor Yellow
    Write-Host2 ("  # 1. Logon to the affected DC's using Hyper-V console.".PadRight($longestMinus1, " ") + "#") -ForegroundColor Yellow
    Write-Host2 ("  # 2. Launch 'AD Users and Computers', and reset the account for the above listed accounts to the desiredPassword.".PadRight($longestMinus1, " ") + "#") -ForegroundColor Yellow
    Write-Host2 ("  # 3. Run 'VMBuild.cmd' again.".PadRight($longestMinus1, " ") + "#") -ForegroundColor Yellow
    Write-Host2 ("  #".PadRight($longestMinus1, " ") + "#") -ForegroundColor Yellow
    Write-Host2 ("  # If the password hasn't expired/changed, re-run VMBuild.cmd in case there was a transient issue.".PadRight($longestMinus1, " ") + "#") -ForegroundColor Yellow
    Write-Host2 ("  # If the issue persists, please report it.".PadRight($longestMinus1, " ") + "#") -ForegroundColor Yellow
    Write-Host2 ("  #".PadRight($longestMinus1, " ") + "#") -ForegroundColor Yellow
    Write-Host2 "  #".PadRight($longest, "#") -ForegroundColor Yellow

}

function Start-VMMaintenance {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "VMName")]
        [object] $VMName,
        [Parameter(Mandatory = $false, HelpMessage = "Apply fixes applicable to new")]
        [switch] $ApplyNewOnly
    )

    Write-Log "Starting maintenance for VM: $VMName"

    $vmNoteObject = Get-VMNote -VMName $VMName

    if (-not $vmNoteObject) {
        Write-Log "$vmName`: VM Notes property could not be read. Skipping." -Warning
        return $false
    }

    $global:MaintenanceActivity = $VMName
    $latestFixVersion = $Common.LatestHotfixVersion
    $inProgress = if ($vmNoteObject.inProgress) { $true } else { $false }
    $vmVersion = $vmNoteObject.memLabsVersion

    # This should never happen, since parent filters these out. Leaving just-in-case.
    if ($inProgress) {
        Write-Log "$vmName`: VM Deployment State is in-progress. Skipping." -Warning
        return $false
    }

    # This should never happen, unless Get-List provides outdated version, so check again with current VMNote object
    if ($vmVersion -ge $latestFixVersion -and -not $ApplyNewOnly.IsPresent) {
        Write-Progress2 -Log -PercentComplete 0 -Activity $global:MaintenanceActivity -Status "VM Version ($vmVersion) is up-to-date."
        return $true
    }

    if ($ApplyNewOnly.IsPresent) {
        Write-Progress2 -Log -PercentComplete 0 -Activity $global:MaintenanceActivity -Status  "Newly deployed VM is NOT up-to-date. Required Hotfix Version is $latestFixVersion. Performing maintenance..."
    }
    else {
        Write-Progress2 -Log -PercentComplete 0 -Activity $global:MaintenanceActivity -Status  "VM (version $vmVersion) is NOT up-to-date. Required Hotfix Version is $latestFixVersion. Performing maintenance..."
    }

    if ($ApplyNewOnly.IsPresent) {
        $vmFixes = Get-VMFixes -VMName $VMName | Where-Object { $_.AppliesToNew -eq $true }
    }
    else {
        $vmFixes = Get-VMFixes -VMName $VMName | Where-Object { $_.AppliesToExisting -eq $true }
    }

    $worked = Start-VMFixes -VMName $VMName -VMFixes $vmFixes -ApplyNewOnly:$ApplyNewOnly

    if ($worked) {
        Write-Progress2 -Log -PercentComplete 0 -Activity $global:MaintenanceActivity -Status  "VM maintenance completed successfully."
        Set-VMNote -vmName $VMName -vmVersion ([string]$latestFixVersion) -forceVersionUpdate
        $logoffusers = {
            try {
                query user 2>&1 | Select-Object -skip 1 | ForEach-Object {
                    logoff ($_ -split "\s+")[-6]
                }
            }
            catch {}
        }
        try {
            if ($ApplyNewOnly.IsPresent) {
                Invoke-VmCommand -VmName $VMName -VmDomainName $vmNoteObject.domain -ScriptBlock $logoffusers
            }
        }
        catch {}
    }
    else {
        Write-Log "$VMName`: VM maintenance failed. Review VMBuild.log." -Failure
        Show-Notification -ToastText "$VMName`: VM maintenance failed. Review VMBuild.log." -ToastTag $VMName
    }

    return $worked
}

function Start-VMFixes {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "VMName")]
        [string] $VMName,
        [Parameter(Mandatory = $true, HelpMessage = "VMFixes")]
        [object] $VMFixes,
        [Parameter(Mandatory = $false, HelpMessage = "SkipVMShutdown")]
        [switch] $SkipVMShutdown,
        [Parameter(Mandatory = $false, HelpMessage = "Apply fixes applicable to new")]
        [switch] $ApplyNewOnly
    )

    Write-Progress2 -Log -PercentComplete 0 -Activity $global:MaintenanceActivity -Status "Applying fixes to the virtual machine."

    $success = $false
    $toStop = @()

    $rootPath = Split-Path $PSScriptRoot -Parent

    $vmNote = Get-VMNote -VMName $vmName
    $vmDomain = $vmNote.domain

    if (-not $vmDomain) {
        Write-log "No domain found in VMNote for $vmName.. assuming unmanaged. Return true" -LogOnly
        return $true
    }

    $HashArguments = @{
        VmName       = $vmName
        VMDomainName = $vmDomain
        DisplayName  = "Testing for Memlabs files"
        ScriptBlock  = {Test-Path "C:\Staging"}
    }

    $result = Invoke-VmCommand @HashArguments -ShowVMSessionError -CommandReturnsBool
    if ($result.ScriptBlockOutput -eq $false) {
        Write-Log "C:\Staging not found in vm $VMName.  Machine may no longer be managed by MemLabs.  Returning success." -Success -OutputStream
        return $true
    }

    $copyResults = Copy-ItemSafe -VmName $vmName -VMDomainName $vmDomain -Path "$rootPath\DSC" -Destination "C:\staging" -Recurse -Container -Force

    foreach ($vmFix in $VMFixes | Sort-Object FixVersion ) {
        $status = Start-VMFix -vmName $VMName -vmFix $vmFix -ApplyNewOnly:$ApplyNewOnly
        $toStop += $status.VMsToStop
        $success = $status.Success
        if (-not $success) {
            $resetVersion = [int]($vmFix.FixVersion) - 1
            Set-VMNote -vmName $VMName -vmVersion ([string]$resetVersion) -forceVersionUpdate
            break
        }
    }

    if ($toStop.Count -ne 0 -and -not $SkipVMShutdown.IsPresent) {
        foreach ($vm in $toStop) {
            if ([string]::isnullorwhitespace($vm)) {
                continue
            }
            $vmNote = Get-VMNote -VMName $vm
            if ($vmNote.role -ne "DC") {
                Write-Progress2 -Activity $global:MaintenanceActivity -Status  "Shutting down VM "
                Stop-Vm2 -Name $vm -retryCount 5 -retrySeconds 3
            }
        }
    }

    return $success
}

function Start-VMFix {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "vmName")]
        [string] $vmName,
        [Parameter(Mandatory = $true, HelpMessage = "vmFix")]
        [object] $vmFix,
        [Parameter(Mandatory = $false, HelpMessage = "Apply fixes applicable to new")]
        [switch] $ApplyNewOnly
    )

    $return = [PSCustomObject]@{
        Success   = $false
        VMsToStop = @()
    }

    # Get current VM note to ensure we don't have outdated version
    $vmNote = Get-VMNote -VMName $vmName
    $vmDomain = $vmNote.domain

    # Check applicability
    $fixName = $vmFix.FixName
    $fixVersion = $vmFix.FixVersion

    if ($vmNote.memLabsVersion -ge $fixVersion -and -not $ApplyNewOnly.IsPresent) {
        Write-Progress2 -Log -PercentComplete 0 -Activity $global:MaintenanceActivity -Status "Fix '$fixName' ($fixVersion) has been applied already."
        $return.Success = $true
        return $return
    }

    if (-not $vmFix.AppliesToThisVM) {
        Write-Progress2 -Log -PercentComplete 0 -Activity $global:MaintenanceActivity -Status "Fix '$fixName' ($fixVersion) is not applicable. Updating version to '$fixVersion'"
        Set-VMNote -VMName $vmName -vmVersion $fixVersion
        $return.Success = $true
        return $return
    }

    Write-Progress2 -Log -PercentComplete 0 -Activity $global:MaintenanceActivity -Status "Fix '$fixName' ($fixVersion) is applicable. Applying fix now."

    # Start dependent VM's
    if ($vmFix.DependentVMs) {
        $dependentVMs = $vmFix.DependentVMs
        Write-Progress2 -Log -PercentComplete 0 -Activity $global:MaintenanceActivity -Status "Fix '$fixName' ($fixVersion) requires '$($dependentVMs -join ',')' to be running."
        foreach ($vm in $dependentVMs) {
            if ([string]::IsNullOrWhiteSpace($vm)) { continue }
            $note = Get-VMNote -VMName $vm
            $status = Start-VMIfNotRunning -VMName $vm -VMDomain $note.domain -WaitForConnect -Quiet
            if ($status.StartedVM) {
                $return.VMsToStop += $vm
            }

            if ($status.StartFailed) {
                return $return
            }
        }
    }
    Write-Progress2 -Log -PercentComplete 0 -Activity $global:MaintenanceActivity -Status "Fix '$fixName' Starting $VMName."
    # Start VM to apply fix
    $status = Start-VMIfNotRunning -VMName $VMName -VMDomain $vmDomain -WaitForConnect -Quiet
    if ($status.StartedVM) {
        $return.VMsToStop += $VMName
    }

    if ($status.StartFailed) {
        return $return
    }
    
    # Apply Fix
    $HashArguments = @{
        VmName       = $VMName
        VMDomainName = $vmDomain
        DisplayName  = $fixName
        ScriptBlock  = $vmFix.ScriptBlock
    }

    if ($vmFix.ArgumentList) {
        $HashArguments.Add("ArgumentList", $vmFix.ArgumentList)
    }

    if ($vmFix.RunAsAccount) {
        $HashArguments.Add("VmDomainAccount", $vmFix.RunAsAccount)
    }

    start-sleep -Milliseconds 200
    Write-Progress2 -Log -PercentComplete 0 -Activity $global:MaintenanceActivity -Status "Fix '$fixName' Connecting to $VMName"
    if ($vmFix.InjectFiles) {
        try {
            $ps = Get-VmSession -VmName $VMName -VmDomainName $vmDomain
            foreach ($file in $vmFix.InjectFiles) {
                $sourcePath = Join-Path $Common.StagingInjectPath "staging\$file"
                $targetPathInVM = "C:\staging\$file"
                Write-Progress2 -Log -PercentComplete 0 -Activity $global:MaintenanceActivity -Status "Copying $file to the VM [$targetPathInVM]..."
                Copy-Item -ToSession $ps -Path $sourcePath -Destination $targetPathInVM -Force -ErrorAction Stop
            }
        }
        catch {
            Write-Log "$VMName`: Failed to copy files for fix '$fixName' ($fixVersion)." -Warning
            $return.Success = $false
            return $return
        }
    }

    start-sleep -Milliseconds 200
    Write-Progress2 -Log -PercentComplete 0 -Activity $global:MaintenanceActivity -Status "Fix '$fixName' Starting ScriptBlock on $VMName"
    $result = Invoke-VmCommand @HashArguments -ShowVMSessionError -CommandReturnsBool
    if ($result.ScriptBlockFailed -or $result.ScriptBlockOutput -eq $false) {
        Write-Log "$VMName`: Fix '$fixName' ($fixVersion) failed to be applied." -Warning
        $return.Success = $false
        # if ($Common.VerboseEnabled) {
        #     $pull_Transcript = {
        #         $filePath = "C:\staging\Fix\$($using:fixName).txt"
        #         if (Test-Path $filePath) {
        #             Get-Content -Path $filePath -ErrorAction SilentlyContinue -Force
        #         }
        #     }
        #     $HashArguments2 = @{
        #         VmName       = $VMName
        #         VMDomainName = $vmDomain
        #         DisplayName  = "Pull-Fix-Transcript"
        #         ScriptBlock  = $pull_Transcript
        #     }
        #     $result2 = Invoke-VmCommand @HashArguments2 -SuppressLog
        #     if (-not $result2.ScriptBlockFailed) { $result2.ScriptBlockOutput | Out-Host }
        # }
    }
    else {
        Write-Progress2 -Log -PercentComplete 0 -Activity $global:MaintenanceActivity -Status "Fix '$fixName' ($fixVersion) applied. Updating version to $fixVersion."
        Set-VMNote -vmName $VMName -vmVersion $fixVersion
        $return.Success = $true
    }

    return $return
}

function Start-VMIfNotRunning {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "VM Name")]
        [string] $VMName,
        [Parameter(Mandatory = $true, HelpMessage = "VM Domain")]
        [string] $VMDomain,
        [Parameter(Mandatory = $false, HelpMessage = "Wait for VM to be connectable")]
        [switch] $WaitForConnect,
        [Parameter(Mandatory = $false, HelpMessage = "Quiet - No logging when VM is already running")]
        [switch] $Quiet
    )

    $return = [PSCustomObject]@{
        StartedVM     = $false
        StartFailed   = $false
        ConnectFailed = $false
    }


    $vm = Get-VM2 -Name $VMName -ErrorAction SilentlyContinue

    Write-Log -verbose "Starting $vmName if not running"

    if (-not $vm) {
        Write-Log "$VMName`: Failed to get VM from Hyper-V. Error: $_" -Warning
        $return.StartFailed = $true
        $return.ConnectFailed = $true
        return $return
    }

    if ($vm.State -ne "Running") {
        Write-Progress2 -Log -PercentComplete 0 -Activity $global:MaintenanceActivity -Status "Starting VM for maintenance and waiting for it to be ready to connect."
        $started = Start-VM2 -Name $VMName -Passthru
        if ($started) {
            $return.StartedVM = $true
            if ($WaitForConnect.IsPresent) {
                Write-Log -verbose "Waiting to connect to $vmName"
                $connected = Wait-ForVM -VmName $VMname -PathToVerify "C:\Users" -VmDomainName $VMDomain -TimeoutMinutes 2 -Quiet
                if (-not $connected) {
                    Write-Progress2 -Log -PercentComplete 0 -Activity $global:MaintenanceActivity -Status "Could not connect to the VM after waiting for 2 minutes."
                    $return.ConnectFailed = $true
                }
            }
        }
        else {
            $return.StartFailed = $true
            $return.ConnectFailed = $true
        }
    }
    else {
        if (-not $Quiet.IsPresent) { Write-Progress2 -Log -PercentComplete 0 -Activity $global:MaintenanceActivity -Status "VM is already running." }
    }
    Write-Log -verbose "Starting $vmName Completed. $return"
    return $return
}

function Get-VMFixes {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "VMName", ParameterSetName = "Real")]
        [object] $VMName,
        [Parameter(Mandatory = $true, HelpMessage = "VMName", ParameterSetName = "Dummy")]
        [switch] $ReturnDummyList
    )

    if ($ReturnDummyList.IsPresent) {
        $vmNote = $null
    }
    else {
        $vmNote = Get-VMNote -VMName $VMName
        $dc = Get-List -Type VM | Where-Object { $_.role -eq "DC" -and $_.domain -eq $vmNote.domain }
    }

    $fixesToPerform = @()
    ### Domain account password expiration

    #region Fix-DomainAccounts

    $Fix_DomainAccount = {
        param ($accountName)
        if (-not (Test-Path "C:\staging\Fix")) { New-Item -Path "C:\staging\Fix" -ItemType Directory -Force | Out-Null }
        $transcriptPath = "C:\staging\Fix\Fix-DomainAccounts.txt"
        Start-Transcript -Path $transcriptPath -Force -ErrorAction SilentlyContinue | out-null
        $accountsToUpdate = @("vmbuildadmin", "administrator", "cm_svc", $accountName)
        $accountsToUpdate = $accountsToUpdate | Select-Object -Unique
        $accountsUpdated = 0
        foreach ($account in $accountsToUpdate) {
            $i = 0
            do {
                $i++
                Set-ADUser -Identity $account -PasswordNeverExpires $true -CannotChangePassword $true -ErrorVariable AccountError -ErrorAction SilentlyContinue | out-null
                if ($AccountError.Count -ne 0) { Start-Sleep -Seconds (20 * $i) }
            }
            until ($i -ge 5 -or $AccountError.Count -eq 0)

            if ($AccountError.Count -eq 0) {
                $accountsUpdated++
            }
        }
        Stop-Transcript | out-null
        if ($accountsUpdated -ne $accountsToUpdate.Count) {
            return $false
        }
        else {
            return $true
        }
    }

    $fixesToPerform += [PSCustomObject]@{
        FixName           = "Fix-DomainAccounts"
        FixVersion        = "211125.1"
        AppliesToNew      = $false
        AppliesToExisting = $true
        AppliesToRoles    = @("DC")
        NotAppliesToRoles = @("OSDClient", "Linux", "AADClient")
        DependentVMs      = @()
        ScriptBlock       = $Fix_DomainAccount
        ArgumentList      = @($vmNote.adminName)
    }
    #endregion
    ### Local account password expiration

    #region Fix-Prereq
    $Fix_Prereq = {
        $SiteCode = Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Microsoft\SMS\Identification' -Name 'Site Code'
        if (-not $SiteCode) {
            Write-host "No sitecode in HKLM:\SOFTWARE\Microsoft\SMS\Identification"
            return $true
        }
        $version = Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Microsoft\SMS' -Name 'Full Version'
        if (-not $version) {
            Write-host "No Version found in HKLM:\SOFTWARE\Microsoft\SMS\Full Version"
            return $false
        }

        if ([System.Version]$version -lt [System.Version]"5.0.9128")
        {
            Write-Host "2309 or older.. Should not force EHTTP"
            return $true
        }
        
        $NameSpace = "ROOT\SMS\site_$SiteCode"
        $component = gwmi -ns $NameSpace -Query "SELECT * FROM SMS_SCI_Component WHERE FileType=2 AND ItemName='SMS_SITE_COMPONENT_MANAGER|SMS Site Server' AND ItemType='Component' AND SiteCode='$SiteCode'"
        $props = $component.Props
        $index = [Array]::IndexOf($props.PropertyName, 'IISSSLState')
        $value = $props[$index].Value    
        $enabled = ($value -band 1024) -eq 1024 -or ($value -eq 63) -or ($value -eq 1472) -or ($value -eq 1504)
        if (-not $enabled) {
            Write-Host  "IISSSLSTATE $value is not correct.. Updated for EHTTP"
            $props[$index].Value = 1024
            $component.Props = $props
            $component.Put()
            return $true
        } else {
            write-host "IISSSLSTATE of $value looks good.. You should not be failing at prereq check"
            return $true
        }
    }

    $fixesToPerform += [PSCustomObject]@{
        FixName           = "Fix-PreReq"
        FixVersion        = "250116.0"
        AppliesToNew      = $false
        AppliesToExisting = $true
        AppliesToRoles    = @("CAS")
        NotAppliesToRoles = @()
        DependentVMs      = @()
        ScriptBlock       = $Fix_Prereq 
    }
    #endregion


    #region Fix-Upgrade-Console
    $Fix_UpgradeConsole = {
        & C:\staging\DSC\phases\Upgrade-Console.ps1
        return $true
    }

    $fixesToPerform += [PSCustomObject]@{
        FixName           = "Fix-Upgrade-Console"
        FixVersion        = "250107.0"
        AppliesToNew      = $true
        AppliesToExisting = $false
        AppliesToRoles    = @("Primary", "CAS")
        NotAppliesToRoles = @()
        DependentVMs      = @()
        ScriptBlock       = $Fix_UpgradeConsole
    }
    #endregion


    #region Fix-LocalAccount
    $Fix_LocalAccount = {
        Set-LocalUser -Name "vmbuildadmin" -PasswordNeverExpires $true -ErrorAction SilentlyContinue -ErrorVariable AccountError
        if ($AccountError.Count -eq 0) {
            return $true
        }
        else {
            return $false
        }
    }

    $fixesToPerform += [PSCustomObject]@{
        FixName           = "Fix-LocalAccount"
        FixVersion        = "211125.2"
        AppliesToNew      = $true
        AppliesToExisting = $true
        AppliesToRoles    = @()
        NotAppliesToRoles = @("DC", "OSDClient", "Linux", "AADClient")
        DependentVMs      = @()
        ScriptBlock       = $Fix_LocalAccount
    }
    #endregion
    # Default user profile

    #region Fix-DefaultUserProfile
    $Fix_DefaultProfile = {
        $path1 = "C:\Users\Default\AppData\Local\Microsoft\Windows\WebCache"
        $path2 = "C:\Users\Default\AppData\Local\Microsoft\Windows\INetCache"
        $path3 = "C:\Users\Default\AppData\Local\Microsoft\Windows\WebCacheLock.dat"
        if (Test-Path $path1) { Remove-Item -Path $path1 -Force -Recurse | Out-Null }
        if (Test-Path $path2) { Remove-Item -Path $path2 -Force -Recurse | Out-Null }
        if (Test-Path $path3) { Remove-Item -Path $path3 -Force | Out-Null }
        return $true
    }

    $fixesToPerform += [PSCustomObject]@{
        FixName           = "Fix-DefaultUserProfile"
        FixVersion        = "211126"
        AppliesToNew      = $true
        AppliesToExisting = $true
        AppliesToRoles    = @()
        NotAppliesToRoles = @("OSDClient", "Linux", "AADClient")
        DependentVMs      = @()
        ScriptBlock       = $Fix_DefaultProfile
    }
    #endregion

    #region Fix-CMFullAdmin
    # Full Admin in CM

    $Fix_CMFullAdmin = {
        if (-not (Test-Path "C:\staging\Fix")) { New-Item -Path "C:\staging\Fix" -ItemType Directory -Force | Out-Null }
        $transcriptPath = "C:\staging\Fix\Fix-CMFullAdmin.txt"
        try {


            Start-Transcript -Path $transcriptPath -Force -ErrorAction SilentlyContinue | out-null
            $SiteCode = Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Microsoft\SMS\Identification' -Name 'Site Code' -ErrorVariable ErrVar

            if ($ErrVar.Count -ne 0) {
                return $true
            }

            if ([string]::IsNullOrWhiteSpace($SiteCode)) {
                # Deployment was done with cmOptions.Install=False, or site was uninstalled
                return $true
            }

            $ProviderMachineName = $env:COMPUTERNAME + "." + $DomainFullName # SMS Provider machine name

            # Get CM module path
            $key = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry32)
            try {
                $subKey = $key.OpenSubKey("SOFTWARE\Microsoft\ConfigMgr10\Setup")
            }
            catch {
                return $true
            }
            $uiInstallPath = $subKey.GetValue("UI Installation Directory")
            $modulePath = $uiInstallPath + "bin\ConfigurationManager.psd1"
            $initParams = @{}

            $userName = "vmbuildadmin"
            $userDomain = $env:USERDOMAIN
            $domainUserName = "$userDomain\$userName"

            $i = 0
            do {
                $i++

                # Import the ConfigurationManager.psd1 module
                if ($null -eq (Get-Module ConfigurationManager)) {
                    Import-Module $modulePath -ErrorAction SilentlyContinue | out-null
                }

                # Connect to the site's drive if it is not already present
                New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $ProviderMachineName @initParams -ErrorAction SilentlyContinue | out-null

                while ($null -eq (Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue)) {
                    Start-Sleep -Seconds 10
                    New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $ProviderMachineName @initParams -ErrorAction SilentlyContinue | out-null
                }

                # Set the current location to be the site code.
                Set-Location "$($SiteCode):\" @initParams | out-null

                $exists = Get-CMAdministrativeUser -RoleName "Full Administrator" | Where-Object { $_.LogonName -like "*$userName*" } -ErrorAction SilentlyContinue

                if (-not $exists) {
                    New-CMAdministrativeUser -Name $domainUserName -RoleName "Full Administrator" `
                        -SecurityScopeName "All", "All Systems", "All Users and User Groups" -ErrorAction SilentlyContinue | out-null
                    Start-Sleep -Seconds 30
                    $exists = Get-CMAdministrativeUser -RoleName "Full Administrator" | Where-Object { $_.LogonName -eq $domainUserName } -ErrorAction SilentlyContinue
                }
            }
            until ($exists -or $i -gt 5)

            Stop-Transcript | out-null

            if ($exists) { return $true }
            else { return $false }
        }
        catch {
            Stop-Transcript | out-null
            return $false
        }

        if ([string]::IsNullOrWhiteSpace($SiteCode)) {
            # Deployment was done with cmOptions.Install=False, or site was uninstalled
            return $true
        }

        $ProviderMachineName = $env:COMPUTERNAME + "." + $DomainFullName # SMS Provider machine name

        # Get CM module path
        $key = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry32)
        $subKey = $key.OpenSubKey("SOFTWARE\Microsoft\ConfigMgr10\Setup")
        if (-not $subKey) {
            return $true
        }
        $uiInstallPath = $subKey.GetValue("UI Installation Directory")
        $modulePath = $uiInstallPath + "bin\ConfigurationManager.psd1"
        $initParams = @{}

        $userName = "vmbuildadmin"
        $userDomain = $env:USERDOMAIN
        $domainUserName = "$userDomain\$userName"

        $i = 0
        do {
            $i++

            # Import the ConfigurationManager.psd1 module
            if ($null -eq (Get-Module ConfigurationManager)) {
                Import-Module $modulePath -ErrorAction SilentlyContinue | out-null
            }

            # Connect to the site's drive if it is not already present
            New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $ProviderMachineName @initParams -ErrorAction SilentlyContinue | out-null

            $c = 0
            while ($null -eq (Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue)) {
                $c++
                if ($c -gt 5) {
                    return $false
                }
                Start-Sleep -Seconds 10
                New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $ProviderMachineName @initParams -ErrorAction SilentlyContinue | out-null
            }

            # Set the current location to be the site code.
            Set-Location "$($SiteCode):\" @initParams | out-null

            $exists = Get-CMAdministrativeUser -RoleName "Full Administrator" | Where-Object { $_.LogonName -like "*$userName*" } -ErrorAction SilentlyContinue

            if (-not $exists) {
                New-CMAdministrativeUser -Name $domainUserName -RoleName "Full Administrator" `
                    -SecurityScopeName "All", "All Systems", "All Users and User Groups" -ErrorAction SilentlyContinue | out-null
                Start-Sleep -Seconds 30
                $exists = Get-CMAdministrativeUser -RoleName "Full Administrator" | Where-Object { $_.LogonName -eq $domainUserName } -ErrorAction SilentlyContinue
            }
        }
        until ($exists -or $i -gt 5)

        #Stop-Transcript | out-null

        if ($exists) { return $true }
        else { return $false }
    }

    $fixesToPerform += [PSCustomObject]@{
        FixName           = "Fix-CMFullAdmin"
        FixVersion        = "211127"
        AppliesToNew      = $false
        AppliesToExisting = $true
        AppliesToRoles    = @("CASorStandalonePrimary")
        NotAppliesToRoles = @("OSDClient", "Linux", "AADClient")
        DependentVMs      = @($dc.vmName, $vmNote.remoteSQLVM)
        ScriptBlock       = $Fix_CMFullAdmin
    }
    #endregion

    #region Fix-DisableIEESC
    # Disable IE Enhanced Security for all usres via Scheduled task
    $Fix_DisableIEESC = {

        $os = Get-CimInstance -Class Win32_OperatingSystem -ErrorAction SilentlyContinue
        if ($os) {
            if ($os.Producttype -eq 1) {
                return $true # workstation OS, fix not applicable
            }
        }
        else {
            return $false # failed to determine OS type, fail
        }

        $taskName = "Disable-IEESC"
        $filePath = "$env:systemdrive\staging\Disable-IEESC.ps1"

        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($task) {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false | Out-Null
        }

        # Action
        $taskCommand = "cmd"
        $taskArgs = "/c start /min C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -WindowStyle Hidden -NonInteractive -Executionpolicy unrestricted -file $filePath"
        $action = New-ScheduledTaskAction -Execute $taskCommand -Argument $taskArgs

        # Trigger
        $trigger = New-ScheduledTaskTrigger -AtLogOn

        # Principal
        $principal = New-ScheduledTaskPrincipal -GroupId Users -RunLevel Highest

        # Task
        $definition = New-ScheduledTask -Action $action -Principal $principal -Trigger $trigger -Description "Disable IE Enhanced Security"

        Register-ScheduledTask -TaskName $taskName -InputObject $definition | Out-Null
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue

        if ($null -ne $task) {
            return $true
        }
        else {
            return $false
        }
    }

    $fixesToPerform += [PSCustomObject]@{
        FixName           = "Fix-DisableIEESC"
        FixVersion        = "220422"
        AppliesToNew      = $true
        AppliesToExisting = $true
        AppliesToRoles    = @()
        NotAppliesToRoles = @("OSDClient", "Linux", "AADClient")
        DependentVMs      = @()
        ScriptBlock       = $Fix_DisableIEESC
        RunAsAccount      = $vmNote.adminName
        InjectFiles       = @("Disable-IEESC.ps1") # must exist in filesToInject\staging dir
    }

    #endregion

    #region Fix-CleanupSQL

    $Fix_CleanupSQL = {

        $os = Get-CimInstance -Class Win32_OperatingSystem -ErrorAction SilentlyContinue
        if ($os) {
            if ($os.Producttype -eq 1) {
                return $true # workstation OS, fix not applicable
            }
        }
        else {
            return $false # failed to determine OS type, fail
        }

        $taskName = "MemLabs Cleanup SQL"
        $filePath = "$env:systemdrive\staging\Cleanup-SQL.ps1"

        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($task) {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false | Out-Null
        }

        # Action
        $taskCommand = "cmd"
        $taskArgs = "/c start /min C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -WindowStyle Hidden -NonInteractive -Executionpolicy unrestricted -file $filePath"
        $action = New-ScheduledTaskAction -Execute $taskCommand -Argument $taskArgs

        # Trigger
        $trigger = New-ScheduledTaskTrigger -Daily -At 3am

        # Principal
        $principal = New-ScheduledTaskPrincipal -UserId "System"

        # Task
        $definition = New-ScheduledTask -Action $action -Principal $principal -Trigger $trigger -Description "Cleanup SQL"

        Register-ScheduledTask -TaskName $taskName -InputObject $definition | Out-Null
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue

        if ($null -ne $task) {
            return $true
        }
        else {
            return $false
        }
    }

    $fixesToPerform += [PSCustomObject]@{
        FixName           = "Fix-CleanupSQL"
        FixVersion        = "241124"
        AppliesToNew      = $true
        AppliesToExisting = $true
        AppliesToRoles    = @()
        NotAppliesToRoles = @("OSDClient", "Linux", "AADClient")
        DependentVMs      = @()
        ScriptBlock       = $Fix_CleanupSQL
        RunAsAccount      = $vmNote.adminName
        InjectFiles       = @("Cleanup-SQL.ps1") # must exist in filesToInject\staging dir
    }

    #endregion

    #region Fix-EnableLogMachine

    $Fix_EnableLogMachine = {

        $taskName = "EnableLogMachine"
        $filePath = "$env:systemdrive\staging\Enable-LogMachine.ps1"

        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($task) {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false | Out-Null
        }

        # Action
        $taskCommand = "cmd"
        $taskArgs = "/c start /min C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -WindowStyle Hidden -NonInteractive -Executionpolicy unrestricted -file $filePath"
        $action = New-ScheduledTaskAction -Execute $taskCommand -Argument $taskArgs

        # Trigger
        $trigger = New-ScheduledTaskTrigger -AtLogOn

        # Principal
        $principal = New-ScheduledTaskPrincipal -GroupId Users -RunLevel Highest

        # Task
        $definition = New-ScheduledTask -Action $action -Principal $principal -Trigger $trigger -Description "Enable Log Machine"

        Register-ScheduledTask -TaskName $taskName -InputObject $definition | Out-Null
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue

        if ($null -ne $task) {
            return $true
        }
        else {
            return $false
        }
    }
    $fixesToPerform += [PSCustomObject]@{
        FixName           = "Fix-EnableLogMachine"
        FixVersion        = "250206"
        AppliesToNew      = $true 
        AppliesToExisting = $true
        AppliesToRoles    = @()
        NotAppliesToRoles = @("OSDClient", "Linux", "AADClient")
        DependentVMs      = @()
        ScriptBlock       = $Fix_EnableLogMachine
        RunAsAccount      = $vmNote.adminName
        InjectFiles       = @("Enable-LogMachine.ps1") # must exist in filesToInject\staging dir
    }

    #endregion

    #region Fix-AccountExpiry

    $Fix_AccountExpiry = {

        $RegistryPath = 'HKLM:\\SYSTEM\CurrentControlSet\Services\Netlogon\Parameters'
        $Name = 'DisablePasswordChange'
        $Value = '1'
        New-ItemProperty -Path $RegistryPath -Name $Name -Value $Value -PropertyType DWORD -Force | Out-Null
        return $true
    }

    $fixesToPerform += [PSCustomObject]@{
        FixName           = "Fix-AccountExpiry"
        FixVersion        = "230922"
        AppliesToNew      = $true
        AppliesToExisting = $true
        AppliesToRoles    = @()
        NotAppliesToRoles = @("DC", "OSDClient", "Linux", "AADClient")
        DependentVMs      = @()
        ScriptBlock       = $Fix_AccountExpiry

    }
    #endregion

    #region Fix_LocalAdminAccount
    $Fix_LocalAdminAccount = {
        param ($password)
        $p = ConvertTo-SecureString $password -AsPlainText -Force
        Set-LocalUser -Password $p "Administrator"
        Enable-LocalUser "Administrator"
        return $true
    }

    $fixesToPerform += [PSCustomObject]@{
        FixName           = "Fix_LocalAdminAccount"
        FixVersion        = "240710"
        AppliesToNew      = $true
        AppliesToExisting = $true
        AppliesToRoles    = @()
        NotAppliesToRoles = @("DC", "OSDClient", "Linux", "AADClient")
        DependentVMs      = @()
        ScriptBlock       = $Fix_LocalAdminAccount
        ArgumentList      = @($Common.LocalAdmin.GetNetworkCredential().Password)
    }
    #endregion

    #region Fix_ActivateWindows
    $Fix_ActivateWindows = {

        $atkms = "azkms.core.windows.net:1688"
        $winp = "W269N-WFGWX-YVC9B-4J6C9-T83GX"
        $wine = "NPPR9-FWDCX-D2C8J-H872K-2YT43"
        $cosname = (Get-CimInstance -Class Win32_OperatingSystem).Name
        
        if ($cosname -like "*Pro*") {
            $key = $winp
        }
        if ($cosname -like "*Enterprise*") {
            $key = $wine
        }
        
        if ($key) {
            cscript //NoLogo C:\Windows\system32\slmgr.vbs /skms $atkms > $null    
            Start-Sleep -Seconds 5        
            cscript //NoLogo C:\Windows\system32\slmgr.vbs /ipk $key > $null
            Start-Sleep -Seconds 5
            cscript //NoLogo C:\Windows\system32\slmgr.vbs /ato > $null
        }
        return $true
    }
        
    $fixesToPerform += [PSCustomObject]@{
        FixName           = "Fix_ActivateWindows"
        FixVersion        = "240713"
        AppliesToNew      = $true
        AppliesToExisting = $true
        AppliesToRoles    = @('DomainMember', 'WorkgroupMember', "InternetClient")
        NotAppliesToRoles = @()
        DependentVMs      = @()
        ScriptBlock       = $Fix_ActivateWindows
        RunAsAccount      = $vmNote.adminName
    }
    #endregion

    # ========================
    # Determine applicability
    # ========================
    foreach ($vmFix in $fixesToPerform) {
        $applicable = $false
        $applicableRoles = $vmFix.AppliesToRoles
        if (-not $applicableRoles) {
            $applicableRoles = $Common.Supported.AllRoles
        }
        if ($vmFix.NotAppliesToRoles -and $vmNote.role -in $vmFix.NotAppliesToRoles) {
            $applicable = $false
        }
        elseif ($vmNote.role -in $applicableRoles) {
            $applicable = $true
        }
        else {
            $topLevelSite = $vmNote.role -eq "CAS" -or ($vmNote.role -eq "Primary" -and (-not $vmNote.parentSiteCode))
            if ($applicableRoles -contains "CASorStandalonePrimary" -and $topLevelSite) {
                $applicable = $true
            }
        }
        $vmfix | Add-Member -MemberType NoteProperty -Name AppliesToThisVM -Value $applicable -force

        # Filter out null's'
        $vmFix.DependentVMs = $vmFix.DependentVMs | Where-Object { $_ -and $_.Trim() }
    }

    return $fixesToPerform
}
