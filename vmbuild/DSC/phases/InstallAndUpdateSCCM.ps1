# InstallAndUpdateSCCM.ps1
param(
    [string]$ConfigFilePath,
    [string]$LogPath
)
Write-DscStatus "Started InstallAndUpdateSCCM.ps1"

# Invoke-Command against a remote host (the DC or a SQLAO node) uses WinRM,
# which has NO native timeout -- if the target's WinRM/CIM is briefly wedged
# the call blocks for minutes and stalls this Phase 8 DSC script. Run it via
# -AsJob and bound it with Wait-Job -Timeout; on overrun the job (and its
# stuck WinRM session) is killed and we return $null so the best-effort
# recovery caller continues instead of hanging. PS5.1-safe.
function Invoke-CommandWithTimeout {
    param(
        [Parameter(Mandatory)] [string] $ComputerName,
        [Parameter(Mandatory)] [scriptblock] $ScriptBlock,
        [object[]] $ArgumentList = @(),
        [int] $TimeoutSec = 120
    )
    $job = $null
    try {
        $job = Invoke-Command -ComputerName $ComputerName -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList -AsJob -ErrorAction Stop
        if (Wait-Job -Job $job -Timeout $TimeoutSec) {
            return (Receive-Job -Job $job -ErrorAction SilentlyContinue)
        }
        Write-DscStatus "Invoke-CommandWithTimeout: remote command on '$ComputerName' did not finish within ${TimeoutSec}s -- killing it and continuing."
        return $null
    }
    catch {
        return $null
    }
    finally {
        if ($job) {
            try { Stop-Job -Job $job -ErrorAction SilentlyContinue } catch {}
            try { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue } catch {}
        }
    }
}

# Read config json
$deployConfig = Get-Content $ConfigFilePath | ConvertFrom-Json

# Get required values from config
$DomainFullName = $deployConfig.parameters.domainName
$ThisMachineName = $deployConfig.parameters.ThisMachineName
$ThisVM = $deployConfig.virtualMachines | where-object { $_.vmName -eq $ThisMachineName }
$CurrentRole = $ThisVM.role
$psvms = $deployConfig.VirtualMachines | Where-Object { $_.Role -eq "Primary" -and $_.ParentSiteCode -eq $thisVM.SiteCode }
$PSVM = $deployConfig.virtualMachines | where-object { $_.vmName -eq $ThisVM.thisParams.Primary }

# Per-VM cmOptions wins over the rehydrated global so multi-hierarchy deploys
# (CAS hierarchy alongside a separate standalone Primary with differing
# version/OfflineSCP/UsePKI) pick this VM's own hierarchy settings.
$cmo = if ($ThisVM.cmOptions) { $ThisVM.cmOptions } else { $deployConfig.cmOptions }
$CM = if ($cmo.version -eq "tech-preview") { "CMTP" } else { "CMCB" }

# Read locale settings
$locale = $deployConfig.vmOptions.locale
$cmLanguage = "ENG"
if ($locale -and $locale -ne "en-US") {
    $localeConfigPath = "C:\staging\locale\_localeConfig.json"
    $localeConfig = Get-Content -Path $localeConfigPath -Force -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    $cmLanguage = $localeConfig.$locale.CMLanguage

    # Falling back to ENG if invalid language was set
    if ($cmLanguage.Length -ne 3) {
        $cmLanguage = "ENG"
    }
}

# Set scenario
$scenario = "Standalone"
if ($ThisVM.role -eq "CAS" -or $ThisVM.parentSiteCode) { $scenario = "Hierarchy" }
Write-DscStatus "InstallAndUpdateSCCM.ps1 Scenario $scenario"
# Set Install Dir
$SMSInstallDir = "C:\Program Files\Microsoft Configuration Manager"
if ($ThisVM.cmInstallDir) {
    $SMSInstallDir = $ThisVM.cmInstallDir
}

# SQL FQDN

if ($ThisVM.remoteSQLVM) {
    $sqlServerName = $ThisVM.remoteSQLVM
    $SQLVM = $deployConfig.virtualMachines | Where-Object { $_.vmName -eq $sqlServerName }
    $sqlInstanceName = $SQLVM.sqlInstanceName
    if ($SQLVM.sqlPort) {
        $sqlPort = $SQLVM.sqlPort
    }
    else {
        $sqlPort = 1433
    }
    if ($SQLVM.AlwaysOnListenerName) {
        $installToAO = $true
        $sqlServerName = $SQLVM.AlwaysOnListenerName
        $sqlNode1 = $SQLVM.VMName
        $sqlNode2 = $SQLVM.OtherNode
        $sqlAOGroupName = $SQLVM.AlwaysOnGroupName
        $agBackupShare = $SQLVM.thisParams.SQLAO.BackupShareFQ
        $sqlPort = $SQLVM.thisParams.SQLAO.SQLAOPort
    }
}
else {
    $sqlServerName = $env:COMPUTERNAME
    $sqlInstanceName = $ThisVM.sqlInstanceName
    if ($ThisVM.sqlPort) {
        $sqlPort = $ThisVM.sqlPort
    }
    else {
        $sqlPort = 1433
    }
}

# Set Site Code
if ($ThisVM.siteCode) {
    $SiteCode = $ThisVM.siteCode
}

# Create $CM and redist dir before we create the INI
if (!(Test-Path C:\$CM\Redist)) {
    New-Item C:\$CM\Redist -ItemType directory | Out-Null
}

# Read Actions file

$ConfigurationFile = Join-Path -Path $LogPath -ChildPath "ScriptWorkflow.json"
$Configuration = Get-Content -Path $ConfigurationFile | ConvertFrom-Json

# Reset upgrade action (in case called again in add to existing scenario), but not if already completed
if ($Configuration.UpgradeSCCM.Status -ne 'Completed') {
    $Configuration.UpgradeSCCM.Status = 'NotStart'
    $Configuration.UpgradeSCCM.StartTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
    Write-ScriptWorkFlowData -Configuration $Configuration -ConfigurationFile $ConfigurationFile
}

# On re-entry, Status='Running' means the prior runner was killed mid-install
# (the script never reached the 'Completed' write). What's safe to do next
# depends on *which* sub-step was running when it got killed:
#
#   * setupdl.exe (the pre-req downloader) is idempotent -- it has its own
#     two-successes-in-a-row verification loop and will quickly re-verify
#     already-downloaded files. Safe to re-run.
#   * setup.exe before it creates the site database: nothing of substance
#     committed yet (no CM_<sitecode> on the SQL server). Safe to re-run.
#   * setup.exe after the CM_<sitecode> database exists: partial install
#     state lives in SQL and on disk; re-running setup.exe is unsafe and
#     the supported recovery is to restore the Phase 8 checkpoint on this
#     VM.
#
# Two breadcrumbs disambiguate:
#   $setupExeStartedFlag: written just before Start-Process setup.exe.
#   CM_<SiteCode> database on $sqlServerName\$sqlInstanceName: probed via
#     a short-timeout System.Data.SqlClient query against sys.databases.
#
# Decision matrix on Status='Running' re-entry:
#   flag absent                      -> setupdl/ini phase, reset to NotStart
#   flag present + DB absent         -> setup.exe failed early, reset
#   flag present + DB present        -> fail loudly, demand checkpoint
#   flag present + SQL unreachable   -> fail loudly (conservative; can't
#                                       confirm DB state, assume worst)
$setupExeStartedFlag = 'C:\staging\DSC\InstallSCCM.setupexe.started'
if ($Configuration.InstallSCCM.Status -eq 'Running') {

    $resetReason = $null      # if set, we will reset to NotStart
    $failReason = $null      # if set, we will Write-DscStatus -Failure and return

    if (-not (Test-Path $setupExeStartedFlag)) {
        $resetReason = "setup.exe breadcrumb absent -- prior attempt was killed before setup.exe launched (still in setupdl or earlier)."
    }
    else {
        # Breadcrumb present. Probe the site DB to decide whether setup.exe
        # got far enough to do real damage.
        $cmDbName = "CM_$SiteCode"
        if ($sqlInstanceName -and $sqlInstanceName.ToUpper() -ne 'MSSQLSERVER') {
            $sqlDataSource = "$sqlServerName\$sqlInstanceName"
        }
        else {
            $sqlDataSource = $sqlServerName
        }
        if ($sqlPort -and $sqlPort -ne 1433) {
            $sqlDataSource = "$sqlServerName,$sqlPort"
        }

        # For SQLAO, if the listener fails try the actual SQL node which has
        # a real computer account and works with Integrated Auth.
        $sqlProbeTargets = @($sqlDataSource)
        if ($installToAO -and $sqlNode1) {
            $nodeDataSource = $sqlNode1
            if ($sqlPort -and $sqlPort -ne 1433) {
                $nodeDataSource = "$sqlNode1,$sqlPort"
            }
            if ($nodeDataSource -ne $sqlDataSource) {
                $sqlProbeTargets += $nodeDataSource
            }
        }

        Write-DscStatus "InstallSCCM.Status='Running' on re-entry with setup.exe breadcrumb present. Probing for database [$cmDbName] (targets: $($sqlProbeTargets -join ', ')) to decide whether retry is safe..."

        $probeReached = $false
        $probeDbExists = $false
        $probeError = $null
        foreach ($probeTarget in $sqlProbeTargets) {
            try {
                $cs = "Data Source=$probeTarget;Initial Catalog=master;Integrated Security=True;Connect Timeout=10;Encrypt=False;TrustServerCertificate=True"
                $conn = New-Object System.Data.SqlClient.SqlConnection $cs
                $conn.Open()
                try {
                    $cmd = $conn.CreateCommand()
                    $cmd.CommandText = "SELECT COUNT(*) FROM sys.databases WHERE name = @n"
                    $p = $cmd.Parameters.Add('@n', [System.Data.SqlDbType]::NVarChar, 128)
                    $p.Value = $cmDbName
                    [int]$probeCount = $cmd.ExecuteScalar()
                    $probeDbExists = ($probeCount -gt 0)
                    $probeReached = $true
                    $sqlDataSource = $probeTarget
                }
                finally {
                    $conn.Close()
                }
                break  # connected successfully
            }
            catch {
                $probeError = $_.Exception.Message
                Write-DscStatus "SQL probe of [$probeTarget] failed: $probeError"
            }
        }

        if (-not $probeReached) {
            $failReason = "setup.exe breadcrumb present but SQL probe failed (tried: $($sqlProbeTargets -join ', ')): $probeError. Cannot confirm whether [$cmDbName] exists; refusing to retry blind. Restore the Phase 8 checkpoint on this VM and re-run the deployment. See C:\ConfigMgrSetup.log for how far the prior attempt got."
        }
        elseif ($probeDbExists) {
            $failReason = "setup.exe breadcrumb present and [$cmDbName] already exists on [$sqlDataSource] -- prior setup.exe attempt created the site database before being killed. setup.exe cannot be safely re-run against a partial install. Restore the Phase 8 checkpoint on this VM and re-run the deployment. See C:\ConfigMgrSetup.log for how far the prior attempt got."
        }
        else {
            $resetReason = "setup.exe breadcrumb present but [$cmDbName] does not exist on [$sqlDataSource] -- prior setup.exe attempt failed before creating the site database, so no install state was committed. Safe to retry."
        }
    }

    if ($failReason) {
        Write-DscStatus $failReason -Failure
        return
    }

    # Otherwise reset and fall through to the install block.
    Write-DscStatus "InstallSCCM.Status='Running' on re-entry: $resetReason Resetting to 'NotStart' so setupdl + setup.exe re-run from a clean state."
    # Clear the breadcrumb so the next attempt starts from a clean state.
    if (Test-Path $setupExeStartedFlag) {
        Remove-Item -Path $setupExeStartedFlag -Force -ErrorAction SilentlyContinue
    }
    $Configuration.InstallSCCM.Status = 'NotStart'
    $Configuration.InstallSCCM.StartTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
    Write-ScriptWorkFlowData -Configuration $Configuration -ConfigurationFile $ConfigurationFile
}

# Ground truth check: if Status='Completed' from a prior deploy, verify that
# ConfigMgr is actually installed (registry key present AND site database
# exists).  On redeploy the VM may be rebuilt but ScriptWorkflow.json
# survives, causing us to skip the install even though CM is gone.
if ($Configuration.InstallSCCM.Status -eq 'Completed') {

    $regPresent = $false
    try {
        $regSiteCode = Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Microsoft\SMS\Identification' -Name 'Site Code' -ErrorAction SilentlyContinue
        if ($regSiteCode) { $regPresent = $true }
    }
    catch { }

    # If registry says CM is installed, try WMI first. The SMS Provider uses
    # CM's own SQL connection (with proper SPNs/auth) so it works reliably
    # with SQLAO listeners where raw System.Data.SqlClient can fail due to
    # Kerberos issues against the listener VNN.
    $siteHealthy = $false
    $wmiSiteError = $null
    if ($regPresent) {
        # After a reboot the SMS Provider can take a few minutes to register its
        # namespace, so one miss is not an answer. A site that finished setup
        # always has root\SMS\Site_<code>; one that died in Init_Database never does.
        # 15x30s matches Get-SMSProvider's own 450s budget, so this gate can never
        # reject a site that the provider wait further down would have accepted.
        for ($wmiTry = 1; $wmiTry -le 15; $wmiTry++) {
            try {
                $wmiSite = Get-CimInstance -Namespace "root\SMS\Site_$SiteCode" -Class "SMS_Site" -ErrorAction Stop
                if ($wmiSite) {
                    $siteHealthy = $true
                    Write-DscStatus "InstallSCCM.Status='Completed' -- WMI confirms site $SiteCode is operational (SMS_Site present, attempt $wmiTry)"
                    break
                }
            }
            catch {
                $wmiSiteError = $_.Exception.Message
            }
            if ($wmiTry -eq 1) {
                Write-DscStatus "Registry present but WMI SMS_Site check failed: $wmiSiteError. Retrying for up to 7 min before falling back to the SQL probe..."
            }
            if ($wmiTry -lt 15) { Start-Sleep -Seconds 30 }
        }
        if (-not $siteHealthy) {
            Write-DscStatus "WMI SMS_Site for site $SiteCode never appeared after 15 attempts (last error: $wmiSiteError). Falling back to SQL probe..."
        }
    }

    if (-not $siteHealthy) {
        # Either registry is missing or WMI failed. Fall back to direct SQL probe.
        $dbExists = $false
        $sqlReachable = $false
        $cmDbName = "CM_$SiteCode"
        if ($sqlInstanceName -and $sqlInstanceName.ToUpper() -ne 'MSSQLSERVER') {
            $sqlDataSource = "$sqlServerName\$sqlInstanceName"
        }
        else {
            $sqlDataSource = $sqlServerName
        }
        if ($sqlPort -and $sqlPort -ne 1433) {
            $sqlDataSource = "$sqlServerName,$sqlPort"
        }

        # For SQLAO, if the listener fails try the actual SQL node name which
        # has a real computer account and works with Integrated Auth.
        $sqlProbeTargets = @($sqlDataSource)
        if ($installToAO -and $sqlNode1) {
            $nodeDataSource = $sqlNode1
            if ($sqlPort -and $sqlPort -ne 1433) {
                $nodeDataSource = "$sqlNode1,$sqlPort"
            }
            if ($nodeDataSource -ne $sqlDataSource) {
                $sqlProbeTargets += $nodeDataSource
            }
        }

        foreach ($probeTarget in $sqlProbeTargets) {
            try {
                $cs = "Data Source=$probeTarget;Initial Catalog=master;Integrated Security=True;Connect Timeout=10;Encrypt=False;TrustServerCertificate=True"
                $conn = New-Object System.Data.SqlClient.SqlConnection $cs
                $conn.Open()
                try {
                    $cmd = $conn.CreateCommand()
                    $cmd.CommandText = "SELECT COUNT(*) FROM sys.databases WHERE name = @n"
                    $p = $cmd.Parameters.Add('@n', [System.Data.SqlDbType]::NVarChar, 128)
                    $p.Value = $cmDbName
                    [int]$probeCount = $cmd.ExecuteScalar()
                    $dbExists = ($probeCount -gt 0)
                    $sqlReachable = $true
                    $sqlDataSource = $probeTarget
                }
                finally {
                    $conn.Close()
                }
                break  # connected successfully, stop trying
            }
            catch {
                Write-DscStatus "SQL probe of [$probeTarget] for [$cmDbName] failed: $($_.Exception.Message)"
            }
        }

        # Decision matrix (only reached when SMS_Site could NOT be read, so a
        # completed install has already been ruled out by the strongest oracle):
        #   db=Y                    -> FAIL, partial/corrupt install needs checkpoint
        #   db=N  sql=Y             -> safe retry, nothing committed
        #   any   sql=N             -> FAIL, can't confirm state
        if (-not $sqlReachable) {
            Write-DscStatus "InstallSCCM.Status='Completed' but SQL is unreachable (tried: $($sqlProbeTargets -join ', ')). Cannot confirm whether [$cmDbName] exists; refusing to retry blind. Check SQL connectivity or restore the Phase 8 checkpoint." -Failure
            return
        }
        elseif ($dbExists) {
            # Setup writes SMS\Identification and creates CM_<site> early, so a
            # present registry key proves nothing about how far it got.
            $partialDetail = if ($regPresent) {
                "registry key SMS\Identification is present and [$cmDbName] exists on [$sqlDataSource], but the site's WMI namespace root\SMS\Site_$SiteCode does not -- setup.exe committed the database and then died before the site came up"
            }
            else {
                "registry key SMS\Identification is missing while [$cmDbName] exists on [$sqlDataSource]"
            }
            Write-DscStatus "InstallSCCM.Status='Completed' but $partialDetail. This is a partial/corrupt install; setup.exe cannot be safely re-run over it. Restore the Phase 8 checkpoint on this VM (or drop [$cmDbName] from every replica) and re-run the deployment. See C:\ConfigMgrSetup.log for how far the prior attempt got." -Failure
            return
        }
        else {
            # DB absent (with or without registry) — safe to re-install.
            $missing = @()
            if (-not $regPresent) { $missing += "registry key SMS\Identification" }
            $missing += "database [$cmDbName] on [$sqlDataSource]"
            Write-DscStatus "InstallSCCM.Status='Completed' but CM is not actually installed (missing: $($missing -join ', ')). Resetting to 'NotStart' for re-install."
            if (Test-Path $setupExeStartedFlag) {
                Remove-Item -Path $setupExeStartedFlag -Force -ErrorAction SilentlyContinue
            }
            $Configuration.InstallSCCM.Status = 'NotStart'
            $Configuration.InstallSCCM.StartTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
            Write-ScriptWorkFlowData -Configuration $Configuration -ConfigurationFile $ConfigurationFile
        }
    }
}

