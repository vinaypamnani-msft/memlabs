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
$SecondaryVM = $deployConfig.virtualMachines | Where-Object { $_.role -eq "Secondary" -and $_.parentSiteCode -eq $ThisVM.siteCode }

# Add Passive site
$secondaryFQDN = $SecondaryVM.vmName + "." + $DomainFullName
$secondarySiteCode = $SecondaryVM.siteCode

$SMSInstallDir = "C:\Program Files\Microsoft Configuration Manager"
if ($SecondaryVM.cmInstallDir) {
    $SMSInstallDir = $SecondaryVM.cmInstallDir
}

Write-DscStatus "Adding secondary site server on $secondaryFQDN"
try {

    $Date = [DateTime]::Now.AddYears(30)
    $FileSetting = New-CMInstallationSourceFile -CopyFromParentSiteServer
    $SQLSetting = New-CMSqlServerSetting -CopySqlServerExpressOnSecondarySite
    if ($SecondaryVM.sqlVersion) {
        # TODO: Add remote SQL Setting
    }
    New-CMSecondarySite -CertificateExpirationTimeUtc $Date -Http -InstallationFolder $SMSInstallDir -InstallationSourceFile $FileSetting -InstallInternetServer $True `
        -PrimarySiteCode $SecondaryVM.parentSiteCode -ServerName $secondaryFQDN -SecondarySiteCode $secondarySiteCode `
        -SiteName "Secondary Site" -SqlServerSetting $SQLSetting -CreateSelfSignedCertificate | Out-File $global:StatusLog -Append
}
catch {
    Write-DscStatus "Failed to add secondary site on $secondaryFQDN. Error: $_" -Failure
    return
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

    $state = Get-WmiObject -ComputerName $ProviderMachineName -Namespace root\SMS\site_$SiteCode -Class SMS_SecondarySiteStatus -Filter "SiteCode = '$secondarySiteCode'" | Sort-Object MessageTime | Select-Object -Last 1

    if ($state) {
        Write-DscStatus "Installing Secondary site on $secondaryFQDN`: $($state.Status)" -RetrySeconds 30
    }

    if (-not $state) {
        if (0 -eq $i % 10) {
            Write-DscStatus "No Progress after $i tries, Adding secondary site server again on $secondaryFQDN"
            New-CMSecondarySite -CertificateExpirationTimeUtc $Date -Http -InstallationFolder $SMSInstallDir -InstallationSourceFile $FileSetting -InstallInternetServer $True `
                -PrimarySiteCode $SecondaryVM.parentSiteCode -ServerName $secondaryFQDN -SecondarySiteCode $secondarySiteCode `
                -SiteName "Secondary Site" -SqlServerSetting $SQLSetting -CreateSelfSignedCertificate | Out-File $global:StatusLog -Append
        }

        if ($i -gt 31) {
            Write-DscStatus "No Progress for adding secondary site server after $i tries, giving up." -Failure
            $installFailure = $true
        }
    }

    Start-Sleep -Seconds 30

} until ($installed -or $installFailure)

# Update actions file
$Configuration.InstallSecondary.Status = 'Completed'
$Configuration.InstallSecondary.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
$Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force