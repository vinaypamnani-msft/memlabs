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

$Configuration.InstallSecondary.Status = 'Running'
$Configuration.InstallSecondary.StartTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
$Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force

# Read Site Code from registry
Write-DscStatus "Setting PS Drive for ConfigMgr"
$SiteCode = Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Microsoft\SMS\Identification' -Name 'Site Code'
$ProviderMachineName = $env:COMPUTERNAME + "." + $DomainFullName # SMS Provider machine name
$localSiteServer = $ProviderMachineName

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
New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $ProviderMachineName @initParams -ErrorAction SilentlyContinue

$psDriveFailcount = 0
while ($null -eq (Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue)) {
    $psDriveFailcount++
    if ($psDriveFailcount -gt 20) {
        Write-DscStatus "Failed to get the PS Drive for site $SiteCode.  Install may have failed. Check C:\ConfigMgrSetup.log"
        return
    }
    Write-DscStatus "Retry in 10s to Set PS Drive" -NoLog
    Start-Sleep -Seconds 10
    New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $ProviderMachineName @initParams -ErrorAction SilentlyContinue
}

# Set the current location to be the site code.
Set-Location "$($SiteCode):\" @initParams

function Install-MP {
    param (
        [string]
        $ServerFQDN,
        [string]
        $ServerSiteCode
    )

    $i = 0
    $installFailure = $false
    $MPFQDN = $ServerFQDN

    do {

        $i++
        $SystemServer = Get-CMSiteSystemServer -SiteSystemServerName $MPFQDN
        if (-not $SystemServer) {
            Write-DscStatus "Creating new CM Site System server on $MPFQDN"
            New-CMSiteSystemServer -SiteSystemServerName $MPFQDN -SiteCode $ServerSiteCode | Out-File $global:StatusLog -Append
            Start-Sleep -Seconds 15
            $SystemServer = Get-CMSiteSystemServer -SiteSystemServerName $MPFQDN
        }

        $mpinstalled = Get-CMManagementPoint -SiteSystemServerName $MPFQDN
        if (-not $mpinstalled) {
            Write-DscStatus "MP Role not detected on $MPFQDN. Adding Management Point role."
            Add-CMManagementPoint -InputObject $SystemServer -CommunicationType Http | Out-File $global:StatusLog -Append
            Start-Sleep -Seconds 60
        }
        else {
            Write-DscStatus "MP Role detected on $MPFQDN"
            $mpinstalled = $true
        }

        if ($i -gt 10) {
            Write-DscStatus "No Progress after $i tries, Giving up."
            $installFailure = $true
        }

        Start-Sleep -Seconds 10

    } until ($mpinstalled -or $installFailure)
}

# Get info for Passive Site Server
$ThisMachineName = $deployConfig.parameters.ThisMachineName
$ThisVM = $deployConfig.virtualMachines | where-object {$_.vmName -eq $ThisMachineName}
$SecondaryVM = $deployConfig.virtualMachines | Where-Object { $_.role -eq "Secondary" -and $_.parentSiteCode -eq $ThisVM.siteCode }

# Add Passive site
$secondaryFQDN = $SecondaryVM.vmName + "." + $DomainFullName
$secondarySiteCode = $SecondaryVM.siteCode
$parentSiteCode = $SecondaryVM.parentSiteCode

$SMSInstallDir = "C:\Program Files\Microsoft Configuration Manager"
if ($SecondaryVM.cmInstallDir) {
    $SMSInstallDir = $SecondaryVM.cmInstallDir
}

$mpCount = (Get-CMManagementPoint -SiteCode $SiteCode | Measure-Object).Count
if ($mpCount -eq 0) {
    Write-DscStatus "No MP's were found in this site. Forcing MP install on Site Server $ThisMachineName"
    Install-MP -ServerFQDN ($ThisMachineName + "." + $DomainFullName) -ServerSiteCode $SiteCode
}

