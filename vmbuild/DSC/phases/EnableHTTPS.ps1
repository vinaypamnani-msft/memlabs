#enableHTTPS.ps1
param(
    [string]$ConfigFilePath,
    [string]$LogPath,
    [bool]$FirstRun
)

# Read config json
$deployConfig = Get-Content $ConfigFilePath | ConvertFrom-Json

# Get required values from config
$DomainFullName = $deployConfig.parameters.domainName
$ThisMachineName = $deployConfig.parameters.ThisMachineName
$ThisVM = $deployConfig.virtualMachines | where-object { $_.vmName -eq $ThisMachineName }
$isCas = $ThisVM.Role -eq "CAS"
$CAVM = $deployConfig.virtualMachines | Where-Object { $_.InstallCA }
$CAVMName = $CAVM.vmName
$DomainShort = $DomainFullName.Split(".")[0]
# Read Site Code from registry

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
Write-DscStatus "Setting PS Drive for ConfigMgr Site: $Sitecode on Provider $ProviderMachineName" -NoStatus
# Connect to the site's drive if it is not already present
#New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $ProviderMachineName @initParams
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
# Same budget as EnableEHTTP.ps1: role installs keep reverting the site control
# file while they run, so a 5-attempt loop can lose the fight.
$maxAttempts = 40
# Don't stop on the first success -- site component manager can flip it back while
# roles are still installing. Stop once it has held for a few consecutive checks.
$stableChecks = 0
$requiredStableChecks = 3

