# InstallPSForHierarchy.ps1
param(
    [string]$ConfigFilePath,
    [string]$LogPath
)

# Read config json
$deployConfig = Get-Content $ConfigFilePath | ConvertFrom-Json
$DomainFullName = $deployConfig.parameters.domainName
$ThisMachineName = $deployConfig.parameters.ThisMachineName
$ThisVM = $deployConfig.virtualMachines | where-object { $_.vmName -eq $ThisMachineName }
$CSName = $ThisVM.thisParams.ParentSiteServer
# Per-VM cmOptions wins over the rehydrated global for multi-hierarchy deploys.
$cmo = if ($ThisVM.cmOptions) { $ThisVM.cmOptions } else { $deployConfig.cmOptions }
$CM = if ($cmo.version -eq "tech-preview") { "CMTP" } else { "CMCB" }

# Set Install Dir
$SMSInstallDir = "C:\Program Files\Microsoft Configuration Manager"
if ($ThisVM.cmInstallDir) {
    $SMSInstallDir = $ThisVM.cmInstallDir
}

# SQL FQDN
$installToAO = $false
$sqlAoMaxDopParameters = $null
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
        $sqlNode2Vm = $deployConfig.virtualMachines | Where-Object { $_.vmName -eq $SQLVM.OtherNode }
        $sqlAoMaxDopParameters = @{
            Node1 = $SQLVM.vmName
            Node2 = $SQLVM.OtherNode
            Node1Port = "$sqlPort"
            Node2Port = $(if ($sqlNode2Vm.sqlPort) { "$($sqlNode2Vm.sqlPort)" } else { "$sqlPort" })
        }
        $sqlServerName = $SQLVM.AlwaysOnListenerName
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

function Get-HierarchyOdbcConnectionString {
    param(
        [Parameter(Mandatory)][string]$Target,
        [bool]$MultiSubnet
    )
    $multiSubnetOption = if ($MultiSubnet) { ';MultiSubnetFailover=Yes' } else { '' }
    return "Driver={ODBC Driver 18 for SQL Server};AutoTranslate=no;Server=$Target;Database=master;Trusted_Connection=yes;Encrypt=no;TrustServerCertificate=yes$multiSubnetOption"
}

function Get-HierarchyRecoveryAction {
    param(
        [AllowEmptyString()][string]$Stage,
        [bool]$SiteReady,
        [bool]$ModulePresent
    )
    if (-not $Stage -or $Stage -eq 'Preflight') { return 'RetrySetup' }
    if ($Stage -eq 'LaunchConfirmed') {
        if ($SiteReady -and $ModulePresent) { return 'ResumePostflight' }
        return 'RequireCheckpoint'
    }
    if ($Stage -eq 'SetupCompleted') {
        if ($SiteReady) { return 'ResumePostflight' }
        return 'RequireCheckpoint'
    }
    return 'RequireCheckpoint'
}

function Stop-HierarchyInstall {
    param([Parameter(Mandatory)][string]$Message)
    Write-DscStatus $Message -Failure
    Write-ScriptWorkFlowData -Configuration $Configuration -ConfigurationFile $ConfigurationFile
}

$multiSubnetHierarchy = $installToAO -and $SQLVM.thisParams.SQLAO.MultiSubnetFailover

# Set Site Code
if ($ThisVM.siteCode) {
    $SiteCode = $ThisVM.siteCode
}

