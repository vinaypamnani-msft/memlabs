$global:StatusFile = "C:\staging\DSC\DSC_Status.txt"
$global:StatusLog = "C:\staging\DSC\InstallCMLog.txt"

function Write-DscStatusSetup {
    $StatusPrefix = "Setting up ConfigMgr. See ConfigMgrSetup.log"
    $StatusPrefix | Out-File $global:StatusFile -Force
    "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] $StatusPrefix" | Out-File -Append $global:StatusLog
}

function Write-DscStatus {
    param($status, [switch]$NoLog, [switch]$NoStatus, [int]$RetrySeconds, [switch]$Failure, [string]$MachineName)

    $RemoteStatusFile = $null
    if ($MachineName -and ($MachineName -ne $Env:ComputerName)) {
        $RemoteStatusFile = "FileSystem::\\$($MachineName)\c$\staging\DSC\DSC_Status.txt"
    }

    if ($RetrySeconds) {
        $status = "$status; checking again in $RetrySeconds seconds"
    }

    if ($Failure.IsPresent) {
        # Add prefix that host job can use to acknowledge failure
        $status = "JOBFAILURE: $status"
    }

    if (-not $NoStatus.IsPresent) {
        $StatusPrefix = "Setting up ConfigMgr."
        try {
            if ($RemoteStatusFile) {
                $contents = Get-Content $RemoteStatusFile
                if ($contents -and $contents.EndsWith("Complete!")) {
                    #Remote Contents end with Complete!.  Write to local file to prevent overwriting this event.
                    "$StatusPrefix Status: $status" | Out-File $global:StatusFile -Force
                }
                else {
                    #Remote Contents Are fine to overwrite
                    "$StatusPrefix [$($Env:ComputerName)]: $status" | Out-File -FilePath $RemoteStatusFile -Force
                }
            }
            else {
                #Write Status Locally, since RemoteStatusFile was not set.
                "$StatusPrefix Status: $status" | Out-File $global:StatusFile -Force
            }

        }
        catch {
            if ($RemoteStatusFile) {
                #If we are writing remote, and we had an exception.. Log the Status Locally
                "Exception: $_ $StatusPrefix Status: $status" | Out-File $global:StatusFile -Force
            }
        }
    }

    if (-not $NoLog.IsPresent) {
        "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] $status" | Out-File -Append $global:StatusLog
    }

    if ($Failure.IsPresent) {
        # Add a sleep so host VM has had time to poll for this entry
        Start-Sleep -Seconds 10
    }
}

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
    Write-DscStatus "Setting PS Drive" -NoStatus
    New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $ProviderFQDN -scope global @initParams -ErrorAction SilentlyContinue | Out-Null

    $psDriveFailcount = 0
    while ($null -eq (Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue)) {
        $psDriveFailcount++
        if ($psDriveFailcount -gt 20) {
            Write-DscStatus "Failed to get the PS Drive for site $SiteCode. Install may have failed. Check C:\ConfigMgrSetup.log" -Failure
            return $false
        }
        Write-DscStatus "Retry in 10s to Set PS Drive for site $SiteCode on $ProviderFQDN" -NoStatus
        Start-Sleep -Seconds 10
        New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $ProviderFQDN -scope global @initParams | Out-Null
    }

    Write-DscStatus "Successfully set PS Drive for site $SiteCode on $ProviderFQDN" -NoStatus
    return $true
}