Write-DscStatus "Adding secondary site server on $secondaryFQDN with Site Code $secondarySiteCode, attached to $parentSiteCode"
try {

    $Date = [DateTime]::Now.AddYears(30)
    $FileSetting = New-CMInstallationSourceFile -CopyFromParentSiteServer
    $SQLSetting = New-CMSqlServerSetting -CopySqlServerExpressOnSecondarySite -SqlServerServiceBrokerPort 4022 -SqlServerServicePort 1433
    if ($SecondaryVM.sqlVersion) {
        if ($SecondaryVM.sqlInstanceName.ToUpper() -eq "MSSQLSERVER") {
            $SQLSetting = New-CMSqlServerSetting -SiteDatabaseName "CM_$secondarySiteCode" -UseExistingSqlServerInstance -SqlServerServiceBrokerPort 4022
        }
        else {
            $SQLSetting = New-CMSqlServerSetting -SiteDatabaseName "CM_$secondarySiteCode" -UseExistingSqlServerInstance -InstanceName $SecondaryVM.sqlInstanceName -SqlServerServiceBrokerPort 4022
        }
    }

    New-CMSecondarySite -CertificateExpirationTimeUtc $Date -Http -InstallationFolder $SMSInstallDir -InstallationSourceFile $FileSetting -InstallInternetServer $True `
        -PrimarySiteCode $parentSiteCode -ServerName $secondaryFQDN -SecondarySiteCode $secondarySiteCode `
        -SiteName "Secondary Site" -SqlServerSetting $SQLSetting -CreateSelfSignedCertificate | Out-File $global:StatusLog -Append
}
catch {
    try {
        $_ | Out-File $global:StatusLog -Append
        Write-DscStatus "Failed to add secondary site on $secondaryFQDN. Error: $_. Retrying once."
        Start-Sleep -Seconds 30
        New-CMSecondarySite -CertificateExpirationTimeUtc $Date -Http -InstallationFolder $SMSInstallDir -InstallationSourceFile $FileSetting -InstallInternetServer $True `
        -PrimarySiteCode $parentSiteCode -ServerName $secondaryFQDN -SecondarySiteCode $secondarySiteCode `
        -SiteName "Secondary Site" -SqlServerSetting $SQLSetting -CreateSelfSignedCertificate | Out-File $global:StatusLog -Append
    }
    catch {
        $_ | Out-File $global:StatusLog -Append
        Write-DscStatus "Failed to add secondary site on $secondaryFQDN. Error: $_" -Failure
        return
    }
}

$i = 0
$installed = $false

do {

    $i++
    $siteStatus = Get-CMSite -SiteCode $secondarySiteCode

    if ($siteStatus -and $siteStatus.Status -eq 1) {
        $installed = $true
    }

    if ($siteStatus -and $siteStatus.Status -eq 3) {
        Write-DscStatus "Adding secondary site server failed. Review details in ConfigMgr Console." -Failure
        $installFailure = $true
    }

    if ($siteStatus -and $siteStatus.Status -eq 2) {
        $state = Get-WmiObject -ComputerName $ProviderMachineName -Namespace root\SMS\site_$SiteCode -Class SMS_SecondarySiteStatus -Filter "SiteCode = '$secondarySiteCode'" | Sort-Object MessageTime | Select-Object -Last 1

        if ($state) {
            Write-DscStatus "Installing Secondary site on $secondaryFQDN`: $($state.Status)" -RetrySeconds 30
        }

        if (-not $state) {
            if (0 -eq $i % 20) {
                Write-DscStatus "No Progress reported after $($i * 30) seconds, restarting SMS_Executive"
                Restart-Service -DisplayName "SMS_Executive" -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 60
            }

            if ($i -gt 61) {
                Write-DscStatus "No Progress for adding secondary site reported after $($i * 30) seconds, giving up." -Failure
                $installFailure = $true
            }
        }
    }

    Start-Sleep -Seconds 30

} until ($installed -or $installFailure)

if ($installed) {
    # Wait for replication ready
    $replicationStatus = Get-CMDatabaseReplicationStatus -Site2 $secondarySiteCode
    Write-DscStatus "Secondary installation complete. Waiting for replication link to be 'Active'"
    Start-Sleep -Seconds 30
    while ($replicationStatus.LinkStatus -ne 2 -or $replicationStatus.Site1ToSite2GlobalState -ne 2 -or $replicationStatus.Site2ToSite1GlobalState -ne 2 ) {
        Write-DscStatus "Waiting for Data Replication. $SiteCode -> $secondarySiteCode global data init percentage: $($replicationStatus.GlobalInitPercentage)" -RetrySeconds 60
        Start-Sleep -Seconds 60
        $replicationStatus = Get-CMDatabaseReplicationStatus -Site2 $secondarySiteCode
    }

    Write-DscStatus "Secondary installation complete. Replication link is 'Active'."
}

# Update actions file
$Configuration.InstallSecondary.Status = 'Completed'
$Configuration.InstallSecondary.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
$Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force