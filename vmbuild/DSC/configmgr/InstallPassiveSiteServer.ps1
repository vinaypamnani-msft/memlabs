param(
    [string]$ConfigFilePath,
    [string]$LogPath
)

# Read config json
$deployConfig = Get-Content $ConfigFilePath | ConvertFrom-Json

# Get reguired values from config
$DomainFullName = $deployConfig.parameters.domainName
$DomainName = $DomainFullName.Split(".")[0]

# Read Actions file
$ConfigurationFile = Join-Path -Path $LogPath -ChildPath "ScriptWorkflow.json"
$Configuration = Get-Content -Path $ConfigurationFile | ConvertFrom-Json

$Configuration.InstallPassive.Status = 'Running'
$Configuration.InstallPassive.StartTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
$Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force

# Read Site Code from registry
Write-DscStatus "Setting PS Drive for ConfigMgr"
$SiteCode = Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Microsoft\SMS\Identification' -Name 'Site Code'
$ProviderMachineName = $env:COMPUTERNAME + "." + $DomainFullName # SMS Provider machine name

# Get CM module path
$key = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry32)
$subKey = $key.OpenSubKey("SOFTWARE\Microsoft\ConfigMgr10\Setup")
$uiInstallPath = $subKey.GetValue("UI Installation Directory")
$modulePath = $uiInstallPath + "bin\ConfigurationManager.psd1"
$initParams = @{}

# Import the ConfigurationManager.psd1 module
if ($null -eq (Get-Module ConfigurationManager)) {
    Import-Module $modulePath
}

# Connect to the site's drive if it is not already present
New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $ProviderMachineName @initParams

while ($null -eq (Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue)) {
    Write-DscStatus "Retry in 10s to Set PS Drive" -NoLog
    Start-Sleep -Seconds 10
    New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $ProviderMachineName @initParams
}

# Set the current location to be the site code.
Set-Location "$($SiteCode):\" @initParams

# Get info for Passive Site Server
$ThisMachineName = $deployConfig.parameters.ThisMachineName
$ThisVM = $deployConfig.virtualMachines | Where-Object { $_.vmName -eq $ThisMachineName }
$SSVM = $deployConfig.virtualMachines | Where-Object { $_.siteCode -eq $ThisVM.siteCode -and $_.vmName -ne $ThisVm.vmName }
$shareName = "ContentLib$SiteCode"
$sharePath = "E:\$shareName"
$remoteLibVMName = $SSVM.remoteContentLibVM
$computersToAdd = @("$($SSVM.vmName)$", "$($ThisMachineName)$")

# Create share on remote FS to host Content Library
$create_Share = {

    $shareName = $using:shareName
    $sharePath = $using:sharePath
    $remoteLibVMName = $using:remoteLibVMName
    $computersToAdd = $using:computersToAdd
    $SiteCode = $using:SiteCode

    $exists = Get-SmbShare -Name $shareName -ErrorAction SilentlyContinue
    if ($exists) {
        Grant-SmbShareAccess -Name $shareName -AccountName $computersToAdd -AccessRight Full -Force
    }
    else {
        New-Item -Path $sharePath -type directory -Force
        New-Item -Path (Join-Path $sharePath $SiteCode) -type directory -Force
        New-SMBShare -Name $shareName -Path $sharePath -FullAccess $computersToAdd -ReadAccess Everyone
    }

    # Configure the access object values - READ-ONLY
    $access = [System.Security.AccessControl.AccessControlType]::Allow
    $rights = [System.Security.AccessControl.FileSystemRights]"FullControl"
    $inherit = [System.Security.AccessControl.InheritanceFlags]"ContainerInherit,ObjectInherit"
    $propagate = [System.Security.AccessControl.PropagationFlags]::None

    foreach($item in $computersToAdd) {
        $ace = New-Object System.Security.AccessControl.FileSystemAccessRule($item,$rights,$inherit,$propagate,$access)

        # Retrieve the directory ACL and add a new ACL rule
        $acl = Get-Acl $sharePath
        $acl.AddAccessRule($ace)
        $acl.SetAccessRuleProtection($false,$false)

        # Set-Acl $directory $acl
        Set-ACL -aclobject $acl $sharePath
    }

}

Write-DscStatus "Creating a share on $remoteLibVMName to host the content library"
Invoke-Command -Session (New-PSSession -ComputerName $remoteLibVMName) -ScriptBlock $create_Share

# Remove SCP
# Remove-CMServiceConnectionPoint -SiteSystemServerName SCCM-CAS.contosomd.com -Force
# Add NOSMS on all drives but H for fileserver
# Add CAS to admin group on machine
# New-CMSiteSystemServer -SiteCode CAS -SiteSystemServerName SCCM-FileServer.contosomd.com
# Add-CMServiceConnectionPoint -Mode Online -SiteCode CAS -SiteSystemServerName SCCM-FileServer.contosomd.com
# New-CMSiteSystemServer -SiteCode CAS -SiteSystemServerName SCCM-CAS2.contosomd.com

$contentLibShare = "\\$remoteLibVMName\$shareName\$SiteCode"
Write-DscStatus "Moving Content Library to $contentLibShare for site $SiteCode"
Move-CMContentLibrary -NewLocation $contentLibShare -SiteCode $SiteCode

do {
    $moveStatus = Get-CMSite -SiteCode $SiteCode
    Write-DscStatus "Moving Content Library to $($moveStatus.ContentLibraryLocation), Current Progress: $($moveStatus.ContentLibraryMoveProgress)%" -RetrySeconds 30
    Start-Sleep -Seconds 30
} until ($moveStatus.ContentLibraryMoveProgress -eq 100 -and $null -ne $moveStatus.ContentLibraryLocation)

$passiveFQDN = $SSVM.vmName + "." + $DomainFullName
Write-DscStatus "Adding passive site server on $passiveFQDN"
New-CMSiteSystemServer -SiteCode $SiteCode -SiteSystemServerName $passiveFQDN
Add-CMPassiveSite -InstallDirectory $SSVM.cmInstallDir -SiteCode $SiteCode -SiteSystemServerName $passiveFQDN -SourceFilePathOption CopySourceFileFromActiveSite
do {
    $state = Get-WmiObject -ComputerName $ProviderMachineName -Namespace root\SMS\site_$SiteCode -Class SMS_HA_SiteServerDetailedMonitoring -Filter "IsComplete = 2 AND Applicable = 1" | Sort-Object MessageTime | Select-Object -Last 1
    if ($state) {
        Write-DscStatus "Adding passive site server on $passiveFQDN. Current State: $($state.SubStageName)" -RetrySeconds 60
    }
    Start-Sleep -Seconds 60
} until ($state.SubStageId -eq 917515)

# Update actions file
$Configuration.InstallPassive.Status = 'Completed'
$Configuration.InstallPassive.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
$Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force