function Get-SMSProvider {
    param($SiteCode)

    $return = [PSCustomObject]@{
        FQDN          = $null
        NamespacePath = $null
    }

    # try local provider first
    $localTest = Get-WmiObject -Namespace "root\SMS\Site_$SiteCode" -Class "SMS_Site" -ErrorVariable WmiErr
    if ($localTest -and $WmiErr.Count -eq 0) {
        $return.FQDN = "$($env:COMPUTERNAME).$($env:USERDNSDOMAIN)"
        $return.NamespacePath = "root\SMS\Site_$SiteCode"
        return $return
    }

    # loop through providers
    $providers = Get-WmiObject -class "SMS_ProviderLocation" -Namespace "root\SMS"
    foreach ($provider in $providers) {

        # Test provider
        Get-WmiObject -Namespace $provider.NamespacePath -Class SMS_Site -ErrorVariable WmiErr | Out-Null
        if ($WmiErr.Count -gt 0) {
            continue
        }
        else {
            $return.FQDN = $provider.Machine
            $return.NamespacePath = "root\SMS\Site_$SiteCode"
            return $return
        }
    }

    return $return
}

function Install-DP {
    param (
        [Parameter()]
        [string]
        $ServerFQDN,
        [string]
        $ServerSiteCode
    )

    $i = 0
    $installFailure = $false
    $DPFQDN = $ServerFQDN

    do {

        $i++

        # Create Site system Server
        #============
        $SystemServer = Get-CMSiteSystemServer -SiteSystemServerName $DPFQDN -SiteCode $ServerSiteCode
        if (-not $SystemServer) {
            Write-DscStatus "Creating new CM Site System server on $DPFQDN SiteCode: $ServerSiteCode"
            New-CMSiteSystemServer -SiteSystemServerName $DPFQDN -SiteCode $ServerSiteCode | Out-File $global:StatusLog -Append
            Start-Sleep -Seconds 15
            $SystemServer = Get-CMSiteSystemServer -SiteSystemServerName $DPFQDN -SiteCode $ServerSiteCode
        }

        # Install DP
        #============
        $dpinstalled = Get-CMDistributionPoint -SiteSystemServerName $DPFQDN -SiteCode $ServerSiteCode
        if (-not $dpinstalled) {
            Write-DscStatus "DP Role not detected on $DPFQDN. Adding Distribution Point role."
            $Date = [DateTime]::Now.AddYears(30)
            #Add-CMDistributionPoint -InputObject $SystemServer -CertificateExpirationTimeUtc $Date | Out-File $global:StatusLog -Append
            Add-CMDistributionPoint -SiteSystemServerName $DPFQDN -SiteCode $ServerSiteCode -CertificateExpirationTimeUtc $Date | Out-File $global:StatusLog -Append
            Start-Sleep -Seconds 60
        }
        else {
            Write-DscStatus "DP Role detected on $DPFQDN SiteCode: $ServerSiteCode"
            $dpinstalled = $true
        }

        if ($i -gt 10) {
            Write-DscStatus "No Progress after $i tries, Giving up on $DPFQDN SiteCode: $ServerSiteCode ."
            $installFailure = $true
        }

        Start-Sleep -Seconds 10

    } until ($dpinstalled -or $installFailure)
}

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

function Get-UpdatePack {

    Write-DscStatus "Get CM Update..." -NoStatus

    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUserDeclaredVarsMoreThanAssignments', '', Scope = 'Function')]
    $CMPSSuppressFastNotUsedCheck = $true

    $updatepacklist = Get-CMSiteUpdate -Fast | Where-Object { $_.State -ne 196612 }
    $getupdateretrycount = 0
    while ($updatepacklist.Count -eq 0) {

        if ($getupdateretrycount -eq 3) {
            break
        }

        Write-DscStatus "No update found. Running Invoke-CMSiteUpdateCheck and waiting for 2 mins..." -NoStatus
        $getupdateretrycount++

        Invoke-CMSiteUpdateCheck -ErrorAction Ignore
        Start-Sleep 120

        $updatepacklist = Get-CMSiteUpdate | Where-Object { $_.State -ne 196612 }
    }

    $updatepack = ""

    if ($updatepacklist.Count -eq 0) {
        # No updates
    }
    elseif ($updatepacklist.Count -eq 1) {
        # Single update
        $updatepack = $updatepacklist
    }
    else {
        # Multiple updates
        $updatepack = ($updatepacklist | Sort-Object -Property fullversion)[-1]
    }

    return $updatepack
}

