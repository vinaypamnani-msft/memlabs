
function Start-Maintenance {

    $vmsNeedingMaintenance = Get-List -Type VM | Where-Object { $_.memLabsVersion -lt $Common.LatestHotfixVersion } | Sort-Object vmName
    $vmsNeedingMaintenance = $vmsNeedingMaintenance | Where-Object { $_.role -ne "OSDClient" }
    $vmsNeedingMaintenance = $vmsNeedingMaintenance | Where-Object { $_.inProgress -ne $true }
    $vmsNeedingMaintenance = $vmsNeedingMaintenance | Where-Object { $_.vmBuild -eq $true }

    $vmCount = ($vmsNeedingMaintenance | Measure-Object).Count

    $text = "Performing maintenance"
    Write-Log $text -Activity

    if ($vmCount -gt 0) {
        Write-Log "$vmCount VM's need maintenance. VM's will be started if needed and shut down post-maintenance."
    }
    else {
        Write-Log "No maintenance required." -Success
        return
    }

    $progressId = Get-Random
    Write-Progress -Id $progressId -Activity $text -Status "Please wait..." -PercentComplete 0

    $i = 0
    $countWorked = $countFailed = 0

    # Perform maintenance... run it on DC's first, rest after.
    foreach ($vm in $vmsNeedingMaintenance | Where-Object { $_.role -eq "DC" }) {
        $i++
        Write-Progress -Id $progressId -Activity $text -Status "Performing maintenance on VM $i/$vmCount`: $($vm.vmName)" -PercentComplete (($i / $vmCount) * 100)
        $worked = Start-VMMaintenance -VMName $vm.vmName
        if ($worked) { $countWorked++ } else { $countFailed++ }
    }

    foreach ($vm in $vmsNeedingMaintenance | Where-Object { $_.role -ne "DC" }) {
        $i++
        Write-Progress -Id $progressId -Activity $text -Status "Performing maintenance on VM $i/$vmCount`: $($vm.vmName)" -PercentComplete (($i / $vmCount) * 100)
        $worked = Start-VMMaintenance -VMName $vm.vmName
        if ($worked) { $countWorked++ } else { $countFailed++ }
    }

    Write-Log "Finished maintenance. Success: $countWorked; Failures: $countFailed" -Activity
    Write-Progress -Id $progressId -Activity $text -Completed
}

function Start-VMMaintenance {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "VMName")]
        [object] $VMName
    )

    $vmNoteObject = Get-VMNote -VMName $VMName

    if (-not $vmNoteObject) {
        Write-Log "$vmName`: VM Notes property could not be read. Skipping." -Warning
        return $false
    }

    $latestFixVersion = $Common.LatestHotfixVersion
    $inProgress = if ($vmNoteObject.inProgress) { $true } else { $false }
    $vmVersion = $vmNoteObject.memLabsVersion

    # This should never happen, since parent filters these out. Leaving just-in-case.
    if ($inProgress) {
        Write-Log "$vmName`: VM Deployment State is in-progress. Skipping." -Warning
        return $false
    }

    # This should never happen, unless Get-List provides outdated version, so check again with current VMNote object
    if ($vmVersion -ge $latestFixVersion) {
        Write-Log "$VMName`: VM Version ($vmVersion) is up-to-date."
        return $true
    }

    Write-Log "$VMName`: VM (version $vmVersion) is NOT up-to-date. Required Version is $latestFixVersion." -Highlight

    $vmFixes = Get-VMFixes -VMName $VMName | Where-Object { $_.AppliesToExisting -eq $true }
    $worked = Start-VMFixes -VMName $VMName -VMFixes $vmFixes

    if ($worked) {
        Write-Log "$VMName`: VM maintenance completed successfully." -Success
    }
    else {
        Write-Log "$VMName`: VM maintenance failed. Review VMBuild.log and refer to internal documentation." -Failure
        Show-Notification -ToastText "$VMName`: VM maintenance failed. Review VMBuild.log and refer to internal documentation." -ToastTag $VMName
    }

    return $worked
}