# Read Actions file
$ConfigurationFile = Join-Path -Path $LogPath -ChildPath "ScriptWorkflow.json"
$Configuration = Read-ScriptWorkflowData -ConfigurationFile $ConfigurationFile `
    -RequiredSteps @('WaitingForCASFinishedInstall', 'InstallSCCM')
$setupStagePath = Join-Path -Path $LogPath -ChildPath 'InstallPSForHierarchy.setup.stage'

if ($installToAO -and -not (Set-SqlAoLabMaxDop @sqlAoMaxDopParameters)) { return }

# Set Install action as Running
$Configuration.WaitingForCASFinishedInstall.Status = 'Running'
$Configuration.WaitingForCASFinishedInstall.StartTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
Write-ScriptWorkFlowData -Configuration $Configuration -ConfigurationFile $ConfigurationFile

# Read Actions file on CAS
$LogFolder = Split-Path $LogPath -Leaf
$CSFilePath = "\\$CSName\$LogFolder"
$CSConfigurationFile = Join-Path -Path $CSFilePath -ChildPath "ScriptWorkflow.json"
$casWorkflowFileWaitMaxMinutes = 60
$casDependencyWaitMaxMinutes = 240

function Assert-CasWorkflowStepCanContinue {
    param(
        [Parameter(Mandatory)]$CasConfiguration,
        [Parameter(Mandatory)][string]$Step
    )

    foreach ($dependency in @('InstallSCCM', 'UpgradeSCCM', $Step) | Select-Object -Unique) {
        $status = "$($CasConfiguration.$dependency.Status)"
        if ($status -in @('Error', 'Failed', 'Failure')) {
            throw "$CSName reported $dependency=$status in '$CSConfigurationFile'. Stopping the primary before dependent setup; inspect the CAS Phase 8 diagnostics."
        }
    }
}

# Wait for ScriptWorkflow.json to exist on CAS
Write-DscStatus "Waiting for $CSName to begin installation"
$casBeginStart = Get-Date
$casBeginDeadline = $casBeginStart.AddMinutes(30)
while (!(Test-Path $CSConfigurationFile)) {
    if ((Get-Date) -ge $casBeginDeadline) {
        Stop-HierarchyInstall "Timed out after 30 minutes waiting for $CSName to publish ScriptWorkflow.json. Verify the CAS VM/share and rerun Phase 8."
        return
    }
    # Elapsed goes in the TEXT: the host only records status CHANGES, so a constant
    # message is indistinguishable from a hang for the whole wait.
    $casBeginMin = [int]((Get-Date) - $casBeginStart).TotalMinutes
    if ($casBeginMin -ge $casWorkflowFileWaitMaxMinutes) {
        throw "$CSName did not publish '$CSConfigurationFile' within $casWorkflowFileWaitMaxMinutes minutes."
    }
    Write-DscStatus "Waiting for $CSName to begin installation (${casBeginMin}m elapsed)" -RetrySeconds 30
    Start-Sleep -Seconds 30
}

# Read CAS actions file, wait for install to finish
Write-DscStatus "Waiting for $CSName to finish installing ConfigMgr"
$casInstallStart = Get-Date
$CSConfiguration = Read-ScriptWorkflowData -ConfigurationFile $CSConfigurationFile `
    -RequiredSteps @('InstallSCCM', 'UpgradeSCCM')
