
function Start-Maintenance {

    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false, HelpMessage = "If present, maintenance runs only for machines in DeployConfig")]
        [object]$DeployConfig
    )

    $applyNewOnly = $false
    if ($DeployConfig) {
        $allVMs = $DeployConfig.virtualMachines | Where-Object { -not $_.hidden }
        $vmsNeedingMaintenance = $DeployConfig.virtualMachines | Where-Object { -not $_.hidden } | Sort-Object vmName
        $applyNewOnly = $true
    }
    else {
        $allVMs = Get-List -Type VM | Where-Object { $_.vmBuild -eq $true -and $_.inProgress -ne $true }
        $vmsNeedingMaintenance = $allVMs | Where-Object { $_.memLabsVersion -lt $Common.LatestHotfixVersion } | Sort-Object vmName
    }

    # Filter in-progress
    $vmsNeedingMaintenance = $vmsNeedingMaintenance | Where-Object { $_.inProgress -ne $true }
    $newVmsNeedingMaintenance = @()
    foreach ($vm in $vmsNeedingMaintenance) {
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

    if ($applyNewOnly -eq $false) {
        if ($vmCount -gt 0) {
            $response = Read-YesorNoWithTimeout -Prompt "$($newVmsNeedingMaintenance.Count) VM(s) [$($newVmsNeedingMaintenance.vmName -join ",")] need memlabs maintenance. Run now? (Y/n)" -HideHelp -Default "y" -timeout 15
            if ($response -eq "n") {
                return
            }

            $response = Read-YesorNoWithTimeout -Prompt "Start VM's that are stopped for Maintenance (y/N)" -HideHelp -Default "n" -timeout 15
            if ($response -eq "y") {
                Write-Log "$vmCount VM's need maintenance. VM's will be started (if stopped) and shut down post-maintenance."
            }
            else {
                Write-Log "$vmCount VM's need maintenance. VM's will NOT be started (if stopped)."
                $maintenanceDoNotStart = $true
            }
        }
        else {
            Write-Log "No maintenance required." -Success
            return
        }
    }

    $progressId = Get-Random
    Write-Progress2 -Id $progressId -Activity $text -Status "Please wait..." -PercentComplete 0

    $i = 0
    $countWorked = $countFailed = $countSkipped = 0

    # Perform maintenance... run it on DC's first, rest after.
    $failedDomains = @()
    foreach ($vm in $newVmsNeedingMaintenance | Where-Object { $_.role -eq "DC" }) {
        $i++
        Write-Progress2 -Id $progressId -Activity $text -Status "Performing maintenance on VM $i/$vmCount`: $($vm.vmName)" -PercentComplete (($i / $vmCount) * 100)
        $worked = Start-VMMaintenance -VMName $vm.vmName -ApplyNewOnly:$applyNewOnly
        if ($worked) { $countWorked++ } else {
            $failedDomains += $vm.domain
            $countFailed++
        }
    }

    # Check if failed domain is -le 211125.1
    $failedDCs = Get-List -Type VM | Where-Object { $_.role -eq "DC" -and $_.domain -in $failedDomains }
    $criticalDomains = @()
    foreach ($dc in $failedDCs) {
        $vmNote = Get-VMNote $dc.vmName
        if ($vmNote.memlabsVersion -le "211125.1") {
            $criticalDomains += $dc.domain
        }
    }

    # Perform maintenance on other VM's
    foreach ($vm in $newVmsNeedingMaintenance | Where-Object { $_.role -ne "DC" }) {
        $i++
        if ($maintenanceDoNotStart) {
            if ($vm.State -ne "Running") {
                $countSkipped++
                continue
            }
        }

        Write-Progress2 -Id $progressId -Activity $text -Status "Performing maintenance on VM $i/$vmCount`: $($vm.vmName)" -PercentComplete (($i / $vmCount) * 100)
        if ($vm.domain -in $criticalDomains) {
            Write-Log "$($vm.vmName)`: Maintenance skipped, DC maintenance failed." -Highlight
            $countSkipped++
        }
        else {
            try {
                $worked = Start-VMMaintenance -VMName $vm.vmName -ApplyNewOnly:$applyNewOnly
            }
            catch {
                write-exception $_
                $worked = $false
            }
            if ($worked) { $countWorked++ } else { $countFailed++ }
        }
    }

    if ($criticalDomains.Count -gt 0) {
        Write-Log "DC Maintenance failed for the domains ($($criticalDomains -join ',')). Skipping maintenance of VM's in these domain(s)." -LogOnly
        Show-FailedDomains -failedDomains $criticalDomains
    }

    Write-Host
    Write-Log "Finished maintenance. Success: $countWorked; Failures: $countFailed; Skipped: $countSkipped; Already up-to-date: $countNotNeeded" -SubActivity
    Write-Progress2 -Id $progressId -Activity $text -Completed
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
            $vmNote = Get-VMNote -VMName $vm
            if ($vmNote.role -ne "DC") {
                Write-Progress2 -Activity $global:MaintenanceActivity -Status  "Shutting down VM."
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
        AppliesToThisVM   = $false
        AppliesToNew      = $false
        AppliesToExisting = $true
        AppliesToRoles    = @("DC")
        NotAppliesToRoles = @("OSDClient", "Linux", "AADClient")
        DependentVMs      = @()
        ScriptBlock       = $Fix_DomainAccount
        ArgumentList      = @($vmNote.adminName)
    }

    ### Local account password expiration

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
        AppliesToThisVM   = $false
        AppliesToNew      = $true
        AppliesToExisting = $true
        AppliesToRoles    = @()
        NotAppliesToRoles = @("DC", "OSDClient", "Linux", "AADClient")
        DependentVMs      = @()
        ScriptBlock       = $Fix_LocalAccount
    }

    # Default user profile

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
        AppliesToThisVM   = $false
        AppliesToNew      = $true
        AppliesToExisting = $true
        AppliesToRoles    = @()
        NotAppliesToRoles = @("OSDClient", "Linux", "AADClient")
        DependentVMs      = @()
        ScriptBlock       = $Fix_DefaultProfile
    }

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
        AppliesToThisVM   = $false
        AppliesToNew      = $false
        AppliesToExisting = $true
        AppliesToRoles    = @("CASorStandalonePrimary")
        NotAppliesToRoles = @("OSDClient", "Linux", "AADClient")
        DependentVMs      = @($dc.vmName, $vmNote.remoteSQLVM)
        ScriptBlock       = $Fix_CMFullAdmin
    }

    # Disable IE Enhanced Security for all usres via Scheduled task
    $Fix_DisableIEESC = {

        $os = Get-WmiObject -Class Win32_OperatingSystem -ErrorAction SilentlyContinue
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
        $taskCommand = "cmd /c start /min C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
        $taskArgs = "-WindowStyle Hidden -NonInteractive -Executionpolicy unrestricted -file $filePath"
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
        AppliesToThisVM   = $false
        AppliesToNew      = $true
        AppliesToExisting = $true
        AppliesToRoles    = @()
        NotAppliesToRoles = @("OSDClient", "Linux", "AADClient")
        DependentVMs      = @()
        ScriptBlock       = $Fix_DisableIEESC
        RunAsAccount      = $vmNote.adminName
        InjectFiles       = @("Disable-IEESC.ps1") # must exist in filesToInject\staging dir
    }


    $Fix_EnableLogMachine = {

        $taskName = "EnableLogMachine"
        $filePath = "$env:systemdrive\staging\Enable-LogMachine.ps1"

        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($task) {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false | Out-Null
        }

        # Action
        $taskCommand = "cmd /c start /min C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
        $taskArgs = "-WindowStyle Hidden -NonInteractive -Executionpolicy unrestricted -file $filePath"
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
        FixVersion        = "240307"
        AppliesToThisVM   = $false
        AppliesToNew      = $true
        AppliesToExisting = $true
        AppliesToRoles    = @()
        NotAppliesToRoles = @("OSDClient", "Linux", "AADClient")
        DependentVMs      = @()
        ScriptBlock       = $Fix_EnableLogMachine
        RunAsAccount      = $vmNote.adminName
        InjectFiles       = @("Enable-LogMachine.ps1") # must exist in filesToInject\staging dir
    }

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
        AppliesToThisVM   = $false
        AppliesToNew      = $true
        AppliesToExisting = $true
        AppliesToRoles    = @()
        NotAppliesToRoles = @("DC", "OSDClient", "Linux", "AADClient")
        DependentVMs      = @()
        ScriptBlock       = $Fix_AccountExpiry

    }

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
        AppliesToThisVM   = $false
        AppliesToNew      = $true
        AppliesToExisting = $true
        AppliesToRoles    = @()
        NotAppliesToRoles = @("DC", "OSDClient", "Linux", "AADClient")
        DependentVMs      = @()
        ScriptBlock       = $Fix_LocalAdminAccount
        ArgumentList      = @($Common.LocalAdmin.GetNetworkCredential().Password)
    }
    $Fix_ActivateWindows = {

        $atkms = "azkms.core.windows.net:1688"
        $winp = "W269N-WFGWX-YVC9B-4J6C9-T83GX"
        $wine = "NPPR9-FWDCX-D2C8J-H872K-2YT43"
        $cosname = (Get-WmiObject -Class Win32_OperatingSystem).Name
        
        if ($cosname -like "Pro") {
            $key = $winp
        }
        if ($cosname -like "Enterprise") {
            $key = $wine
        }
        
        if ($key) {
            cscript //NoLogo C:\Windows\system32\slmgr.vbs /skms $atkms       
            Start-Sleep -Seconds 5        
            cscript //NoLogo C:\Windows\system32\slmgr.vbs /ipk $key
            Start-Sleep -Seconds 5
            cscript //NoLogo C:\Windows\system32\slmgr.vbs /ato
        }
        return $true
    }
        
    $fixesToPerform += [PSCustomObject]@{
        FixName           = "Fix_ActivateWindows"
        FixVersion        = "240711"
        AppliesToThisVM   = $false
        AppliesToNew      = $true
        AppliesToExisting = $true
        AppliesToRoles    = @('DomainMember', 'WorkgroupMember')
        NotAppliesToRoles = @()
        DependentVMs      = @()
        ScriptBlock       = $Fix_ActivateWindows
        RunAsAccount      = $vmNote.adminName
    }
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
        $vmFix.AppliesToThisVM = $applicable

        # Filter out null's'
        $vmFix.DependentVMs = $vmFix.DependentVMs | Where-Object { $_ -and $_.Trim() }
    }

    return $fixesToPerform
}
