param(
    [string]$ConfigFilePath,
    [string]$LogPath
)

# Read config json
$deployConfig = Get-Content $ConfigFilePath | ConvertFrom-Json

# Get reguired values from config
$DomainFullName = $deployConfig.vmOptions.domainName
#$DomainName = $DomainFullName.Split(".")[0]
$DomainName = $deployConfig.vmOptions.domainNetBiosName

# Read Actions file
$ConfigurationFile = Join-Path -Path $LogPath -ChildPath "ScriptWorkflow.json"
$Configuration = Get-Content -Path $ConfigurationFile | ConvertFrom-Json

$Configuration.InstallPassive.Status = 'Running'
$Configuration.InstallPassive.StartTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
$Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force

# Read Site Code from registry
$SiteCode = Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Microsoft\SMS\Identification' -Name 'Site Code'
if (-not $SiteCode) {
    Write-DscStatus "Failed to get 'Site Code' from SOFTWARE\Microsoft\SMS\Identification. Install may have failed. Check C:\ConfigMgrSetup.log" -Failure
    return
}

# Provider
$smsProvider = Get-SMSProvider -SiteCode $SiteCode
if (-not $smsProvider.FQDN) {
    Write-DscStatus "Failed to get SMS Provider for site $SiteCode. Install may have failed. Check C:\ConfigMgrSetup.log" -Failure
    return $false
}

# Set CMSite Provider
$worked = Set-CMSiteProvider -SiteCode $SiteCode -ProviderFQDN $($smsProvider.FQDN)
if (-not $worked) {
    return
}

# Set the current location to be the site code.
Set-Location "$($SiteCode):\"
if ((Get-Location).Drive.Name -ne $SiteCode) {
    Write-DscStatus "Failed to Set-Location to $SiteCode`:"
    return $false
}

# Get info for Passive Site Server
$ThisMachineName = $deployconfig.Parameters.ThisMachineName
$ThisVM = $deployConfig.virtualMachines | where-object {$_.vmName -eq $deployconfig.Parameters.ThisMachineName}
$SSVM = $deployConfig.virtualMachines | Where-Object { $_.siteCode -eq $ThisVM.siteCode -and $_.role -eq "PassiveSite" }
$shareName = $SiteCode
$sharePath = "E:\$shareName"
$remoteLibVMName = $SSVM.remoteContentLibVM
$passiveFQDN = $SSVM.vmName + "." + $DomainFullName
if ($remoteLibVMName -is [string]) {$remoteLibVMName = $remoteLibVMName.Trim() }
$computersToAdd = @("$($SSVM.vmName)$", "$($ThisMachineName)$")
$contentLibShare = "\\$remoteLibVMName\$shareName\ContentLib"

# Check if Passive already exists
$exists = Get-CMSiteRole -SiteSystemServerName $passiveFQDN -RoleName "SMS Site Server"
if ($exists) {
    Write-DscStatus "Passive Site Server is already installed on $($SSVM.vmName). Exiting."
    Start-Sleep -Seconds 5 # Force sleep for status to update on host.
    return
}

# Create share on remote FS to host Content Library
$create_Share = {

    $shareName = $using:shareName
    $sharePath = $using:sharePath
    $computersToAdd = $using:computersToAdd

    $exists = Get-SmbShare -Name $shareName -ErrorAction SilentlyContinue
    if ($exists) {
        Grant-SmbShareAccess -Name $shareName -AccountName $computersToAdd -AccessRight Full -Force -ErrorAction Stop
    }
    else {
        New-Item -Path $sharePath -type directory -Force -ErrorAction Stop
        New-Item -Path (Join-Path $sharePath "ContentLib") -type directory -Force -ErrorAction Stop
        New-SMBShare -Name $shareName -Path $sharePath -FullAccess $computersToAdd -ReadAccess Everyone -ErrorAction Stop
    }

    # Configure the access object values - READ-ONLY
    $access = [System.Security.AccessControl.AccessControlType]::Allow
    $rights = [System.Security.AccessControl.FileSystemRights]"FullControl"
    $inherit = [System.Security.AccessControl.InheritanceFlags]"ContainerInherit,ObjectInherit"
    $propagate = [System.Security.AccessControl.PropagationFlags]::None

    foreach ($item in $computersToAdd) {
        $ace = New-Object System.Security.AccessControl.FileSystemAccessRule($item, $rights, $inherit, $propagate, $access)

        # Retrieve the directory ACL and add a new ACL rule
        $acl = Get-Acl $sharePath -ErrorAction Stop
        $acl.AddAccessRule($ace)
        $acl.SetAccessRuleProtection($false, $false)

        # Set-Acl $directory $acl
        Set-ACL -aclobject $acl $sharePath -ErrorAction Stop
    }

}