if ($Configuration.InstallSCCM.Status -ne "Completed" -and $Configuration.InstallSCCM.Status -ne "Running") {

    # Set Install action as Running
    $Configuration.InstallSCCM.Status = 'Running'
    $Configuration.InstallSCCM.StartTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
    Write-ScriptWorkFlowData -Configuration $Configuration -ConfigurationFile $ConfigurationFile

    # Ensure CM files were downloaded
    $cmsourcepath = "c:\$CM"
    if (!(Test-Path $cmsourcepath)) {
        Write-DscStatus "$CM Does not exist. Failed." -Failure
        return
    }

    Write-DscStatus "Creating $scenario.ini file" # Standalone or Hierarchy
    $CMINIPath = "c:\$CM\$scenario.ini"

    $cmini = @'
[Identification]
Action=%InstallAction%
Preview=0

[Options]
ProductID=%ProductID%
SiteCode=%SiteCode%
SiteName=%SiteName%
SMSInstallDir=%InstallDir%
SDKServer=%MachineFQDN%
RoleCommunicationProtocol=HTTPorHTTPS
ClientsUsePKICertificate=0
PrerequisiteComp=1
PrerequisitePath=C:\%CM%\REdist
MobileDeviceLanguage=0
AdminConsole=1
JoinCEIP=0
%AddServerLanguages%
%AddClientLanguages%

[SQLConfigOptions]
SQLServerName=%SQLMachineFQDN%
DatabaseName=%SQLInstance%CM_%SiteCode%
SQLServerPort=%SqlPort%
SQLSSBPort=4022

AGBackupShare=

[CloudConnectorOptions]
CloudConnector=1
CloudConnectorServer=%MachineFQDN%
UseProxy=0
ProxyName=
ProxyPort=

[SystemCenterOptions]
SysCenterId=

[HierarchyExpansionOption]

[SABranchOptions]
SAActive=1
CurrentBranch=1
'@

    # Get SQL instance info
    #$inst = (get-itemproperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server').InstalledInstances[0]
    #$p = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL').$inst
    #$sqlinfo = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$p\$inst"

    # Set ini values
    $installAction = if ($CurrentRole -eq "CAS") { "InstallCAS" } else { "InstallPrimarySite" }
    $productID = "EVAL"

    if ($CM -ne "CMTP") {
        if (-not $($cmo.EVALVersion)) {
            if ($($deployConfig.parameters.ProductID)) {
                $productID = $($deployConfig.parameters.ProductID)
            }
        }
    }
    $cmini = $cmini.Replace('%ProductID%', $productID)
    $cmini = $cmini.Replace('%InstallAction%', $installAction)
    $cmini = $cmini.Replace('%InstallDir%', $SMSInstallDir)
    $cmini = $cmini.Replace('%MachineFQDN%', "$env:computername.$DomainFullName")
    $cmini = $cmini.Replace('%SQLMachineFQDN%', "$sqlServerName.$DomainFullName")
    $cmini = $cmini.Replace('%SqlPort%', $sqlPort)
    $cmini = $cmini.Replace('%SiteCode%', $SiteCode)
    # $cmini = $cmini.Replace('%SQLDataFilePath%', $sqlinfo.DefaultData)
    # $cmini = $cmini.Replace('%SQLLogFilePath%', $sqlinfo.DefaultLog)
    $cmini = $cmini.Replace('%CM%', $CM)

    if ($($cmo.InstallSCP) -eq $false) {
        $cmini = $cmini.Replace('CloudConnector=1', "CloudConnector=0")
    }

    if ($($cmo.OfflineSCP) -eq $true) {
        $cmini = $cmini.Replace('CloudConnector=1', "CloudConnector=0")
    }

    if ($installToAO) {
        $cmini = $cmini.Replace('AGBackupShare=', "AGBackupShare=$agBackupShare")
    }

    if ($deployConfig.parameters.SysCenterId) {
        $cmini = $cmini.Replace('SysCenterId=', "SysCenterId=$($deployConfig.parameters.SysCenterId)")
    }

    # Remove items not needed on CAS
    if ($installAction -eq "InstallCAS") {
        $cmini = $cmini.Replace('RoleCommunicationProtocol=HTTPorHTTPS', "")
        $cmini = $cmini.Replace('ClientsUsePKICertificate=0', "")
    }

    # Set site name
    if ($CM -eq "CMTP") {
        $cmini = $cmini.Replace('%SiteName%', "ConfigMgr Tech Preview")
        $cmini = $cmini.Replace('Preview=0', "Preview=1")
    }
    else {
        $cmini = $cmini.Replace('Preview=0', "")
        if ($installAction -eq "InstallCAS") {
            if (-not [string]::IsNullOrWhiteSpace($ThisVM.siteName)) {
                $cmini = $cmini.Replace('%SiteName%', $ThisVM.siteName)
            }
            else {
                $cmini = $cmini.Replace('%SiteName%', "ConfigMgr CAS")
            }
        }
        else {
            if (-not [string]::IsNullOrWhiteSpace($ThisVM.siteName)) {
                $cmini = $cmini.Replace('%SiteName%', $ThisVM.siteName)
            }
            else {
                $cmini = $cmini.Replace('%SiteName%', "ConfigMgr Primary Site")
            }
        }
    }

    if ($sqlInstanceName.ToUpper() -eq "MSSQLSERVER" -or $installToAO) {
        $cmini = $cmini.Replace('%SQLInstance%', "")
    }
    else {
        $tinstance = $sqlInstanceName.ToUpper() + "\"
        $cmini = $cmini.Replace('%SQLInstance%', $tinstance)
    }

    # Set language
    if ($cmLanguage -ne "ENG") {
        $cmini = $cmini.Replace('%AddServerLanguages%', "AddServerLanguages=${cmLanguage}")
        $cmini = $cmini.Replace('%AddClientLanguages%', "AddClientLanguages=${cmLanguage}")
    }
    else {
        $cmini = $cmini.Replace('%AddServerLanguages%', '')
        $cmini = $cmini.Replace('%AddClientLanguages%', '')
    }

    # Write Setup entry, which causes the job on host to overwrite status with entries from ConfigMgrSetup.log
    Write-DscStatusSetup

    #Setup Downloader

    $CMDir = "c:\$CM"
    $CMDirnew = Join-Path $CMDir "cd.retail"
    if (Test-Path $CMDirnew -PathType Container) {
        $CMDir = $CMDirnew
    }
    else {
        $CMDirnew = Join-Path $CMDir "cd.retail.LN"
        if (Test-Path $CMDirnew -PathType Container) {
            $CMDir = $CMDirnew
        }
        else {
            $CMDirnew = Join-Path $CMDir "cd.preview"
            if (Test-Path $CMDirnew -PathType Container) {
                $CMDir = $CMDirnew
            }
        }
    }

    # Prefer the mounted CM ISO (DVD) when present. The host mounts the CM ISO on
    # this site server's DVD right before Phase 8 (Mount-CmIsoForPhase), so we run
    # setupdl.exe + setup.exe DIRECTLY off the read-only media instead of a
    # create-time copy under C:\CMCB. The C:\CMCB\cd.retail* resolution above is
    # the fallback for URL-download CM versions (DownloadSCCM extracts there).
    # $CMDir has no trailing slash so "$CMDir\SMSSETUP\..." stays a valid path.
    $cmDvd = Get-Volume | Where-Object { $_.DriveType -eq 'CD-ROM' -and $_.DriveLetter } | Where-Object {
        Test-Path ("$($_.DriveLetter):\SMSSETUP\BIN\X64\Setup.exe")
    } | Select-Object -First 1
    if ($cmDvd) {
        $CMDir = "$($cmDvd.DriveLetter):"
        Write-DscStatus "Installing ConfigMgr from mounted ISO on drive $CMDir"
    }

    $CMBin = "$CMDir\SMSSETUP\BIN\X64"
    $CMSetupDL = "$CMBin\Setupdl.exe"
    $CMRedist = "C:\$CM\REdist"
    $CMLog = "C:\ConfigMgrSetup.log"

    Write-DscStatus "Starting Pre-Req Download using $CMSetupDL /NOUI $CMRedist"

    # If the Phase 3 "ScriptWorkflow Download" pre-warm task is still
    # registered/running, stop it and kill any setupdl.exe it left behind so
    # our own download below is the only setupdl writing to $CMRedist / $CMLog.
    # The pre-warm only populates REdist (idempotent); whatever it finished
    # persists on disk and this run just verifies it -- which is fast.
    Stop-CMSetupPrereqPrewarm

    # The setupdl loop is single-sourced in ScriptFunctions.ps1 so this path
    # and the Phase 3 pre-warm (ScriptWorkflow.ps1 -DownloadOnly) stay in sync.
    $dlOk = Invoke-CMSetupPrereqDownload -CMSetupDL $CMSetupDL -CMRedist $CMRedist -CMLog $CMLog -MaxTries 20
    if (-not $dlOk) {
        Write-DscStatus "Pre-Req Downloading failed after 20 tries. see $CMLog"
        # Set Status to not 'Running' so it can run again.
        $Configuration.InstallSCCM.Status = 'Failed'
        $Configuration.InstallSCCM.StartTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
        Write-ScriptWorkFlowData -Configuration $Configuration -ConfigurationFile $ConfigurationFile
        return
    }

    # Create ini
    $cmini > $CMINIPath

    # Install CM
    $CMInstallationFile = "$CMDir\SMSSETUP\BIN\X64\Setup.exe"
    $CMFileVersion = Get-Item -Path $CMInstallationFile -ErrorAction SilentlyContinue

    # Pre-flight: verify SQL connectivity using the FQDN with Integrated Auth
    # before launching setup.exe. Setup.exe uses the FQDN for Kerberos auth
    # which requires DNS resolution. LLMNR/NetBIOS won't work.
    #
    # Known failure mode: SQLAO listener DNS A record missing — the cluster
    # service was supposed to register it but didn't. We detect this, attempt
    # to register the record ourselves, and retry the connection.
    if ($sqlServerName -ne $env:COMPUTERNAME) {
        $sqlFQDN = "$sqlServerName.$DomainFullName"
        $sqlTarget = $sqlFQDN
        if ($sqlPort -and $sqlPort -ne 1433) {
            $sqlTarget = "$sqlFQDN,$sqlPort"
        }

        # Step 1: Verify DNS resolves the SQL server FQDN.
        # If missing (common for SQLAO listeners), escalate through:
        #   a) Force AD replication (record may exist but not replicated to our DC)
        #   b) Bounce the cluster Network Name resource (makes cluster re-register DNS)
        #   c) Register the A record directly on the DC as last resort
        $dnsOk = $false
        $clusterBounced = $false
        for ($dnsTry = 1; $dnsTry -le 3; $dnsTry++) {
            try {
                Clear-DnsClientCache -ErrorAction SilentlyContinue
                $dnsResult = @(Resolve-DnsName -Name $sqlFQDN -Type A -ErrorAction Stop)
                if ($dnsResult.Count -gt 0) {
                    $dnsOk = $true
                    Write-DscStatus "SQL pre-flight DNS: '$sqlFQDN' resolves to $($dnsResult.IPAddress -join ', ')"
                    break
                }
            }
            catch {
                Write-DscStatus "SQL pre-flight DNS: attempt $dnsTry/3 — '$sqlFQDN' not resolvable: $($_.Exception.Message)"
            }
            if (-not $dnsOk -and $installToAO) {
                # Discover ALL DCs for replication
                $allDCs = @(Get-ADDomainController -Filter * -ErrorAction SilentlyContinue | Select-Object -ExpandProperty HostName)
                $dcName = $null
                if ($allDCs.Count -gt 0) {
                    $dcName = $allDCs[0]
                }
                else {
                    $dcName = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\History' -Name DCName -ErrorAction SilentlyContinue).DCName
                    if ($dcName) { $dcName = $dcName.TrimStart('\\') }
                    if (-not $dcName) { $dcName = (nltest /dsgetdc:$DomainFullName 2>$null | Select-String 'DC: \\\\(.+)' | ForEach-Object { $_.Matches[0].Groups[1].Value }) }
                    $allDCs = @($dcName)
                }
                $dcShortNames = @($allDCs | ForEach-Object { ($_ -split '\.')[0] })

                # Attempt a) Force AD replication — the record may already exist
                # on one DC but not yet replicated to the one this VM queries.
                if ($dnsTry -eq 1) {
                    Write-DscStatus "SQL pre-flight DNS: forcing AD replication across $($allDCs.Count) DC(s)"
                    try {
                        Invoke-CommandWithTimeout -ComputerName $dcName -TimeoutSec 120 -ScriptBlock {
                            param($dcNames)
                            $dcNames | ForEach-Object { repadmin /syncall $_ /AdeP 2>&1 | Out-Null }
                        } -ArgumentList (,$dcShortNames)
                        Start-Sleep -Seconds 5
                        Clear-DnsClientCache -ErrorAction SilentlyContinue
                    }
                    catch {
                        Write-DscStatus "SQL pre-flight DNS: replication attempt failed: $($_.Exception.Message)"
                    }
                }

                # Attempt b) Bounce the listener's cluster Network Name resource
                # on the SQLAO node — this makes the cluster service re-register
                # its DNS records. The CAS doesn't have FailoverClusters, so run
                # via Invoke-Command on the SQLAO node.
                if ($dnsTry -eq 2 -and $sqlNode1) {
                    Write-DscStatus "SQL pre-flight DNS: bouncing cluster Network Name for '$sqlServerName' on $sqlNode1"
                    try {
                        Invoke-CommandWithTimeout -ComputerName $sqlNode1 -TimeoutSec 90 -ScriptBlock {
                            param($listenerName)
                            Import-Module FailoverClusters -ErrorAction SilentlyContinue
                            $nnRes = Get-ClusterResource -ErrorAction SilentlyContinue |
                                Where-Object { $_.ResourceType -eq 'Network Name' -and $_.OwnerGroup -eq $listenerName }
                            if ($nnRes) {
                                $nnRes | Stop-ClusterResource -ErrorAction SilentlyContinue
                                Start-Sleep -Seconds 3
                                $nnRes | Start-ClusterResource -ErrorAction SilentlyContinue
                                Start-Sleep -Seconds 5
                            }
                        } -ArgumentList $sqlServerName
                        $clusterBounced = $true
                        # Force replication again after the cluster re-registered
                        Invoke-CommandWithTimeout -ComputerName $dcName -TimeoutSec 120 -ScriptBlock {
                            param($dcNames)
                            $dcNames | ForEach-Object { repadmin /syncall $_ /AdeP 2>&1 | Out-Null }
                        } -ArgumentList (,$dcShortNames)
                        Start-Sleep -Seconds 5
                        Clear-DnsClientCache -ErrorAction SilentlyContinue
                    }
                    catch {
                        Write-DscStatus "SQL pre-flight DNS: cluster bounce failed: $($_.Exception.Message)"
                    }
                }

                # Attempt c) Register the A record directly as last resort.
                if ($dnsTry -eq 3) {
                    try {
                        $agIPAddr = $null
                        # Try Get-ClusterResource on the SQLAO node to find the listener IP
                        if ($sqlNode1) {
                            $agIPAddr = Invoke-CommandWithTimeout -ComputerName $sqlNode1 -TimeoutSec 60 -ScriptBlock {
                                param($listenerName)
                                Import-Module FailoverClusters -ErrorAction SilentlyContinue
                                $ipRes = Get-ClusterResource -ErrorAction SilentlyContinue |
                                    Where-Object { $_.ResourceType -eq 'IP Address' -and $_.OwnerGroup -eq $listenerName } |
                                    Select-Object -First 1
                                if ($ipRes) {
                                    return ($ipRes | Get-ClusterParameter -Name Address -ErrorAction SilentlyContinue).Value
                                }
                            } -ArgumentList $sqlServerName
                        }
                        # Fallback: resolve the short name via NetBIOS/LLMNR
                        if (-not $agIPAddr) {
                            $shortResolve = [System.Net.Dns]::GetHostAddresses($sqlServerName) |
                                Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1
                            if ($shortResolve) { $agIPAddr = $shortResolve.IPAddressToString }
                        }
                        if ($agIPAddr) {
                            Write-DscStatus "SQL pre-flight DNS: registering A record '$sqlServerName' -> $agIPAddr on DC '$dcName'"
                            Invoke-CommandWithTimeout -ComputerName $dcName -TimeoutSec 60 -ScriptBlock {
                                param($zone, $name, $ip)
                                # Remove any stale record first, then add fresh
                                $existing = Get-DnsServerResourceRecord -ZoneName $zone -Name $name -RRType A -ErrorAction SilentlyContinue
                                if (-not $existing) {
                                    Add-DnsServerResourceRecordA -ZoneName $zone -Name $name -IPv4Address $ip -ErrorAction Stop
                                }
                            } -ArgumentList $DomainFullName, $sqlServerName, $agIPAddr
                            # Force replication after registration
                            if ($allDCs.Count -gt 1) {
                                Invoke-CommandWithTimeout -ComputerName $dcName -TimeoutSec 120 -ScriptBlock {
                                    param($dcNames)
                                    $dcNames | ForEach-Object { repadmin /syncall $_ /AdeP 2>&1 | Out-Null }
                                } -ArgumentList (,$dcShortNames)
                            }
                            Start-Sleep -Seconds 5
                            Clear-DnsClientCache -ErrorAction SilentlyContinue
                        }
                        else {
                            Write-DscStatus "SQL pre-flight DNS: could not determine listener IP for registration"
                        }
                    }
                    catch {
                        Write-DscStatus "SQL pre-flight DNS: could not register A record: $($_.Exception.Message)"
                    }
                }
            }
            if ($dnsTry -lt 3) { Start-Sleep -Seconds 10 }
        }
        if (-not $dnsOk) {
            Write-DscStatus "SQL pre-flight DNS: WARNING — '$sqlFQDN' still not resolvable after registration attempts. Proceeding with SQL connection test anyway."
        }

        # Step 2: Verify SQL connectivity using ODBC — the same driver and
        # connection strings that setup.exe's CSql::Connect() uses.
        #
        # setup.exe tries two connection strings in order:
        #   1) DRIVER={SQL Server} + Trusted_Connection=yes + Encrypt=no
        #   2) DRIVER={ODBC Driver 18} + Trusted_Connection=yes + Encrypt=yes;TrustServerCertificate=no
        # We test the same way. If both fail after retries, setup.exe would
        # also fail with error 18452 ("untrusted domain").
        #
        # If we bounced the cluster Network Name during DNS recovery, auth
        # can take 10-15 min to settle. Use a longer retry window.
        if ($clusterBounced) {
            $sqlPreCheckMax = 60   # 60 attempts x 15s = 15 min (cluster settling)
            Write-DscStatus "SQL pre-flight: cluster was bounced during DNS recovery, using extended retry window (15 min)"
        }
        else {
            $sqlPreCheckMax = 12   # 12 attempts x 15s = 3 min
        }
        $sqlPreCheckOk = $false
        for ($sqlTry = 1; $sqlTry -le $sqlPreCheckMax; $sqlTry++) {
            # Try unsecure first (same as setup.exe: bUseSecureConnection=false)
            $odbcCs1 = "Driver={SQL Server};AutoTranslate=no;Server=$sqlTarget;Database=master;Trusted_Connection=yes;Encrypt=no;TrustServerCertificate=yes"
            try {
                $odbcConn = New-Object System.Data.Odbc.OdbcConnection $odbcCs1
                $odbcConn.Open()
                $odbcConn.Close()
                $sqlPreCheckOk = $true
                $sqlPreCheckCs = $odbcCs1
                Write-DscStatus "SQL pre-flight: ODBC connected to [$sqlTarget] on attempt $sqlTry (Driver={SQL Server})"
                break
            }
            catch {
                $sqlPreErr1 = $_.Exception.Message
            }
            # Fallback to secure (same as setup.exe: bUseSecureConnection=true)
            $odbcCs2 = "Driver={ODBC Driver 18 for SQL Server};AutoTranslate=no;Server=$sqlTarget;Database=master;Trusted_Connection=yes;Encrypt=yes;TrustServerCertificate=no"
            try {
                $odbcConn = New-Object System.Data.Odbc.OdbcConnection $odbcCs2
                $odbcConn.Open()
                $odbcConn.Close()
                $sqlPreCheckOk = $true
                $sqlPreCheckCs = $odbcCs2
                Write-DscStatus "SQL pre-flight: ODBC connected to [$sqlTarget] on attempt $sqlTry (Driver={ODBC Driver 18}, secure)"
                break
            }
            catch {
                $sqlPreErr2 = $_.Exception.Message
            }
            Write-DscStatus "SQL pre-flight: attempt $sqlTry/$sqlPreCheckMax to [$sqlTarget] failed: $sqlPreErr1"
            if ($sqlTry -lt $sqlPreCheckMax) { Start-Sleep -Seconds 15 }
        }
        if (-not $sqlPreCheckOk) {
            Write-DscStatus "SQL pre-flight: ODBC failed after $sqlPreCheckMax attempts to [$sqlTarget]. setup.exe would also fail. Cannot start." -Failure
            Write-DscStatus "SQL pre-flight: Last errors — Driver={SQL Server}: $sqlPreErr1 | Driver={ODBC Driver 18}: $sqlPreErr2"
            return
        }

        # Step 3: Verify Kerberos authentication to remote SQL.
        # NTLM works but can fail intermittently during cluster settling
        # when the DC is briefly unreachable for pass-through validation.
        # If we see NTLM, wait up to 5 min for Kerberos to become available.
        $authScheme = $null
        $kerbMaxAttempts = 20   # 20 x 15s = 5 min
        for ($authTry = 1; $authTry -le $kerbMaxAttempts; $authTry++) {
            try {
                $authConn = New-Object System.Data.Odbc.OdbcConnection $sqlPreCheckCs
                $authConn.Open()
                $authCmd = $authConn.CreateCommand()
                $authCmd.CommandText = "SELECT auth_scheme FROM sys.dm_exec_connections WHERE session_id = @@SPID"
                $authScheme = $authCmd.ExecuteScalar()
                $authConn.Close()
            }
            catch {
                Write-DscStatus "SQL pre-flight: could not query auth_scheme (attempt $authTry): $($_.Exception.Message)"
                $authScheme = $null
            }
            if ($authScheme -eq 'KERBEROS') {
                Write-DscStatus "SQL pre-flight: auth_scheme = KERBEROS on attempt $authTry — good"
                break
            }
            if ($authTry -eq 1) {
                Write-DscStatus "SQL pre-flight: auth_scheme = $authScheme (not KERBEROS). Waiting up to 5 min for Kerberos to become available..."
            }
            if ($authTry -lt $kerbMaxAttempts) { Start-Sleep -Seconds 15 }
        }
        if ($authScheme -and $authScheme -ne 'KERBEROS') {
            Write-DscStatus "SQL pre-flight: WARNING — auth_scheme still $authScheme after $kerbMaxAttempts attempts. setup.exe may fail with error 18452 during cluster settling. Check SPNs and msDS-SupportedEncryptionTypes on the SQL service account."
        }

        # Step 3.5: Verify this site server's COMPUTER ACCOUNT has admin /
        # remote-WMI rights on every SQL host that backs the site DB. The
        # SQL probes above only validate the SQL login path (Integrated
        # Auth via Kerberos), but ConfigMgr Setup ALSO walks the SQL
        # host(s) via remote WMI (root\cimv2) during its prereq pass to
        # read SQL config/services. That call uses our computer account's
        # OS-level credentials, not the SQL login, and surfaces as the
        # cryptic prereq:
        #   "The site server computer's machine account does not have
        #    Administrator's privileges on the SQL Server selected for
        #    site database installation."
        # The host-side Phase 8 preflight (Common.Phases.ps1) already
        # tries to add $env:COMPUTERNAME$ to BUILTIN\Administrators on
        # every SQL node before this DSC script runs, but membership can
        # still be missing on this exact box at this exact moment due to
        # AD replication lag, GPO churn, a stale Kerberos ticket caching
        # the old token, or a manually-edited SQL host. Probe it here so
        # we fail in seconds with a precise pointer instead of waiting
        # for setup.exe's prereq pass to surface it minutes later. The
        # Phase 8 per-VM job's outer timeout would otherwise let the
        # whole deploy hang while dependent nodes wait.
        #
        # IMPORTANT (SQLAO): probe the physical AG NODES only, NEVER the
        # listener. On an AO install $sqlServerName is the AlwaysOn
        # LISTENER name (a virtual cluster network name / VCO), not a
        # real machine. Get-CimInstance -ComputerName <listener> opens a
        # WinRM/Kerberos session that resolves to whichever node currently
        # owns the listener IP, and that node's WinRM rejects the
        # HOST/<listener> service ticket as the wrong principal -> error
        # 0x80090322 (SEC_E_WRONG_PRINCIPAL, "An unknown security error
        # occurred"). This is inherently flaky (depends on listener
        # ownership / SPN registration / ticket cache at that instant), so
        # it spuriously hard-failed Phase 8 on a perfectly healthy site.
        # CM Setup's own prereq pass walks the physical nodes (zz-fries /
        # zz-shake) via WMI, NOT the listener, so the nodes are the
        # correct -- and only -- thing to validate here.
        $wmiTargets = New-Object System.Collections.Generic.List[string]
        if ($installToAO) {
            if ($sqlNode1 -and $sqlNode1 -ne $env:COMPUTERNAME -and -not $wmiTargets.Contains($sqlNode1)) { $wmiTargets.Add($sqlNode1) | Out-Null }
            if ($sqlNode2 -and $sqlNode2 -ne $env:COMPUTERNAME -and -not $wmiTargets.Contains($sqlNode2)) { $wmiTargets.Add($sqlNode2) | Out-Null }
        }
        elseif ($sqlServerName -and $sqlServerName -ne $env:COMPUTERNAME) {
            # Non-AO: $sqlServerName is a real remote SQL machine; probe it.
            $wmiTargets.Add($sqlServerName) | Out-Null
        }
        if ($wmiTargets.Count -gt 0) {
            $wmiFailures = New-Object System.Collections.Generic.List[string]
            foreach ($wmiHost in $wmiTargets) {
                $wmiOk = $false
                $wmiErr = $null
                # 6 attempts x 10s = 60s. Anything genuinely broken
                # (account not a member) reports ACCESS_DENIED on the
                # FIRST attempt; the retry budget is for transient
                # RPC/DCOM warmup right after VMs cold-boot.
                for ($wmiTry = 1; $wmiTry -le 6; $wmiTry++) {
                    try {
                        $null = Get-CimInstance -ComputerName $wmiHost -Namespace 'root\cimv2' -ClassName Win32_ComputerSystem -OperationTimeoutSec 15 -ErrorAction Stop
                        $note = if ($wmiTry -gt 1) { " (attempt $wmiTry)" } else { '' }
                        Write-DscStatus "SQL pre-flight WMI: $env:COMPUTERNAME`$ has admin/WMI access to [$wmiHost]$note"
                        $wmiOk = $true
                        break
                    }
                    catch {
                        $wmiErr = $_.Exception.Message
                        Write-DscStatus "SQL pre-flight WMI: attempt $wmiTry/6 to [$wmiHost] failed: $wmiErr"
                    }
                    if ($wmiTry -lt 6) { Start-Sleep -Seconds 10 }
                }
                if (-not $wmiOk) {
                    $wmiFailures.Add("[$wmiHost] $wmiErr") | Out-Null
                }
            }
            if ($wmiFailures.Count -gt 0) {
                Write-DscStatus "SQL pre-flight WMI: $env:COMPUTERNAME`$ cannot WMI to: $($wmiFailures -join ' | '). CM Setup would fail its prereq pass with 'Computer account doesn't have admininstrative rights to the SQL Server'. Add $env:COMPUTERNAME`$ to BUILTIN\Administrators on each listed SQL host (e.g. 'net localgroup Administrators $env:USERDOMAIN\$env:COMPUTERNAME`$ /add' from the SQL host) and re-run -StartPhase 8. Refusing to launch setup.exe blind -- a failed prereq pass would otherwise hang for many minutes per VM and stall every dependent node." -Failure
                return
            }
        }

        # Step 4: AG synchronization stability gate (SQLAO only).
        # ConfigMgr Setup's Init_Database does an unconditional failover to
        # the secondary (to set db_owner / clr / trustworthy on the AG db)
        # and then a failback. Each leg waits a hardcoded ~15 min for the AG
        # to report HEALTHY/SYNCHRONIZED. If the secondary is still seeding,
        # is briefly NOT_HEALTHY, or its replica state-machine gets stuck in
        # UNKNOWN after the failback, setup fails with:
        #     "Init_Database (AG) - Something went wrong waiting for
        #      synchronization to report as healthy."
        #     "~Setup has encountered fatal errors during database
        #      initialization. Contact your SQL administrator."
        # The site DB CM_<sitecode> is committed BEFORE that failover, so a
        # retry needs a Phase 8 checkpoint restore. We require N consecutive
        # clean polls (not just one momentary HEALTHY blip) before allowing
        # setup.exe to launch, and resume any suspended AG dbs as we go.
        if ($installToAO -and $sqlPreCheckCs -and $sqlAOGroupName) {
            $agStableMin     = 3        # consecutive clean polls required (~60s stability)
            $agPollInterval  = 20       # seconds between polls
            $agMaxAttempts   = 30       # 30 * 20s = 10 min max wall-clock
            $agCleanStreak   = 0
            $agLastSnapshot  = $null
            $agStable        = $false
            $agReplicaQuery  = @"
SELECT ar.replica_server_name,
       rs.role_desc,
       rs.connected_state_desc,
       rs.synchronization_health_desc,
       rs.operational_state_desc,
       rs.recovery_health_desc
FROM sys.dm_hadr_availability_replica_states rs
JOIN sys.availability_groups ag ON rs.group_id = ag.group_id
JOIN sys.availability_replicas ar ON rs.replica_id = ar.replica_id
WHERE ag.name = '$sqlAOGroupName'
"@
            $agSuspendedQuery = @"
SELECT DISTINCT adb.database_name
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_databases_cluster adb ON drs.group_database_id = adb.group_database_id
WHERE drs.is_suspended = 1
"@
            for ($agTry = 1; $agTry -le $agMaxAttempts; $agTry++) {
                $replicas = @()
                try {
                    $agConn = New-Object System.Data.Odbc.OdbcConnection $sqlPreCheckCs
                    $agConn.Open()
                    try {
                        $agCmd = $agConn.CreateCommand()
                        $agCmd.CommandTimeout = 30
                        $agCmd.CommandText = $agReplicaQuery
                        $agReader = $agCmd.ExecuteReader()
                        while ($agReader.Read()) {
                            $replicas += [pscustomobject]@{
                                Name   = $agReader['replica_server_name']
                                Role   = $agReader['role_desc']
                                Conn   = $agReader['connected_state_desc']
                                Health = $agReader['synchronization_health_desc']
                                Op     = if ($agReader.IsDBNull(4)) { 'UNKNOWN' } else { $agReader['operational_state_desc'] }
                                Rec    = if ($agReader.IsDBNull(5)) { 'UNKNOWN' } else { $agReader['recovery_health_desc'] }
                            }
                        }
                        $agReader.Close()
                    }
                    finally { $agConn.Close() }
                }
                catch {
                    Write-DscStatus "AG pre-flight: attempt $agTry/$agMaxAttempts — replica query failed: $($_.Exception.Message)"
                    $agCleanStreak = 0
                    if ($agTry -lt $agMaxAttempts) { Start-Sleep -Seconds $agPollInterval }
                    continue
                }

                if ($replicas.Count -eq 0) {
                    Write-DscStatus "AG pre-flight: attempt $agTry/$agMaxAttempts — AG '$sqlAOGroupName' returned 0 replicas (listener may not be on a node that hosts the AG yet)"
                    $agCleanStreak = 0
                }
                else {
                    $snapshot = ($replicas | ForEach-Object { "$($_.Name)[$($_.Role)/$($_.Conn)/$($_.Health)/op=$($_.Op)/rec=$($_.Rec)]" }) -join '; '
                    $allHealthy = $true
                    foreach ($r in $replicas) {
                        # Connected + synchronization-health are populated for EVERY replica
                        # (local and remote) -- these are the authoritative cross-replica gates.
                        if ($r.Conn -ne 'CONNECTED' -or $r.Health -ne 'HEALTHY') {
                            $allHealthy = $false
                            break
                        }
                        # operational_state / recovery_health are ONLY populated for the LOCAL
                        # replica in sys.dm_hadr_availability_replica_states; they come back NULL
                        # (-> 'UNKNOWN' here) for any remote replica. Since this pre-flight queries
                        # through the listener it always lands on the PRIMARY, so only the primary's
                        # row carries real op/rec values -- enforce them there only. Gating op/rec on
                        # the (remote) secondary would make this loop NEVER reach HEALTHY on a
                        # perfectly healthy AG (the long-standing 'op=UNKNOWN/rec=UNKNOWN' false WARN).
                        if ($r.Role -eq 'PRIMARY') {
                            if ($r.Op  -eq 'UNKNOWN' -or $r.Op  -eq 'OFFLINE' -or
                                $r.Rec -eq 'UNKNOWN' -or $r.Rec -eq 'ONLINE_IN_PROGRESS') {
                                $allHealthy = $false
                                break
                            }
                        }
                    }
                    if ($allHealthy) {
                        $agCleanStreak++
                        if ($snapshot -ne $agLastSnapshot -or $agCleanStreak -eq $agStableMin) {
                            Write-DscStatus "AG pre-flight: attempt $agTry — HEALTHY (streak $agCleanStreak/$agStableMin) [$snapshot]"
                            $agLastSnapshot = $snapshot
                        }
                        if ($agCleanStreak -ge $agStableMin) {
                            $agStable = $true
                            Write-DscStatus "AG pre-flight: AG '$sqlAOGroupName' stable for $($agStableMin * $agPollInterval)s — safe for ConfigMgr Init_Database failover/failback"
                            break
                        }
                    }
                    else {
                        if ($snapshot -ne $agLastSnapshot) {
                            Write-DscStatus "AG pre-flight: attempt $agTry/$agMaxAttempts — UNHEALTHY [$snapshot]"
                            $agLastSnapshot = $snapshot
                        }
                        $agCleanStreak = 0
                        # Remediation: resume any suspended AG databases via the listener.
                        # (Endpoint cycling / per-node SQL restarts are intentionally NOT
                        # done here — those require remoting into the SQLAO nodes and
                        # belong to Test-SQLAOFunctionality. We do the cheap, safe
                        # remediation only; if the AG is in serious trouble we surface
                        # the WARN and let the operator look at it.)
                        try {
                            $rsConn = New-Object System.Data.Odbc.OdbcConnection $sqlPreCheckCs
                            $rsConn.Open()
                            try {
                                $suspended = @()
                                $rsCmd = $rsConn.CreateCommand()
                                $rsCmd.CommandTimeout = 30
                                $rsCmd.CommandText = $agSuspendedQuery
                                $rsReader = $rsCmd.ExecuteReader()
                                while ($rsReader.Read()) { $suspended += [string]$rsReader['database_name'] }
                                $rsReader.Close()
                                foreach ($db in $suspended) {
                                    try {
                                        $resCmd = $rsConn.CreateCommand()
                                        $resCmd.CommandTimeout = 30
                                        $resCmd.CommandText = "ALTER DATABASE [$db] SET HADR RESUME"
                                        $null = $resCmd.ExecuteNonQuery()
                                        Write-DscStatus "AG pre-flight: resumed suspended AG database '$db'"
                                    }
                                    catch {
                                        Write-DscStatus "AG pre-flight: failed to resume '$db': $($_.Exception.Message)"
                                    }
                                }
                            }
                            finally { $rsConn.Close() }
                        }
                        catch {
                            Write-DscStatus "AG pre-flight: suspended-database probe failed: $($_.Exception.Message)"
                        }
                    }
                }

                if ($agStable) { break }
                if ($agTry -lt $agMaxAttempts) { Start-Sleep -Seconds $agPollInterval }
            }

            if (-not $agStable) {
                Write-DscStatus "AG pre-flight: WARNING — AG '$sqlAOGroupName' did not stay HEALTHY for $($agStableMin * $agPollInterval)s within $($agMaxAttempts * $agPollInterval)s. ConfigMgr Init_Database may fail at AGWaitForSynchronizationHealth (the failover/failback CM does to set db_owner needs both replicas HEALTHY+SYNCHRONIZED within ~15 min). Last state: $agLastSnapshot. Proceeding anyway."
            }
        }
    }

    # ConfigMgr seeds the AG secondary through this share, and its RESTORE LOG names no
    # backup set, so it reads the FIRST one in the file. A .bak/.trn left by a previous
    # build is restored instead of the one setup just wrote, and SQL rejects it with 3154
    # -- surfaced only as the generic 3013. Phase 5 creates the share with a DSC File
    # resource set to Ensure=Present, which never purges, so nothing else clears it.
    if ($installToAO -and $agBackupShare) {
        try {
            $staleSeed = @(Get-ChildItem -Path (Join-Path $agBackupShare '*') -Include '*.bak', '*.trn' -File -ErrorAction Stop)
            if ($staleSeed.Count -eq 0) {
                Write-DscStatus "AG seeding share '$agBackupShare' holds no leftover backups."
            }
            foreach ($s in $staleSeed) {
                try {
                    Remove-Item -LiteralPath $s.FullName -Force -ErrorAction Stop
                    Write-DscStatus "Deleted stale AG seeding backup '$($s.Name)' ($([int]($s.Length / 1MB))MB, written $($s.LastWriteTime.ToString('yyyy-MM-dd HH:mm')))"
                }
                catch {
                    Write-DscStatus "WARNING: could not delete stale AG seeding backup '$($s.Name)': $($_.Exception.Message). If it predates this build, Init_Database will fail with SQL 3154."
                }
            }
        }
        catch {
            Write-DscStatus "WARNING: could not read AG seeding share '$agBackupShare': $($_.Exception.Message). A leftover .trn there fails Init_Database with SQL 3154."
        }
    }

    Write-DscStatus "Starting Install of CM from $CMInstallationFile [$($CMFileVersion.VersionInfo.FileVersion)]"
    start-sleep -seconds 2

    # Rename any existing ConfigMgrSetup.log from a prior attempt so the host
    # monitoring loop (bail-early check) only sees errors from THIS run.
    if (Test-Path 'C:\ConfigMgrSetup.log') {
        $oldLogName = "C:\ConfigMgrSetup_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
        try {
            Rename-Item -Path 'C:\ConfigMgrSetup.log' -NewName (Split-Path $oldLogName -Leaf) -Force
            Write-DscStatus "Renamed prior ConfigMgrSetup.log to $(Split-Path $oldLogName -Leaf)"
        }
        catch {
            Write-DscStatus "Warning: could not rename prior ConfigMgrSetup.log: $($_.Exception.Message)"
        }
    }

    Write-DscStatusSetup

    # Drop a breadcrumb so a future re-entry can tell whether the prior
    # 'Running' state was killed during setupdl (safe to retry) or during
    # setup.exe (must restore Phase 8 checkpoint). See the Status='Running'
    # gate near the top of this script for the consuming side.
    try {
        $flagDir = Split-Path -Parent $setupExeStartedFlag
        if (-not (Test-Path $flagDir)) { New-Item -ItemType Directory -Path $flagDir -Force | Out-Null }
        Set-Content -Path $setupExeStartedFlag -Value (Get-Date -Format 'o') -Force
    }
    catch {
        Write-DscStatus "Warning: failed to write setup.exe breadcrumb at $setupExeStartedFlag : $($_.Exception.Message). Re-entry recovery may be less precise."
    }

    Start-Process -Filepath ($CMInstallationFile) -ArgumentList ('/NOUSERINPUT /script "' + $CMINIPath + '"') -wait

    # Check if setup.exe failed the prerequisite check. If so, rename the
    # log, re-run the SQL pre-flight (Kerberos may have settled since our
    # first check), and re-launch setup.exe once. A second prereq failure
    # falls through to the normal failure path.
    if (Test-Path 'C:\ConfigMgrSetup.log') {
        $prereqFail = Get-Content 'C:\ConfigMgrSetup.log' -Tail 10 -ErrorAction SilentlyContinue |
            Select-String "Prereq check didn't pass" | Select-Object -First 1
        if ($prereqFail) {
            Write-DscStatus "setup.exe failed prerequisite check on first attempt. Renaming log and retrying after SQL pre-flight..."
            $failLogName = "C:\ConfigMgrSetup_prereqfail_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
            try { Rename-Item -Path 'C:\ConfigMgrSetup.log' -NewName (Split-Path $failLogName -Leaf) -Force }
            catch { Write-DscStatus "Warning: could not rename prereq-failed log: $($_.Exception.Message)" }

            # Re-run SQL pre-flight (Steps 2-3) before second attempt
            if ($sqlServerName -ne $env:COMPUTERNAME) {
                # Step 2 retry: ODBC connectivity
                $sqlPreCheckOk = $false
                $sqlPreCheckCs = $null
                for ($sqlTry = 1; $sqlTry -le 20; $sqlTry++) {
                    $odbcCs1 = "Driver={SQL Server};AutoTranslate=no;Server=$sqlTarget;Database=master;Trusted_Connection=yes;Encrypt=no;TrustServerCertificate=yes"
                    try {
                        $odbcConn = New-Object System.Data.Odbc.OdbcConnection $odbcCs1
                        $odbcConn.Open(); $odbcConn.Close()
                        $sqlPreCheckOk = $true; $sqlPreCheckCs = $odbcCs1
                        Write-DscStatus "Prereq retry: ODBC connected on attempt $sqlTry (Driver={SQL Server})"
                        break
                    } catch { $sqlPreErr1 = $_.Exception.Message }
                    $odbcCs2 = "Driver={ODBC Driver 18 for SQL Server};AutoTranslate=no;Server=$sqlTarget;Database=master;Trusted_Connection=yes;Encrypt=yes;TrustServerCertificate=no"
                    try {
                        $odbcConn = New-Object System.Data.Odbc.OdbcConnection $odbcCs2
                        $odbcConn.Open(); $odbcConn.Close()
                        $sqlPreCheckOk = $true; $sqlPreCheckCs = $odbcCs2
                        Write-DscStatus "Prereq retry: ODBC connected on attempt $sqlTry (Driver={ODBC Driver 18}, secure)"
                        break
                    } catch {}
                    Write-DscStatus "Prereq retry: ODBC attempt $sqlTry/20 to [$sqlTarget] failed: $sqlPreErr1"
                    if ($sqlTry -lt 20) { Start-Sleep -Seconds 15 }
                }
                if (-not $sqlPreCheckOk) {
                    Write-DscStatus "Prereq retry: ODBC still failing after 20 attempts. Cannot retry setup.exe." -Failure
                    return
                }

                # Step 3 retry: Kerberos auth check
                $authScheme = $null
                for ($authTry = 1; $authTry -le 20; $authTry++) {
                    try {
                        $authConn = New-Object System.Data.Odbc.OdbcConnection $sqlPreCheckCs
                        $authConn.Open()
                        $authCmd = $authConn.CreateCommand()
                        $authCmd.CommandText = "SELECT auth_scheme FROM sys.dm_exec_connections WHERE session_id = @@SPID"
                        $authScheme = $authCmd.ExecuteScalar()
                        $authConn.Close()
                    } catch { $authScheme = $null }
                    if ($authScheme -eq 'KERBEROS') {
                        Write-DscStatus "Prereq retry: auth_scheme = KERBEROS on attempt $authTry — good"
                        break
                    }
                    if ($authTry -eq 1) {
                        Write-DscStatus "Prereq retry: auth_scheme = $authScheme, waiting up to 5 min for Kerberos..."
                    }
                    if ($authTry -lt 20) { Start-Sleep -Seconds 15 }
                }
                if ($authScheme -and $authScheme -ne 'KERBEROS') {
                    Write-DscStatus "Prereq retry: WARNING — auth_scheme still $authScheme after 20 attempts"
                }
            }

            Write-DscStatus "Re-launching setup.exe (attempt 2)"
            Start-Process -Filepath ($CMInstallationFile) -ArgumentList ('/NOUSERINPUT /script "' + $CMINIPath + '"') -wait

            # Check if the retry also failed prereq
            if (Test-Path 'C:\ConfigMgrSetup.log') {
                $prereqFail2 = Get-Content 'C:\ConfigMgrSetup.log' -Tail 10 -ErrorAction SilentlyContinue |
                    Select-String "Prereq check didn't pass" | Select-Object -First 1
                if ($prereqFail2) {
                    Write-DscStatus "setup.exe failed prerequisite check on both attempts. Check C:\ConfigMgrSetup.log." -Failure
                    return
                }
            }
        }
    }

    # setup.exe returning is not setup.exe succeeding -- a database-init fatal ends
    # with "Contact your SQL administrator" in its own log and nothing else. Marking
    # Completed here strands the site for good: every later re-run takes the
    # "already installed" path and waits for an SMS Provider that will never exist.
    # Same tail and patterns the host monitor uses, so both sides agree on "fatal".
    if (Test-Path 'C:\ConfigMgrSetup.log') {
        $setupFatal = Get-Content 'C:\ConfigMgrSetup.log' -Tail 30 -ErrorAction SilentlyContinue |
            Select-String "Failed Configuration Manager Server Setup|fatal errors|cannot be completed|doesn't have administrative rights" |
            Select-Object -First 1
        if ($setupFatal) {
            # Leave Status='Running' and the breadcrumb in place: re-entry then takes
            # the partial-install path, which knows a checkpoint restore is required.
            Write-DscStatus "setup.exe returned but ConfigMgrSetup.log reports a fatal -- NOT marking the install complete: $(($setupFatal.Line -split '\$\$<')[0].Trim()). Check C:\ConfigMgrSetup.log." -Failure
            return
        }
    }

    Write-DscStatus "Installation finished [$($CMFileVersion.VersionInfo.FileVersion)]."

    # Write action completed
    $Configuration.InstallSCCM.Status = 'Completed'
    $Configuration.InstallSCCM.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
    Write-ScriptWorkFlowData -Configuration $Configuration -ConfigurationFile $ConfigurationFile
    start-sleep -seconds 5
    $firstRun = $true

}
else {
    Write-DscStatus "ConfigMgr is already installed"
    $firstRun = $false
    Write-DscStatusSetup
}

