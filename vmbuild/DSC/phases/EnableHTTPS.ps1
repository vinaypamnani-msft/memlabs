#enableHTTPS.ps1
param(
    [string]$ConfigFilePath,
    [string]$LogPath,
    [bool]$FirstRun
)

# Read config json
$deployConfig = Get-Content $ConfigFilePath | ConvertFrom-Json

# Get reguired values from config
$DomainFullName = $deployConfig.parameters.domainName
$ThisMachineName = $deployConfig.parameters.ThisMachineName
$ThisVM = $deployConfig.virtualMachines | where-object { $_.vmName -eq $ThisMachineName }
$isCas = $ThisVM.Role -eq "CAS"
$DCName = ($deployConfig.virtualMachine | Where-Object { $_.Role -eq "DC" }).vmName
# Read Site Code from registry
Write-DscStatus "Setting PS Drive for ConfigMgr" -NoStatus
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
$psDriveFailcount = 0
while ($null -eq (Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue)) {
    $psDriveFailcount++
    if ($psDriveFailcount -gt 20) {
        Write-DscStatus "Failed to get the PS Drive for site $SiteCode.  Install may have failed. Check C:\ConfigMgrSetup.log" -NoStatus
        return
    }
    Write-DscStatus "Retry in 10s to Set PS Drive" -NoStatus
    Start-Sleep -Seconds 10
    New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $ProviderMachineName @initParams
}

# Set the current location to be the site code.
Set-Location "$($SiteCode):\" @initParams

# Keep setting it every 30 seconds, 10 times and bail...
$enabled = $false
$attempts = 0
$maxAttempts = 5

if (-not $FirstRun) {
    # Only try this once (in case it failed during initial PS setup when we're re-running DSC)
    Write-DscStatus "Not the first run.. Skipping HTTPS setup."
    return
    $attempts = $maxAttempts
}

Write-DscStatus "Enabling HTTPS"
$prop = Get-CMSiteComponent -SiteCode $SiteCode -ComponentName "SMS_SITE_COMPONENT_MANAGER" | Select-Object -ExpandProperty Props | Where-Object { $_.PropertyName -eq "IISSSLState" }
$enabled = ($prop.Value -eq 63)
if ($enabled) {
    Write-DscStatus "HTTPS Already Enabled.. Done." 
    return
}
$CAName = $DCName + "-CA"
$CertPath = "c:\temp\rootca.cer"

if (-not (Test-Path $CertPath)) {
    Get-Item  Cert:\LocalMachine\CA\* | Where-Object { $_.Subject -cmatch $CAName } | Export-Certificate -FilePath $CertPath -Force
    Write-DscStatus "Exported root CA to $CertPath"
}


$flagFile = "C:\staging\DSC\EnableEHTTPorHTTPS.flag"

# Check if the flag file exists
if (Test-Path $flagFile) {
    Write-DscStatus "HTTPS already enabled. Flag file exists. Skipping execution."
}
else {
    do {
        $attempts++   
        Write-DscStatus "Enable HTTPS"
        $prop = Get-CMSiteComponent -SiteCode $SiteCode -ComponentName "SMS_SITE_COMPONENT_MANAGER" | Select-Object -ExpandProperty Props | Where-Object { $_.PropertyName -eq "IISSSLState" }

        if ($isCas) {
       
            $NameSpace = "ROOT\SMS\site_$SiteCode"
            #Hack for CAS.. Since Set-CMSite doesnt appear to work on CAS:
            # Get the WMI object
            $component = gwmi -ns $NameSpace -Query "SELECT * FROM SMS_SCI_Component WHERE FileType=2 AND ItemName='SMS_SITE_COMPONENT_MANAGER|SMS Site Server' AND ItemType='Component' AND SiteCode='$SiteCode'"
            # Get the Props array
            $props = $component.Props
            # Find the index of the IISSSLState property in the Props array
            $index = [Array]::IndexOf($props.PropertyName, 'IISSSLState')
            # Change the Value of the IISSSLState property
            $props[$index].Value = 63
            # Assign the modified Props array back to the component
            $component.Props = $props
            # Save the changes
            $component.Put()
            #End Hack 
        }
        Set-CMSite -SiteCode $SiteCode -UsePkiClientCertificate $true -ClientComputerCommunicationType HttpsOnly -AddCertificateByPath $CertPath *>&1 | Out-File $global:StatusLog -Append

        Start-Sleep 10

        $prop = Get-CMSiteComponent -SiteCode $SiteCode -ComponentName "SMS_SITE_COMPONENT_MANAGER" | Select-Object -ExpandProperty Props | Where-Object { $_.PropertyName -eq "IISSSLState" }
        $enabled = ($prop.Value -eq 63)
        Write-DscStatus "IISSSLState Value is $($prop.Value). HTTPS enabled: $enabled" -RetrySeconds 15
    } until ($attempts -ge $maxAttempts)

    if (-not $enabled) {
        Write-DscStatus "HTTPS not enabled after trying $attempts times, skip."
    }
    else {
        Write-DscStatus "HTTPS was enabled."
        New-Item -ItemType File -Path $flagFile -Force | Out-Null
    }
}