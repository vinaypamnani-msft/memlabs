#Start-CMPS.ps1
function Set-CMSiteProvider {
    param($SiteCode, $ProviderFQDN)

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
    New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $ProviderFQDN -scope global @initParams -ErrorAction SilentlyContinue | Out-Null

    $psDriveFailcount = 0
    while ($null -eq (Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue)) {
        $psDriveFailcount++
        if ($psDriveFailcount -gt 20) {
            Write-DscStatus "Failed to get the PS Drive for site $SiteCode. Install may have failed. Check C:\ConfigMgrSetup.log" -Failure
            return $false
        }       
        Start-Sleep -Seconds 10
        New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $ProviderFQDN -scope global @initParams | Out-Null
    }

    return $true
}

function Get-SMSProvider {
    param($SiteCode)

    $return = [PSCustomObject]@{
        FQDN          = $null
        NamespacePath = $null
    }
    $SiteServerName = "localhost"

    $retry = 0

    while ($retry -lt 3) {
        # try local provider first
        try {
            $localTest = Get-CimInstance -Computername $SiteServerName -Namespace "root\SMS\Site_$SiteCode" -Class "SMS_Site" -ErrorVariable WmiErr -ErrorAction SilentlyContinue | out-null
        }
        catch {
            $localTest = $false
        }

        if ($localTest -and $WmiErr.Count -eq 0) {
            $return.FQDN = "$($env:COMPUTERNAME).$($env:USERDNSDOMAIN)"
            $return.NamespacePath = "root\SMS\Site_$SiteCode"
            return $return
        }
        else {
            $key = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry32)
            $subKey = $key.OpenSubKey("SOFTWARE\Microsoft\ConfigMgr10\AdminUI\Connection")
            $SiteServerName = $subKey.GetValue("Server")
            Write-Host "Setting SiteServerName to $SiteServerName"
        }


        # loop through providers
        $providers = Get-CimInstance -Computername $SiteServerName -class "SMS_ProviderLocation" -Namespace "root\SMS"
        foreach ($provider in $providers) {
            Write-Host "Found Provider: $($provider.Machine) with Namespace $($provider.NamespacePath)"
        }
        foreach ($provider in $providers) {

            # Split the path into components
            $components = $provider.NamespacePath -split '\\'

            # Extract the computer name and the WMI namespace
            $computerName = $components[2]
            $wmiNamespace = ($components[3..($components.Length - 1)] -join '\')

            #Write-Host "Computer Name: $computerName"
            #Write-Host "WMI Namespace: $wmiNamespace"

            Get-CimInstance -Namespace $wmiNamespace -Computer $computerName -Class "SMS_Site" -ErrorVariable WmiErr | Out-Null
            if ($WmiErr.Count -gt 0) {
                continue
            }
            else {
                $return.FQDN = $provider.Machine
                $return.NamespacePath = "root\SMS\Site_$SiteCode"
                return $return
            }
        }
        $retry++
        $seconds = $retry
        start-sleep -seconds $seconds
    }

    return $return
}


# Read Site Code from registry
Write-Host "Getting SiteCode from registry:" -NoNewline
$SiteCode = Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Microsoft\SMS\Identification' -Name 'Site Code'
if (-not $SiteCode) {
    return
}
Write-host " $SiteCode"
Write-Host "Getting SMS Provider"
# Provider
$smsProvider = Get-SMSProvider -SiteCode $SiteCode
if (-not $smsProvider.FQDN) {
    return $false
}
Write-Host "Using Provider: $($smsProvider.FQDN)"

Write-Host "Setting CM Site Provider"
# Set CMSite Provider
$worked = Set-CMSiteProvider -SiteCode $SiteCode -ProviderFQDN $($smsProvider.FQDN)
if (-not $worked) {
    return
}

Set-Location "$sitecode`:"