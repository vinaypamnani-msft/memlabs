
function Start-Maintenance {

    $vmsNeedingMaintenance = Get-List -Type VM | Where-Object { $_.memLabsVersion -lt $Common.LatestHotfixVersion }
    $vmsNeedingMaintenance = $vmsNeedingMaintenance | Where-Object { $_.role -ne "OSDClient" }
    $vmsNeedingMaintenance = $vmsNeedingMaintenance | Where-Object { $_.inProgress -ne $true }
    $vmsNeedingMaintenance = $vmsNeedingMaintenance | Where-Object { $_.vmBuild -eq $true }

    $vmCount = ($vmsNeedingMaintenance | Measure-Object).Count

    $text = "Performing maintenance"
    Write-Progress -Activity $text -Status "Please wait..." -PercentComplete 0
    Write-Log $text -Activity

    if ($vmCount -gt 0) {
        Write-Log "$vmCount VM's need maintenance. VM's will be started if needed and shut down post-maintenance."
    }
    else {
        Write-Log "No maintenance required." -Success
        return
    }

    $i = 0
    $countWorked = $countFailed = 0

    # Perform maintenance... run it on DC's first, rest after.
    # Start DC if not running, but don't bother stoppping them. Other VM's would need domain creds to work.
    foreach ($vm in $vmsNeedingMaintenance | Where-Object { $_.role -eq "DC" }) {
        $i++
        Start-VMIfNotRunning -VMName $vm.vmName | Out-Null
        $worked = Start-VMMaintenance -VMName $vm.vmName
        if ($worked) { $countWorked++ } else { $countFailed++ }
        Write-Progress -Activity $text -Status "Performing maintenance on VM $i/$vmCount`: $($vm.vmName)" -PercentComplete (($i / $vmCount) * 100)
    }

    foreach ($vm in $vmsNeedingMaintenance | Where-Object { $_.role -ne "DC" }) {
        $i++
        $worked = Start-VMMaintenance -VMName $vm.vmName
        if ($worked) { $countWorked++ } else { $countFailed++ }
        Write-Progress -Activity $text -Status "Performing maintenance on VM $i/$vmCount`: $($vm.vmName)" -PercentComplete (($i / $vmCount) * 100)
    }

    Write-Log "Finished maintenance. Success: $countWorked; Failures: $countFailed" -Activity
    Write-Progress -Activity $text -Completed
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
        Write-Log "$VMName`: VM maintenance failed. Review VMBuild.log and refer to internal documentation." -ShowNotification -Failure
    }

    return $worked
}

function Start-VMFixes {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "VMName")]
        [object] $VMName,
        [Parameter(Mandatory = $true, HelpMessage = "VMFixes")]
        [object] $VMFixes
    )

    Write-Log "$VMName`: Applying fixes to the virtual machine." -Verbose

    $success = $false
    $vmStarted = $false

    foreach ($vmFix in $VMFixes | Sort-Object FixVersion ) {
        $status = Start-VMFix -vmName $VMName -vmFix $vmFix

        if ($status.StartedVM) {
            $vmStarted = $true
        }

        $success = $status.Success
        if (-not $success) { break }
    }

    if ($vmStarted) {
        $vmNote = Get-VMNote -VMName $VMName
        if ($vmNote.role -ne "DC") {
            Write-Log "$VMName`: Shutting down VM." -Verbose
            Stop-VM -Name $VMName -Force -ErrorVariable StopError -ErrorAction SilentlyContinue
            if ($StopError.Count -ne 0) {
                Write-Log "$VMName`: Failed to stop the VM" -Warning
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

    # Check applicability
    $fixName = $vmFix.FixName
    $fixVersion = $vmFix.FixVersion
    if (-not $vmFix.AppliesToThisVM) {
        Write-Log "$VMName`: Fix '$fixName' is not applicable. Updating version to '$fixVersion'"
        Set-VMNote -VMName $vmName -vmVersion $fixVersion
        $return.Success = $true
        return $return
    }

    Write-Log "$VMName`: '$fixName' is applicable. Applying fix now."

    # Start VM to apply fix
    $status = Start-VMIfNotRunning -VMName $VMName -Quiet
    $return.StartedVM = $status.StartedVM

    if ($status.StartFailed) {
        Write-Log "$VMName`: VM could not be started to apply fix '$fixName'."
        return $return
    }

    # Apply Fix
    $vmDomain = $vmNote.domain

    $HashArguments = @{
        VmName       = $VMName
        VMDomainName = $vmDomain
        DisplayName  = $vmFix.FixName
        ScriptBlock  = $vmFix.ScriptBlock
    }

    if ($vmFix.ArgumentList) {
        $HashArguments.Add("ArgumentList", $vmFix.ArgumentList)
    }

    $result = Invoke-VmCommand @HashArguments
    if ($result.ScriptBlockFailed) {
        Write-Log "$VMName`: Failed to apply fix '$fixName'."
        $return.Success = $false
    }
    else {
        Write-Log "$VMName`: Fix '$fixName' applied. Updating version to $fixVersion"
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
        [Parameter(Mandatory = $false, HelpMessage = "Quiet - No logging")]
        [switch] $Quiet
    )

    $return = [PSCustomObject]@{
        StartedVM   = $false
        StartFailed = $false
    }

    $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue

    if (-not $vm) {
        Write-Log "$VMName`: Failed to get VM from Hyper-V. Error: $_" -Warning
        return $return
    }

    if ($vm.State -ne "Running") {
        try {
            Start-VM -Name $VMName -ErrorAction Stop
            Write-Log "$VMName`: Starting VM for maintenance and waiting 30 seocnds."
            Start-Sleep -Seconds 30
            $return.StartedVM = $true
            $return.StartFailed = $false
        }
        catch {
            Write-Log "$VMName`: Failed to start VM. Error: $_"
            $return.StartedVM = $false
            $return.StartFailed = $true
        }
    }
    else {
        if (-not $Quiet.IsPresent) { Write-Log "$VMName`: VM is already running." -Verbose }
        $return.StartedVM = $false
    }

    return $return
}

function Get-VMFixes {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "VMName", ParameterSetName="Real")]
        [object] $VMName,
        [Parameter(Mandatory = $true, HelpMessage = "VMName", ParameterSetName="Dummy")]
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
        $accountsToUpdate = @("vmbuildadmin", "administrator", "cm_svc", $accountName)
        $accountsToUpdate = $accountsToUpdate | Select-Object -Unique
        $accountsUpdated = 0
        foreach ($account in $accountsToUpdate) {
            Set-ADUser -Identity $account -PasswordNeverExpires $true -CannotChangePassword $true -ErrorVariable AccountError -ErrorAction SilentlyContinue
            if ($AccountError.Count -eq 0) {
                $accountsUpdated++
            }
        }
        if ($accountsUpdated -ne $accountsToUpdate.Count) {
            throw "Updated $accountsUpdated accounts out of $($accountsToUpdate.Count)."
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
    }

    ### Local account password expiration

    $Fix_LocalAccount = {
        Set-LocalUser -Name "vmbuildadmin" -PasswordNeverExpires $true
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