Write-DscStatus "Creating a share on $remoteLibVMName to host the content library"
Invoke-Command -Session (New-PSSession -ComputerName $remoteLibVMName) -ScriptBlock $create_Share -ErrorVariable Err2

if ($Err2.Count -ne 0) {
    Write-DscStatus "Invoke-Command: Failed to create share $contentLibShare on $remoteLibVMName. Error: $Err2" -Failure
    return
}

$add_local_admin = {
    param($computersToAdd, $domainName)
    foreach($computer in $computersToAdd) {
        if ($computer -eq "$($env:COMPUTERNAME)$") { continue }
        $memberToCheck = "$domainName\$computer"
        $exists = Get-LocalGroupMember -Name "Administrators" -Member $memberToCheck
        if (-not $exists) {
            Add-LocalGroupMember -Group "Administrators" -Member $computer
        }
    }
}

Write-DscStatus "Verifying/adding Active and Passive computer accounts on all site system servers"
$siteSystems = Get-CMSiteSystemServer -SiteCode $SiteCode | Select-Object -Expand NetworkOSPath
$siteSystems += "\\$remoteLibVMName"
$localSiteServer = "$($env:COMPUTERNAME).$($env:USERDNSDOMAIN)"
foreach ($server in $siteSystems) {
    $serverName = $server.Substring(2, $server.Length - 2) # NetworkOSPath = \\server.domain.dom
    if ($serverName -eq $localSiteServer) {
        Invoke-Command -ScriptBlock $add_local_admin -ArgumentList $computersToAdd, $domainName -ErrorVariable Err3
    }
    else {
        Invoke-Command -Session (New-PSSession -ComputerName $serverName) -ScriptBlock $add_local_admin -ArgumentList $computersToAdd, $domainName -ErrorVariable Err3
    }

    $displayName = $computersToAdd -join ","
    if ($Err3.Count -ne 0) {
        Write-DscStatus "WARNING: Failed to add [$displayName] to local Administrators group on $serverName. Error: $Err3"
    }
    else {
        Write-DscStatus "Verified/added [$displayName] as members of local Administrators group on $serverName."
    }
}

# Remove SCP?
# Remove-CMServiceConnectionPoint -SiteSystemServerName SCCM-CAS.contosomd.com -Force
# Add NOSMS on all drives but H for fileserver
# Add CAS to admin group on machine
# New-CMSiteSystemServer -SiteCode CAS -SiteSystemServerName SCCM-FileServer.contosomd.com
# Add-CMServiceConnectionPoint -Mode Online -SiteCode CAS -SiteSystemServerName SCCM-FileServer.contosomd.com
# New-CMSiteSystemServer -SiteCode CAS -SiteSystemServerName SCCM-CAS2.contosomd.com

if ((Get-CMDistributionPoint -SiteSystemServerName $localSiteServer).count -eq 1) {
    Write-DscStatus "Removing DP Role from $localSiteServer before moving Content Library."
    Remove-CMDistributionPoint -SiteSystemServerName $localSiteServer -Force | Out-File $global:StatusLog -Append
}


Write-DscStatus "Moving Content Library to $contentLibShare for site $SiteCode"
Move-CMContentLibrary -NewLocation $contentLibShare -SiteCode $SiteCode | Out-File $global:StatusLog -Append

