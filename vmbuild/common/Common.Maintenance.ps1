
function Invoke-Maintenance {

    $vmsNeedingMaintenance = Get-List -Type VM | Where-Object { $_.memLabsVersion -lt $Common.LatestHotfixVersion }
    $vmsNeedingMaintenance = $vmsNeedingMaintenance | Where-Object { $_.role -ne "OSDClient" }
    $vmCount = ($vmsNeedingMaintenance | Measure-Object).Count

    $text = "Performing VM maintenance"
    Write-Progress -Activity $text -Status "Please wait..." -PercentComplete 0
    # Write-Log $text -Activity

    if ($vmCount -gt 0) {
        Write-Log "$vmCount VM's need maintenance. VM's will be started if needed and shut down post-maintenance." -Activity
    }
    else {
        Write-Log "There are no VM's that need maintenance." -Activity
        return
    }

    $i = 0
    $countWorked = $countFailed = 0

    # Perform maintenance... run it on DC's first, rest after. Start DC if not running, but don't bother stoppping them. Other VM's would need domain creds to work.
    foreach ($vm in $vmsNeedingMaintenance | Where-Object { $_.role -eq "DC" }) {
        $i++
        Start-VMIfNotRunning -VMName $vm.vmName | Out-Null
        $worked = Invoke-VMMaintenance -VMName $vm.vmName
        if ($worked) { $countWorked++} else {$countFailed++}
        Write-Progress -Activity $text -Status "Performing maintenance on VM $i/$vmCount`: $($vm.vmName)" -PercentComplete (($i/$vmCount)*100)
    }

    foreach ($vm in $vmsNeedingMaintenance | Where-Object { $_.role -ne "DC" }) {
        $i++
        $worked = Invoke-VMMaintenance -VMName $vm.vmName
        if ($worked) { $countWorked++} else {$countFailed++}
        Write-Progress -Activity $text -Status "Performing maintenance on VM $i/$vmCount`: $($vm.vmName)" -PercentComplete (($i/$vmCount)*100)
    }

    Write-Log "Finished maintenance. Success: $countWorked; Failures: $countFailed" -Activity
    Write-Progress -Activity $text -Completed
}

function Invoke-VMMaintenance {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "VMName")]
        [object] $VMName
    )

    $vmNoteObject = Get-VMNote -VMName $VMName

    if (-not $vmNoteObject) {
        Write-Log "$vmName`: VM Notes property could not be read. Skipping." -Warning -LogOnly
        return $false
    }

    $latestFixVersion = $Common.LatestHotfixVersion
    $inProgress = if ($vmNoteObject.inProgress) { $true } else { $false }
    $vmVersion = $vmNoteObject.memLabsVersion

    if ($inProgress) {
        Write-Log "$vmName`: VM Deployment State is in-progress. Skipping." -Verbose
        return $false
    }

    if ($vmVersion -ge $latestFixVersion) {
        Write-Log "$VMName`: VM Version ($vmVersion) is up-to-date." -Verbose
        return $true
    }

    Write-Log "$VMName`: VM (version $vmVersion) is NOT up-to-date. Required Version is $latestFixVersion." -SubActivity

    $startInitiated = Start-VMIfNotRunning -VMName $VMName

    $worked = Set-PasswordExpiration -vmNoteObject $vmNoteObject -fixVersion "211125.1"

    if ($worked) {
        $worked = Set-AdminProfileFix -vmNoteObject $vmNoteObject -fixVersion "211125.2"
    }

    if ($worked) {
        Write-Log "$VMName`: VM maintenance completed successfully." -Success
    }
    else {
        Write-Log "$VMName`: VM maintenance failed. Review VMBuild.log and refer to internal documentation." -ShowNotification -Failure
    }

    if ($startInitiated) {
        Write-Log "$VMName`: Shutting down VM." -Verbose
        Stop-VM -Name $VMName -Force -ErrorAction SilentlyContinue
    }

    return $worked

}

function Start-VMIfNotRunning {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "VM Name")]
        [string] $VMName,
        [Parameter(Mandatory = $false, HelpMessage = "Quiet - No logging")]
        [switch] $Quiet
    )

    $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue

    if (-not $vm) {
        if (-not $Quiet.IsPresent) { Write-Log "$VMName`: Failed to get VM from Hyper-V. Error: $_" }
        return $false
    }

    if ($vm.State -ne "Running") {
        try {
            Start-VM -Name $VMName -ErrorAction Stop
            Write-Log "$VMName`: Starting VM for maintenance and waiting 30 seocnds."
            Start-Sleep -Seconds 30
            return $true
        }
        catch {
            Write-Log "$VMName`: Failed to start VM. Error: $_"
            return $false
        }
    }
    else {
        if (-not $Quiet.IsPresent) { Write-Log "$VMName`: VM is already running." -Verbose }
        return $false
    }
}

