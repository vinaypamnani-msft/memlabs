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
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Write-DscStatus "[Invoke-DotSource] START $scriptName" -NoStatus
    try {
        . $Script @Arguments
    }
    catch {
        Write-DscStatus "WARNING: exception in ${scriptName}: $_"
    }
    finally {
        $sw.Stop()
        $elapsed = $sw.Elapsed.ToString('hh\:mm\:ss')
        Write-DscStatus "[Invoke-DotSource] END   $scriptName  ($elapsed elapsed)" -NoStatus
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

function Test-WsusBaselineImportSuccess {
    # Returns $true when import.log tail shows a successful wsusutil completion.
    # wsusutil writes the same final line on success regardless of the cab size.
    param([string]$ImportLog)
    if (-not (Test-Path $ImportLog)) { return $false }
    try {
        $tail = Get-Content $ImportLog -Tail 25 -ErrorAction Stop
    } catch { return $false }
    if (-not $tail) { return $false }
    $joined = ($tail -join "`n")
    if ($joined -match 'Successfully imported metadata' -or $joined -match 'Import .* (succeeded|completed)') {
        return $true
    }
    return $false
}

function Get-WsusTaxonomyCategoryCount {
    # Lightweight count of the WSUS UpdateCategories taxonomy. Used to gauge
    # whether a cab import landed (postinstall=~17, healthy cab=~400+).
    param([string]$ServerName = $env:COMPUTERNAME, [int]$PortNumber = 8530)
    try {
        $w = Get-WsusServer -Name $ServerName -PortNumber $PortNumber -ErrorAction Stop
        if (-not $w) { return -1 }
        return @($w.GetUpdateCategories()).Count
    } catch {
        return -1
    }
}

function Start-WsusBaselineImportBackground {
    # Launch `wsusutil import` against C:\staging\wsus\WsusCategoriesBaseline.cab
    # in the background and persist PID + start time + expected-count to a
    # state file for Wait-WsusBaselineImport to consume. Owns the entire cab
    # lifecycle (previously this was split across WSUSSync DSC + perfloading
    # and a post-Phase-7 reboot could kill wsusutil mid-import, leaving a
    # partial taxonomy that the next CM sync would fail on).
    #
    # No-op when the cab is absent, wsusutil is missing, the taxonomy is
    # already populated (count >= ExpectedCount), or a launch already
    # produced a state file with a still-running PID.
    #
    # Returns one of: 'launched', 'already-running', 'already-imported',
    # 'no-cab', 'no-wsusutil', 'fast-fail', 'error'.
    param(
        [string]$Tag = '[WSUS]',
        [int]$MaxWaitMinutes = 30,
        [int]$ExpectedCount = 100   # taxonomy threshold above which we consider the cab "landed"
    )

    $cabPath   = 'C:\staging\wsus\WsusCategoriesBaseline.cab'
    $stateFile = 'C:\staging\wsus\WsusCategoriesBaseline.import.state.json'
    $importLog = 'C:\staging\wsus\WsusCategoriesBaseline.import.log'

    if (-not (Test-Path $cabPath)) {
        Write-DscStatus "$Tag Baseline cab not present at $cabPath - skipping import (Phase 7 MU fire-and-forget sync should populate taxonomy instead)."
        return 'no-cab'
    }

    # Skip if a prior pass already imported a healthy taxonomy.
    $preCount = Get-WsusTaxonomyCategoryCount
    if ($preCount -ge $ExpectedCount) {
        Write-DscStatus "$Tag Baseline cab already imported (TaxonomyCats=$preCount >= $ExpectedCount). Skipping re-import."
        if (Test-Path $stateFile) { Remove-Item $stateFile -Force -ErrorAction SilentlyContinue }
        return 'already-imported'
    }

    # Honor an in-flight import from a previous pass (idempotent re-entry).
    if (Test-Path $stateFile) {
        try {
            $existing = Get-Content $stateFile -Raw -ErrorAction Stop | ConvertFrom-Json
            $exPid = [int]$existing.ProcessId
            $exName = if ($existing.ProcessName) { [string]$existing.ProcessName } else { 'WsusUtil' }
            $exProc = Get-Process -Id $exPid -ErrorAction SilentlyContinue
            if ($exProc -and $exProc.ProcessName -ieq $exName) {
                Write-DscStatus "$Tag Baseline import already running (pid=$exPid). Not relaunching."
                return 'already-running'
            }
        } catch {}
        Remove-Item $stateFile -Force -ErrorAction SilentlyContinue
    }

    $wsusUtil = Join-Path $env:ProgramFiles 'Update Services\Tools\WsusUtil.exe'
    if (-not (Test-Path $wsusUtil)) {
        Write-DscStatus "$Tag WsusUtil.exe not found at $wsusUtil - cab import skipped."
        return 'no-wsusutil'
    }

    try {
        # Rotate the import log so we don't confuse Test-WsusBaselineImportSuccess
        # with tail lines from a prior partial run.
        if (Test-Path $importLog) {
            try { Move-Item -Path $importLog -Destination "$importLog.prev" -Force -ErrorAction SilentlyContinue } catch {}
        }

        Write-DscStatus "$Tag Launching wsusutil import (cab=$([math]::Round((Get-Item $cabPath).Length/1MB,1)) MB, pre-TaxonomyCats=$preCount, max wait $MaxWaitMinutes min)..."
        $proc = Start-Process -FilePath $wsusUtil -ArgumentList @('import', $cabPath, $importLog) -PassThru -NoNewWindow -ErrorAction Stop
        Start-Sleep -Seconds 2

        if ($proc.HasExited -and $proc.ExitCode -ne 0) {
            $tail = ''
            if (Test-Path $importLog) {
                $tailLines = Get-Content $importLog -Tail 5 -ErrorAction SilentlyContinue
                if ($tailLines) { $tail = ($tailLines -join ' | ') }
            }
            Write-DscStatus "$Tag WARN: wsusutil import fast-failed (exit=$($proc.ExitCode)). Tail: $tail"
            return 'fast-fail'
        }

        $state = [PSCustomObject]@{
            ProcessId       = $proc.Id
            ProcessName     = $proc.ProcessName
            StartTimeUtc    = (Get-Date).ToUniversalTime().ToString('o')
            CabPath         = $cabPath
            ImportLog       = $importLog
            MaxWaitMinutes  = $MaxWaitMinutes
            ExpectedCount   = $ExpectedCount
            PreTaxonomyCats = $preCount
        }
        try {
            $state | ConvertTo-Json | Set-Content -Path $stateFile -Encoding UTF8 -Force
        }
        catch {
            Write-DscStatus "$Tag WARN: failed to persist baseline import state ($($_.Exception.Message)). Wait-WsusBaselineImport will be unable to verify."
        }
        Write-DscStatus "$Tag wsusutil import running in background (pid=$($proc.Id))."
        return 'launched'
    }
    catch {
        Write-DscStatus "$Tag WARN: wsusutil import launch threw: $($_.Exception.Message)"
        return 'error'
    }
}

function Wait-WsusBaselineImport {
    # Wait for a previously-launched `wsusutil import` (see
    # Start-WsusBaselineImportBackground) to finish AND verify success via
    # three checks before allowing a CM-side sync to proceed on top of it:
    #   1. import.log tail shows a wsusutil completion marker
    #   2. WSUS taxonomy count >= ExpectedCount (default 100)
    #   3. If neither (1) nor (2) holds, the import is partial; retry once
    #      synchronously, then surface a WARN and proceed.
    #
    # No-op when the state file is absent (cab path wasn't used, or a
    # previous Wait already cleared it). Bounded to MaxWaitMinutes from
    # the import's original StartTimeUtc so a long Phase 8/9 doesn't
    # extend the deadline. Removes the state file on terminal exit so a
    # later perfloading Wait call is a clean no-op.
    param(
        [string]$Tag = '[WSUS]',
        [int]$RetryOnPartial = 1
    )

    $stateFile = 'C:\staging\wsus\WsusCategoriesBaseline.import.state.json'
    $importLog = 'C:\staging\wsus\WsusCategoriesBaseline.import.log'
    if (-not (Test-Path $stateFile)) { return }

    try {
        $state = Get-Content $stateFile -Raw -ErrorAction Stop | ConvertFrom-Json
    }
    catch {
        Write-DscStatus "$Tag Baseline import state file unreadable ($($_.Exception.Message)). Proceeding without wait."
        Remove-Item $stateFile -Force -ErrorAction SilentlyContinue
        return
    }

    $importPid = 0
    try { $importPid = [int]$state.ProcessId } catch {}
    $expectedName  = if ($state.ProcessName) { [string]$state.ProcessName } else { 'WsusUtil' }
    $maxMinutes    = 30
    try { if ($state.MaxWaitMinutes) { $maxMinutes = [int]$state.MaxWaitMinutes } } catch {}
    $expectedCount = 100
    try { if ($state.ExpectedCount)  { $expectedCount = [int]$state.ExpectedCount } } catch {}
    if ($state.ImportLog) { $importLog = [string]$state.ImportLog }
    $startTimeUtc = [DateTime]::UtcNow
    try { $startTimeUtc = ([DateTime]::Parse($state.StartTimeUtc)).ToUniversalTime() } catch {}
    $deadlineUtc  = $startTimeUtc.AddMinutes($maxMinutes)

    # Poll until the wsusutil process exits or we hit the deadline.
    if ($importPid -gt 0) {
        $proc = Get-Process -Id $importPid -ErrorAction SilentlyContinue
        if ($proc -and ($expectedName -and $proc.ProcessName -ieq $expectedName)) {
            $remainingSec = ($deadlineUtc - [DateTime]::UtcNow).TotalSeconds
            if ($remainingSec -gt 0) {
                Write-DscStatus "$Tag Waiting for in-flight WSUS baseline import (pid=$importPid, up to $([math]::Round($remainingSec/60,1)) min remaining)..."
                $lastLogUtc = [DateTime]::UtcNow
                while ($true) {
                    $p = Get-Process -Id $importPid -ErrorAction SilentlyContinue
                    if (-not $p -or ($expectedName -and $p.ProcessName -ine $expectedName)) { break }
                    if ([DateTime]::UtcNow -ge $deadlineUtc) {
                        Write-DscStatus "$Tag WARN: Baseline import (pid=$importPid) exceeded $maxMinutes-min deadline. Proceeding anyway; sync may fail."
                        Remove-Item $stateFile -Force -ErrorAction SilentlyContinue
                        return
                    }
                    Start-Sleep -Seconds 5
                    if (([DateTime]::UtcNow - $lastLogUtc).TotalSeconds -ge 60) {
                        $remSec = [math]::Max(0, ($deadlineUtc - [DateTime]::UtcNow).TotalSeconds)
                        $liveCount = Get-WsusTaxonomyCategoryCount
                        Write-DscStatus "$Tag Baseline import still running (pid=$importPid, TaxonomyCats=$liveCount, $([math]::Round($remSec/60,1)) min remaining)..."
                        $lastLogUtc = [DateTime]::UtcNow
                    }
                }
            }
        }
    }

    # Verify the import actually completed (not just "process gone").
    $elapsedMin   = [math]::Round(([DateTime]::UtcNow - $startTimeUtc).TotalMinutes, 1)
    $logSuccess   = Test-WsusBaselineImportSuccess -ImportLog $importLog
    $postCount    = Get-WsusTaxonomyCategoryCount
    $countLanded  = ($postCount -ge $expectedCount)

    if ($logSuccess -and $countLanded) {
        Write-DscStatus "$Tag Baseline import verified (elapsed=${elapsedMin}min, TaxonomyCats=$postCount, log='Successfully imported metadata')."
        Remove-Item $stateFile -Force -ErrorAction SilentlyContinue
        return
    }

    if ($countLanded -and -not $logSuccess) {
        Write-DscStatus "$Tag Baseline import looks landed (TaxonomyCats=$postCount >= $expectedCount) but no success marker in $importLog. Proceeding."
        Remove-Item $stateFile -Force -ErrorAction SilentlyContinue
        return
    }

    # Partial import (process ended without populating the taxonomy).
    Write-DscStatus "$Tag WARN: Baseline import did not complete (elapsed=${elapsedMin}min, TaxonomyCats=$postCount, expected>=$expectedCount, logSuccess=$logSuccess). Likely killed by reboot or wsusutil error."

    if ($RetryOnPartial -gt 0) {
        Write-DscStatus "$Tag Retrying wsusutil import synchronously (one shot)..."
        Remove-Item $stateFile -Force -ErrorAction SilentlyContinue
        $wsusUtil = Join-Path $env:ProgramFiles 'Update Services\Tools\WsusUtil.exe'
        $cabPath  = if ($state.CabPath) { [string]$state.CabPath } else { 'C:\staging\wsus\WsusCategoriesBaseline.cab' }
        if (-not (Test-Path $wsusUtil)) {
            Write-DscStatus "$Tag WARN: WsusUtil.exe missing at $wsusUtil. Cannot retry."
            return
        }
        if (-not (Test-Path $cabPath)) {
            Write-DscStatus "$Tag WARN: Cab missing at $cabPath. Cannot retry."
            return
        }
        try {
            if (Test-Path $importLog) {
                try { Move-Item -Path $importLog -Destination "$importLog.partial" -Force -ErrorAction SilentlyContinue } catch {}
            }
            $retryDeadlineMin = 20
            $retry = Start-Process -FilePath $wsusUtil -ArgumentList @('import', $cabPath, $importLog) -PassThru -NoNewWindow -ErrorAction Stop
            Write-DscStatus "$Tag wsusutil import retry running (pid=$($retry.Id), up to $retryDeadlineMin min)..."
            $retryDeadline = (Get-Date).AddMinutes($retryDeadlineMin)
            while (-not $retry.HasExited -and (Get-Date) -lt $retryDeadline) {
                Start-Sleep -Seconds 10
            }
            if (-not $retry.HasExited) {
                try { $retry.Kill() } catch {}
                Write-DscStatus "$Tag WARN: wsusutil import retry exceeded $retryDeadlineMin min and was killed. Proceeding with whatever taxonomy is loaded."
                return
            }
            $finalCount = Get-WsusTaxonomyCategoryCount
            if ($retry.ExitCode -eq 0 -and $finalCount -ge $expectedCount) {
                Write-DscStatus "$Tag Baseline import retry succeeded (exit=0, TaxonomyCats=$finalCount)."
            }
            else {
                Write-DscStatus "$Tag WARN: Baseline import retry ended exit=$($retry.ExitCode), TaxonomyCats=$finalCount. Proceeding; CM sync may need extra cycles to populate categories."
            }
        }
        catch {
            Write-DscStatus "$Tag WARN: wsusutil import retry threw: $($_.Exception.Message). Proceeding."
        }
    }
}