# Read Site Code from registry
$SiteCode = Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Microsoft\SMS\Identification' -Name 'Site Code'
if (-not $SiteCode) {
    Write-DscStatus "Failed to get 'Site Code' from SOFTWARE\Microsoft\SMS\Identification. Install may have failed. Check C:\ConfigMgrSetup.log" -Failure
    return
}

# Provider
$smsProvider = Get-SMSProvider -SiteCode $SiteCode
if (-not $smsProvider.FQDN) {
    Write-DscStatus "Failed to get SMS Provider for site $SiteCode. Install may have failed. Check C:\ConfigMgrSetup.log" -Failure
    return $false
}

# Set CMSite Provider
$worked = Set-CMSiteProvider -SiteCode $SiteCode -ProviderFQDN $($smsProvider.FQDN)
if (-not $worked) {
    Write-DscStatus "Failed to load the ConfigMgr Powershell Components for site $SiteCode, and provider $($smsProvider.FQDN). Install may have failed. Check C:\ConfigMgrSetup.log" -Failure
    return $false
}

# Set the current location to be the site code.
Set-Location "$($SiteCode):\"
if ((Get-Location).Drive.Name -ne $SiteCode) {
    Write-DscStatus "Failed to Set-Location to $SiteCode`:"
    return $false
}