function Set-PasswordExpiration {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "VMNoteObject")]
        [object] $vmNoteObject,
        [Parameter(Mandatory = $true, HelpMessage = "FixVersion")]
        [string] $fixVersion
    )

    if (-not $vmNoteObject) {
        return $false
    }

    $vmDomain = $vmNoteObject.domain
    $vmAdminUser = $vmNoteObject.adminName
    $vmVersion = $vmNoteObject.memLabsVersion

    if ($vmVersion -ge $fixVersion) {
        Write-Log "$VMName`: VM (version $vmVersion)  already has the fix ($fixVersion) applied." -Verbose
        return $true
    }

    $startInitiated = Start-VMIfNotRunning -VMName $VMName -Quiet
    $success = $false

    $Fix_DomainAccount = {
        Set-ADUser -Identity $using:account -PasswordNeverExpires $true -CannotChangePassword $true
    }

    $Fix_LocalAccount = {
        Set-LocalUser -Name $using:account -PasswordNeverExpires $true
    }

    if ($vmNoteObject.role -eq "DC") {
        $accountsToUpdate = @("vmbuildadmin", "administrator", "cm_svc", $vmAdminUser)
        $accountsToUpdate = $accountsToUpdate | Select-Object -Unique
        $accountsUpdated = 0
        foreach ($account in $accountsToUpdate) {
            $accountReset = Invoke-VmCommand -VmName $VMName -VmDomainName $vmDomain -ScriptBlock $Fix_DomainAccount -DisplayName "Fix $account Password Expiration"
            if ($accountReset.ScriptBlockFailed) {
                Write-Log "$VMName`: Failed to set PasswordNeverExpires flag for '$vmDomain\$account'" -Failure -LogOnly
            }
            else {
                Write-Log "$VMName`: Set PasswordNeverExpires flag for '$vmDomain\$account'" -Verbose
                $accountsUpdated++
            }
        }
        $success = $accountsUpdated -eq $accountsToUpdate.Count
        Write-Log "Updated $accountsUpdated accounts out of $($accountsToUpdate.Count). Result: $success" -Verbose
    }

    if ($vmNoteObject.role -ne "DC") {
        $account = "vmbuildadmin"
        $accountReset = Invoke-VmCommand -VmName $VMName -VmDomainName $vmDomain -ScriptBlock $Fix_LocalAccount -DisplayName "Fix $account Password Expiration"
        if ($accountReset.ScriptBlockFailed) {
            Write-Log "$VMName`: Failed to set PasswordNeverExpires flag for '$VMName\$account'" -Failure -LogOnly
        }
        else {
            Write-Log "$VMName`: Set PasswordNeverExpires flag for '$VMName\$account'" -Verbose
            $success = $true
        }
        Write-Log "Updated vmbuildaccount. Result: $success" -Verbose
    }

    if ($startInitiated) {
        Write-Log "$VMName`: Shutting down VM." -Verbose
        Stop-VM -Name $VMName -Force -ErrorAction SilentlyContinue
    }

    if ($success) {
        Write-Log "$VMName`: Fix applied. Updating version to $fixVersion" -Verbose
        Set-VMNote -vmName $VMName -vmVersion $fixVersion
    }

    return $success
}

function Set-AdminProfileFix {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, HelpMessage = "VMNoteObject")]
        [object] $vmNoteObject,
        [Parameter(Mandatory = $true, HelpMessage = "FixVersion")]
        [string] $fixVersion
    )

    if (-not $vmNoteObject) {
        return $false
    }

    $vmDomain = $vmNoteObject.domain
    $vmVersion = $vmNoteObject.memLabsVersion

    if ($vmVersion -ge $fixVersion) {
        Write-Log "$VMName`: VM (version $vmVersion) already has the fix ($fixVersion) applied." -Verbose
        return $true
    }

    $startInitiated = Start-VMIfNotRunning -VMName $VMName -Quiet

    $Fix_DefaultProfile = {
        $path1 = "C:\Users\Default\AppData\Local\Microsoft\Windows\WebCache"
        $path2 = "C:\Users\Default\AppData\Local\Microsoft\Windows\INetCache"
        $path3 = "C:\Users\Default\AppData\Local\Microsoft\Windows\WebCacheLock.dat"
        if (Test-Path $path1) { Remove-Item -Path $path1 -Force -Recurse | Out-Null }
        if (Test-Path $path2) { Remove-Item -Path $path2 -Force -Recurse | Out-Null }
        if (Test-Path $path3) { Remove-Item -Path $path3 -Force | Out-Null }
    }

    $success = $false
    $result = Invoke-VmCommand -VmName $VMName -VmDomainName $vmDomain -ScriptBlock $Fix_DefaultProfile -DisplayName "Fix Default Profile"
    if ($result.ScriptBlockFailed) {
        Write-Log "$VMName`: Failed to fix the default user profile." -Warning -LogOnly
    }
    else {
        Write-Log "$VMName`: Fixed the default user profile." -Verbose
        $success = $true
    }

    if ($startInitiated) {
        Write-Log "$VMName`: Shutting down VM." -Verbose
        Stop-VM -Name $VMName -Force -ErrorAction SilentlyContinue
    }

    if ($success) {
        Write-Log "$VMName`: Fix applied. Updating version to $fixVersion" -Verbose
        Set-VMNote -vmName $VMName -vmVersion $fixVersion
    }

    return $success
}