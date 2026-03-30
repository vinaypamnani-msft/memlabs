#enableEHTTP.ps1
param(
    [string]$configFilePath,
    [string]$logPath,
    [bool]$firstRun
)

# Read config json
$deployConfig = Get-Content $configFilePath | ConvertFrom-Json

# Get required values from config
$domainFullName = $deployConfig.parameters.domainName
$thisMachineName = $deployConfig.parameters.thisMachineName
$thisVM = $deployConfig.virtualMachines | Where-Object { $_.vmName -eq $thisMachineName }
$isCas = $thisVM.Role -eq "CAS"

# Read Site Code from registry
Write-DscStatus "Setting PS Drive for ConfigMgr" -NoStatus
$siteCode = Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Microsoft\SMS\Identification' -Name 'Site Code'
$providerMachineName = $env:COMPUTERNAME + "." + $domainFullName # SMS Provider machine name

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

# Check if the configuration file exists
if (-not (Test-Path $configFilePath)) {
    Write-DscStatus "Configuration file not found at path: $configFilePath" -NoStatus
    return
}

# Check if the log path is writable
try {
    if (-not (Test-Path $logPath)) {
        New-Item -ItemType Directory -Path $logPath -Force | Out-Null
    }
} catch {
    Write-DscStatus "Failed to create or access log directory at path: $logPath" -NoStatus
    return
}

# Validate registry key existence
if (-not (Test-Path 'HKLM:\SOFTWARE\Microsoft\SMS\Identification')) {
    Write-DscStatus "Registry key for Site Code not found. Ensure ConfigMgr is installed." -NoStatus
    return
}

# Validate module path
if (-not (Test-Path $modulePath)) {
    Write-DscStatus "ConfigurationManager.psd1 module not found at path: $modulePath" -NoStatus
    return
}

# Connect to the site's drive if it is not already present
try {
    New-PSDrive -Name $siteCode -PSProvider CMSite -Root $providerMachineName @initParams
} catch {
    Write-DscStatus "Failed to create PS Drive for site $siteCode. Error: $_" -NoStatus
    return
}

# Validate PS Drive creation
$psDriveFailCount = 0
while ($null -eq (Get-PSDrive -Name $siteCode -PSProvider CMSite -ErrorAction SilentlyContinue)) {
    $psDriveFailCount++
    if ($psDriveFailCount -gt 20) {
        Write-DscStatus "Failed to get the PS Drive for site $siteCode after multiple attempts. Check C:\ConfigMgrSetup.log" -NoStatus
        return
    }
    Write-DscStatus "Retry in 10s to Set PS Drive" -NoStatus
    Start-Sleep -Seconds 10
    try {
        New-PSDrive -Name $siteCode -PSProvider CMSite -Root $providerMachineName @initParams
    } catch {
        Write-DscStatus "Failed to create PS Drive for site $siteCode during retry. Error: $_" -NoStatus
    }
}

# Set the current location to be the site code.
Set-Location "$($siteCode):\" @initParams


$prop = Get-CMSiteComponent -SiteCode $siteCode -ComponentName "SMS_SITE_COMPONENT_MANAGER" | Select-Object -ExpandProperty Props | Where-Object { $_.PropertyName -eq "IISSSLState" }

$flagFile = "C:\staging\DSC\EnableEHTTPorHTTPS.flag"

# Check if the flag file exists
if (Test-Path $flagFile) {
    Write-DscStatus "EHTTP already enabled. Flag file exists. Skipping execution."
}
else {

    # Enable EHTTP, some components are still installing and they reset it to Disabled.
    # Keep setting it every 30 seconds, 10 times and bail...
    $enabled = $false
    $attempts = 0
    $maxAttempts = 40

    if (-not $firstRun) {
        Write-DscStatus "Not the first run.. Skipping e-HTTP setup."
        return
        # Only try this once (in case it failed during initial PS setup when we're re-running DSC)
        $attempts = $maxAttempts
    }
    else {
   
        #Hack.. Set to HTTPS first, then back to EHTTP (First Run only):

        if ($isCas) {
            $NameSpace = "ROOT\SMS\site_$SiteCode"
            #Hack for CAS.. Since Set-CMSite doesn't appear to work on CAS:
            # Get the WMI object
            try {
                $component = gwmi -ns $NameSpace -Query "SELECT * FROM SMS_SCI_Component WHERE FileType=2 AND ItemName='SMS_SITE_COMPONENT_MANAGER|SMS Site Server' AND ItemType='Component' AND SiteCode='$SiteCode'"
            } catch {
                Write-DscStatus "Failed to query WMI for CAS. Error: $_" -NoStatus
                return
            }

            if (-not $component) {
                Write-DscStatus "WMI query returned no results for CAS. Ensure the site code and namespace are correct." -NoStatus
                return
            }

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
        }
    }


    Write-DscStatus "Enabling e-HTTP" -NoStatus
    do {
        $attempts++
   

        if ($isCas) {
            $NameSpace = "ROOT\SMS\site_$SiteCode"
            # Hack for CAS.. Since Set-CMSite doesn't appear to work on CAS:
            # Get the WMI object
            try {
                $component = gwmi -ns $NameSpace -Query "SELECT * FROM SMS_SCI_Component WHERE FileType=2 AND ItemName='SMS_SITE_COMPONENT_MANAGER|SMS Site Server' AND ItemType='Component' AND SiteCode='$SiteCode'"
            } catch {
                Write-DscStatus "Failed to query WMI for CAS during e-HTTP enabling. Error: $_" -NoStatus
                return
            }

            if (-not $component) {
                Write-DscStatus "WMI query returned no results for CAS during e-HTTP enabling. Ensure the site code and namespace are correct. Retrying..." -NoStatus
                Start-Sleep -Seconds 10
                continue
            }

            # Get the Props array
            $props = $component.Props
            # Find the index of the IISSSLState property in the Props array
            $index = [Array]::IndexOf($props.PropertyName, 'IISSSLState')
            if ($index -eq -1) {
                Write-DscStatus "IISSSLState property not found in WMI component properties." -NoStatus
                return
            }

            # Change the Value of the IISSSLState property
            try {
                $props[$index].Value = 1024
                # Assign the modified Props array back to the component
                $component.Props = $props
                # Save the changes
                $component.Put()
            } catch {
                Write-DscStatus "Failed to update IISSSLState property in WMI component. Error: $_" -NoStatus
                return
            }
        }

        Set-CMSite -SiteCode $SiteCode -UseSmsGeneratedCert $true -Verbose | Out-File $global:StatusLog -Append
        Start-Sleep 10
        $prop = Get-CMSiteComponent -SiteCode $siteCode -ComponentName "SMS_SITE_COMPONENT_MANAGER" | Select-Object -ExpandProperty Props | Where-Object { $_.PropertyName -eq "IISSSLState" }
        $enabled = ($prop.Value -band 1024) -eq 1024
        Write-DscStatus "IISSSLState Value is $($prop.Value). e-HTTP enabled: $enabled" -RetrySeconds 15 -NoStatus
    } until ($attempts -ge $maxAttempts)

    if (-not $enabled) {
        Write-DscStatus "e-HTTP not enabled after trying $attempts times, skip." 
        return
    }
    else {
        Write-DscStatus "e-HTTP was enabled." 
        New-Item -ItemType File -Path $flagFile -Force | Out-Null
    }
}