# Add vmbuildadmin as Full Admin

$userName = "vmbuildadmin"
$userDomain = $env:USERDOMAIN
$domainUserName = "$userDomain\$userName"
$exists = Get-CMAdministrativeUser -RoleName "Full Administrator" | Where-Object { $_.LogonName -like "*$userName*" }

if (-not $exists) {
    Write-DscStatus "Adding '$userName' account as Full Administrator in ConfigMgr"
    $i = 0
    do {
        $i++
        New-CMAdministrativeUser -Name $domainUserName -RoleName "Full Administrator" `
            -SecurityScopeName "All", "All Systems", "All Users and User Groups"
        Start-Sleep -Seconds 10
        $exists = Get-CMAdministrativeUser -RoleName "Full Administrator" | Where-Object { $_.LogonName -eq $domainUserName }
    }
    until ($exists -or $i -gt 10)
}

if (-not $exists) {
    Write-DscStatus "Failed to add 'vmbuildadmin' account as Full Administrator in ConfigMgr"
}

# Check if we should update
$UpdateRequired = $false
if ($cmo.version -notin "current-branch", "tech-preview" -and $cmo.version -ne $ThisVM.thisParams.cmDownloadVersion.baselineVersion) {
    $UpdateRequired = $true

    if ($($cmo.InstallSCP) -eq $false) {
        $UpdateRequired = $false
    }

    if ($($cmo.OfflineSCP) -eq $true) {
        $UpdateRequired = $false        
    }

}

if ($($cmo.OfflineSCP) -eq $true) {
    $UpdateRequired = $false
    Write-DscStatus "Installing Offline SCP"
    Add-CMServiceConnectionPoint -SiteSystemServerName "$env:computername.$DomainFullName" -SiteCode $SiteCode -Mode Offline
}


if ($Configuration.UpgradeSCCM.Status -eq 'Completed') {
    # Verify the update is actually installed before skipping
    $targetVersion = $cmo.version
    if (-not $UpdateRequired) {
        # No in-console update applies here (baseline media is already at this version,
        # or the SCP is offline/absent), so there is no site-update record to find and
        # the check below would fail forever.
        Write-DscStatus "UpgradeSCCM Completed and no in-console update applies for 'Configuration Manager $targetVersion'. Skipping upgrade."
    }
    else {
        $installedUpdate = Get-CMSiteUpdate -Fast | Where-Object { $_.State -eq 196612 -and $_.Name -eq "Configuration Manager $targetVersion" }
        if ($installedUpdate) {
            Write-DscStatus "Update 'Configuration Manager $targetVersion' verified as installed. Skipping upgrade."
            $UpdateRequired = $false
        }
        else {
            Write-DscStatus "UpgradeSCCM marked Completed but update 'Configuration Manager $targetVersion' not found in installed state. Re-running upgrade."
            $Configuration.UpgradeSCCM.Status = 'NotStart'
            Write-ScriptWorkFlowData -Configuration $Configuration -ConfigurationFile $ConfigurationFile
            $UpdateRequired = $true
        }
    }
}

if ($UpdateRequired) {

    if ($InstalltoAO) {
        try {
            Get-ChildItem "SQLSERVER:\Sql\$sqlServerName\DEFAULT\AvailabilityGroups\$sqlAOGroupName\AvailabilityDatabases" | Resume-SqlAvailabilityDatabase -ErrorAction SilentlyContinue
            Get-ChildItem "SQLSERVER:\Sql\$sqlNode2\DEFAULT\AvailabilityGroups\$sqlAOGroupName\AvailabilityDatabases" | Resume-SqlAvailabilityDatabase -ErrorAction SilentlyContinue
            Get-ChildItem "SQLSERVER:\Sql\$sqlNode1\DEFAULT\AvailabilityGroups\$sqlAOGroupName\AvailabilityDatabases" | Resume-SqlAvailabilityDatabase -ErrorAction SilentlyContinue
        }
        catch {}
    }
    # Update actions file
    $Configuration.UpgradeSCCM.Status = 'Running'
    $Configuration.UpgradeSCCM.StartTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
    Write-ScriptWorkFlowData -Configuration $Configuration -ConfigurationFile $ConfigurationFile

    # Check if DMP Downloader is has recently checked for updates

    $registryPath = "HKLM:\Software\Microsoft\SMS\COMPONENTS\SMS_DMP_DOWNLOADER"
    $valueName = "LastSyncedTime"
    
    $lastSyncedTimeHex = (Get-ItemProperty -Path $registryPath -Name $valueName).$valueName
    
    $epoch = [DateTime]::ParseExact("1970-01-01", "yyyy-MM-dd", [System.Globalization.CultureInfo]::InvariantCulture)
    
    $lastSyncedTime = $epoch.AddSeconds($lastSyncedTimeHex)
    
    $currentTimeUTC = (Get-Date).ToUniversalTime()
    
    $timeDifference = $currentTimeUTC - $lastSyncedTime
    
    # Check if the time difference is less than or equal to 60 minutes
    if ($timeDifference.TotalMinutes -le 60) {
        Write-DscStatus "[DMP Downloader] The LastSyncedTime was updated in the last 60 minutes. Checking for updates."
    }
    else {
        Write-DscStatus "[DMP Downloader] The LastSyncedTime was not updated in the last 60 minutes."
        Set-ItemProperty -Path $registryPath -Name $valueName -Value 0 -Force
        Set-ItemProperty -Path $registryPath -Name "LastSyncRequestTime" -Value 0 -Force
        # Wait before checking DMP Downloader status
        Start-Sleep -Seconds 30
        Write-DscStatus "Checking for updates. Waiting for DMP Downloader."

        # Set var
        $upgradingfailed = $false
        $originalbuildnumber = ""

        # Wait for SMS_DMP_DOWNLOADER running
        $counter = 0
        $key = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
        $subKey = $key.OpenSubKey("SOFTWARE\Microsoft\SMS\Components\SMS_Executive\Threads\SMS_DMP_DOWNLOADER")
        $DMPState = $subKey.GetValue("Current State")

        if ($DMPState -ne "Running") {
            Restart-Service -DisplayName "SMS_Site_Component_Manager" -ErrorAction SilentlyContinue
        }

        while ($DMPState -ne "Running") {
            $counter += 1
            Write-DscStatus "SMS_DMP_DOWNLOADER state is: $DMPState" -RetrySeconds 30
            Start-Sleep -Seconds 30
            $DMPState = $subKey.GetValue("Current State")

            if (0 -eq $counter % 10) {
                Write-DscStatus "SMS_DMP_DOWNLOADER state is still $DMPState. Restarting SiteComp service."
                Restart-Service -DisplayName "SMS_Site_Component_Manager" -ErrorAction SilentlyContinue
                Start-Sleep 30
            }
        }


        Write-DscStatus "SMS_DMP_DOWNLOADER state is: $DMPState. Checking for updates."

    }




    #----------------------------------------------------
    $state = @{
        0      = 'UNKNOWN'
        2      = 'ENABLED'
        #DMP DOWNLOAD
        262145 = 'DOWNLOAD_IN_PROGRESS'
        262146 = 'DOWNLOAD_SUCCESS'
        327679 = 'DOWNLOAD_FAILED'
        #APPLICABILITY
        327681 = 'APPLICABILITY_CHECKING'
        327682 = 'APPLICABILITY_SUCCESS'
        393213 = 'APPLICABILITY_HIDE'
        393214 = 'APPLICABILITY_NA'
        393215 = 'APPLICABILITY_FAILED'
        #CONTENT
        65537  = 'CONTENT_REPLICATING'
        65538  = 'CONTENT_REPLICATION_SUCCESS'
        131071 = 'CONTENT_REPLICATION_FAILED'
        #PREREQ
        131073 = 'PREREQ_IN_PROGRESS'
        131074 = 'PREREQ_SUCCESS'
        131075 = 'PREREQ_WARNING'
        196607 = 'PREREQ_ERROR'
        #Apply changes
        196609 = 'INSTALL_IN_PROGRESS'
        196610 = 'INSTALL_WAITING_SERVICE_WINDOW'
        196611 = 'INSTALL_WAITING_PARENT'
        196612 = 'INSTALL_SUCCESS'
        196613 = 'INSTALL_PENDING_REBOOT'
        262143 = 'INSTALL_FAILED'
        #CMU SERVICE UPDATEI
        196614 = 'INSTALL_CMU_VALIDATING'
        196615 = 'INSTALL_CMU_STOPPED'
        196616 = 'INSTALL_CMU_INSTALLFILES'
        196617 = 'INSTALL_CMU_STARTED'
        196618 = 'INSTALL_CMU_SUCCESS'
        196619 = 'INSTALL_WAITING_CMU'
        262142 = 'INSTALL_CMU_FAILED'
        #DETAILED INSTALL STATUS
        196620 = 'INSTALL_INSTALLFILES'
        196621 = 'INSTALL_UPGRADESITECTRLIMAGE'
        196622 = 'INSTALL_CONFIGURESERVICEBROKER'
        196623 = 'INSTALL_INSTALLSYSTEM'
        196624 = 'INSTALL_CONSOLE'
        196625 = 'INSTALL_INSTALLBASESERVICES'
        196626 = 'INSTALL_UPDATE_SITES'
        196627 = 'INSTALL_SSB_ACTIVATION_ON'
        196628 = 'INSTALL_UPGRADEDATABASE'
        196629 = 'INSTALL_UPDATEADMINCONSOLE'
    }
    #----------------------------------------------------

    # Get build number of current install
    $sites = Get-CMSite
    if ($originalbuildnumber -eq "") {
        if ($sites.count -eq 1) {
            $originalbuildnumber = $sites.BuildNumber
        }
        else {
            $originalbuildnumber = $sites[0].BuildNumber
        }
    }
    Write-DscStatus "InstallAndUpdateSCCM.ps1 Found Current Build number $originalbuildnumber"
    # Check for updates
    $retrytimes = 0
    $downloadretrycount = 0
    $updatepack = Get-UpdatePack -UpdateVersion $cmo.version
    if ($updatepack -ne "") {
        Write-DscStatus "Found '$($updatepack.Name)' update."
    }
    else {
        Write-DscStatus "No updates found."
    }

    # Best-effort CM in-console-version -> baseline build-number map. Used by the
    # version guard below (skip a same-version/no-op update) and by the monitor
    # loop's INSTALL_WAITING_PARENT handling (accept 'already at target' as done).
    # Unknown/future versions are absent on purpose: the code then falls through
    # to the normal path (no false skips) and the bounded monitor loop still
    # protects against a wedge.
    $cmVersionBuildMap = @{
        '2103' = 9049; '2107' = 9058; '2111' = 9068; '2203' = 9078
        '2207' = 9088; '2211' = 9096; '2303' = 9106; '2309' = 9122
        '2403' = 9128; '2409' = 9132
    }
    $targetBuild = $cmVersionBuildMap["$($cmo.version)"]
    $currentBuildNum = 0
    [int]::TryParse("$originalbuildnumber", [ref]$currentBuildNum) | Out-Null

    # Version guard: if the site is ALREADY at (or above) the build this update
    # would install, applying it is a no-op self-update. On a top-level site
    # (a CAS / standalone primary has NO parent) that same-version update can
    # wedge the state machine at INSTALL_WAITING_PARENT forever -- observed on
    # CT1-CS1SITE (build 9122 = 2309) being told to 'update to 2309'. Skip it
    # here rather than entering the monitor loop.
    if ($updatepack -ne "" -and $targetBuild -and $currentBuildNum -ge $targetBuild) {
        Write-DscStatus "Site is already at build $currentBuildNum (>= $targetBuild for CM $($cmo.version)); '$($updatepack.Name)' is a same-version/no-op update. Skipping to avoid an INSTALL_WAITING_PARENT wedge on a top-level site."
        $Configuration.UpgradeSCCM.Status = 'Completed'
        Write-ScriptWorkFlowData -Configuration $Configuration -ConfigurationFile $ConfigurationFile
        $updatepack = ""
    }

    $updateCompleted = $false
    # Work on update
    while ($updatepack -ne "") {

        if ($updateCompleted) {
            break
        }

        # Set failure if retry exhausted
        if ($retrytimes -eq 3) {
            $upgradingfailed = $true
            break
        }

        # Get update info
        $updatepack = Get-CMSiteUpdate -Fast -Name $updatepack.Name

        if (-not $updatepack) {
            start-sleep -Seconds 300
            $retrytimes++
            continue
        }
        if ($updatepack.state -eq 196612 -or $updatepack.state -eq 199612) {
            $updateCompleted = $true
            break
        }

        # If the update is already installing (196609-196629), skip straight
        # to the monitoring loop. Re-triggering EnableHTTPS, download, prereq,
        # or Install-CMSiteUpdate would all throw "Cannot perform an update
        # at this time" and waste retry attempts.
        $installInProgress = ($updatepack.State -ge 196609 -and $updatepack.State -le 196629)
        if ($installInProgress) {
            Write-DscStatus "Update '$($updatepack.Name)' is already installing (state $($updatepack.State) = $($state[$updatepack.State])). Monitoring."
        }

        if (-not $installInProgress -and -not $cmo.UsePKI) {
            # Enable E-HTTP. This takes time on new install because SSLState flips, so start the script but don't monitor.
            Write-DscStatus "Not UsePKI Running EnableEHTTP.ps1"
            $ScriptFile = Join-Path -Path $PSScriptRoot -ChildPath "EnableEHTTP.ps1"
            Invoke-DotSource -Script $ScriptFile -Arguments $ConfigFilePath, $LogPath, $firstRun
            Write-DscStatus "EnableEHTTP.ps1 done"
        }
        elseif (-not $installInProgress) {
            Write-DscStatus "UsePKI Running EnableHTTPS.ps1"
            $ScriptFile = Join-Path -Path $PSScriptRoot -ChildPath "EnableHTTPS.ps1"
            Invoke-DotSource -Script $ScriptFile -Arguments $ConfigFilePath, $LogPath, $firstRun
            Write-DscStatus "EnableHTTPS.ps1 done"
        }

        # Invoke update download
        while (-not $installInProgress -and ($updatepack.State -eq 327682 -or $updatepack.State -eq 262145 -or $updatepack.State -eq 327679)) {

            # Package not downloaded
            if ($updatepack.State -eq 327682) {

                # Invoke download
                Write-DscStatus "Invoking download for '$($updatepack.Name)', waiting for download to begin."
                Invoke-CMSiteUpdateDownload -Name $updatepack.Name -Force -WarningAction SilentlyContinue
                Restart-Service -DisplayName "SMS_Executive" -ErrorAction SilentlyContinue
                Start-Sleep 120                               

                # Check state
                $updatepack = Get-CMSiteUpdate -Name $updatepack.Name -Fast
                $downloadstarttime = get-date
                while ($updatepack.State -eq 327682) {

                    # Get update state
                    Write-DscStatus "Waiting for '$($updatepack.Name)' download to begin" -RetrySeconds 60
                    Start-Sleep 60

                    # Check state again
                    $downloadspan = New-TimeSpan -Start $downloadstarttime -End (Get-Date)
                    $updatepack = Get-CMSiteUpdate -Name $updatepack.Name -Fast

                    # Trigger restart every 5 mins
                    if (0 -eq $downloadspan.Minutes % 5) {
                        Write-DscStatus "Still waiting for '$($updatepack.Name)' download to begin, Restarting SmsExec."
                        Restart-Service -DisplayName "SMS_Executive" -ErrorAction SilentlyContinue
                    }

                    # Been an hour, increment retry counter
                    if ($downloadspan.Hours -ge 1) {
                        Write-DscStatus "Still waiting for '$($updatepack.Name)' download to begin, Restarting SmsExec and incrementing retry counter."
                        Restart-Service -DisplayName "SMS_Executive"
                        $downloadretrycount++
                        Start-Sleep 120
                        $downloadstarttime = get-date
                    }

                    # Give up and fail after 2 hours
                    if ($downloadretrycount -ge 2) {
                        Write-DscStatus "Timed out waiting for '$($updatepack.Name)' download to start."
                        break
                    }
                }
            }

            # Give up and fail
            if ($downloadretrycount -ge 2) {
                break
            }

            #waiting package downloaded
            $downloadstarttime = get-date
            while ($updatepack.State -eq 262145) {
                Write-DscStatus "Download in progress. Waiting for '$($updatepack.Name)' download to complete" -RetrySeconds 30
                Start-Sleep 30
                $updatepack = Get-CMSiteUpdate -Name $updatepack.Name -Fast
                $downloadspan = New-TimeSpan -Start $downloadstarttime -End (Get-Date)
                if ($downloadspan.Minutes -ge 30) {
                    Write-DscStatus "Still waiting for '$($updatepack.Name)' download to complete'. Restarting SmsExec."
                    Restart-Service -DisplayName "SMS_Executive"
                    Start-Sleep 120
                    $downloadstarttime = get-date
                }
            }

            #downloading failed
            if ($updatepack.State -eq 327679) {
                $retrytimes++
                Start-Sleep 300
                continue
            }
        }

        if ($downloadretrycount -ge 2) {
            Write-DscStatus "Timed out waiting for '$($updatepack.Name)' download to complete."
            break
        }

        # trigger prerequisites check after the package downloaded
        if (-not $installInProgress) {
            try {
                Invoke-CMSiteUpdatePrerequisiteCheck -Name $updatepack.Name
            }
            catch {
                Write-DscStatus "WARNING: Invoke-CMSiteUpdatePrerequisiteCheck threw: $_"
            }
        }
        $count = 0
        while (-not $installInProgress -and $updatepack.State -ne 196607 -and $updatepack.State -ne 131074 -and $updatepack.State -ne 131075 -and $updatepack.State -ne 262143 -and $updatepack.State -ne 196612 -and $updatepack.State -ne 196609) {

            $count++
            if ($count -eq 12) {
                try {
                    Invoke-CMSiteUpdatePrerequisiteCheck -Name $updatepack.Name
                }
                catch {
                    Write-DscStatus "WARNING: Invoke-CMSiteUpdatePrerequisiteCheck retry threw: $_"
                }
            }
            if ($count -ge 30) {
                breaK
            }
            Write-DscStatus "[$($state[$updatepack.State])] Prereq check for '$($updatepack.Name)'."
            Start-Sleep 90
            $updatepack = Get-CMSiteUpdate -Fast -Name $updatepack.Name
            
        }

        if (-not $installInProgress -and $updatepack.State -eq 196607) {
            Write-DscStatus "Update State: PREREQ_FAILED"
            $retrytimes++
            Start-Sleep 100
            continue
        }

        if ($InstalltoAO) {
            try {
                Get-ChildItem "SQLSERVER:\Sql\$sqlServerName\DEFAULT\AvailabilityGroups\$sqlAOGroupName\AvailabilityDatabases" | Resume-SqlAvailabilityDatabase -ErrorAction SilentlyContinue
                Get-ChildItem "SQLSERVER:\Sql\$sqlNode2\DEFAULT\AvailabilityGroups\$sqlAOGroupName\AvailabilityDatabases" | Resume-SqlAvailabilityDatabase -ErrorAction SilentlyContinue
                Get-ChildItem "SQLSERVER:\Sql\$sqlNode1\DEFAULT\AvailabilityGroups\$sqlAOGroupName\AvailabilityDatabases" | Resume-SqlAvailabilityDatabase -ErrorAction SilentlyContinue
            }
            catch {}
        }
        # trigger setup after the prerequisites check
        if (-not $installInProgress) {
            Write-DscStatus "Calling Install-CMSiteUpdate -Name $updatepack.Name -SkipPrerequisiteCheck -Force"
            try {
                Install-CMSiteUpdate -Name $updatepack.Name -SkipPrerequisiteCheck -Force
            }
            catch {
                # Check if the update started installing despite the error
                $updatepack = Get-CMSiteUpdate -Fast -Name $updatepack.Name
                if ($updatepack.State -ge 196609 -and $updatepack.State -le 196629) {
                    Write-DscStatus "Install-CMSiteUpdate threw but update is now installing (state $($updatepack.State)). Monitoring."
                }
                else {
                    Write-DscStatus "WARNING: Install-CMSiteUpdate threw: $_"
                    $retrytimes++
                    Start-Sleep 60
                    continue
                }
            }
        }
        # Bounded, self-healing monitor loop. The OLD loop was UNBOUNDED and only
        # exited on PREREQ_ERROR / INSTALL_FAILED / INSTALL_SUCCESS -- so a wedged
        # update on a TOP-LEVEL site (a CAS / standalone primary has NO parent) spun
        # forever. Two live wedges seen on CT1-CS1SITE applying 2309: (a) a
        # same-version update parking at INSTALL_WAITING_PARENT (196611) forever, and
        # (b) a genuine 9106->9122 update sitting at INSTALL_IN_PROGRESS (196609) for
        # 120 min while cmupdate.log idle-polled ("Waiting for changes ... 600s").
        # Add: an overall deadline, a shared stuck-state self-heal for 196611 AND a
        # prolonged 196609 (already-at-target => accept as done; else a one-shot
        # SMS_EXECUTIVE bounce so cmupdate/hman re-evaluate), a last-chance
        # build-based fast-accept at the deadline, and cmupdate/hman/dmpdownloader
        # log tails on give-up.
        $monitorStart = Get-Date
        $monitorDeadlineMin = 120
        $smsExecSelfHealed = $false
        $lastMonitorState = $null
        $stateUnchangedSince = Get-Date
        # False once a state refresh has failed: $updatepack is then a frozen snapshot, so
        # "State unchanged" means "not read", which is not evidence of a wedge.
        $stateReadOk = $true
        while ($updatepack.State -ne 196607 -and $updatepack.State -ne 262143 -and $updatepack.State -ne 196612) {
            if ($updatepack.Flag -eq 1) {
                Write-DscStatus "Update State: PREREQ_ONLY"
                try {
                    Install-CMSiteUpdate -Name $updatepack.Name -SkipPrerequisiteCheck -Force
                }
                catch {
                    Write-DscStatus "WARNING: Install-CMSiteUpdate (PREREQ_ONLY) threw: $_"
                }
            }    
            #if ($updatepack.State -eq 131074 -and $updatepack.Flag -eq 1) {
            # PREREQ_SUCCESS and Flag = 1 means the update is in prereq only mode.
            #    Install-CMSiteUpdate -Name $updatepack.Name -SkipPrerequisiteCheck -Force
            #}

            $elapsedMin = ((Get-Date) - $monitorStart).TotalMinutes

            # Track how long we've sat on the SAME state. A healthy install walks
            # THROUGH the detailed sub-states (196620-196629); a wedge sits on one
            # state -- typically 196609 INSTALL_IN_PROGRESS or 196611
            # INSTALL_WAITING_PARENT -- with cmupdate.log idle ("Waiting for changes
            # ... updates will be polled in 600 seconds").
            if ($updatepack.State -ne $lastMonitorState) {
                $lastMonitorState = $updatepack.State
                $stateUnchangedSince = Get-Date
            }
            $stateStuckMin = ((Get-Date) - $stateUnchangedSince).TotalMinutes

            # A top-level site (a CAS / standalone primary has NO parent) can sit
            # indefinitely once cmupdate goes idle -- both at INSTALL_WAITING_PARENT
            # (196611, waiting on a parent that doesn't exist) and at a wedged
            # INSTALL_IN_PROGRESS (196609, observed live on CT1-CS1SITE applying
            # 2309: State stuck at 196609 for 120 min while cmupdate.log idle-polled).
            # For either: (1) if the site's ACTUAL BuildNumber already reached the
            # target build, the update effectively applied -- accept as done (the
            # package State just never flipped to INSTALL_SUCCESS); otherwise
            # (2) bounce SMS_EXECUTIVE once so CONFIGURATION_MANAGER_UPDATE / hman
            # re-evaluate the cmupdate.box trigger. WAITING_PARENT is anomalous
            # immediately (threshold 8m); IN_PROGRESS is a normal *active* state, so
            # only treat it as wedged after a long stall on the SAME state (45m) to
            # avoid disrupting a legitimate long-running install.
            $stuckState = ($updatepack.State -eq 196611) -or ($updatepack.State -eq 196609)
            $stuckThreshold = if ($updatepack.State -eq 196611) { 8 } else { 45 }
            if ($stuckState -and $stateReadOk -and $stateStuckMin -ge $stuckThreshold) {
                $isTopLevel = $false
                $curBuild = 0
                try {
                    $selfSite = Get-CMSite | Where-Object { $_.SiteCode -eq $sitecode }
                    if ($selfSite -and [string]::IsNullOrEmpty("$($selfSite.ReportingSiteCode)")) { $isTopLevel = $true }
                    [int]::TryParse("$($selfSite.BuildNumber)", [ref]$curBuild) | Out-Null
                }
                catch {}

                if ($isTopLevel) {
                    if ($targetBuild -and $curBuild -ge $targetBuild) {
                        Write-DscStatus "'$($updatepack.Name)' stuck at $($state[$updatepack.State]) on top-level site $sitecode for $([int]$stateStuckMin)m, but site is already at build $curBuild (>= $targetBuild). Treating as already-updated and continuing."
                        $updateCompleted = $true
                        break
                    }
                    if (-not $smsExecSelfHealed) {
                        Write-DscStatus "'$($updatepack.Name)' stuck at $($state[$updatepack.State]) on top-level site $sitecode for $([int]$stateStuckMin)m. Restarting SMS_EXECUTIVE once to force CONFIGURATION_MANAGER_UPDATE to re-evaluate. See cmupdate.log/hman.log."
                        Restart-Service -DisplayName "SMS_Executive" -ErrorAction SilentlyContinue
                        $smsExecSelfHealed = $true
                        Start-Sleep -Seconds 120
                    }
                }
            }

            # Overall deadline: scrape cmupdate/hman/dmpdownloader tails and fail with
            # an actionable message instead of spinning forever.
            if ($elapsedMin -ge $monitorDeadlineMin) {
                $diag = ""
                try {
                    $cmInstallDir = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\SMS\Setup' -Name 'Installation Directory' -ErrorAction SilentlyContinue).'Installation Directory'
                    if ($cmInstallDir) {
                        # cmupdate.log is the decisive one -- tail it deeper. The 2303->2309
                        # in-console update hangs mid-install in a KNOWN product bug
                        # (ADO #26532278 / #17508537): cmupdate's DCOM step wedges when the
                        # HKLM\SOFTWARE\Microsoft\Ole MachineAccessRestriction /
                        # MachineLaunchRestriction values are absent, leaving the package at
                        # INSTALL_IN_PROGRESS while the monitor thread idle-polls cmupdate.box.
                        $logTails = @{ 'cmupdate.log' = 60; 'hman.log' = 8; 'dmpdownloader.log' = 8 }
                        foreach ($lg in $logTails.Keys) {
                            $lp = Join-Path $cmInstallDir "Logs\$lg"
                            if (Test-Path $lp) {
                                $tail = (Get-Content -Path $lp -Tail $logTails[$lg] -ErrorAction SilentlyContinue) -join "`n"
                                if ($tail) { $diag += "`n--- $lg (tail) ---`n$tail" }
                            }
                        }
                    }
                }
                catch {}

                # Read-only probe of the DCOM/OLE machine restriction values behind the
                # known 2303->2309 stuck-upgrade bug (ADO #26532278). If either value is
                # missing, surface it -- that is the prime suspect for a wedged
                # INSTALL_IN_PROGRESS on this hop (fixed in later builds; the RTM 2309
                # in-console update still hits it).
                try {
                    $oleProps = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Ole' -ErrorAction SilentlyContinue
                    $haveAccess = $oleProps -and $null -ne $oleProps.MachineAccessRestriction
                    $haveLaunch = $oleProps -and $null -ne $oleProps.MachineLaunchRestriction
                    if (-not $haveAccess -or -not $haveLaunch) {
                        $diag += "`n--- DCOM/OLE restriction check ---`nMachineAccessRestriction present: $haveAccess; MachineLaunchRestriction present: $haveLaunch. MISSING value(s) match ADO #26532278 (2303->2309 upgrade hangs when these HKLM\SOFTWARE\Microsoft\Ole values are absent). Workaround: set default DCOM COM Security limits (dcomcnfg -> My Computer -> COM Security -> Edit Limits) to populate them, then reboot + rerun."
                    }
                    else {
                        $diag += "`n--- DCOM/OLE restriction check ---`nMachineAccessRestriction + MachineLaunchRestriction both present (not the ADO #26532278 missing-value signature)."
                    }
                }
                catch {}
                # Last-chance fast-accept: if the site's actual BuildNumber reached
                # the target build, the update applied even though the package State
                # never flipped to INSTALL_SUCCESS -- accept it rather than failing.
                $finalBuild = 0
                try {
                    $selfSiteF = Get-CMSite | Where-Object { $_.SiteCode -eq $sitecode }
                    [int]::TryParse("$($selfSiteF.BuildNumber)", [ref]$finalBuild) | Out-Null
                }
                catch {}
                if ($targetBuild -and $finalBuild -ge $targetBuild) {
                    Write-DscStatus "Update '$($updatepack.Name)' did not reach INSTALL_SUCCESS within $monitorDeadlineMin min (last state: $($state[$updatepack.State]) [$($updatepack.State)]), but site $sitecode is at build $finalBuild (>= $targetBuild). Treating as already-updated.$diag"
                    $updateCompleted = $true
                    break
                }
                Write-DscStatus "Update '$($updatepack.Name)' did not complete within $monitorDeadlineMin min (last state: $($state[$updatepack.State]) [$($updatepack.State)]). cmupdate.log went idle without reaching INSTALL_SUCCESS. See cmupdate.log/hman.log.$diag"
                $upgradingfailed = $true
                $updateCompleted = $true
                break
            }

            Write-DscStatus "Updating to '$($updatepack.Name)'. Current State: $($state[$updatepack.State]) ($([int]$elapsedMin)m/$monitorDeadlineMin`m)"
            Start-Sleep -Seconds 60
            # Cleared first: a swallowed failure here used to leave the PREVIOUS poll's rows
            # in $instance, so a dead query kept logging a stale timestamp as current progress.
            $instance = $null
            try {
                $instance = Get-CimInstance -Class SMS_CM_UpdatePackDetailedMonitoring -Namespace root/SMS/site_$sitecode -Filter "PackageGuid='$($updatepack.PackageGuid)'" | Where-Object { $_.Progress -and $_.Progress -lt 100 }
            }
            catch {
                Write-DscStatus "Detailed update progress unavailable this poll: $_" -NoLog
            }
            if ($instance) {
                Write-DscStatus "$($instance[0].MessageTime.ToShortDateString()) $($instance[0].MessageTime.ToLongTimeString()) $($instance[0].Description)" -NoLog
            }
            start-sleep -seconds 60

            try {
                $updatepack = Get-CMSiteUpdate -Fast -Name $updatepack.Name
                $stateReadOk = $true
            }
            catch {
                $stateReadOk = $false
                Write-DscStatus "WARNING: could not refresh update state for '$($updatepack.Name)': $_. Every State value reported below is the last SUCCESSFUL read, not a current one."
            }
        }

        if ($updatepack.State -eq 196612) {
            Write-DscStatus "'$($updatepack.Name)' update completed. Current State: $($state[$updatepack.State])"

            # we need waiting the copying files finished if there is only one site
            $toplevelsite = Get-CMSite | Where-Object { $_.ReportingSiteCode -eq "" }
            if ((Get-CMSite).count -eq 1) {

                Write-DscStatus "'$($updatepack.Name)' update completed. Current State: $($state[$updatepack.State]). Waiting for file copy to finish."

                $path = Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Microsoft\SMS\Setup' -Name 'Installation Directory'
                $fileversion = (Get-Item ($path + '\cd.latest\SMSSETUP\BIN\X64\setup.exe')).VersionInfo.FileVersion.split('.')[2]

                while ($fileversion -ne $toplevelsite.BuildNumber) {
                    Start-Sleep 60
                    $fileversion = (Get-Item ($path + '\cd.latest\SMSSETUP\BIN\X64\setup.exe')).VersionInfo.FileVersion.split('.')[2]
                }

                # Wait for copying files finished
                Start-Sleep 120
                $updateCompleted = $true
            }
        }

        if ($updatepack.state -eq 199612 ) {
            $updateCompleted = $true
            break
        }

        if ($updatepack.State -eq 196607 -or $updatepack.State -eq 262143 ) {
            if ($retrytimes -le 3) {
                $retrytimes++
                Start-Sleep 300
                continue
            }
        }
    }

    # Update Action file
    if ($downloadretrycount -ge 2) {
        Write-DscStatus "Failed to download '$($updatepack.Name)'"
        $Configuration.UpgradeSCCM.Status = 'Error'
    }

    # Update Action file
    if ($upgradingfailed -eq $true) {
        Write-DscStatus "Upgrade to '$($updatepack.Name)' failed."

        if ($($updatepack.Name).ToLower().Contains("hotfix")) {
            Write-DscStatus "'$($updatepack.Name)' is a hotfix, skip it and continue...."
            $Configuration.UpgradeSCCM.Status = 'Completed'
        }
        else {
            $Configuration.UpgradeSCCM.Status = 'Error'
        }
    }
    else {
        $Configuration.UpgradeSCCM.Status = 'Completed'
    }
}
else {

    # Write action completed, PS can start when UpgradeSCCM.EndTime is not empty
    $Configuration.UpgradeSCCM.Status = 'Completed'
    $Configuration.UpgradeSCCM.StartTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
    $Configuration.UpgradeSCCM.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
    Write-ScriptWorkFlowData -Configuration $Configuration -ConfigurationFile $ConfigurationFile
}