function Start-VMFixes {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "VMName")]
        [object] $VMName,
        [Parameter(Mandatory = $true, HelpMessage = "VMFixes")]
        [object] $VMFixes,
        [Parameter(Mandatory = $false, HelpMessage = "SkipVMShutdown")]
        [switch] $SkipVMShutdown
    )

    Write-Log "$VMName`: Applying fixes to the virtual machine." -Verbose

    $success = $false
    $vmStarted = $false

    foreach ($vmFix in $VMFixes | Sort-Object FixVersion ) {
        $status = Start-VMFix -vmName $VMName -vmFix $vmFix
        if ($status.StartedVM) { $vmStarted = $true }
        $success = $status.Success

        if (-not $success) {
            Write-Log "Retrying fix '$($vmFix.FixName)' after waiting for 30 seconds."
            Start-Sleep -Seconds 30
            $status = Start-VMFix -vmName $VMName -vmFix $vmFix
            if ($status.StartedVM) { $vmStarted = $true }
            $success = $status.Success

            if (-not $success) { break }
        }
    }

    if ($vmStarted -and -not $SkipVMShutdown.IsPresent) {
        $vmNote = Get-VMNote -VMName $VMName
        if ($vmNote.role -ne "DC") {
            Write-Log "$VMName`: Shutting down VM." -Verbose
            $i = 0
            do {
                $i++
                Stop-VM -Name $VMName -Force -ErrorVariable StopError -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 3
            }
            until ($i -ge 5 -or $StopError.Count -eq 0)

            if ($StopError.Count -ne 0) {
                Write-Log "$VMName`: Failed to stop the VM. $StopError" -Warning
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
        [object] $vmFix
    )

    $return = [PSCustomObject]@{
        Success   = $false
        StartedVM = $false
    }

    # Get current VM note to ensure we don't have outdated version
    $vmNote = Get-VMNote -VMName $vmName
    $vmDomain = $vmNote.domain

    # Check applicability
    $fixName = $vmFix.FixName
    $fixVersion = $vmFix.FixVersion

    if ($vmNote.memLabsVersion -ge $fixVersion) {
        Write-Log "$VMName`: Fix '$fixName' ($fixVersion) has been applied already."
        $return.Success = $true
        return $return
    }

    if (-not $vmFix.AppliesToThisVM) {
        Write-Log "$VMName`: Fix '$fixName' ($fixVersion) is not applicable. Updating version to '$fixVersion'"
        Set-VMNote -VMName $vmName -vmVersion $fixVersion
        $return.Success = $true
        return $return
    }

    Write-Log "$VMName`: Fix '$fixName' ($fixVersion) is applicable. Applying fix now." -Verbose

    # Start VM to apply fix
    $status = Start-VMIfNotRunning -VMName $VMName -VMDomain $vmDomain -WaitForConnect -Quiet
    $return.StartedVM = $status.StartedVM

    if ($status.StartFailed -or $status.ConnectFailed) {
        # Write-Log "$VMName`: VM could not be started to apply fix '$fixName'."
        return $return
    }

    # Apply Fix
    $HashArguments = @{
        VmName       = $VMName
        VMDomainName = $vmDomain
        DisplayName  = $vmFix.FixName
        ScriptBlock  = $vmFix.ScriptBlock
    }

    if ($vmFix.ArgumentList) {
        $HashArguments.Add("ArgumentList", $vmFix.ArgumentList)
    }

    if ($vmFix.RunAsAccount) {
        $HashArguments.Add("VmDomainAccount", $vmFix.RunAsAccount)
    }

    $result = Invoke-VmCommand @HashArguments
    if ($result.ScriptBlockFailed -or $result.ScriptBlockOutput -eq $false) {
        Write-Log "$VMName`: Fix '$fixName' ($fixVersion) failed to be applied." -Warning
        $return.Success = $false
    }
    else {
        Write-Log "$VMName`: Fix '$fixName' ($fixVersion) applied. Updating version to $fixVersion."
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

    $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue

    if (-not $vm) {
        Write-Log "$VMName`: Failed to get VM from Hyper-V. Error: $_" -Warning
        $return.StartFailed = $true
        $return.ConnectFailed = $true
        return $return
    }

    if ($vm.State -ne "Running") {
        try {
            Write-Log "$VMName`: Starting VM for maintenance and waiting for it to be ready to connect."
            Start-VM -Name $VMName -ErrorAction Stop | Out-Null
            $return.StartedVM = $true
            if ($WaitForConnect.IsPresent) {
                $connected = Wait-ForVM -VmName $VMname -PathToVerify "C:\Users" -VmDomainName $VMDomain -TimeoutMinutes 2 -Quiet
                if (-not $connected) {
                    Write-Log "$VMName`: Could not connect to the VM after waiting for 2 minutes."
                    $return.ConnectFailed = $true
                }
            }
        }
        catch {
            Write-Log "$VMName`: Failed to start VM. Error: $_"
            $return.StartFailed = $true
            $return.ConnectFailed = $true
        }
    }
    else {
        if (-not $Quiet.IsPresent) { Write-Log "$VMName`: VM is already running." -Verbose }
    }

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
    }

    $fixesToPerform = @()

    ### Domain account password expiration

    $Fix_DomainAccount = {
        param ($accountName)
        Start-Transcript -Path "C:\staging\Fix-DomainAccounts.txt"
        $accountsToUpdate = @("vmbuildadmin", "administrator", "cm_svc", $accountName)
        $accountsToUpdate = $accountsToUpdate | Select-Object -Unique
        $accountsUpdated = 0
        foreach ($account in $accountsToUpdate) {
            $i = 0
            do {
                $i++
                Set-ADUser -Identity $account -PasswordNeverExpires $true -CannotChangePassword $true -ErrorVariable AccountError -ErrorAction SilentlyContinue
            }
            until ($i -ge 5 -or $AccountError.Count -eq 0)

            if ($AccountError.Count -eq 0) {
                $accountsUpdated++
            }
            else {
                $AccountError | Out-Host
            }
        }
        Stop-Transcript
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
        NotAppliesToRoles = @()
        ScriptBlock       = $Fix_DomainAccount
        ArgumentList      = @($vmNote.adminName)
        RunAsAccount      = $vmNote.adminName
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
        NotAppliesToRoles = @("DC")
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
        FixVersion        = "211125.3"
        AppliesToThisVM   = $false
        AppliesToNew      = $true
        AppliesToExisting = $true
        AppliesToRoles    = @()
        NotAppliesToRoles = @()
        ScriptBlock       = $Fix_DefaultProfile
    }

    # Determine applicability
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
        $vmFix.AppliesToThisVM = $applicable
    }

    return $fixesToPerform
}