if (-not $FirstRun) {
    if ($isCas) {
        # CAS has no Management Point, so there is no mSSMSManagementPoint AD object.
        # Check IISSSLState directly instead.
        $prop = Get-CMSiteComponent -SiteCode $SiteCode -ComponentName "SMS_SITE_COMPONENT_MANAGER" | Select-Object -ExpandProperty Props | Where-Object { $_.PropertyName -eq "IISSSLState" }
        if ($prop.Value -band 1) {
            Write-DscStatus "Not the first run. CAS IISSSLState=$($prop.Value) has CCM_SSL_ENABLED. Skipping."
            return
        }
        else {
            Write-DscStatus "Not the first run but CAS IISSSLState=$($prop.Value) missing CCM_SSL_ENABLED. Will re-enable."
        }
    }
    else {
        # On re-runs, check BOTH the site's own IISSSLState and the AD copy ccmsetup
        # reads. AD is published FROM IISSSLState and lags it, so deciding on AD alone
        # lets a re-run skip a site that a role install reverted moments earlier.
        $siteOk = $false
        try {
            $reProp = Get-CMSiteComponent -SiteCode $SiteCode -ComponentName "SMS_SITE_COMPONENT_MANAGER" | Select-Object -ExpandProperty Props | Where-Object { $_.PropertyName -eq "IISSSLState" }
            $siteOk = [bool]($reProp.Value -band 1)
        }
        catch { }
        $adOk = $false
        try {
            $searchBase = "CN=System Management,CN=System," + ([ADSI]"LDAP://RootDSE").defaultNamingContext
            $mpObj = Get-ADObject -Filter "objectClass -eq 'mSSMSManagementPoint' -and mSSMSSiteCode -eq '$SiteCode'" `
                -SearchBase $searchBase -Properties mSSMSCapabilities -ErrorAction Stop | Select-Object -First 1
            if ($mpObj -and $mpObj.mSSMSCapabilities) {
                $maskMatch = [regex]::Match($mpObj.mSSMSCapabilities, '<SecurityModeMaskEx>(\d+)</SecurityModeMaskEx>')
                if ($maskMatch.Success -and ([int]$maskMatch.Groups[1].Value -band 1)) {
                    $adOk = $true
                }
            }
        }
        catch { }
        if ($siteOk -and $adOk) {
            Write-DscStatus "Not the first run. IISSSLState=$($reProp.Value) and AD SecurityModeMaskEx both have CCM_SSL_ENABLED. Skipping."
            return
        }
        else {
            Write-DscStatus "Not the first run: site CCM_SSL_ENABLED=$siteOk (IISSSLState=$($reProp.Value)), AD CCM_SSL_ENABLED=$adOk. Continuing."
        }
    }
}

Write-DscStatus "Enabling HTTPS"
$prop = Get-CMSiteComponent -SiteCode $SiteCode -ComponentName "SMS_SITE_COMPONENT_MANAGER" | Select-Object -ExpandProperty Props | Where-Object { $_.PropertyName -eq "IISSSLState" }
$enabled = ($prop.Value -band 1)  # CCM_SSL_ENABLED (bit 0x1) -- don't require exactly 63, users may have eHTTP+HTTPS
if ($enabled) {
    if ($isCas) {
        # CAS has no MP, so no AD object to check. IISSSLState is the definitive source.
        Write-DscStatus "HTTPS Already Enabled on CAS (IISSSLState=$($prop.Value)). Done."
        return
    }
    # IISSSLState is good, but verify AD has caught up too.
    $adOk = $false
    try {
        $searchBase = "CN=System Management,CN=System," + ([ADSI]"LDAP://RootDSE").defaultNamingContext
        $mpObj = Get-ADObject -Filter "objectClass -eq 'mSSMSManagementPoint' -and mSSMSSiteCode -eq '$SiteCode'" `
            -SearchBase $searchBase -Properties mSSMSCapabilities -ErrorAction Stop | Select-Object -First 1
        if ($mpObj -and $mpObj.mSSMSCapabilities) {
            $maskMatch = [regex]::Match($mpObj.mSSMSCapabilities, '<SecurityModeMaskEx>(\d+)</SecurityModeMaskEx>')
            if ($maskMatch.Success -and ([int]$maskMatch.Groups[1].Value -band 1)) {
                $adOk = $true
            }
        }
    }
    catch { }
    if ($adOk) {
        Write-DscStatus "HTTPS Already Enabled (IISSSLState=$($prop.Value)) and AD is current. Done."
        return
    }
    else {
        Write-DscStatus "HTTPS Enabled (IISSSLState=$($prop.Value)) but AD SecurityModeMaskEx is stale. Will wait for site component manager to republish."
        # Fall through to the wait loop below -- don't re-run Set-CMSite, just wait for AD
        $enabled = $true
    }
}
$CAName = "$DomainShort-$CAVMName-CA"
$CertPath = "c:\temp\rootca.cer"

if (-not (Test-Path $CertPath)) {
    if ($CAVM.SubordinateCA) {
        # Two-tier PKI: ConfigMgr validates client certs against the ROOT of the chain.
        # Export the root CA cert, not the issuing (subordinate) CA cert.
        $issuingCACert = Get-Item Cert:\LocalMachine\CA\* | Where-Object { $_.Subject -cmatch $CAName } | Select-Object -First 1
        if ($issuingCACert) {
            $chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
            # We only need the chain structure (to find the root cert), not revocation
            # validation. CRL is published to http://pki.<domain>/crl/ but the HTTP
            # fetch can time out under heavy Phase 8 load. NoCheck avoids the dependency.
            $chain.ChainPolicy.RevocationMode = [System.Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
            $built = $chain.Build($issuingCACert)
            if ($built -and $chain.ChainElements.Count -gt 1) {
                $rootCert = $chain.ChainElements[$chain.ChainElements.Count - 1].Certificate
                $rootCert | Export-Certificate -FilePath $CertPath -Force
                Write-DscStatus "Exported root CA '$($rootCert.Subject)' to $CertPath (two-tier PKI)"
            }
            else {
                # Fallback: export the issuing CA cert directly (same as single-tier behavior).
                Write-DscStatus "Chain build incomplete (built=$built, elements=$($chain.ChainElements.Count)). Exporting issuing CA cert as fallback."
                $issuingCACert | Export-Certificate -FilePath $CertPath -Force
                Write-DscStatus "Exported issuing CA '$($issuingCACert.Subject)' to $CertPath"
            }
        }
        else {
            Write-DscStatus "WARNING: Could not find issuing CA cert matching '$CAName' in Intermediate store"
        }
    }
    else {
        Get-Item Cert:\LocalMachine\CA\* | Where-Object { $_.Subject -cmatch $CAName } | Export-Certificate -FilePath $CertPath -Force
        Write-DscStatus "Exported root CA to $CertPath"
    }
}


$flagFile = "C:\staging\DSC\EnableEHTTPorHTTPS.flag"

# The flag only records that SOME earlier pass reached HTTPS mode. Installing the
# MP/DP roles rewrites the site control file and reverts IISSSLState to the
# install-time default (1248 = e-HTTP + switching mode, no PKI cert). This script
# is invoked again after those installs precisely to catch that, so the decision
# has to come from the live value, not from the flag.
$prop = Get-CMSiteComponent -SiteCode $SiteCode -ComponentName "SMS_SITE_COMPONENT_MANAGER" | Select-Object -ExpandProperty Props | Where-Object { $_.PropertyName -eq "IISSSLState" }
if ($prop.Value -band 1) {
    Write-DscStatus "HTTPS already enabled (IISSSLState=$($prop.Value)). Skipping execution."
    $enabled = $true
}
else {
    if (Test-Path $flagFile) {
        Write-DscStatus "IISSSLState is $($prop.Value) but the flag file says an earlier pass enabled HTTPS -- something reverted it. Re-applying."
        Write-CmSslStateForensics -Tag '[SSLState revert]'
    }
    do {
        $attempts++   
        Write-DscStatus "Enable HTTPS"
        $prop = Get-CMSiteComponent -SiteCode $SiteCode -ComponentName "SMS_SITE_COMPONENT_MANAGER" | Select-Object -ExpandProperty Props | Where-Object { $_.PropertyName -eq "IISSSLState" }

        if ($isCas) {
       
            $NameSpace = "ROOT\SMS\site_$SiteCode"
            #Hack for CAS.. Since Set-CMSite doesn't appear to work on CAS:
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
        Set-CMSite -SiteCode $SiteCode -UsePkiClientCertificate $true -ClientComputerCommunicationType HttpsOnly -AddCertificateByPath $CertPath *>&1 | Write-StatusLogEntry

        Start-Sleep 10

        $prop = Get-CMSiteComponent -SiteCode $SiteCode -ComponentName "SMS_SITE_COMPONENT_MANAGER" | Select-Object -ExpandProperty Props | Where-Object { $_.PropertyName -eq "IISSSLState" }
        # Same bit ccmsetup and Phase 11 test; e-HTTP may legitimately stay on alongside it.
        $enabled = [bool]($prop.Value -band 1)
        if ($enabled) { $stableChecks++ } else { $stableChecks = 0 }
        Write-DscStatus "IISSSLState Value is $($prop.Value). HTTPS enabled: $enabled (stable $stableChecks/$requiredStableChecks, attempt $attempts/$maxAttempts)" -RetrySeconds 15
    } until ($stableChecks -ge $requiredStableChecks -or $attempts -ge $maxAttempts)

    if (-not $enabled) {
        Write-DscStatus "HTTPS not enabled after trying $attempts times, skip."
    }
    else {
        Write-DscStatus "HTTPS was enabled."
        New-Item -ItemType File -Path $flagFile -Force | Out-Null
    }
}

# ccmsetup reads SecurityModeMaskEx from the MP's AD object and needs
# CCM_SSL_ENABLED (bit 0x1) set, but the site component manager republishes the
# OperationalXml on its own schedule and polling cannot make that happen sooner.
# Nothing between here and PushClients reads the value, so record the state and
# move on -- PushClients gates on every DC immediately before the only consumer.
# CAS has no Management Point, so there is no mSSMSManagementPoint AD object.
if ($isCas) {
    Write-DscStatus "CAS has no MP -- skipping the AD SecurityModeMaskEx check."
}
elseif ($enabled -or (Test-Path $flagFile)) {
    $adReady = $false
    try {
        $searchBase = "CN=System Management,CN=System," + ([ADSI]"LDAP://RootDSE").defaultNamingContext
        $mpObj = Get-ADObject -Filter "objectClass -eq 'mSSMSManagementPoint' -and mSSMSSiteCode -eq '$SiteCode'" `
            -SearchBase $searchBase -Properties mSSMSCapabilities -ErrorAction Stop | Select-Object -First 1
        if ($mpObj -and $mpObj.mSSMSCapabilities) {
            $maskMatch = [regex]::Match($mpObj.mSSMSCapabilities, '<SecurityModeMaskEx>(\d+)</SecurityModeMaskEx>')
            if ($maskMatch.Success -and ([int]$maskMatch.Groups[1].Value -band 1)) {
                $adReady = $true
            }
        }
    }
    catch { }
    if ($adReady) {
        Write-DscStatus "AD OperationalXml already current -- SecurityModeMaskEx has CCM_SSL_ENABLED."
    }
    else {
        Write-DscStatus "AD OperationalXml not republished yet. Not waiting here -- PushClients verifies every DC before it pushes."
    }
}