if ($installAction -eq "InstallPrimarySite") {

    # We're done, Update Actions file
    $Configuration.UpgradeSCCM.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
    Write-ScriptWorkFlowData -Configuration $Configuration -ConfigurationFile $ConfigurationFile

}
else {

    # Write action completed, PS can start when UpgradeSCCM.EndTime is not empty
    $Configuration.UpgradeSCCM.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
    Write-ScriptWorkFlowData -Configuration $Configuration -ConfigurationFile $ConfigurationFile

    if ($PSVMs) {

        #Set each Primary to Started
        foreach ($PSVM in $PSVMs) {

            # Set Delegation for CMPivot
            try {
                if ($SQLVM) {
                    if ($SQLVM.SqlServiceAccount) {
                        if ($SQLVM.SqlServiceAccount -ne "LocalSystem") {
                            $SQLServiceAccountCAS = Get-ADUser -Identity $SQLVM.SqlServiceAccount -Properties PrincipalsAllowedToDelegateToAccount
                        }
                        else {
                            $SQLServiceAccountCAS = Get-ADComputer -Identity $SQLVM.vmName -Properties PrincipalsAllowedToDelegateToAccount
                        }
                    }
                    else {
                        $SQLServiceAccountCAS = Get-ADComputer -Identity $SQLVM.vmName -Properties PrincipalsAllowedToDelegateToAccount
                    }
                }
                else {
                    $SQLServiceAccountCAS = Get-ADComputer -Identity $ThisVM.vmName -Properties PrincipalsAllowedToDelegateToAccount

                }

                $user = $false
                if ($PSVM.remoteSQLVM) {
                    $PriSQLVM = $deployConfig.virtualMachines | Where-Object { $_.vmName -eq $($PSVM.remoteSQLVM) }
                    if ($PriSQLVM.SqlServiceAccount) {
                        if ($PriSQLVM.SqlServiceAccount -ne "LocalSystem") {
                            $SQLServiceAccountPRI = Get-ADUser -Identity $PriSQLVM.SqlServiceAccount -Properties PrincipalsAllowedToDelegateToAccount
                            $user = $true
                        }
                        else {
                            $SQLServiceAccountPRI = Get-ADComputer -Identity $PriSQLVM.vmName -Properties PrincipalsAllowedToDelegateToAccount
                        }
                    }
                    else {
                        $SQLServiceAccountPRI = Get-ADComputer -Identity $PriSQLVM.vmName -Properties PrincipalsAllowedToDelegateToAccount
                    }
                }
                else {
                    $SQLServiceAccountPRI = Get-ADComputer -Identity $PSVM.vmName -Properties PrincipalsAllowedToDelegateToAccount
                }

                if ($user) {
                    Set-ADUser -Identity $SQLServiceAccountPRI -PrincipalsAllowedToDelegateToAccount $SQLServiceAccountCAS
                }
                else {
                    Set-ADComputer -Identity $SQLServiceAccountPRI -PrincipalsAllowedToDelegateToAccount $SQLServiceAccountCAS
                }
            }
            catch {
                Write-DscStatus "Delegation failed $_"
                start-sleep -seconds 60
            }
            $propName = "PSReadyToUse" + $PSVM.VmName
            if (-not $Configuration.$propName) {
                $PSReadytoUse = @{
                    Status    = 'NotStart'
                    StartTime = ''
                    EndTime   = ''
                }
                $Configuration | Add-Member -MemberType NoteProperty -Name  $propName  -Value  $PSReadytoUse -Force

            }
            # Only mark Running if not already Completed
            if ($Configuration.$propName.Status -ne 'Completed') {
                $Configuration.$propName.Status = 'Running'
                $Configuration.$propName.StartTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
            }
            Write-ScriptWorkFlowData -Configuration $Configuration -ConfigurationFile $ConfigurationFile
        }

        # Build wait list excluding already-completed primaries
        $waitList = @()
        foreach ($PSVM in $PSVMs) {
            $propName = "PSReadyToUse" + $PSVM.VmName
            if ($Configuration.$propName.Status -eq 'Completed') {
                Write-DscStatus "Replication link for $($PSVM.VmName) already verified. Skipping."
                continue
            }
            $waitList += $PSVM.vmName
        }

        if ($waitList.Count -eq 0) {
            Write-DscStatus "All replication links already active. Skipping wait."
        }
        else {
            #Wait for primaries that still need verification
            foreach ($PSVM in $PSVMs) {
                if ($waitList -notcontains $PSVM.vmName) { continue }
                $PSSiteCode = $PSVM.siteCode
                $PSSystemServer = Get-CMSiteSystemServer -SiteCode $PSSiteCode
                $psWaitStart = Get-Date
                Write-DscStatus "Waiting for Primary site $PSSiteCode ($($PSVM.vmName)) installation to finish"
                while (!$PSSystemServer) {
                    # Elapsed goes in the TEXT: the host only records status CHANGES, and this
                    # poll is also the only guest-log evidence that the wait is still alive.
                    $psWaitMin = [int]((Get-Date) - $psWaitStart).TotalMinutes
                    Write-DscStatus "Waiting for Primary site $PSSiteCode ($($PSVM.vmName)) to show up via Get-CMSiteSystemServer (${psWaitMin}m elapsed)" -RetrySeconds 30
                    Start-Sleep -Seconds 30
                    $PSSystemServer = Get-CMSiteSystemServer -SiteCode $PSSiteCode
                }
                Write-DscStatus "Primary site $PSSiteCode ($($PSVM.vmName)) is visible via Get-CMSiteSystemServer ($([int]((Get-Date) - $psWaitStart).TotalMinutes)m elapsed)."
            }

            Write-DscStatus "Primary is installed. Waiting for replication link to be 'Active'"
        }

        # --- DRS stale-status self-heal helpers (force-send the primary's global changes) ---
        # The wedge: a child primary finishes init and flips its OWN ServerData.SiteStatus to
        # ReplicationActive(125), but the CAS reads the primary's status from its own replicated copy
        # of ServerData, which can lag ~50 min. While stale, the CAS logs "Publisher not active" and the
        # link sits NotStarted - and the built-in reinit below only fires on Failed/Degraded/Error, so it
        # never triggers. spDRSSendChangesForGroup run on the PRIMARY flushes its pending global changes
        # (including that status row) up to the CAS - exactly what the DRS message builder calls internally
        # (guarded by context_info), idempotent, and a no-op when nothing is pending. Proven on cstest8 to
        # collapse the ~50-min dead-wait to ~20s. Requires the wait-loop account to have rights on the
        # primary's SQL; on any failure we log and fall back to the existing wait (no worse than today).
        function Get-PrimarySqlDataSourceForResync {
            param($PrimaryVM, $DeployCfg, $DomainFqdn)
            return Get-VmSqlConnectionTarget -SiteVm $PrimaryVM -DeployConfig $DeployCfg -DomainFullName $DomainFqdn
        }
        function Invoke-DrsForceSendOnPrimary {
            param($PrimaryVM, $PrimarySiteCode, $DeployCfg, $DomainFqdn)
            $r = [pscustomobject]@{ DataSource = $null; Database = $null; Groups = 0; Sent = 0; Failed = 0; Error = $null; SelfStatus = $null; Skipped = $false }
            try {
                $ds = Get-PrimarySqlDataSourceForResync -PrimaryVM $PrimaryVM -DeployCfg $DeployCfg -DomainFqdn $DomainFqdn
                $db = "CM_$PrimarySiteCode"
                $r.DataSource = $ds
                $r.Database = $db
                $cs = "Data Source=$ds;Initial Catalog=$db;Integrated Security=True;Connect Timeout=15;Encrypt=False;TrustServerCertificate=True"
                $conn = New-Object System.Data.SqlClient.SqlConnection $cs
                $conn.Open()
                try {
                    # Self-active precheck: the force-send only does real work when the primary has already
                    # flipped its OWN ServerData.SiteStatus to ReplicationActive(125) but the CAS hasn't yet
                    # observed it (the stale-status wedge). On fabrikam the gate could fire while the primary
                    # was still in ReplicationMaintenance(120) / "Site is NOT active" - at which point there is
                    # no status row to flush and the sproc is a pure no-op. Read the primary's own status row
                    # first and only force-send when it is genuinely self-active.
                    $statusCmd = $conn.CreateCommand()
                    $statusCmd.CommandText = "SELECT SiteStatus FROM ServerData WHERE SiteCode = @sc"
                    $statusCmd.CommandTimeout = 30
                    [void]$statusCmd.Parameters.AddWithValue("@sc", $PrimarySiteCode)
                    $statusVal = $statusCmd.ExecuteScalar()
                    if ($null -ne $statusVal -and $statusVal -isnot [System.DBNull]) { $r.SelfStatus = [int]$statusVal }
                    if ($r.SelfStatus -ne 125) {
                        # Not self-active yet (e.g. 120 ReplicationMaintenance / 115 ReplicationInitializing).
                        # Nothing to flush - skip the send so we don't fire prematurely.
                        $r.Skipped = $true
                        return $r
                    }
                    $listCmd = $conn.CreateCommand()
                    $listCmd.CommandText = "SELECT ReplicationGroup FROM ReplicationData WHERE ReplicationPattern = 'global' ORDER BY ReplicationGroup"
                    $listCmd.CommandTimeout = 30
                    $groups = @()
                    $rdr = $listCmd.ExecuteReader()
                    while ($rdr.Read()) { $groups += [string]$rdr['ReplicationGroup'] }
                    $rdr.Close()
                    $r.Groups = $groups.Count
                    foreach ($grp in $groups) {
                        try {
                            $execCmd = $conn.CreateCommand()
                            $execCmd.CommandText = "EXEC dbo.spDRSSendChangesForGroup @ReplicationGroup = @rg"
                            $execCmd.CommandTimeout = 120
                            [void]$execCmd.Parameters.AddWithValue("@rg", $grp)
                            [void]$execCmd.ExecuteNonQuery()
                            $r.Sent++
                        }
                        catch { $r.Failed++ }
                    }
                }
                finally { $conn.Close() }
            }
            catch { $r.Error = $_.Exception.Message }
            return $r
        }
        # --- DRS ground-truth health check (trust SQL data, NOT the lagging monitoring summary) ---
        # Get-CMDatabaseReplicationStatus reads the RCM link-summary view ("Summarizing all replication links
        # for monitoring UI"), which is recomputed lazily and can sit at Failed/NotStarted for many minutes
        # AFTER replication has actually recovered. The authoritative truth lives in the CAS's own site DB:
        #   * ServerData.SiteStatus = ReplicationActive for BOTH the CAS site and this child primary, AND
        #   * no DRS_MessageActivity_Send row for the primary has LastSendResult < 0 (a real send error).
        # ReplicationActive is 125 on a child primary; the CAS reports its OWN status as 225 (the top-level /
        # central-administration site uses the 200-series), though some hierarchies show the CAS at 125 too -
        # so we treat BOTH 125 and 225 as active and don't assume which side reports which. When this holds the
        # link is functionally Active regardless of what the summary still says. Proven on fabrikam (2026-06-22):
        # summary stuck Link=Failed for 45m while ServerData was active on both sides and every send result was
        # >= 0. Runs against the CAS's own CM_<CAS> over the already-resolved CAS SQL data source; on any error
        # it returns Healthy=$false so the loop falls back to the normal wait.
        $drsActiveStatuses = @(125, 225)  # ReplicationActive: 125 (child primary), 225 (CAS / top-level)
        function Test-DrsLinkHealthyViaSql {
            param($CasSqlDataSource, $CasDbName, $CasSiteCode, $PriSiteCode, $ActiveStatuses)
            $h = [pscustomobject]@{ Healthy = $false; CasStatus = $null; PriStatus = $null; NegativeSends = $null; Error = $null }
            try {
                $cs = "Data Source=$CasSqlDataSource;Initial Catalog=$CasDbName;Integrated Security=True;Connect Timeout=15;Encrypt=False;TrustServerCertificate=True"
                $conn = New-Object System.Data.SqlClient.SqlConnection $cs
                $conn.Open()
                try {
                    $sdCmd = $conn.CreateCommand()
                    $sdCmd.CommandText = "SELECT SiteCode, SiteStatus FROM ServerData WHERE SiteCode IN (@cas, @pri)"
                    $sdCmd.CommandTimeout = 30
                    [void]$sdCmd.Parameters.AddWithValue("@cas", $CasSiteCode)
                    [void]$sdCmd.Parameters.AddWithValue("@pri", $PriSiteCode)
                    $rdr = $sdCmd.ExecuteReader()
                    while ($rdr.Read()) {
                        $sc = [string]$rdr['SiteCode']
                        $st = [int]$rdr['SiteStatus']
                        if ($sc -eq $CasSiteCode) { $h.CasStatus = $st }
                        elseif ($sc -eq $PriSiteCode) { $h.PriStatus = $st }
                    }
                    $rdr.Close()
                    $negCmd = $conn.CreateCommand()
                    $negCmd.CommandText = "SELECT COUNT(*) FROM DRS_MessageActivity_Send WHERE SiteCode = @pri AND LastSendResult < 0"
                    $negCmd.CommandTimeout = 30
                    [void]$negCmd.Parameters.AddWithValue("@pri", $PriSiteCode)
                    $h.NegativeSends = [int]$negCmd.ExecuteScalar()
                    if (($h.CasStatus -in $ActiveStatuses) -and ($h.PriStatus -in $ActiveStatuses) -and $h.NegativeSends -eq 0) {
                        $h.Healthy = $true
                    }
                }
                finally { $conn.Close() }
            }
            catch { $h.Error = $_.Exception.Message }
            return $h
        }

        # Replication wait with timeout, failure detection, and reinit
        $drsStartTime = Get-Date
        $drsTimeoutSec = 120 * 60  # 2 hours
        # Get-CMDatabaseReplicationStatus LinkStatus / GlobalState / SiteState enum. Authoritative source:
        # AdminConsole SMS_ReplicationLinkSummary-LinkStatus.resx (the SAME table backs all four columns):
        #   0=Deleted, 1=Tombstoned, 2=Active, 3=Interim, 4=Initializing, 5=NotStarted(being configured),
        #   6=Error, 7=Unknown, 8=Degraded, 9=Failed, 99=N/A
        # Only 6/8/9 are genuine failures the InitializeData reinit can recover; 3/4/5 are healthy in-progress
        # states (4=Initializing was previously mislabeled "Failed" by $stateMap, which is what made a healthy
        # link print as "Link=Failed" while the gate correctly treated it as not-failed).
        $failedStates = @(6, 8, 9)  # Error, Degraded, Failed -> reinit territory
        $failedSinceTime = @{}     # per-primary tracking
        $reinitAttempted = @{}
        $reinitCooldownMin = 10
        $sleepSeconds = 30

        # DRS stale-status force-send self-heal (tunables + per-primary tracking)
        $forceSendThresholdMin = 3      # link stuck at 100% init / not-active / not-failed this long -> force-send
        $forceSendMaxAttempts = 2       # cap force-send attempts per primary
        $forceSendCooldownMin = 5       # minimum gap between attempts
        $forceSendStuckSince = @{}      # when the non-failed stuck window started, per primary
        $forceSendCount = @{}           # attempts made, per primary
        $forceSendLastAttempt = @{}     # timestamp of last attempt, per primary

        # Display labels for the four replication state columns - values match the authoritative
        # SMS_ReplicationLinkSummary-LinkStatus.resx enum above (do NOT diverge from it).
        $stateMap = @{ 0 = "Deleted"; 1 = "Tombstoned"; 2 = "Active"; 3 = "Interim"; 4 = "Initializing"; 5 = "NotStarted"; 6 = "Error"; 7 = "Unknown"; 8 = "Degraded"; 9 = "Failed"; 99 = "N/A" }

        # CAS's own site DB data source (for the SQL ground-truth health check below). Mirrors the CAS SQL
        # resolution used elsewhere in this script (honors named instance / non-default or SQLAO port).
        $casSqlDataSource = $sqlServerName
        if ($sqlInstanceName -and $sqlInstanceName.ToUpper() -ne 'MSSQLSERVER') { $casSqlDataSource = "$sqlServerName\$sqlInstanceName" }
        if ($sqlPort -and $sqlPort -ne 1433) { $casSqlDataSource = "$sqlServerName,$sqlPort" }
        $casDbName = "CM_$SiteCode"

        while ($waitList.Count -gt 0) {
            foreach ($PSVM in $PSVMs) {
                if ($waitList -notcontains $PSVM.VmName) {
                    continue
                }
                $PSSiteCode = $PSVM.siteCode
                $drsElapsed = [int]((Get-Date) - $drsStartTime).TotalSeconds
                $drsElapsedMin = [int]($drsElapsed / 60)

                if ($drsElapsed -ge $drsTimeoutSec) {
                    Write-DscStatus "DRS replication wait timed out after ${drsElapsedMin}m. Proceeding anyway." -MachineName $PSVM.VmName
                    $waitList = @($waitList | Where-Object { $_ -ne $PSVM.vmName })
                    $propName = "PSReadyToUse" + $PSVM.VmName
                    $Configuration.$propName.Status = 'Completed'
                    $Configuration.$propName.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
                    Write-ScriptWorkFlowData -Configuration $Configuration -ConfigurationFile $ConfigurationFile
                    continue
                }

                # Wait for replication ready
                $replicationStatus = Get-CMDatabaseReplicationStatus -Site2 $PSSiteCode

                if ( $replicationStatus.LinkStatus -ne 2 -or $replicationStatus.Site1ToSite2GlobalState -ne 2 -or $replicationStatus.Site2ToSite1GlobalState -ne 2 -or $replicationStatus.Site2ToSite1SiteState -ne 2 ) {
                    $linkName = $stateMap[[int]$replicationStatus.LinkStatus]; if (-not $linkName) { $linkName = "$($replicationStatus.LinkStatus)" }
                    $g12Name = $stateMap[[int]$replicationStatus.Site1ToSite2GlobalState]; if (-not $g12Name) { $g12Name = "$($replicationStatus.Site1ToSite2GlobalState)" }
                    $g21Name = $stateMap[[int]$replicationStatus.Site2ToSite1GlobalState]; if (-not $g21Name) { $g21Name = "$($replicationStatus.Site2ToSite1GlobalState)" }
                    $s21Name = $stateMap[[int]$replicationStatus.Site2ToSite1SiteState]; if (-not $s21Name) { $s21Name = "$($replicationStatus.Site2ToSite1SiteState)" }

                    # AUTHORITATIVE GROUND TRUTH: before trusting the (lagging) monitoring summary's Failed/
                    # NotStarted verdict - which would trigger a needless reinit and a long false wait - ask the
                    # CAS's own site DB directly. If ServerData shows BOTH the CAS and this primary at
                    # ReplicationActive (125 child / 225 CAS) and there are no failed sends for the primary, the
                    # link is functionally Active and we complete now, regardless of the stale summary.
                    $sqlHealth = Test-DrsLinkHealthyViaSql -CasSqlDataSource $casSqlDataSource -CasDbName $casDbName -CasSiteCode $SiteCode -PriSiteCode $PSSiteCode -ActiveStatuses $drsActiveStatuses
                    if ($sqlHealth.Healthy) {
                        Write-DscStatus "Replication link is Active per SQL ground truth (ServerData: $SiteCode=$($sqlHealth.CasStatus), $PSSiteCode=$($sqlHealth.PriStatus); 0 failed sends) - the monitoring summary still lags (Link=$linkName, CAS->PRI=$g12Name, PRI->CAS=$g21Name, Site=$s21Name) (${drsElapsedMin}m elapsed)" -MachineName $PSVM.VmName
                        Write-DscStatus "$SiteCode -> $PSSiteCode replication link Active (SQL ground truth)"
                        $waitList = @($waitList | Where-Object { $_ -ne $PSVM.vmName })
                        $propName = "PSReadyToUse" + $PSVM.VmName
                        $Configuration.$propName.Status = 'Completed'
                        $Configuration.$propName.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
                        Write-ScriptWorkFlowData -Configuration $Configuration -ConfigurationFile $ConfigurationFile
                        continue
                    }

                    # Detect failed/degraded link and attempt reinit
                    $linkInFailedState = [int]$replicationStatus.LinkStatus -in $failedStates -or `
                        [int]$replicationStatus.Site1ToSite2GlobalState -in $failedStates -or `
                        [int]$replicationStatus.Site2ToSite1GlobalState -in $failedStates -or `
                        [int]$replicationStatus.Site2ToSite1SiteState -in $failedStates
                    # The force-send self-heal targets the *idle* NotStarted/Unknown wedge only. If any column is
                    # actively progressing (Interim=3 / Initializing=4) the link is moving on its own, so a
                    # force-send would be premature noise - track that so the gate below can hold off.
                    $progressingStates = @(3, 4)  # Interim, Initializing
                    $linkIsProgressing = [int]$replicationStatus.LinkStatus -in $progressingStates -or `
                        [int]$replicationStatus.Site1ToSite2GlobalState -in $progressingStates -or `
                        [int]$replicationStatus.Site2ToSite1GlobalState -in $progressingStates -or `
                        [int]$replicationStatus.Site2ToSite1SiteState -in $progressingStates
                    if ($linkInFailedState) {
                        if (-not $failedSinceTime[$PSVM.VmName]) {
                            $failedSinceTime[$PSVM.VmName] = Get-Date
                            Write-DscStatus "DRS link is in a failed/degraded state (Link=$linkName, CAS->PRI=$g12Name, PRI->CAS=$g21Name, Site=$s21Name). Will attempt reinit after $reinitCooldownMin minutes." -MachineName $PSVM.VmName
                        }
                        $failedMin = [int]((Get-Date) - $failedSinceTime[$PSVM.VmName]).TotalMinutes
                        if ($failedMin -ge $reinitCooldownMin -and -not $reinitAttempted[$PSVM.VmName]) {
                            $reinitAttempted[$PSVM.VmName] = $true
                            Write-DscStatus "DRS link has been failed for $failedMin minutes. Attempting reinitialization via SMS_ReplicationGroup.InitializeData..." -MachineName $PSVM.VmName
                            try {
                                $failedGroups = Get-WmiObject -Namespace "root\sms\site_$SiteCode" -Class SMS_ReplicationGroup `
                                    -Filter "SiteCode1 = '$SiteCode' AND SiteCode2 = '$PSSiteCode' AND Status != 2"
                                if ($failedGroups) {
                                    foreach ($group in $failedGroups) {
                                        Write-DscStatus "Reinitializing replication group '$($group.ReplicationGroup)' (ID=$($group.ID))..." -MachineName $PSVM.VmName
                                        $result = ([wmiclass]"\\.\root\sms\site_$($SiteCode):SMS_ReplicationGroup").InitializeData($group.ID, $SiteCode, $PSSiteCode)
                                        Write-DscStatus "InitializeData result for group '$($group.ReplicationGroup)': ReturnValue=$($result.ReturnValue)" -MachineName $PSVM.VmName
                                    }
                                }
                                else {
                                    Write-DscStatus "No failed replication groups found via WMI. Link may recover on its own." -MachineName $PSVM.VmName
                                }
                            }
                            catch {
                                Write-DscStatus "Failed to reinitialize DRS link: $_. Will continue waiting." -MachineName $PSVM.VmName
                            }
                        }
                    }
                    else {
                        if ($failedSinceTime[$PSVM.VmName]) {
                            Write-DscStatus "DRS link is no longer in a failed state (Link=$linkName). Continuing to wait for Active." -MachineName $PSVM.VmName
                            $failedSinceTime[$PSVM.VmName] = $null
                            $reinitAttempted[$PSVM.VmName] = $false
                        }
                    }

                    if ($replicationStatus.GlobalInitPercentage -ge 100) {
                        # Init complete but link not yet active - show which states are pending
                        $pending = @()
                        if ($replicationStatus.LinkStatus -ne 2) { $pending += "Link=$linkName" }
                        if ($replicationStatus.Site1ToSite2GlobalState -ne 2) { $pending += "Global($SiteCode->$PSSiteCode)=$g12Name" }
                        if ($replicationStatus.Site2ToSite1GlobalState -ne 2) { $pending += "Global($PSSiteCode->$SiteCode)=$g21Name" }
                        if ($replicationStatus.Site2ToSite1SiteState -ne 2) { $pending += "Site($PSSiteCode->$SiteCode)=$s21Name" }
                        $pendingStr = $pending -join ", "
                        Write-DscStatus "Init 100% complete, waiting for link activation. Pending: $pendingStr (${drsElapsedMin}m elapsed)" -RetrySeconds $sleepSeconds -MachineName $PSVM.VmName

                        # DRS stale-status self-heal: 100% init done, link NOT active, NOT failed, and NOT actively
                        # progressing - i.e. genuinely idle-stuck at NotStarted(5)/Unknown(7) (the "Publisher not
                        # active" wedge the reinit path above does not cover, since reinit only fires on
                        # Failed/Degraded/Error). A link that is Interim(3)/Initializing(4) is moving on its own and
                        # is intentionally left alone. Force-send the primary's global changes to flush its
                        # ReplicationActive status up to the CAS. Gated, bounded, and fully logged.
                        if (-not $linkInFailedState -and -not $linkIsProgressing) {
                            if (-not $forceSendStuckSince[$PSVM.VmName]) { $forceSendStuckSince[$PSVM.VmName] = Get-Date }
                            $stuckMin = [int]((Get-Date) - $forceSendStuckSince[$PSVM.VmName]).TotalMinutes
                            $attemptsSoFar = [int]$forceSendCount[$PSVM.VmName]
                            $lastFs = $forceSendLastAttempt[$PSVM.VmName]
                            $cooldownOk = (-not $lastFs) -or ([int]((Get-Date) - $lastFs).TotalMinutes -ge $forceSendCooldownMin)
                            if ($stuckMin -ge $forceSendThresholdMin -and $attemptsSoFar -lt $forceSendMaxAttempts -and $cooldownOk) {
                                $forceSendCount[$PSVM.VmName] = $attemptsSoFar + 1
                                $forceSendLastAttempt[$PSVM.VmName] = Get-Date
                                Write-DscStatus "DRS stale-status self-heal: link idle-stuck ${stuckMin}m at 100% init (not-active / not-failed / not-progressing) (Pending: $pendingStr). Force-sending the primary's global changes (spDRSSendChangesForGroup) to flush its status to the CAS [attempt $($attemptsSoFar + 1)/$forceSendMaxAttempts]." -MachineName $PSVM.VmName
                                try {
                                    $fsResult = Invoke-DrsForceSendOnPrimary -PrimaryVM $PSVM -PrimarySiteCode $PSSiteCode -DeployCfg $deployConfig -DomainFqdn $DomainFullName
                                    if ($fsResult.Error) {
                                        Write-DscStatus "DRS force-send could NOT run on the primary's SQL ($($fsResult.DataSource) / $($fsResult.Database)): $($fsResult.Error). No change made; continuing the normal wait." -MachineName $PSVM.VmName
                                    }
                                    elseif ($fsResult.Skipped) {
                                        # Primary has not yet flipped its own ServerData.SiteStatus to ReplicationActive(125)
                                        # - there is nothing pending to flush, so the send would be a no-op (this is what
                                        # happened on fabrikam PS2, which was still in ReplicationMaintenance when the gate
                                        # first fired). Roll back this attempt so the real force-send window (once the primary
                                        # self-activates) still has all $forceSendMaxAttempts available.
                                        $forceSendCount[$PSVM.VmName] = $attemptsSoFar
                                        $forceSendLastAttempt[$PSVM.VmName] = $lastFs
                                        Write-DscStatus "DRS force-send skipped: primary $PSSiteCode is not self-active yet (its own ServerData.SiteStatus=$($fsResult.SelfStatus); ReplicationActive is 125). Nothing to flush - waiting for the primary to finish activating before force-sending." -MachineName $PSVM.VmName
                                    }
                                    else {
                                        Write-DscStatus "DRS force-send done on $($fsResult.DataSource) / $($fsResult.Database) (primary self-active, SiteStatus=$($fsResult.SelfStatus)): $($fsResult.Sent)/$($fsResult.Groups) global groups sent ($($fsResult.Failed) failed). Watching for the CAS to see the primary active." -MachineName $PSVM.VmName
                                    }
                                }
                                catch {
                                    Write-DscStatus "DRS force-send threw unexpectedly: $_. Continuing the normal wait (the sproc is idempotent, so no harm)." -MachineName $PSVM.VmName
                                }
                            }
                        }
                        else {
                            # Either failed (reinit owns it) or actively progressing (Interim/Initializing - the link
                            # is moving on its own). Reset the stuck timer so force-send only fires after the link has
                            # been genuinely idle (NotStarted/Unknown) for the full threshold, with no progress in between.
                            $forceSendStuckSince[$PSVM.VmName] = $null
                        }

                        # Log SQL Broker diagnostics every 5 minutes when stuck at 100% init
                        if ($drsElapsedMin -gt 0 -and $drsElapsedMin % 5 -eq 0) {
                            try {
                                $sqlQuery = @"
SELECT s.name AS [Queue], p.rows AS [Messages]
FROM sys.service_queues s
JOIN sys.partitions p ON s.object_id = p.object_id AND p.index_id = 1
WHERE s.name LIKE '%Rcm%' OR s.name LIKE '%Drs%'
ORDER BY p.rows DESC
"@
                                $sqlDs = $casSqlDataSource
                                $cs = "Data Source=$sqlDs;Initial Catalog=CM_$SiteCode;Integrated Security=True;Connect Timeout=10;Encrypt=False;TrustServerCertificate=True"
                                $conn = New-Object System.Data.SqlClient.SqlConnection $cs
                                $conn.Open()
                                try {
                                    $cmd = $conn.CreateCommand()
                                    $cmd.CommandText = $sqlQuery
                                    $reader = $cmd.ExecuteReader()
                                    $queueParts = @()
                                    while ($reader.Read()) {
                                        $queueParts += "$($reader['Queue'])=$($reader['Messages'])"
                                    }
                                    $reader.Close()
                                    if ($queueParts.Count -gt 0) {
                                        Write-DscStatus "SQL Broker queue depths: $($queueParts -join ', ')" -MachineName $PSVM.VmName
                                    }
                                }
                                finally {
                                    $conn.Close()
                                }
                            }
                            catch { }
                            # Check rcmctrl.log for errors
                            try {
                                $rcmLog = Join-Path $SMSInstallDir "Logs\rcmctrl.log"
                                if (Test-Path $rcmLog) {
                                    $lastErrors = Get-Content $rcmLog -Tail 20 | Where-Object { $_ -match 'ERROR|WARN|failed' } | Select-Object -Last 3
                                    if ($lastErrors) {
                                        foreach ($err in $lastErrors) {
                                            $errTrimmed = $err.Substring(0, [Math]::Min(200, $err.Length))
                                            Write-DscStatus "rcmctrl.log: $errTrimmed" -MachineName $PSVM.VmName
                                        }
                                    }
                                }
                            }
                            catch { }
                        }

                        Write-DscStatus "$SiteCode -> $PSSiteCode replication init done, finalizing link ($pendingStr)" -NoLog -RetrySeconds $sleepSeconds
                    }
                    else {
                        $pct = $replicationStatus.GlobalInitPercentage
                        Write-DscStatus "$SiteCode -> $PSSiteCode global data init: $pct% (${drsElapsedMin}m elapsed)" -RetrySeconds $sleepSeconds -MachineName $PSVM.VmName
                        Write-DscStatus "$SiteCode -> $PSSiteCode replication init: $pct%" -NoLog -RetrySeconds $sleepSeconds
                    }
                }
                else {
                    Write-DscStatus "Replication link is Active (${drsElapsedMin}m elapsed)" -MachineName $PSVM.VmName
                    Write-DscStatus "$SiteCode -> $PSSiteCode replication link Active"
                    $waitList = @($waitList | Where-Object { $_ -ne $PSVM.vmName })
                    $propName = "PSReadyToUse" + $PSVM.VmName
                    $Configuration.$propName.Status = 'Completed'
                    $Configuration.$propName.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
                    Write-ScriptWorkFlowData -Configuration $Configuration -ConfigurationFile $ConfigurationFile
                }
            }
            # One sleep per PASS, not per primary. With the sleep inside the foreach each pending
            # primary was only polled every (pending count) x $sleepSeconds - measured at 60s on
            # fabrikam while PS1 and PS2 both waited, halving back to 30s the moment PS1 completed.
            if ($waitList.Count -gt 0) {
                Start-Sleep -Seconds $sleepSeconds
            }
        }

        Write-DscStatus "Primary installation complete. Replication link is 'Active'."

    }
}
