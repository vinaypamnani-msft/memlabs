# ScriptFunctions.ps1
$global:StatusFile = "C:\staging\DSC\DSC_Status.txt"
$global:StatusLog = "C:\staging\DSC\InstallCMLog.log"

function Write-StatusLogEntry {
    # Pipeline-friendly writer that emits CMTrace-format entries to $global:StatusLog.
    # Drop-in replacement for `Write-StatusLogEntry` so the log can
    # be opened cleanly in CMTrace / OneTrace / the memlabs log viewer.
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline = $true)]
        [object]$InputObject,
        [string]$Component,
        [int]$Type = 1,   # 1=Info, 2=Warning, 3=Error
        [switch]$AllowBlank  # emit blank CMTrace entries instead of filtering them out
    )
    begin {
        if (-not $Component) {
            try {
                $cs = Get-PSCallStack
                $cmd = $cs[1].Command
                if ($cmd -and $cmd -like '*.ps1') { $cmd = $cmd -replace '\.ps1$', '' }
                if (-not $cmd -or $cmd -eq '<ScriptBlock>') { $cmd = '<Script>' }
                $Component = $cmd
            }
            catch { $Component = '<Script>' }
        }
        $date = Get-Date -Format 'MM-dd-yyyy'
        $buffer = New-Object System.Collections.Generic.List[string]
    }
    process {
        if ($null -eq $InputObject) {
            if (-not $AllowBlank) { return }
            $text = ''
        }
        else {
            $text = if ($InputObject -is [string]) { $InputObject } else { ($InputObject | Out-String) }
            $text = $text.TrimEnd("`r", "`n")
        }
        if ([string]::IsNullOrWhiteSpace($text)) {
            if (-not $AllowBlank) { return }
            $time = Get-Date -Format 'HH:mm:ss.fff'
            $tid = [System.Threading.Thread]::CurrentThread.ManagedThreadId
            $buffer.Add("<![LOG[]LOG]!><time=`"$time`" date=`"$date`" component=`"$Component`" context=`"`" type=`"$Type`" thread=`"$tid`" file=`"`">")
            return
        }
        $tid = [System.Threading.Thread]::CurrentThread.ManagedThreadId
        foreach ($line in ($text -split "`r?`n")) {
            if ([string]::IsNullOrWhiteSpace($line)) {
                if ($AllowBlank) {
                    $time = Get-Date -Format 'HH:mm:ss.fff'
                    $buffer.Add("<![LOG[]LOG]!><time=`"$time`" date=`"$date`" component=`"$Component`" context=`"`" type=`"$Type`" thread=`"$tid`" file=`"`">")
                }
                continue
            }
            $clean = [System.Text.RegularExpressions.Regex]::Replace($line, '[^\x09\x20-\x7E]', '')
            $clean = [System.Text.RegularExpressions.Regex]::Replace($clean, '\?{2,}', '')
            $clean = $clean.TrimEnd()
            if ([string]::IsNullOrWhiteSpace($clean)) {
                if ($AllowBlank) {
                    $time = Get-Date -Format 'HH:mm:ss.fff'
                    $buffer.Add("<![LOG[]LOG]!><time=`"$time`" date=`"$date`" component=`"$Component`" context=`"`" type=`"$Type`" thread=`"$tid`" file=`"`">")
                }
                continue
            }
            $time = Get-Date -Format 'HH:mm:ss.fff'
            $buffer.Add("<![LOG[$clean]LOG]!><time=`"$time`" date=`"$date`" component=`"$Component`" context=`"`" type=`"$Type`" thread=`"$tid`" file=`"`">")
        }
    }
    end {
        if ($buffer.Count -gt 0) {
            try {
                Add-Content -Path $global:StatusLog -Value $buffer -Encoding utf8 -ErrorAction Stop
            }
            catch {
                # Best-effort: retry once. Concurrent writers from parallel DSC scripts
                # can briefly collide; one retry is plenty in practice.
                Start-Sleep -Milliseconds 50
                try { Add-Content -Path $global:StatusLog -Value $buffer -Encoding utf8 -ErrorAction SilentlyContinue } catch { }
            }
        }
    }
}

function Invoke-DotSource {
    # Wrapper for dot-sourcing scripts with error handling.
    # Catches parse errors, execution policy blocks, and other failures
    # that would otherwise be silently swallowed by the caller.
    param(
        [Parameter(Mandatory)]
        [string]$Script,
        [object[]]$Arguments
    )

    $scriptName = Split-Path $Script -Leaf

    # Pre-flight: verify the file exists
    if (-not (Test-Path $Script)) {
        Write-DscStatus "FAILED to dot-source $scriptName -- file not found: $Script" -Failure
        return
    }

    # Pre-flight: verify the file parses without errors
    $tokens = $null
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($Script, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors -and $parseErrors.Count -gt 0) {
        $firstErr = $parseErrors[0]
        Write-DscStatus "FAILED to dot-source $scriptName -- parse error at line $($firstErr.Extent.StartLineNumber): $($firstErr.Message)" -Failure
        return
    }

    # Dot-source with error handling.
    # The catch logs runtime errors from within the script for diagnostics but
    # does NOT mark them as -Failure. The pre-flight checks above catch the
    # real infrastructure failures (missing file, parse errors). Runtime errors
    # from CM cmdlets are transient and the scripts have their own retry logic;
    # marking them as JOBFAILURE would abort the phase prematurely.
    try {
        . $Script @Arguments
    }
    catch {
        Write-DscStatus "WARNING: exception in ${scriptName}: $_"
    }
}

function Write-DscStatusSetup {
    $StatusPrefix = "Setting up ConfigMgr. See ConfigMgrSetup.log"
    $StatusPrefix | Out-File $global:StatusFile -Force
    start-sleep -seconds 5
    $StatusPrefix | Write-StatusLogEntry -Component 'Write-DscStatusSetup'
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
        $logType = if ($Failure.IsPresent) { 3 } else { 1 }
        $status | Write-StatusLogEntry -Component 'Write-DscStatus' -Type $logType
    }

    write-host $Status
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

    $retry = 0

    while ($retry -lt 4) {
        # try local provider first
        $localTest = Get-CimInstance -Namespace "root\SMS\Site_$SiteCode" -Class "SMS_Site" -ErrorVariable WmiErr
        if ($localTest -and $WmiErr.Count -eq 0) {
            $return.FQDN = "$($env:COMPUTERNAME).$($env:USERDNSDOMAIN)"
            $return.NamespacePath = "root\SMS\Site_$SiteCode"
            return $return
        }

        # loop through providers
        $providers = Get-CimInstance -class "SMS_ProviderLocation" -Namespace "root\SMS"
        foreach ($provider in $providers) {

            # Test provider Fix me \\server
            Get-CimInstance -Namespace $provider.NamespacePath -Class SMS_Site -ErrorVariable WmiErr | Out-Null
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
        $seconds = $retry * 45
        start-sleep -seconds $seconds
    }

    return $return
}

function Install-DP {
    param (
        [Parameter()]
        [string]
        $ServerFQDN,
        [string]
        $ServerSiteCode,
        [bool]
        $usePKI = $false
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
            New-CMSiteSystemServer -SiteSystemServerName $DPFQDN -SiteCode $ServerSiteCode *>&1 | Write-StatusLogEntry
            Start-Sleep -Seconds 15
            $SystemServer = Get-CMSiteSystemServer -SiteSystemServerName $DPFQDN -SiteCode $ServerSiteCode
        }

        # Install DP
        #============
        $dpinstalled = Get-CMDistributionPoint -SiteSystemServerName $DPFQDN -SiteCode $ServerSiteCode
        if (-not $dpinstalled) {
            Write-DscStatus "DP Role not detected on $DPFQDN. Adding Distribution Point role."
            $Date = [DateTime]::Now.AddYears(30)
            #Add-CMDistributionPoint -InputObject $SystemServer -CertificateExpirationTimeUtc $Date *>&1 | Write-StatusLogEntry
            if ($usePKI) {
                $CertPath = "C:\temp\ConfigMgrClientDistributionPointCertificate.pfx"
                if (Test-Path $CertPath) {
                    $CertAuth = "$env:windir\temp\ProvisionScript\certauth.txt"
                    if (Test-Path $CertAuth) {
                        $certPass = Get-Content $CertAuth | ConvertTo-SecureString -AsPlainText -Force
                        "Add-CMDistributionPoint -SiteSystemServerName $DPFQDN -SiteCode $ServerSiteCode -CertificatePath $CertPath -CertificatePassword $certPass -EnableSSL -EnablePxe -EnableNonWdsPxe -AllowPxeResponse -EnableUnknownComputerSupport -Force" *>&1 | Write-StatusLogEntry
                        Add-CMDistributionPoint -SiteSystemServerName $DPFQDN -SiteCode $ServerSiteCode -CertificatePath $CertPath -CertificatePassword $certPass -EnableSSL -EnablePxe -EnableNonWdsPxe -AllowPxeResponse -EnableUnknownComputerSupport -Force *>&1 | Write-StatusLogEntry
                    }
                    else {
                        "Could Not find $CertAuth" *>&1 | Write-StatusLogEntry
                        $installFailure = $true
                    }
                }
                else {
                    "Could Not find $CertPath" *>&1 | Write-StatusLogEntry
                    $installFailure = $true
                }
            }
            else {
                Add-CMDistributionPoint -SiteSystemServerName $DPFQDN -SiteCode $ServerSiteCode -CertificateExpirationTimeUtc $Date -EnablePxe -EnableNonWdsPxe -AllowPxeResponse -EnableUnknownComputerSupport -Force *>&1 | Write-StatusLogEntry
            }
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

        if (-not $dpinstalled -and -not $installFailure) {
            Start-Sleep -Seconds 10
        }

    } until ($dpinstalled -or $installFailure)

    if ($dpinstalled -and $usePKI) {        
        Invoke-Command -ComputerName $DPFQDN -ScriptBlock {
            Set-ItemProperty -Path "HKLM:\Software\Microsoft\SMS\DP" -Name "SSLState" -Value 63 -Force
        }    
    }
    
}

function Install-PullDP {
    param (
        [Parameter()]
        [string]
        $ServerFQDN,
        [string]
        $ServerSiteCode,
        [string]
        $SourceDPFQDN,
        [bool]
        $usePKI = $false
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
            New-CMSiteSystemServer -SiteSystemServerName $DPFQDN -SiteCode $ServerSiteCode *>&1 | Write-StatusLogEntry
            Start-Sleep -Seconds 15
            $SystemServer = Get-CMSiteSystemServer -SiteSystemServerName $DPFQDN -SiteCode $ServerSiteCode
        }

        # Install Pull DP
        #=================
        $dpinstalled = Get-CMDistributionPoint -SiteSystemServerName $DPFQDN -SiteCode $ServerSiteCode
        if (-not $dpinstalled) {
            Write-DscStatus "DP Role not detected on $DPFQDN. Adding Distribution Point role as a Pull DP, with Source DP $SourceDPFQDN."
            $Date = [DateTime]::Now.AddYears(30)
            if ($usePKI) {
                $CertPath = "C:\temp\ConfigMgrClientDistributionPointCertificate.pfx"
                if (Test-Path $CertPath) {
                    $CertAuth = "$env:windir\temp\ProvisionScript\certauth.txt"
                    if (Test-Path $CertAuth) {
                        $certPass = Get-Content $CertAuth | ConvertTo-SecureString -AsPlainText -Force
                        Add-CMDistributionPoint -SiteCode $ServerSiteCode -SiteSystemServerName $DPFQDN -CertificatePath $CertPath -CertificatePassword $certPass -EnablePullDP -SourceDistributionPoint $SourceDPFQDN -Force *>&1 | Write-StatusLogEntry
                    }
                    else {
                        "Could Not find $CertAuth" *>&1 | Write-StatusLogEntry
                        $installFailure = $true
                    }
                }
                else {
                    "Could Not find $CertPath" *>&1 | Write-StatusLogEntry
                    $installFailure = $true
                }
            }
            else {
                Add-CMDistributionPoint -SiteCode $ServerSiteCode -SiteSystemServerName $DPFQDN -CertificateExpirationTimeUtc $Date -EnablePullDP -SourceDistributionPoint $SourceDPFQDN -Force *>&1 | Write-StatusLogEntry

            }
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

        if (-not $dpinstalled -and -not $installFailure) {
            Start-Sleep -Seconds 10
        }

    } until ($dpinstalled -or $installFailure)
}

function Install-MP {
    param (
        [string]
        $ServerFQDN,
        [string]
        $ServerSiteCode,
        [bool]
        $UsePKI = $false
    )

    $i = 0
    $installFailure = $false
    $MPFQDN = $ServerFQDN

    do {

        $i++
        $SystemServer = Get-CMSiteSystemServer -SiteSystemServerName $MPFQDN
        if (-not $SystemServer) {
            Write-DscStatus "Creating new CM Site System server on $MPFQDN"
            New-CMSiteSystemServer -SiteSystemServerName $MPFQDN -SiteCode $ServerSiteCode *>&1 | Write-StatusLogEntry
            Start-Sleep -Seconds 15
            $SystemServer = Get-CMSiteSystemServer -SiteSystemServerName $MPFQDN
        }

        $mpinstalled = Get-CMManagementPoint -SiteSystemServerName $MPFQDN
        if (-not $mpinstalled) {
            Write-DscStatus "MP Role not detected on $MPFQDN. Adding Management Point role."
            if ($UsePKI) {
                Add-CMManagementPoint -InputObject $SystemServer -CommunicationType Https -EnableSSL *>&1 | Write-StatusLogEntry
            }
            else {
                Add-CMManagementPoint -InputObject $SystemServer -CommunicationType Http *>&1 | Write-StatusLogEntry
            }
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

        if (-not $mpinstalled -and -not $installFailure) {
            Start-Sleep -Seconds 10
        }

    } until ($mpinstalled -or $installFailure)
}

function Install-SUP {
    param (
        [string]
        $ServerFQDN,
        [string]
        $ServerSiteCode,
        [bool]
        $usePKI = $false
    )

    $i = 0
    $installFailure = $false


    
    do {

        $i++
        $SystemServer = Get-CMSiteSystemServer -SiteSystemServerName $ServerFQDN
        if (-not $SystemServer) {
            Write-DscStatus "Creating new CM Site System server on $ServerFQDN SiteCode: $ServerSiteCode"
            try {
                New-CMSiteSystemServer -SiteSystemServerName $ServerFQDN -SiteCode $ServerSiteCode -ErrorAction Stop *>&1 | Write-StatusLogEntry
            } catch {
                if ($_.Exception.Message -notmatch 'already exists') { Write-DscStatus "WARNING: New-CMSiteSystemServer failed: $($_.Exception.Message)" }
            }
            Start-Sleep -Seconds 15
            $SystemServer = Get-CMSiteSystemServer -SiteSystemServerName $ServerFQDN
        }

        $installed = Get-CMSoftwareUpdatePoint -SiteCode $ServerSiteCode -SiteSystemServerName $ServerFQDN
        if (-not $installed) {
            Write-DscStatus "SUP Role not detected on $ServerFQDN. Adding Software Update Point role."
            try {
                Add-CMSoftwareUpdatePoint -SiteCode $ServerSiteCode -SiteSystemServerName $ServerFQDN -WsusIisPort 8530 -WsusIisSslPort 8531 -WsusSSL:$usePKI *>&1 | Write-StatusLogEntry
            }
            catch {
                if ($_.FullyQualifiedErrorId -like '*RoleExists*') {
                    Write-DscStatus "SUP Role already exists on $ServerFQDN (detection lag). Treating as installed."
                    $installed = $true
                }
                else {
                    $_ | Write-StatusLogEntry
                    Write-DscStatus "Failed to add SUP on $ServerFQDN`: $_"
                }
            }
            if (-not $installed) {
                Start-Sleep -Seconds 60
            }
        }
        else {
            Write-DscStatus "SUP Role detected on $ServerFQDN"
            $installed = $true
        }

        if ($i -gt 10) {
            Write-DscStatus "No Progress for SUP Role after $i tries, Giving up."
            $installFailure = $true
        }

        if (-not $installed -and -not $installFailure) {
            Start-Sleep -Seconds 10
        }

    } until ($installed -or $installFailure)
}


function Add-ReportingUser {
    [CmdletBinding()]
    Param(
        [string]
        $SiteCode,
        [string]
        $UserName,
        [Parameter(Mandatory = $true)]
        [String]$unencrypted
    )

    # Encrypt the Password
    $SMSSite = "SMS_Site"
    $class_PWD = [wmiclass]""
    $class_PWD.psbase.Path = "ROOT\SMS\site_$($SiteCode):$($SMSSite)"
    $Parameters = $class_PWD.GetMethodParameters("EncryptDataEx")
    $Parameters.Data = $unencrypted
    $Parameters.SiteCode = $SiteCode
    $encryptedPassword = $class_PWD.InvokeMethod("EncryptDataEx", $Parameters, $null)

    # Create the user in the site
    $SMSSCIReserved = "SMS_SCI_Reserved"
    $class_User = [wmiclass]""
    $class_User.psbase.Path = "ROOT\SMS\Site_$($SiteCode):$($SMSSCIReserved)"
    $user = $class_User.createInstance()
    $user.ItemName = "$($UserName)| 0"
    $user.ItemType = "User"
    $user.UserName = $UserName
    $user.Availability = "0"
    $user.FileType = "2"
    $user.SiteCode = $SiteCode
    $user.Reserved2 = $encryptedPassword.EncryptedData.ToString()
    $user.Put() | Out-Null
}

function Install-SRP {
    param (
        [string]
        $ServerFQDN,
        [string]
        $ServerSiteCode,
        [string]
        $UserName,
        [string]
        $SqlServerName,
        [string]
        $DatabaseName
    )

    $i = 0
    $installFailure = $false

    do {

        $i++
        $SystemServer = Get-CMSiteSystemServer -SiteSystemServerName $ServerFQDN
        if (-not $SystemServer) {
            Write-DscStatus "Creating new CM Site System server on $ServerFQDN"
            New-CMSiteSystemServer -SiteSystemServerName $ServerFQDN -SiteCode $ServerSiteCode  *>&1 | Write-StatusLogEntry
            Start-Sleep -Seconds 15
            $SystemServer = Get-CMSiteSystemServer -SiteSystemServerName $ServerFQDN
        }

        $installed = Get-CMReportingServicePoint -SiteSystemServerName $ServerFQDN
        if (-not $installed) {
            Write-DscStatus "Reporting Point Role not detected on $ServerFQDN. Adding Reporting Point role using DB Server [$SqlServerName], DB Name [$DatabaseName], UserName [$UserName]"
            Add-CMReportingServicePoint -SiteCode $ServerSiteCode -SiteSystemServerName $ServerFQDN -UserName $UserName -DatabaseServerName $SqlServerName -DatabaseName $DatabaseName -ReportServerInstance "PBIRS" *>&1 | Write-StatusLogEntry
            Start-Sleep -Seconds 30
        }
        else {
            Write-DscStatus "Reporting Point Role detected on $ServerFQDN"
            $installed = $true
        }

        if ($i -eq 5) {
            try {
                Get-Service -Name SMS_EXECUTIVE | Restart-Service
            }
            catch {}
        }
        if ($i -gt 10) {
            Write-DscStatus "No Progress for Reporting Point Role after $i tries, Giving up."
            $installFailure = $true
        }

        if (-not $installed -and -not $installFailure) {
            Start-Sleep -Seconds 10
        }

    } until ($installed -or $installFailure)

    return (-not $installFailure)
}

function Write-ScriptWorkFlowData {
    param (
        [object]
        $Configuration,
        [string]
        $ConfigurationFile
    )

    $mtx = $null
    try {
        $mtx = New-Object System.Threading.Mutex($false, "ScriptWorkflow")
        [void]$mtx.WaitOne()
    }
    catch {
        # Mutex creation can fail after snapshot restore if a stale kernel
        # object exists with a different security context.  Proceed without
        # synchronization — ScriptWorkflow runs sequentially.
        $mtx = $null
    }
    try {
        $Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force
    }
    finally {
        if ($mtx) {
            [void]$mtx.ReleaseMutex()
            [void]$mtx.Dispose()
        }
    }
}

function Get-UpdatePack {

    [CmdletBinding()]
    param (
        [Parameter()]
        [string]
        $UpdateVersion
    )

    Write-DscStatus "Get CM Update..." -NoStatus
    $updatepack = ""
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUserDeclaredVarsMoreThanAssignments', '', Scope = 'Function')]
    $CMPSSuppressFastNotUsedCheck = $true

    $updatepacklist = Get-CMSiteUpdate | Where-Object { $_.State -ne 196612 -and $_.Name -eq "Configuration Manager $UpdateVersion" } # filter hotfixes
    $doneUpdates = Get-CMSiteUpdate | Where-Object { $_.State -eq 196612 -and $_.Name -eq "Configuration Manager $UpdateVersion" }
    if ($doneUpdates.Count -ge 1 -and $updatepacklist.Count -eq 0) {
        Write-DscStatus "$UpdateVersion Update already installed. Skipping."
        return $updatepack
    }
    $getupdateretrycount = 0
    while ($updatepacklist.Count -eq 0) {

        if ($getupdateretrycount -eq 3) {
            break
        }

        Write-DscStatus "No update found. Running Invoke-CMSiteUpdateCheck and waiting for 2 mins..." -NoStatus
        $getupdateretrycount++

        Invoke-CMSiteUpdateCheck -ErrorAction Ignore *>&1 | Write-StatusLogEntry
        Start-Sleep 120

        $updatepacklist = Get-CMSiteUpdate | Where-Object { $_.State -ne 196612 -and $_.Name -eq "Configuration Manager $UpdateVersion" } # filter hotfixes
    }

   

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