while ($CSConfiguration.InstallSCCM.Status -ne "Completed") {
    Assert-CasWorkflowStepCanContinue -CasConfiguration $CSConfiguration -Step 'InstallSCCM'
    $casInstallMin = [int]((Get-Date) - $casInstallStart).TotalMinutes
    if ($casInstallMin -ge $casDependencyWaitMaxMinutes) {
        throw "$CSName did not finish InstallSCCM within $casDependencyWaitMaxMinutes minutes (last state: $($CSConfiguration.InstallSCCM.Status))."
    }
    $casInstallState = "$($CSConfiguration.InstallSCCM.Status)"
    Write-DscStatus "Waiting for $CSName to finish installing ConfigMgr (${casInstallMin}m elapsed, CAS InstallSCCM=$casInstallState)" -RetrySeconds 30
    Start-Sleep -Seconds 30
    $CSConfiguration = Read-ScriptWorkflowData -ConfigurationFile $CSConfigurationFile `
        -RequiredSteps @('InstallSCCM', 'UpgradeSCCM')
}
Write-DscStatus "$CSName finished installing ConfigMgr ($([int]((Get-Date) - $casInstallStart).TotalMinutes)m elapsed)."

# Read CAS actions file, wait for upgrade to finish
Write-DscStatus "Checking if $CSName is upgrading ConfigMgr"
$casUpgradeStart = Get-Date
$CSConfiguration = Read-ScriptWorkflowData -ConfigurationFile $CSConfigurationFile `
    -RequiredSteps @('UpgradeSCCM')
while ($CSConfiguration.UpgradeSCCM.Status -ne "Completed") {
    Assert-CasWorkflowStepCanContinue -CasConfiguration $CSConfiguration -Step 'UpgradeSCCM'
    $casUpgradeMin = [int]((Get-Date) - $casUpgradeStart).TotalMinutes
    if ($casUpgradeMin -ge $casDependencyWaitMaxMinutes) {
        throw "$CSName did not finish UpgradeSCCM within $casDependencyWaitMaxMinutes minutes (last state: $($CSConfiguration.UpgradeSCCM.Status))."
    }
    $casUpgradeState = "$($CSConfiguration.UpgradeSCCM.Status)"
    Write-DscStatus "Waiting for $CSName to finish upgrading ConfigMgr (${casUpgradeMin}m elapsed, CAS UpgradeSCCM=$casUpgradeState)" -RetrySeconds 30
    Start-Sleep -Seconds 30
    $CSConfiguration = Read-ScriptWorkflowData -ConfigurationFile $CSConfigurationFile `
        -RequiredSteps @('UpgradeSCCM')
}
Write-DscStatus "$CSName finished upgrading ConfigMgr ($([int]((Get-Date) - $casUpgradeStart).TotalMinutes)m elapsed)."

# Write actions file, wait finished
$Configuration.WaitingForCASFinishedInstall.Status = 'Completed'
$Configuration.WaitingForCASFinishedInstall.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
Write-ScriptWorkFlowData -Configuration $Configuration -ConfigurationFile $ConfigurationFile

$resumeHierarchyPostflight = $false
if ($Configuration.InstallSCCM.Status -eq 'Running') {
    $setupStage = if (Test-Path -LiteralPath $setupStagePath) {
        [string](Get-Content -LiteralPath $setupStagePath -Raw -ErrorAction SilentlyContinue).Trim()
    }
    else { '' }
    $installedSiteCode = Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Microsoft\SMS\Identification' -Name 'Site Code' -ErrorAction SilentlyContinue
    $siteReady = $false
    if ($installedSiteCode -eq $SiteCode) {
        try {
            $siteReady = $null -ne (Get-CimInstance -Namespace "root\SMS\Site_$SiteCode" -ClassName SMS_Site -ErrorAction Stop)
        }
        catch { $siteReady = $false }
    }
    $recoveryUiPath = Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Microsoft\SMS\Setup' -Name 'UI Installation Directory' -ErrorAction SilentlyContinue
    $recoveryModule = if ($recoveryUiPath) { Join-Path $recoveryUiPath 'bin\ConfigurationManager.psd1' } else { '' }
    $modulePresent = [bool]($recoveryModule -and (Test-Path -LiteralPath $recoveryModule -PathType Leaf))
    $recoveryAction = Get-HierarchyRecoveryAction -Stage $setupStage -SiteReady $siteReady -ModulePresent $modulePresent

    if ($recoveryAction -eq 'RetrySetup') {
        Write-DscStatus "InstallSCCM.Status is Running at preflight stage; resetting the hierarchy install for a safe retry."
        $Configuration.InstallSCCM.Status = 'NotStart'
        $Configuration.InstallSCCM.StartTime = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        Write-ScriptWorkFlowData -Configuration $Configuration -ConfigurationFile $ConfigurationFile
    }
    elseif ($recoveryAction -eq 'ResumePostflight') {
        Write-DscStatus "Resuming hierarchy postflight from stage '$setupStage': registry and SMS_Site confirm child Primary $SiteCode is installed."
        Set-Content -LiteralPath $setupStagePath -Value 'SetupCompleted' -Force -ErrorAction Stop
        $resumeHierarchyPostflight = $true
    }
    else {
        Stop-HierarchyInstall "Hierarchy setup recovery stage '$setupStage' is incomplete (siteReady=$siteReady, modulePresent=$modulePresent). Restore the Phase 8 checkpoint before retrying."
        return
    }
}

if ($Configuration.InstallSCCM.Status -ne "Completed" -and
    ($Configuration.InstallSCCM.Status -ne "Running" -or $resumeHierarchyPostflight)) {

    if (-not $resumeHierarchyPostflight) {
    # Set Install action as Running
    $Configuration.InstallSCCM.Status = 'Running'
    $Configuration.InstallSCCM.StartTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
    Write-ScriptWorkFlowData -Configuration $Configuration -ConfigurationFile $ConfigurationFile
    Set-Content -LiteralPath $setupStagePath -Value 'Preflight' -Force -ErrorAction Stop

    # Create $CM dir, before creating the ini
    if (!(Test-Path C:\$CM)) {
        New-Item C:\$CM -ItemType directory | Out-Null
    }

    Write-DscStatus "Creating HierarchyPS.ini file"

    $CMINIPath = "c:\$CM\HierarchyPS.ini"

    $cmini = @'
[Identification]
Action=InstallPrimarySite
CDLatest=1

[Options]
ProductID=%ProductID%
SiteCode=%SiteCode%
SiteName=%SiteName%
SMSInstallDir=%InstallDir%
SDKServer=%MachineFQDN%
RoleCommunicationProtocol=HTTPorHTTPS
ClientsUsePKICertificate=0
PrerequisiteComp=1
PrerequisitePath=%REdistPath%
MobileDeviceLanguage=0
AdminConsole=1
JoinCEIP=0

[SQLConfigOptions]
SQLServerName=%SQLMachineFQDN%
DatabaseName=%SQLInstance%CM_%SiteCode%
SQLServerPort=%SqlPort%
SQLSSBPort=4022
AGBackupShare=

[CloudConnectorOptions]
CloudConnector=0
CloudConnectorServer=
UseProxy=0
ProxyName=
ProxyPort=

[SystemCenterOptions]
SysCenterId=

[HierarchyExpansionOption]
CCARSiteServer=%CASMachineFQDN%

[SABranchOptions]
SAActive=1
CurrentBranch=1
'@

    # Get SQL instance info
    #$inst = (get-itemproperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server').InstalledInstances[0]
    #$p = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL').$inst
    #$sqlinfo = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$p\$inst"

    # Set CM Source Path
    $csShare = Invoke-Command -ComputerName $CSName -ScriptBlock { Get-SmbShare | Where-Object { $_.Name -like 'SMS_*' -and $_.Path -notlike '*despoolr.box*' -and $_.Description -like 'SMS Site *' } }
    $cmsourcepath = "\\$CSName\$($csShare.Name)\cd.latest"

    # Set ini values
    $cmini = $cmini.Replace('%InstallDir%', $SMSInstallDir)
    $productID = "EVAL"
    if ($CM -ne "CMTP") {
        if (-not $($cmo.EVALVersion)) {
            if ($($deployConfig.parameters.ProductID)) {
                $productID = $($deployConfig.parameters.ProductID)
            }
        }
    }
    $cmini = $cmini.Replace('%ProductID%', $productID)

    $cmini = $cmini.Replace('%MachineFQDN%', "$env:computername.$DomainFullName")
    $cmini = $cmini.Replace('%SQLMachineFQDN%', "$sqlServerName.$DomainFullName")
    $cmini = $cmini.Replace('%SiteCode%', $SiteCode)


    if (-not [string]::IsNullOrWhiteSpace($ThisVM.siteName)) {
        $cmini = $cmini.Replace('%SiteName%', $ThisVM.siteName)
    }
    else {
        $cmini = $cmini.Replace('%SiteName%', "ConfigMgr Primary Site")
    }

    $cmini = $cmini.Replace('%SqlPort%', $sqlPort)
    # $cmini = $cmini.Replace('%SQLDataFilePath%',$sqlinfo.DefaultData)
    # $cmini = $cmini.Replace('%SQLLogFilePath%',$sqlinfo.DefaultLog)
    $cmini = $cmini.Replace('%CASMachineFQDN%', "$CSName.$DomainFullName")
    $cmini = $cmini.Replace('%REdistPath%', "$cmsourcepath\REdist")

    if ($installToAO) {
        $cmini = $cmini.Replace('AGBackupShare=', "AGBackupShare=$agBackupShare")
    }

    if ($deployConfig.parameters.SysCenterId) {
        $cmini = $cmini.Replace('SysCenterId=', "SysCenterId=$($deployConfig.parameters.SysCenterId)")
    }

    if ($sqlInstanceName -ieq "MSSQLSERVER" -or $installToAO) {
        $cmini = $cmini.Replace('%SQLInstance%', "")
    }
    else {
        $tinstance = $sqlInstanceName.ToUpperInvariant() + "\"
        $cmini = $cmini.Replace('%SQLInstance%', $tinstance)
    }

    # Create ini
    $cmini > $CMINIPath

    # Set env var to disable open file security warning, otherwise PS hangs in background
    $env:SEE_MASK_NOZONECHECKS = 1

    # Install CM
    $CMInstallationFile = "$cmsourcepath\SMSSETUP\BIN\X64\Setup.exe"
    if ($installToAO) {
        $sqlTarget = if ($sqlPort -and $sqlPort -ne 1433) { "$sqlServerName,$sqlPort" } else { $sqlServerName }
        $odbcConnectionString = Get-HierarchyOdbcConnectionString -Target $sqlTarget -MultiSubnet $multiSubnetHierarchy
        $sqlPreflightPassed = $false
        $sqlPreflightError = ''
        for ($attempt = 1; $attempt -le 12; $attempt++) {
            $odbcConnection = $null
            try {
                $odbcConnection = New-Object System.Data.Odbc.OdbcConnection $odbcConnectionString
                $odbcConnection.Open()
                $sqlPreflightPassed = $true
                Write-DscStatus "Hierarchy SQLAO preflight connected to [$sqlTarget] on attempt $attempt."
                break
            }
            catch {
                $sqlPreflightError = $_.Exception.Message
                if ($attempt -lt 12) { Start-Sleep -Seconds 15 }
            }
            finally {
                if ($odbcConnection) {
                    try { $odbcConnection.Close() } catch {}
                    $odbcConnection.Dispose()
                }
            }
        }
        if (-not $sqlPreflightPassed) {
            Stop-HierarchyInstall "Hierarchy SQLAO preflight could not connect to listener [$sqlTarget] after 12 attempts: $sqlPreflightError"
            return
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

    # Write Setup entry, which causes the job on host to overwrite status with entries from ConfigMgrSetup.log
    Write-DscStatusSetup

    $setupProcess = $null
    try {
        $setupProcess = Start-Process -FilePath $CMInstallationFile -ArgumentList ('/NOUSERINPUT /script "' + $CMINIPath + '"') -PassThru -ErrorAction Stop
        Set-Content -LiteralPath $setupStagePath -Value 'LaunchConfirmed' -Force -ErrorAction Stop
        $setupProcess.WaitForExit()
    }
    catch {
        if (-not $setupProcess) {
            Set-Content -LiteralPath $setupStagePath -Value 'Preflight' -Force -ErrorAction SilentlyContinue
        }
        Stop-HierarchyInstall "Hierarchy child Primary setup could not be launched or monitored: $($_.Exception.Message). Restore the Phase 8 checkpoint before retrying."
        return
    }
    $setupLogTail = if (Test-Path 'C:\ConfigMgrSetup.log') { @(Get-Content 'C:\ConfigMgrSetup.log' -Tail 80 -ErrorAction SilentlyContinue) } else { @() }
    $setupFailure = @($setupLogTail | Select-String -Pattern "Failed Configuration Manager Server Setup|fatal errors|cannot be completed|doesn't have administrative rights|^(?:~)?Setup failed to" | Select-Object -First 1)
    if ($setupProcess.ExitCode -ne 0 -or $setupFailure.Count -gt 0) {
        $failureDetail = if ($setupProcess.ExitCode -ne 0) {
            "setup.exe exited with code $($setupProcess.ExitCode)"
        }
        else {
            [string](($setupFailure[0].Line -split '\$\$<')[0]).Trim().TrimStart('~')
        }
        Stop-HierarchyInstall "Hierarchy child Primary setup did not complete: $failureDetail. Restore the Phase 8 checkpoint before retrying."
        return
    }
    if ($installToAO -and -not (Set-SqlAoLabMaxDop @sqlAoMaxDopParameters)) { return }

    $uiInstallDirectory = Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Microsoft\SMS\Setup' -Name 'UI Installation Directory' -ErrorAction SilentlyContinue
    $configurationManagerModule = if ($uiInstallDirectory) { Join-Path $uiInstallDirectory 'bin\ConfigurationManager.psd1' } else { '' }
    if (-not $configurationManagerModule -or -not (Test-Path -LiteralPath $configurationManagerModule -PathType Leaf)) {
        Stop-HierarchyInstall "Hierarchy child Primary setup returned without installing the Configuration Manager module at '$configurationManagerModule'. Restore the Phase 8 checkpoint before retrying."
        return
    }

    Set-Content -LiteralPath $setupStagePath -Value 'SetupCompleted' -Force -ErrorAction Stop
    Write-DscStatus "Installation finished with exit code 0 and completion evidence."
    Start-Sleep -Seconds 5
    } # end fresh setup path

    if ($multiSubnetHierarchy) {
        $listenerTarget = if ($sqlPort -and $sqlPort -ne 1433) { "$sqlServerName,$sqlPort" } else { $sqlServerName }
        $listenerConnection = $null
        try {
            $listenerConnection = New-Object System.Data.SqlClient.SqlConnection "Data Source=$listenerTarget;Initial Catalog=master;Integrated Security=True;Connect Timeout=15;Encrypt=False;TrustServerCertificate=True;MultiSubnetFailover=True"
            $listenerConnection.Open()
            $listenerCommand = $listenerConnection.CreateCommand()
            $listenerCommand.CommandText = @'
SELECT COUNT(*)
FROM sys.availability_group_listener_ip_addresses
WHERE ip_address IN
(
    SELECT local_net_address
    FROM sys.dm_exec_connections
    WHERE session_id = @@SPID
)
'@
            if ([int]$listenerCommand.ExecuteScalar() -lt 1) {
                throw 'SQL session local address was not recognized as an availability group listener address.'
            }
            $identificationPath = 'HKLM:\SOFTWARE\Microsoft\SMS\Identification'
            New-ItemProperty -Path $identificationPath -Name 'Availability Group' -PropertyType DWord -Value 1 -Force -ErrorAction Stop | Out-Null
            New-ItemProperty -Path $identificationPath -Name 'MSF Enabled' -PropertyType DWord -Value 1 -Force -ErrorAction Stop | Out-Null
            $identificationKey = Get-Item -Path $identificationPath -ErrorAction Stop
            if ($identificationKey.GetValueKind('Availability Group') -ne [Microsoft.Win32.RegistryValueKind]::DWord -or
                $identificationKey.GetValueKind('MSF Enabled') -ne [Microsoft.Win32.RegistryValueKind]::DWord -or
                $identificationKey.GetValue('Availability Group') -ne 1 -or
                $identificationKey.GetValue('MSF Enabled') -ne 1) {
                throw 'ConfigMgr SQLAO registry state did not converge to DWORD 1 values.'
            }
            Write-DscStatus "Verified hierarchy listener [$listenerTarget] and enabled ConfigMgr Availability Group / MSF state."
        }
        catch {
            Stop-HierarchyInstall "Failed to validate ConfigMgr multi-subnet SQLAO state for hierarchy listener [$listenerTarget]: $($_.Exception.Message)"
            return
        }
        finally {
            if ($listenerConnection) {
                try { $listenerConnection.Close() } catch {}
                $listenerConnection.Dispose()
            }
        }
    }

    # Delete ini file?
    # Remove-Item $CMINIPath

}

# Recheck the CAS handshake on resumes too; an old Completed flag may be unverified.
$propName = "PSReadyToUse" + $ThisVm.VmName
$CSConfiguration = Read-ScriptWorkflowData -ConfigurationFile $CSConfigurationFile `
    -RequiredSteps @($propName)
Write-DscStatus "Waiting for $CSName to indicate Primary is ready to use"
$psReadyStart = Get-Date
$casReady = $CSConfiguration.$propName
while ($casReady.Status -ne 'Completed' -or
    -not ($casReady.PSObject.Properties['ReplicationVerified'] -and
        $casReady.ReplicationVerified -is [bool] -and $casReady.ReplicationVerified)) {
    Assert-CasWorkflowStepCanContinue -CasConfiguration $CSConfiguration -Step $propName
    $psReadyMin = [int]((Get-Date) - $psReadyStart).TotalMinutes
    if ($psReadyMin -ge $casDependencyWaitMaxMinutes) {
        throw "$CSName did not verify $propName within $casDependencyWaitMaxMinutes minutes (last state: $($casReady.Status))."
    }
    $proof = $casReady.PSObject.Properties['ReplicationVerified']
    $proofText = if ($proof) { "$($proof.Value)" } else { 'missing; update and rerun Phase 8 on the CAS too' }
    Write-DscStatus "Waiting for $CSName to verify Primary replication readiness (${psReadyMin}m elapsed, status=$($casReady.Status), ReplicationVerified=$proofText)" -RetrySeconds 30
    Start-Sleep -Seconds 30
    $CSConfiguration = Read-ScriptWorkflowData -ConfigurationFile $CSConfigurationFile `
        -RequiredSteps @($propName)
    $casReady = $CSConfiguration.$propName
}
Assert-CasWorkflowStepCanContinue -CasConfiguration $CSConfiguration -Step $propName
Write-DscStatus "$CSName verified Primary replication readiness ($([int]((Get-Date) - $psReadyStart).TotalMinutes)m elapsed)."

$Configuration.InstallSCCM.Status = 'Completed'
$Configuration.InstallSCCM.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
Write-ScriptWorkFlowData -Configuration $Configuration -ConfigurationFile $ConfigurationFile
Remove-Item -LiteralPath $setupStagePath -Force -ErrorAction SilentlyContinue