$i = 0
$lastMoveProgress = 0
do {
    $moveStatus = Get-CMSite -SiteCode $SiteCode
    $moveProgress = $moveStatus.ContentLibraryMoveProgress

    if ($lastMoveProgress -eq $moveProgress) {
        $i++
    }
    else {
        $i = 0
    }

    if ($i -gt 120) {
        # Bail after progress hasn't change for 60 minutes (30 seconds * 120)
        $bailOut = $true
        break
    }

    Start-Sleep -Seconds 30
    Write-DscStatus "Moving Content Library to $contentLibShare, Current Progress: $moveProgress%" -RetrySeconds 30

    if ($moveStatus.ContentLibraryStatus -eq 3) {
        Write-DscStatus "Content Library Location empty after move. Retrying Content Library Move"
        Move-CMContentLibrary -NewLocation $contentLibShare -SiteCode $SiteCode | Out-File $global:StatusLog -Append
    }

    $lastMoveProgress = $moveStatus.ContentLibraryMoveProgress

} until ($moveProgress -eq 100 -and (-not [string]::IsNullOrWhitespace($moveStatus.ContentLibraryLocation)))
if ($bailOut) {
    Write-DscStatus "Gave up after 1 hour on Content Library move after move progress stalled at $moveProgress%. Exiting." -Failure
    return
}
else {
    Write-DscStatus "Content Library moved to $($moveStatus.ContentLibraryLocation)"
}

# Add Passive site
$SMSInstallDir = "C:\Program Files\Microsoft Configuration Manager"
if ($SSVM.cmInstallDir) {
    $SMSInstallDir = $SSVM.cmInstallDir
}
Write-DscStatus "Adding passive site server on $passiveFQDN"
try {
    New-CMSiteSystemServer -SiteCode $SiteCode -SiteSystemServerName $passiveFQDN | Out-File $global:StatusLog -Append
    Add-CMPassiveSite -InstallDirectory $SMSInstallDir -SiteCode $SiteCode -SiteSystemServerName $passiveFQDN -SourceFilePathOption CopySourceFileFromActiveSite | Out-File $global:StatusLog -Append
}
catch {
    Write-DscStatus "Failed to add passive site on $passiveFQDN. Error: $_" -Failure
    return
}

$i = 0
$failureCount = 0
do {

    $i++
    $prereqFailure = Get-WmiObject -ComputerName $smsProvider.FQDN -Namespace $smsProvider.NamespacePath -Class SMS_HA_SiteServerDetailedPrereqMonitoring  -Filter "IsComplete = 4 AND Applicable = 1 AND Progress = 100 AND SiteCode = '$SiteCode'" | Sort-Object MessageTime | Select-Object -Last 1
    if ($prereqFailure) {
        Write-DscStatus "Failed to add passive site server on $passiveFQDN due to prereq failure. Reason: $($prereqFailure.SubStageName)" -Failure
    }

    $installFailure = Get-WmiObject -ComputerName $smsProvider.FQDN -Namespace $smsProvider.NamespacePath -Class SMS_HA_SiteServerDetailedMonitoring -Filter "IsComplete = 4 AND Applicable = 1 AND SiteCode = '$SiteCode'" | Sort-Object MessageTime | Select-Object -Last 1
    if ($installFailure) {
        $failureCount++
        if ($failureCount -gt 10) {
            # Some failures are recovered, give it enough time to try to recover - 10 mins should be sufficient
            Write-DscStatus "Failed to add passive site server on $passiveFQDN. Failure State: $($state.SubStageName): $($state.Description)" -Failure
        }
    }
    else {
        $failureCount = 0
    }

    $state = Get-WmiObject -ComputerName $smsProvider.FQDN -Namespace $smsProvider.NamespacePath -Class SMS_HA_SiteServerDetailedMonitoring -Filter "IsComplete = 2 AND Applicable = 1 AND SiteCode = '$SiteCode'" | Sort-Object MessageTime | Select-Object -Last 1

    if ($state) {
        Write-DscStatus "Adding passive site server on $passiveFQDN`: $($state.SubStageName)" -RetrySeconds 30
    }

    if (-not $state) {
        if (0 -eq $i % 20) {
            Write-DscStatus "No Progress for adding passive site server reported after $($i * 30) seconds, restarting SMS_Executive"
            Restart-Service -DisplayName "SMS_Executive" -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 30
        }

        if ($i -gt 61) {
            Write-DscStatus "No Progress for adding passive site server reported after $($i * 30) seconds, giving up." -Failure
            $installFailure = $true
        }
    }

    Start-Sleep -Seconds 60

} until ($state.SubStageId -eq 917515 -or $prereqFailure -or $installFailure)

# Update actions file
$Configuration.InstallPassive.Status = 'Completed'
$Configuration.InstallPassive.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
$Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force