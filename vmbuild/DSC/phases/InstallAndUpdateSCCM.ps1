# InstallAndUpdateSCCM.ps1
param(
    [string]$ConfigFilePath,
    [string]$LogPath
)
Write-DscStatus "Started InstallAndUpdateSCCM.ps1"
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
    if ($regPresent) {
        try {
            $wmiSite = Get-CimInstance -Namespace "root\SMS\Site_$SiteCode" -Class "SMS_Site" -ErrorAction Stop
            if ($wmiSite) {
                $siteHealthy = $true
                Write-DscStatus "InstallSCCM.Status='Completed' -- WMI confirms site $SiteCode is operational (SMS_Site present)"
            }
        }
        catch {
            Write-DscStatus "Registry present but WMI SMS_Site check failed: $($_.Exception.Message). Falling back to SQL probe..."
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

        # Decision matrix:
        #   reg=Y  db=Y             -> OK, CM is installed
        #   reg=N  db=Y             -> FAIL, partial/corrupt install needs checkpoint
        #   reg=N  db=N  sql=Y      -> safe retry, nothing committed
        #   reg=Y  db=N  sql=Y      -> safe retry, DB was dropped
        #   any    any   sql=N      -> FAIL, can't confirm state
        if ($regPresent -and $dbExists) {
            # CM is genuinely installed, nothing to do.
        }
        elseif (-not $sqlReachable) {
            Write-DscStatus "InstallSCCM.Status='Completed' but SQL is unreachable (tried: $($sqlProbeTargets -join ', ')). Cannot confirm whether [$cmDbName] exists; refusing to retry blind. Check SQL connectivity or restore the Phase 8 checkpoint." -Failure
            return
        }
        elseif ($dbExists -and -not $regPresent) {
            Write-DscStatus "InstallSCCM.Status='Completed' but registry key SMS\Identification is missing while [$cmDbName] exists on [$sqlDataSource]. This indicates a partial/corrupt install. Restore the Phase 8 checkpoint on this VM and re-run the deployment." -Failure
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


    $CMBin = "$CMDir\SMSSETUP\BIN\X64"
    $CMSetupDL = "$CMBin\Setupdl.exe"
    $CMRedist = "C:\$CM\REdist"
    $CMLog = "C:\ConfigMgrSetup.log"
    $success = 0
    $fail = 0

    Write-DscStatus "Starting Pre-Req Download using $CMSetupDL /NOUI $CMRedist"

    $maxTries = 20
    # Per-attempt timeout for setupdl.exe. Historically we called
    # Start-Process -Wait with no cap; if setupdl wedged on a single
    # CDN fetch we'd hang for hours with no progress in the DSC status
    # stream. Now we cap each attempt at $setupDlTimeoutSec, surface
    # the tail of ConfigMgrSetup.log every $setupDlPollSec while it
    # runs, and kill+retry if the cap is hit.
    $setupDlTimeoutSec = 1800   # 30 min hard cap per attempt
    $setupDlStallSec = 300      # kill early if log hasn't advanced for 5 min
    $setupDlFastKillSec = 90    # kill in 90s if log is parked on a known-bad marker
    $setupDlPollSec = 30        # status cadence while running
    $lastReportedTail = ''

    # Log lines that immediately precede a known setupdl hang. When the
    # log is parked on one of these AND stops advancing, we don't need
    # to wait the full $setupDlStallSec -- kill quickly and let the
    # retry path re-launch. Pattern is matched case-insensitively as a
    # substring of the latest log line.
    $setupDlBadMarkers = @(
        # MSODBCSQL18 download wedge (observed on CS2-CS1SITE 05/25).
        # setupdl probes for the driver, finds it missing ("Error = 2"),
        # then hangs on the Microsoft CDN fetch.
        'MSODBCSQL18'
    )

    # We require 2 success entries in a row
    while ($success -le 1) {

        #Start Setupdl.exe asynchronously so we can poll its log for
        #progress and enforce a per-attempt timeout.
        $dlProc = Start-Process -Filepath ($CMSetupDL) -ArgumentList ('/NOUI ' + $CMRedist) -PassThru
        $dlStart = Get-Date
        $lastLogAdvanceAt = Get-Date
        $dlTimedOut = $false
        $dlStalled = $false
        while (-not $dlProc.HasExited) {
            Start-Sleep -Seconds $setupDlPollSec
            $elapsedSec = [int]((Get-Date) - $dlStart).TotalSeconds
            $stalledSec = [int]((Get-Date) - $lastLogAdvanceAt).TotalSeconds

            # Tail the setup log and surface the latest activity so the
            # operator can see whether setupdl is making progress or
            # stuck on a specific file.
            $tail = $null
            try { $tail = Get-Content -Path $CMLog -Tail 1 -ErrorAction SilentlyContinue } catch { }
            if ($tail -and $tail -ne $lastReportedTail) {
                $lastReportedTail = $tail
                $lastLogAdvanceAt = Get-Date
                $stalledSec = 0
                Write-DscStatus ("Pre-Req download in progress ({0}s elapsed): {1}" -f $elapsedSec, $tail.Trim())
            }
            elseif ($tail) {
                Write-DscStatus ("Pre-Req download still running ({0}s elapsed, no new log activity for {1}s): {2}" -f $elapsedSec, $stalledSec, $tail.Trim())
            }
            else {
                Write-DscStatus ("Pre-Req download still running ({0}s elapsed; setup log not yet readable)" -f $elapsedSec)
            }

            # Early-kill: if the setup log has been completely silent for
            # $setupDlStallSec, setupdl is wedged on a single fetch (CDN
            # stall, TLS hang, etc.). Kill now rather than waiting the
            # full 30-min hard cap; the outer retry will relaunch and
            # setupdl is idempotent (only re-downloads missing files).
            # Faster-kill: if the latest log line matches a known-bad
            # wedge marker (e.g. MSODBCSQL18 download), use the shorter
            # $setupDlFastKillSec threshold so we recover in ~90s instead
            # of 5 min.
            $matchedBadMarker = $null
            if ($tail) {
                foreach ($marker in $setupDlBadMarkers) {
                    if ($tail -match [Regex]::Escape($marker)) { $matchedBadMarker = $marker; break }
                }
            }
            $effectiveStallLimit = if ($matchedBadMarker) { $setupDlFastKillSec } else { $setupDlStallSec }

            if ($stalledSec -ge $effectiveStallLimit) {
                $dlStalled = $true
                if ($matchedBadMarker) {
                    Write-DscStatus ("Pre-Req download parked on known-bad marker '{0}' for {1}s (fast-kill threshold {2}s); killing setupdl.exe (PID {3}) and retrying" -f $matchedBadMarker, $stalledSec, $effectiveStallLimit, $dlProc.Id)
                }
                else {
                    Write-DscStatus ("Pre-Req download log stalled for {0}s (threshold {1}s); killing setupdl.exe (PID {2}) and retrying" -f $stalledSec, $effectiveStallLimit, $dlProc.Id)
                }
                try { Stop-Process -Id $dlProc.Id -Force -ErrorAction SilentlyContinue } catch { }
                Get-Process -Name 'setupdl' -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $dlProc.Id } | ForEach-Object {
                    try { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue } catch { }
                }
                break
            }

            if ($elapsedSec -ge $setupDlTimeoutSec) {
                $dlTimedOut = $true
                Write-DscStatus ("Pre-Req download exceeded {0}s; killing setupdl.exe (PID {1}) and retrying" -f $setupDlTimeoutSec, $dlProc.Id)
                try { Stop-Process -Id $dlProc.Id -Force -ErrorAction SilentlyContinue } catch { }
                # Also kill any straggler setupdl/Setupdl children spawned by the bootstrap copy
                Get-Process -Name 'setupdl' -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $dlProc.Id } | ForEach-Object {
                    try { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue } catch { }
                }
                break
            }
        }

        #Just to make sure the log is flushed.
        start-sleep -seconds 5

        #Get the last line of the log.  Assumption: No other components are writing to the log at this time.
        $LogLine = Get-Content -Path $CMLog -Tail 1

        if ($dlStalled) {
            $LogLine = "STALLED: setupdl log idle for $setupDlStallSec seconds. Last log line: $LogLine"
        }
        elseif ($dlTimedOut) {
            # Treat as a failed attempt and let the retry/fail counter logic below handle it.
            $LogLine = "TIMEOUT: setupdl exceeded $setupDlTimeoutSec seconds. Last log line: $LogLine"
        }

        #Check for success indicator.
        if (-not $dlTimedOut -and -not $dlStalled -and $LogLine -and $LogLine.Contains("INFO: Setup downloader") -and $LogLine.Contains("FINISHED")) {
            $success++
            Write-DscStatus "Pre-Req downloading complete Success Count $success out of 2."
        }
        else {
            #If we didn't find it, increment fail count, and bail after 10 fails
            Clear-DnsClientCache -ErrorAction SilentlyContinue
            $success = 0
            $fail++
            if ($fail -ge 20) {
                Write-DscStatus "Pre-Req Downloading failed after $maxTries tries. see $CMLog"
                # Set Status to not 'Running' so it can run again.
                $Configuration.InstallSCCM.Status = 'Failed'
                $Configuration.InstallSCCM.StartTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
                Write-ScriptWorkFlowData -Configuration $Configuration -ConfigurationFile $ConfigurationFile
                return
            }
            Write-DscStatus "Pre-Req downloading Failed. Try $fail out of $maxTries See $CMLog for progress"
            start-sleep -Seconds 30
        }
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
                        Invoke-Command -ComputerName $dcName -ScriptBlock {
                            param($dcNames)
                            $dcNames | ForEach-Object { repadmin /syncall $_ /AdeP 2>&1 | Out-Null }
                        } -ArgumentList (,$dcShortNames) -ErrorAction SilentlyContinue
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
                        Invoke-Command -ComputerName $sqlNode1 -ScriptBlock {
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
                        } -ArgumentList $sqlServerName -ErrorAction Stop
                        $clusterBounced = $true
                        # Force replication again after the cluster re-registered
                        Invoke-Command -ComputerName $dcName -ScriptBlock {
                            param($dcNames)
                            $dcNames | ForEach-Object { repadmin /syncall $_ /AdeP 2>&1 | Out-Null }
                        } -ArgumentList (,$dcShortNames) -ErrorAction SilentlyContinue
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
                            $agIPAddr = Invoke-Command -ComputerName $sqlNode1 -ScriptBlock {
                                param($listenerName)
                                Import-Module FailoverClusters -ErrorAction SilentlyContinue
                                $ipRes = Get-ClusterResource -ErrorAction SilentlyContinue |
                                    Where-Object { $_.ResourceType -eq 'IP Address' -and $_.OwnerGroup -eq $listenerName } |
                                    Select-Object -First 1
                                if ($ipRes) {
                                    return ($ipRes | Get-ClusterParameter -Name Address -ErrorAction SilentlyContinue).Value
                                }
                            } -ArgumentList $sqlServerName -ErrorAction SilentlyContinue
                        }
                        # Fallback: resolve the short name via NetBIOS/LLMNR
                        if (-not $agIPAddr) {
                            $shortResolve = [System.Net.Dns]::GetHostAddresses($sqlServerName) |
                                Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1
                            if ($shortResolve) { $agIPAddr = $shortResolve.IPAddressToString }
                        }
                        if ($agIPAddr) {
                            Write-DscStatus "SQL pre-flight DNS: registering A record '$sqlServerName' -> $agIPAddr on DC '$dcName'"
                            Invoke-Command -ComputerName $dcName -ScriptBlock {
                                param($zone, $name, $ip)
                                # Remove any stale record first, then add fresh
                                $existing = Get-DnsServerResourceRecord -ZoneName $zone -Name $name -RRType A -ErrorAction SilentlyContinue
                                if (-not $existing) {
                                    Add-DnsServerResourceRecordA -ZoneName $zone -Name $name -IPv4Address $ip -ErrorAction Stop
                                }
                            } -ArgumentList $DomainFullName, $sqlServerName, $agIPAddr -ErrorAction Stop
                            # Force replication after registration
                            if ($allDCs.Count -gt 1) {
                                Invoke-Command -ComputerName $dcName -ScriptBlock {
                                    param($dcNames)
                                    $dcNames | ForEach-Object { repadmin /syncall $_ /AdeP 2>&1 | Out-Null }
                                } -ArgumentList (,$dcShortNames) -ErrorAction SilentlyContinue
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
                        if ($r.Conn -ne 'CONNECTED' -or $r.Health -ne 'HEALTHY' -or
                            $r.Op   -eq 'UNKNOWN'   -or $r.Op    -eq 'OFFLINE' -or
                            $r.Rec  -eq 'UNKNOWN'   -or $r.Rec   -eq 'ONLINE_IN_PROGRESS') {
                            $allHealthy = $false
                            break
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
    $installedUpdate = Get-CMSiteUpdate -Fast | Where-Object { $_.State -eq 196612 -and $_.Name -eq "Configuration Manager $targetVersion" }
    if ($installedUpdate) {
        Write-DscStatus "Update 'Configuration Manager $targetVersion' verified as installed. Skipping upgrade."
        $UpdateRequired = $false
    }
    else {
        Write-DscStatus "UpgradeSCCM marked Completed but update 'Configuration Manager $targetVersion' not found in installed state. Re-running upgrade."
        $Configuration.UpgradeSCCM.Status = 'NotStart'
        Write-ScriptWorkFlowData -Configuration $Configuration -ConfigurationFile $ConfigurationFile
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

            Write-DscStatus "Updating to '$($updatepack.Name)'. Current State: $($state[$updatepack.State])"
            Start-Sleep -Seconds 60
            try {
                $instance = Get-CimInstance -Class SMS_CM_UpdatePackDetailedMonitoring -Namespace root/SMS/site_$sitecode -Filter "PackageGuid='$($updatepack.PackageGuid)'" | Where-Object { $_.Progress -and $_.Progress -lt 100 }
            }
            catch {}
            if ($instance) {
                Write-DscStatus "$($instance[0].MessageTime.ToShortDateString()) $($instance[0].MessageTime.ToLongTimeString()) $($instance[0].Description)" -NoLog
            }
            start-sleep -seconds 60

            try {
                $updatepack = Get-CMSiteUpdate -Fast -Name $updatepack.Name
            }
            catch {}
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
                Write-DscStatus "Waiting for Primary site installation to finish"
                while (!$PSSystemServer) {
                    Write-DscStatus "Waiting for Primary site to show up via Get-CMSiteSystemServer" -NoLog -RetrySeconds 30
                    Start-Sleep -Seconds 30
                    $PSSystemServer = Get-CMSiteSystemServer -SiteCode $PSSiteCode
                }
            }

            Write-DscStatus "Primary is installed. Waiting for replication link to be 'Active'"
        }

        # Replication wait with timeout, failure detection, and reinit
        $drsStartTime = Get-Date
        $drsTimeoutSec = 120 * 60  # 2 hours
        # WMI ReplicationLinkStatus: Active=2, Initializing=4, NotStarted=5, Error=6, Unknown=7, Degraded=8, Failed=9
        $failedStates = @(6, 8, 9)  # Error, Degraded, Failed
        $failedSinceTime = @{}     # per-primary tracking
        $reinitAttempted = @{}
        $reinitCooldownMin = 10
        $sleepSeconds = 30

        # Expand stateMap to include all WMI enum values
        $stateMap = @{ 0 = "Unknown"; 1 = "Initializing"; 2 = "Active"; 3 = "Degraded"; 4 = "Failed"; 5 = "NotStarted"; 6 = "Error"; 7 = "Unknown(7)"; 8 = "Degraded(8)"; 9 = "Failed(9)" }

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

                    # Detect failed/degraded link and attempt reinit
                    $linkInFailedState = [int]$replicationStatus.LinkStatus -in $failedStates -or `
                        [int]$replicationStatus.Site1ToSite2GlobalState -in $failedStates -or `
                        [int]$replicationStatus.Site2ToSite1GlobalState -in $failedStates -or `
                        [int]$replicationStatus.Site2ToSite1SiteState -in $failedStates
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
                                $sqlDs = if ($sqlInstanceName -and $sqlInstanceName.ToUpper() -ne 'MSSQLSERVER') { "$sqlServerName\$sqlInstanceName" } else { $sqlServerName }
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
                    Start-Sleep -Seconds $sleepSeconds
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
        }

        Write-DscStatus "Primary installation complete. Replication link is 'Active'."

    }
}
