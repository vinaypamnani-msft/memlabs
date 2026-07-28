configuration Phase4
{
    param
    (
        [Parameter(Mandatory)]
        [string]$DeployConfigPath,
        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$Admincreds
    )

    Set-ExecutionPolicy -ExecutionPolicy Bypass -Force
    Import-DscResource -ModuleName 'TemplateHelpDSC'
    Import-DscResource -ModuleName 'PSDesiredStateConfiguration', 'ComputerManagementDsc', 'SqlServerDsc', 'ActiveDirectoryDsc', 'CertificateDsc'

    # Read deployConfig
    $deployConfig = Get-Content -Path $DeployConfigPath | ConvertFrom-Json
    $DomainName = $deployConfig.parameters.domainName
    #$NetBiosDomainName = $DomainName.Split(".")[0]
    $NetBiosDomainName = $deployConfig.vmOptions.domainNetBiosName
    $SQLInstanceDir = "C:\Program Files\Microsoft SQL Server"
    $SQLInstanceName = "MSSQLSERVER"
    $sqlUpdateEnabled = $false


    Node $AllNodes.Where{ $_.Role -eq 'DC' }.NodeName
    {
        WriteStatus Complete {
            Status = "Complete!"
        }
    }

    Node $AllNodes.Where{ $_.Role -ne 'DC' }.NodeName
    {
        $ThisVM = $deployConfig.virtualMachines | Where-Object { $_.vmName -eq $node.NodeName }

        if ($ThisVM.sqlInstanceDir) {
            $SQLInstanceDir = $ThisVM.sqlInstanceDir
        }
        if ($ThisVM.sqlInstanceName) {
            $SQLInstanceName = $ThisVM.sqlInstanceName
        }
        if ($ThisVM.thisParams.sqlCUURL) {
            $sqlUpdateEnabled = $true
            $sqlCUURL = $ThisVM.thisParams.sqlCUURL
            $sqlCuDownloadPath = Join-Path "C:\Temp\SQL_CU" (Split-Path -Path $sqlCUURL -Leaf)
        }


        $backupSolutionURL = $ThisVM.thisParams.backupSolutionURL
        $SQLSysAdminAccounts = $ThisVM.thisParams.SQLSysAdminAccounts

        # Install the SqlServer PowerShell module on every node in this phase. This
        # includes site servers / site systems that use REMOTE SQL and therefore
        # never run the SQL install below (they are added to this phase's node list
        # by Get-Phase4ConfigurationData). Having Invoke-Sqlcmd / the SqlServer
        # module available on those boxes is valuable for later phases (e.g.
        # ConfigureMPReplica) and for testing.
        ModuleAdd SQLServerModule {
            Key             = 'Always'
            CheckModuleName = 'SqlServer'
        }

        # MP database replica: an EXISTING (Hidden) SQL server that hosts a replica
        # DB, or is the site DB (publisher) for a site with a replica MP, needs the
        # SQL 'Replication' feature -- but its SQL install block below is skipped
        # (Hidden), so it never got Replication. Detect the authoritative registry
        # key and, if missing, add the feature from the SQL media the host mounted
        # for this VM. (New/non-Hidden SQL gets Replication via the Features list in
        # SqlSetup below, so this only runs for Hidden replica-involved SQL.)
        $thisNeedsReplication = $false
        foreach ($mpRepl in @($deployConfig.virtualMachines | Where-Object { $_.role -eq 'SiteSystem' -and $_.installMP -and $_.useDatabaseReplica })) {
            if ($mpRepl.replicaSqlServerVM -and $mpRepl.replicaSqlServerVM -eq $ThisVM.vmName) { $thisNeedsReplication = $true; break }
            $replSite = $deployConfig.virtualMachines | Where-Object { $_.role -in @('Primary', 'CAS') -and $_.siteCode -eq $mpRepl.siteCode } | Select-Object -First 1
            if ($replSite) {
                if ($replSite.sqlVersion -and $replSite.vmName -eq $ThisVM.vmName) { $thisNeedsReplication = $true; break }
                if (-not $replSite.sqlVersion -and $replSite.remoteSQLVM -and $replSite.remoteSQLVM -eq $ThisVM.vmName) { $thisNeedsReplication = $true; break }
            }
        }
        if ($ThisVM.Hidden -and $thisNeedsReplication) {
            $replTestScript = (@'
$inst = '__INST__'
$instId = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL' -ErrorAction SilentlyContinue).$inst
if (-not $instId) { return $false }
$replPath = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$instId\Replication"
$isInstalled = (Get-ItemProperty -Path $replPath -Name 'IsInstalled' -ErrorAction SilentlyContinue).IsInstalled
return ($isInstalled -eq 1)
'@) -replace '__INST__', $SQLInstanceName
            $replSetScript = (@'
$inst = '__INST__'
$drive = $null
foreach ($vol in (Get-CimInstance -ClassName Win32_Volume -Filter 'DriveType = 5' -ErrorAction SilentlyContinue)) {
    if ($vol.DriveLetter -and (Test-Path (Join-Path "$($vol.DriveLetter)\" 'setup.exe'))) { $drive = $vol.DriveLetter; break }
}
if (-not $drive) { throw 'SQL setup media not found on any CD-ROM drive; the host should have mounted the SQL ISO for this replica-enabled SQL VM.' }
$setup = Join-Path "$drive\" 'setup.exe'
$sqlArgs = @('/Action=Install','/Quiet','/IAcceptSQLServerLicenseTerms','/ENU','/FEATURES=Replication',"/INSTANCENAME=$inst")
$p = Start-Process -FilePath $setup -ArgumentList $sqlArgs -Wait -PassThru -NoNewWindow
if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) { throw "SQL setup to add the Replication feature failed with exit code $($p.ExitCode). See the SQL Setup Bootstrap Summary.txt log." }
'@) -replace '__INST__', $SQLInstanceName

            WriteStatus EnsureSqlReplication {
                DependsOn = '[ModuleAdd]SQLServerModule'
                Status    = "Ensuring SQL 'Replication' feature is installed (MP database replica)"
            }
            Script EnsureSqlReplication {
                DependsOn  = '[WriteStatus]EnsureSqlReplication'
                GetScript  = 'return @{ Result = "N/A" }'
                TestScript = $replTestScript
                SetScript  = $replSetScript
            }
        }

        # --- PKI IIS web-server certificate (enrolled early, in Phase 4) --------
        # WSUS (Phase 6 ConfigureWSUS) and PBIRS (Phase 7 InstallPBIRS) both need
        # the 'ConfigMgr WebServer Certificate' for their HTTPS/SSL bindings, but
        # the CertReq that enrolls it historically lived in Phase 8 (CM install) --
        # two phases too late, so those phases had to self-heal a missing cert. The
        # Enterprise CA + templates are published by the post-Phase-3 PKI
        # orchestrator (New-Lab) and Phase 3 installs IIS + reboots (refreshing the
        # 'ConfigMgr IIS Servers' group token), so by Phase 4 everything the
        # enrollment needs is present. Enroll here so every early consumer finds the
        # cert already present. Phase 8 keeps its own idempotent CertReq for
        # PassiveSite (not a Phase 4 node) and as a backstop. Same gate + logic as
        # the Phase 8 block. Runs BEFORE the no-local-SQL short-circuit below so it
        # also reaches remote-SQL site servers.
        $cmoCert = if ($ThisVM.cmOptions) { $ThisVM.cmOptions } else { $deployConfig.cmOptions }
        $caVMCert = $deployConfig.virtualMachines | Where-Object { $_.InstallCA }
        $AddIISCert = $false
        if ($ThisVM.role -in "CAS", "Primary", "Secondary", "PassiveSite") { $AddIISCert = $true }
        if ($ThisVM.installSUP -eq $true -and $ThisVM.role -ne "WSUS") { $AddIISCert = $true }
        if ($ThisVM.installRP -eq $true) { $AddIISCert = $true }
        if ($ThisVM.installMP -eq $true) { $AddIISCert = $true }
        if ($ThisVM.installDP -eq $true) { $AddIISCert = $true }
        # When adding a site system to an EXISTING PKI domain the Enterprise CA
        # already lives in AD (no InstallCA VM in this deploy), so an empty
        # $caVMCert must NOT suppress the cert while UsePKI is set.
        if (-not $caVMCert -and -not $cmoCert.UsePKI) { $AddIISCert = $false }
        if (-not $cmoCert.UsePKI) { $AddIISCert = $false }

        $certDepend = '[ModuleAdd]SQLServerModule'
        if ($AddIISCert) {

            WriteStatus PkiRequestCerts {
                Status    = "Requesting IIS Certificate for PKI"
                DependsOn = '[ModuleAdd]SQLServerModule'
            }

            # Refresh the machine Kerberos ticket so its PAC carries the
            # 'ConfigMgr IIS Servers' AD group SID (grants Enroll on the CM cert
            # templates) WITHOUT a reboot: the DC adds this computer account to that
            # group in Phase 2 and Phase 3 already reboots after the group exists,
            # so purging the machine (0x3e7 = SYSTEM LUID) Kerberos ticket cache
            # forces a fresh TGT on the CMC enrollment call to the CA.
            Script PkiRefreshGroupToken {
                GetScript  = { @{ Result = 'N/A' } }
                TestScript = { $false }
                SetScript  = {
                    try { gpupdate.exe /target:computer /force 2>&1 | Out-Null } catch {}
                    try { klist.exe -li 0x3e7 purge 2>&1 | Out-Null } catch {}
                }
                DependsOn  = "[WriteStatus]PkiRequestCerts"
            }

            # Refresh the local certificate template cache before CertReq so its
            # Test() resolves the template OID to its name (otherwise it re-creates
            # the cert on every run).
            Script PkiRefreshTemplateCache {
                GetScript  = { @{ Result = 'N/A' } }
                TestScript = { $false }
                SetScript  = {
                    try { certutil.exe -pulse 2>&1 | Out-Null } catch {}
                    foreach ($hive in @('HKLM', 'HKCU')) {
                        $k = "${hive}:\SOFTWARE\Microsoft\Cryptography\CertificateTemplateCache"
                        Remove-ItemProperty -Path $k -Name 'Timestamp' -Force -ErrorAction SilentlyContinue
                    }
                }
                DependsOn  = "[Script]PkiRefreshGroupToken"
            }

            $subjectCert = $ThisVM.vmName + "." + $DomainName
            CertReq PkiWebCert {
                Subject             = $subjectCert
                SubjectAltName      = "DNS=" + $subjectCert + "&DNS=" + $($ThisVM.VmName)
                KeyLength           = '2048'
                Exportable          = $false
                ProviderName        = 'Microsoft RSA SChannel Cryptographic Provider'
                CertificateTemplate = 'ConfigMgrWebServerCertificate'
                AutoRenew           = $true
                FriendlyName        = 'ConfigMgr WebServer Certificate'
                KeyType             = 'RSA'
                RequestType         = 'CMC'
                DependsOn           = "[Script]PkiRefreshTemplateCache"
            }

            WriteStatus PkiAddCerts {
                Status    = "Adding IIS Certificate for PKI"
                DependsOn = "[CertReq]PkiWebCert"
            }
            AddCertificateToIIS PkiAddCert {
                FriendlyName = 'ConfigMgr WebServer Certificate'
                DependsOn    = "[WriteStatus]PkiAddCerts"
            }
            $certDepend = "[AddCertificateToIIS]PkiAddCert"
        }

        # Nodes without local SQL (remote-SQL site servers, DP/MP site systems) get
        # the module only, then complete -- skip the entire SQL install/config below.
        if (-not $ThisVM.sqlVersion) {
            WriteStatus Complete {
                DependsOn = $certDepend
                Status    = 'Complete!'
            }
            return
        }

        WriteStatus SQLInstallStarted {
            DependsOn = $certDepend
            Status    = "Preparing to Install SQL '$($ThisVM.sqlVersion)'"
        }

        $nextDepend = '[WriteStatus]SQLInstallStarted'
        if (-not ($ThisVM.Hidden)) {
            RebootNow RebootNow {
                FileName  = 'C:\Temp\PreSqlReboot.txt'
                DependsOn = $nextDepend
            }
            $nextDepend = '[RebootNow]RebootNow'

            # SQL media is no longer copied to C:\temp\SQL at VM create time; the
            # SQL ISO is mounted by the host before Phase 4 and assigned drive
            # letter S: below. C:\temp\SQL_CU still holds the downloaded CU and
            # must exist before DownloadSQLCU writes into it.
            File SqlCuDir {
                Type            = 'Directory'
                DestinationPath = 'C:\temp\SQL_CU'
                Ensure          = 'Present'
                DependsOn       = $nextDepend
            }
            $nextDepend = '[File]SqlCuDir'

            if ($sqlUpdateEnabled) {

                WriteStatus DownloadSQLCU {
                    DependsOn = $nextDepend
                    Status    = "Downloading CU File for '$($ThisVM.sqlVersion)'"
                }

                DownloadFile DownloadSQLCU {
                    DownloadUrl = $sqlCUURL
                    FilePath    = $sqlCuDownloadPath
                    Ensure      = "Present"
                    DependsOn   = $nextDepend
                }
                $nextDepend = '[DownloadFile]DownloadSQLCU'
            }

            # Ensure sqlncli.msi is present at the Windows Installer registered
            # source path so the CU can patch the SQL Native Client (error 1706).
            # Query the Installer registry for the actual InstallSource, then
            # copy sqlncli.msi from C:\Windows\Temp (where Phase3 InstallSQLClient
            # downloads the current version). Do NOT use the SQL ISO copy — it
            # ships an older version that mismatches the installed product.
            Script RestoreSqlNcliSource {
                GetScript  = { @{ Result = 'N/A' } }
                TestScript = {
                    $productsPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products'
                    foreach ($product in (Get-ChildItem $productsPath -ErrorAction SilentlyContinue)) {
                        $props = Get-ItemProperty "$($product.PSPath)\InstallProperties" -ErrorAction SilentlyContinue
                        if ($props.DisplayName -match 'SQL Server.*Native Client') {
                            $source = $props.InstallSource
                            if ($source -and -not (Test-Path (Join-Path $source 'sqlncli.msi'))) {
                                Write-Verbose "sqlncli.msi missing from registered InstallSource: $source"
                                return $false
                            }
                        }
                    }
                    return $true
                }
                SetScript  = {
                    $ncli = 'C:\Windows\Temp\sqlncli.msi'
                    if (-not (Test-Path $ncli)) {
                        Write-Verbose "sqlncli.msi not found at $ncli (Phase3 InstallSQLClient should have placed it here)"
                        return
                    }

                    $productsPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products'
                    foreach ($product in (Get-ChildItem $productsPath -ErrorAction SilentlyContinue)) {
                        $props = Get-ItemProperty "$($product.PSPath)\InstallProperties" -ErrorAction SilentlyContinue
                        if ($props.DisplayName -match 'SQL Server.*Native Client') {
                            $source = $props.InstallSource
                            if ($source) {
                                if (-not (Test-Path $source)) {
                                    New-Item -ItemType Directory -Path $source -Force | Out-Null
                                }
                                $dest = Join-Path $source 'sqlncli.msi'
                                if (-not (Test-Path $dest)) {
                                    Copy-Item $ncli $dest -Force
                                    Write-Verbose "Restored sqlncli.msi to $dest from $ncli"
                                }
                            }
                        }
                    }
                }
                DependsOn  = $nextDepend
            }
            $nextDepend = '[Script]RestoreSqlNcliSource'

            # The host mounts the SQL ISO to this VM's DVD drive before Phase 4
            # (Mount-SqlIsoForPhase, runs every Phase 4 pass). It is ejected on a
            # successful phase, so a RE-RUN re-mounts a FRESH optical volume with a
            # new volume GUID -> Windows can't reclaim the old letter (the prior
            # mount's \DosDevices\S: reservation still lingers in MountedDevices) and
            # auto-assigns the next free letter instead. So the SQL disc floats
            # between runs. Force it to the deterministic letter S: so SqlSetup
            # -SourcePath ('S:\') is stable.
            #
            # We ALWAYS ensure S: when the ISO is mounted and do NOT try to shortcut
            # on "SQL already installed": SqlSetup owns its own idempotency and only
            # skips when ALL requested features are present. A partially-installed
            # instance (e.g. SQLENGINE present but CONN/BC missing) still needs
            # setup.exe -- and therefore S: -- to add the remaining features, so a
            # premature skip here would starve setup.exe of its media and strand the
            # config. Relabeling an already-idle ISO to S: is cheap and harmless.
            #
            # Defense in layers: free S: (live holder + stale reservation), then
            # assign via CIM -> WMI -> mountvol until S:\setup.exe resolves.
            Script AssignSqlIsoDriveLetter {
                GetScript  = { @{ Result = '' } }
                TestScript = { [bool](Test-Path 'S:\setup.exe' -ErrorAction SilentlyContinue) }
                SetScript  = {
                    $mountvol = "$env:SystemRoot\System32\mountvol.exe"

                    # Locate the optical (DriveType 5 = CD-ROM = mounted ISO) volume
                    # holding the SQL media (setup.exe at its root). Handles the
                    # LETTERLESS disc: after the host mounts two discs (cache + SQL),
                    # the guest can transiently enumerate the SQL disc without a drive
                    # letter, and a letter-only probe would then miss it, throw "SQL
                    # ISO not found", re-stage pending.mof and strand the config into a
                    # reboot. Bind a temporary scratch letter to probe letterless
                    # optical volumes so the disc is recognized even mid-churn.
                    $findSqlVol = {
                        $optical = @(Get-CimInstance -ClassName Win32_Volume -Filter 'DriveType = 5' -ErrorAction SilentlyContinue)
                        # (a) Prefer a lettered optical volume with setup.exe at its root.
                        foreach ($vol in $optical) {
                            if ($vol.DriveLetter -and (Test-Path (Join-Path "$($vol.DriveLetter)\" 'setup.exe') -ErrorAction SilentlyContinue)) {
                                return $vol
                            }
                        }
                        # (b) Probe letterless optical volumes via a temporary scratch letter.
                        $scratchPool = @('R', 'Q', 'P', 'O', 'N', 'M')
                        $used = @{}
                        foreach ($v in (Get-CimInstance -ClassName Win32_Volume -ErrorAction SilentlyContinue)) {
                            if ($v.DriveLetter) { $used[([string]$v.DriveLetter).TrimEnd(':')] = $true }
                        }
                        foreach ($vol in $optical) {
                            if ($vol.DriveLetter) { continue }
                            $scratch = $scratchPool | Where-Object { -not $used.ContainsKey($_) } | Select-Object -First 1
                            if (-not $scratch) { break }
                            $isSql = $false
                            try {
                                & $mountvol "${scratch}:" $vol.DeviceID 2>$null | Out-Null
                                Start-Sleep -Seconds 1
                                $isSql = [bool](Test-Path "${scratch}:\setup.exe" -ErrorAction SilentlyContinue)
                            }
                            catch {}
                            # Release the scratch letter either way -- if it IS the SQL
                            # disc, the assignment below re-letters it to S: cleanly.
                            try { & $mountvol "${scratch}:" /D 2>$null | Out-Null } catch {}
                            if ($isSql) { return $vol }
                        }
                        return $null
                    }

                    # (1) Locate the SQL optical volume, polling briefly: after a host
                    #     mount the guest can take a few seconds to enumerate the disc,
                    #     and with two discs attached the SQL disc can transiently appear
                    #     letterless. Waiting ~2 min for it to settle avoids stranding
                    #     pending.mof (and forcing a reboot) on a disc that IS present.
                    $sqlVol = $null
                    $deadline = (Get-Date).AddMinutes(2)
                    do {
                        $sqlVol = & $findSqlVol
                        if ($sqlVol) { break }
                        Start-Sleep -Seconds 10
                    } while ((Get-Date) -lt $deadline)
                    if (-not $sqlVol) {
                        throw "SQL ISO not found on any CD-ROM volume (expected setup.exe at the optical drive root) after waiting 2 min. The host should have mounted it before Phase 4."
                    }
                    if ($sqlVol.DriveLetter -eq 'S:') {
                        Write-Verbose "SQL ISO already on S:."
                        return
                    }

                    # (2) Free S: so the reassignment can't be rejected with "Not available".
                    #  (2a) If a LIVE volume currently occupies S:, park it on a high free letter.
                    $high = @('Z', 'Y', 'X', 'W', 'V', 'U', 'T')
                    $used = @{}
                    foreach ($v in (Get-CimInstance -ClassName Win32_Volume -ErrorAction SilentlyContinue)) {
                        if ($v.DriveLetter) { $used[([string]$v.DriveLetter).TrimEnd(':')] = $true }
                    }
                    $sHolder = Get-CimInstance -ClassName Win32_Volume -Filter "DriveLetter = 'S:'" -ErrorAction SilentlyContinue
                    if ($sHolder) {
                        $free = $high | Where-Object { -not $used.ContainsKey($_) } | Select-Object -First 1
                        if ($free) {
                            Write-Verbose "Parking current S: holder on ${free}: to free S: for the SQL ISO."
                            try {
                                $wmiHolder = Get-WmiObject -Class Win32_Volume -ErrorAction SilentlyContinue | Where-Object { $_.DeviceID -eq $sHolder.DeviceID } | Select-Object -First 1
                                if ($wmiHolder) { $wmiHolder | Set-WmiInstance -Arguments @{ DriveLetter = "${free}:" } -ErrorAction SilentlyContinue | Out-Null }
                            }
                            catch {}
                        }
                    }
                    #  (2b) Clear any leftover mount-point mapping for S:.
                    try { & $mountvol S: /D 2>$null | Out-Null } catch {}
                    #  (2c) Clear a STALE MountedDevices reservation (\DosDevices\S:) left by a
                    #       prior mount whose volume no longer exists -- the actual cause of the
                    #       "Not available" rejection -- but only if no live volume holds S: now.
                    try {
                        $stillHeld = Get-CimInstance -ClassName Win32_Volume -Filter "DriveLetter = 'S:'" -ErrorAction SilentlyContinue
                        if (-not $stillHeld) {
                            $md = 'HKLM:\SYSTEM\MountedDevices'
                            if ($null -ne (Get-ItemProperty -Path $md -Name '\DosDevices\S:' -ErrorAction SilentlyContinue)) {
                                Remove-ItemProperty -Path $md -Name '\DosDevices\S:' -ErrorAction SilentlyContinue
                            }
                        }
                    }
                    catch {}

                    # (3) Assign S: to the SQL disc, trying each method until S:\setup.exe resolves.
                    $assigned = $false
                    #  (3a) CIM InputObject.
                    try {
                        $sqlVol.DriveLetter = 'S:'
                        Set-CimInstance -InputObject $sqlVol -ErrorAction Stop
                        $assigned = (Test-Path 'S:\setup.exe')
                    }
                    catch { Write-Verbose "CIM S: assign failed: $($_.Exception.Message)" }
                    #  (3b) WMI Set-WmiInstance (the method InitializeDisks uses successfully).
                    if (-not $assigned) {
                        try {
                            $wmiVol = Get-WmiObject -Class Win32_Volume -Filter 'DriveType = 5' -ErrorAction SilentlyContinue | Where-Object { $_.DeviceID -eq $sqlVol.DeviceID } | Select-Object -First 1
                            if ($wmiVol) { $wmiVol | Set-WmiInstance -Arguments @{ DriveLetter = 'S:' } -ErrorAction SilentlyContinue | Out-Null }
                            $assigned = (Test-Path 'S:\setup.exe')
                        }
                        catch { Write-Verbose "WMI S: assign failed: $($_.Exception.Message)" }
                    }
                    #  (3c) mountvol bind by device path.
                    if (-not $assigned) {
                        try {
                            & $mountvol S: $sqlVol.DeviceID 2>$null | Out-Null
                            Start-Sleep -Seconds 1
                            $assigned = (Test-Path 'S:\setup.exe')
                        }
                        catch { Write-Verbose "mountvol S: assign failed: $($_.Exception.Message)" }
                    }

                    if (-not $assigned) {
                        throw "Failed to assign S: to SQL ISO volume ($($sqlVol.DeviceID)) after CIM/WMI/mountvol attempts. Current optical letter: $($sqlVol.DriveLetter)."
                    }
                }
                DependsOn  = $nextDepend
            }
            $nextDepend = '[Script]AssignSqlIsoDriveLetter'

            WriteStatus InstallSQL {
                DependsOn = $nextDepend
                Status    = "Installing '$($ThisVM.sqlVersion)' ($SQLInstanceName instance)"
            }

            $features = 'SQLENGINE'
            if ($($ThisVm.sqlVersion -match "SQL Server 201")) {
                $features = 'SQLENGINE,CONN,BC'
            }

            # MP database replica uses SQL transactional replication, which requires
            # the 'Replication' setup feature on BOTH the publisher/distributor (the
            # site DB SQL) and every subscriber (replica SQL host). memlabs installs
            # SQLENGINE only by default, so add Replication whenever this deployment
            # has any MP database replica (superset; harmless on uninvolved SQL VMs).
            if (@($deployConfig.virtualMachines | Where-Object { $_.role -eq 'SiteSystem' -and $_.installMP -and $_.useDatabaseReplica }).Count -gt 0) {
                $features = "$features,Replication"
            }

            SqlSetup InstallSQL {
                InstanceName        = $SQLInstanceName
                InstanceDir         = $SQLInstanceDir
                SQLCollation        = 'SQL_Latin1_General_CP1_CI_AS'
                Features            = $features
                SourcePath          = 'S:\'
                UpdateEnabled       = $sqlUpdateEnabled
                UpdateSource        = "C:\temp\SQL_CU"
                SQLSysAdminAccounts = $SQLSysAdminAccounts
                TcpEnabled          = $true
                UseEnglish          = $true
                DependsOn           = '[WriteStatus]InstallSQL'
            }
            $nextDepend = "[SqlSetup]InstallSQL"
        }

        WriteStatus AddSQLPermissions {
            DependsOn = $nextDepend
            Status    = "Adding SQL logins and roles"
        }

        # Fast-fail gate: confirm the local SQL instance is actually reachable
        # BEFORE the SqlLogin/SqlRole/SqlMemory resources run. Those SqlServerDsc
        # resources connect with a ~600s connect timeout, so against a missing or
        # down instance EACH one hangs ~10 min (observed: a Hidden Primary whose
        # SQL was never installed -- the install block above is skipped for
        # existing/Hidden VMs -- wedged Phase 4 for 30+ min on "Adding SQL logins
        # and roles"). This Script connects via the same path with a 5s timeout:
        # on a healthy box Test passes instantly (no-op); when SQL is unreachable
        # it waits up to 3 min (covers a just-started service) then throws ONE
        # clear, actionable error instead of three opaque 600s stalls.
        $cvSqlInstance = $SQLInstanceName
        if ($SQLInstanceName -eq 'MSSQLSERVER') {
            $cvSqlSvc = 'MSSQLSERVER'
            $cvSqlDs  = $node.NodeName
        }
        else {
            $cvSqlSvc = "MSSQL`$$SQLInstanceName"
            $cvSqlDs  = "$($node.NodeName)\$SQLInstanceName"
        }
        $cvHiddenStr = [string][bool]$ThisVM.Hidden

        $sqlReachTest = @"
`$ErrorActionPreference = 'SilentlyContinue'
try {
    `$cs = 'Data Source=$cvSqlDs;Initial Catalog=master;Integrated Security=True;Connect Timeout=5;Encrypt=False;TrustServerCertificate=True'
    `$c = New-Object System.Data.SqlClient.SqlConnection `$cs
    `$c.Open(); `$c.Close(); `$c.Dispose()
    return `$true
} catch { return `$false }
"@

        $sqlReachSet = @"
`$ErrorActionPreference = 'Stop'
`$cs = 'Data Source=$cvSqlDs;Initial Catalog=master;Integrated Security=True;Connect Timeout=5;Encrypt=False;TrustServerCertificate=True'
`$deadline = (Get-Date).AddMinutes(3)
`$err = ''
do {
    try { `$c = New-Object System.Data.SqlClient.SqlConnection `$cs; `$c.Open(); `$c.Close(); `$c.Dispose(); return } catch { `$err = `$_.Exception.Message }
    Start-Sleep -Seconds 10
} while ((Get-Date) -lt `$deadline)
`$svc = Get-Service -Name '$cvSqlSvc' -ErrorAction SilentlyContinue
if (-not `$svc) {
    throw "SQL instance '$cvSqlInstance' is NOT installed on $($node.NodeName) (no '$cvSqlSvc' service). Phase 4's SQL install step is skipped for existing/Hidden VMs (Hidden=$cvHiddenStr) AND the host does not mount the SQL ISO for Hidden VMs, so the SqlLogin/SqlRole resources have no instance to connect to (each would otherwise hang ~600s). Remedy: rebuild SQL on this VM -- delete + recreate it, or re-deploy it non-Hidden -- then re-run Phase 4. Last connect error: `$err"
}
if (`$svc.Status -ne 'Running') {
    try { Start-Service -Name '$cvSqlSvc' -ErrorAction Stop; Start-Sleep -Seconds 20; `$c = New-Object System.Data.SqlClient.SqlConnection `$cs; `$c.Open(); `$c.Close(); `$c.Dispose(); return } catch { `$err = `$_.Exception.Message }
}
throw "SQL instance '$cvSqlInstance' service '$cvSqlSvc' exists (Status=`$(`$svc.Status)) but is not accepting local connections after 3 min. Check the SQL errorlog, the TCP/IP protocol state, and that it is listening on the expected port. Last connect error: `$err"
"@

        Script EnsureSqlReachable {
            DependsOn  = '[WriteStatus]AddSQLPermissions'
            GetScript  = { @{ Result = '' } }
            TestScript = $sqlReachTest
            SetScript  = $sqlReachSet
        }
        $nextDepend = '[Script]EnsureSqlReachable'

        # Add roles explicitly, for re-runs to make sure new accounts are added as sysadmin
        $sqlDependency = @('[Script]EnsureSqlReachable')
        $i = 0
        foreach ($account in $SQLSysAdminAccounts | Where-Object { $_ -notlike "BUILTIN*" } ) {
            if (-not $account) {
                continue
            }
            $i++

            SqlLogin "AddSqlLogin$i" {
                Ensure                  = 'Present'
                Name                    = $account
                LoginType               = 'WindowsUser'
                InstanceName            = $SQLInstanceName
                LoginMustChangePassword = $false
                DependsOn               = $nextDepend
            }
            $sqlDependency += "[SqlLogin]AddSqlLogin$i"
        }

        SqlRole SqlRole {
            Ensure           = 'Present'
            ServerRoleName   = 'sysadmin'
            MembersToInclude = $SQLSysAdminAccounts
            InstanceName     = $SQLInstanceName
            DependsOn        = $sqlDependency
        }

        SqlMemory SetSqlMemory {
            DependsOn    = '[SqlRole]SqlRole'
            Ensure       = 'Present'
            DynamicAlloc = $false
            MinMemory    = 2048
            MaxMemory    = 6144
            InstanceName = $SQLInstanceName
        }

        if ($ThisVM.sqlPort) {
        $SQLport = $ThisVM.sqlPort
        }
        else {
            $SQLport = 1433
        }


        ChangeSqlInstancePort SqlInstancePort {
            SQLInstanceName = $SQLInstanceName
            SQLInstancePort = $SQLport
            Ensure          = "Present"
            DependsOn       = "[SqlMemory]SetSqlMemory"
        }

        $nextDepend = '[ChangeSqlInstancePort]SqlInstancePort'

        # Enable SQL Browser when using a named instance or non-default port.
        # SQL Browser is required for remote clients that connect by instance
        # name without a port, and also helps discovery when the default instance
        # listens on a non-standard port.
        if ($SQLInstanceName -ne 'MSSQLSERVER' -or $SQLport -ne 1433) {
            Script EnableSqlBrowser {
                DependsOn  = '[ChangeSqlInstancePort]SqlInstancePort'
                GetScript  = { @{ Result = (Get-Service SQLBrowser -ErrorAction SilentlyContinue).Status } }
                TestScript = {
                    $svc = Get-Service SQLBrowser -ErrorAction SilentlyContinue
                    return ($svc -and $svc.Status -eq 'Running' -and $svc.StartType -eq 'Automatic')
                }
                SetScript  = {
                    Set-Service -Name SQLBrowser -StartupType Automatic -ErrorAction SilentlyContinue
                    Start-Service -Name SQLBrowser -ErrorAction SilentlyContinue
                }
            }
            $nextDepend = '[Script]EnableSqlBrowser'
        }

        if (-not ($thisVM.Hidden)) {
            if ($ThisVM.SqlServiceAccount -and ($ThisVM.SqlServiceAccount -ne "LocalSystem")) {
                $SPNs = @()
                $SPNs += "MSSQLSvc/" + $thisvm.VmName
                $SPNs += "MSSQLSvc/" + $thisvm.VmName + "." + $DomainName
                $port = $SQLport
                if ($SQLInstanceName -ne "MSSQLSERVER") {
                    $SPNs += "MSSQLSvc/" + $thisvm.VmName + ":" + $SQLInstanceName
                    $SPNs += "MSSQLSvc/" + $thisvm.VmName + "." + $DomainName + ":" + $SQLInstanceName

                }
                $SPNs += "MSSQLSvc/" + $thisvm.VmName + ":" + $port
                $SPNs += "MSSQLSvc/" + $thisvm.VmName + "." + $DomainName + ":" + $port

                # Add roles explicitly, for re-runs to make sure new accounts are added as sysadmin
                $spnDependency = @($nextDepend)

                WriteStatus SetSQLSPN {
                    DependsOn = $nextDepend
                    Status    = "Updating SQL SPNs ($($SPNs -join ",")) for $($ThisVM.SqlServiceAccount)"
                }

                # Register SPNs via a single Script resource that targets the
                # PDC explicitly.  When two SQLAO nodes run Phase 4 in parallel,
                # each writes SPNs to the same AD account (e.g. FryerSvc).  If
                # they talk to different DCs, the concurrent writes to the
                # multi-valued servicePrincipalName attribute cause a replication
                # conflict and last-writer-wins discards one node's SPNs.
                # Targeting the PDC serialises all writes through one DC.
                $cvSPNList    = ($SPNs | ForEach-Object { "'$_'" }) -join ','
                $cvSvcAccount = $ThisVM.SqlServiceAccount
                $cvDCName     = $deployConfig.parameters.DCName
                Script SetSQLSPNs {
                    DependsOn            = '[WriteStatus]SetSQLSPN'
                    PsDscRunAsCredential = $Admincreds
                    GetScript  = { return @{ Result = (Get-Date).ToString() } }
                    TestScript = [string]"
                        `$spns    = @($cvSPNList)
                        `$account = '$cvSvcAccount'
                        `$dc      = '$cvDCName'
                        `$user = Get-ADUser -Identity `$account -Server `$dc -Properties servicePrincipalName -ErrorAction SilentlyContinue
                        if (-not `$user) { return `$false }
                        foreach (`$s in `$spns) {
                            if (`$user.servicePrincipalName -notcontains `$s) { return `$false }
                        }
                        return `$true
                    "
                    SetScript  = [string]"
                        `$spns    = @($cvSPNList)
                        `$account = '$cvSvcAccount'
                        `$dc      = '$cvDCName'
                        foreach (`$s in `$spns) {
                            # Try adding the SPN directly first — this is a fast
                            # targeted write. Only if it fails with a duplicate
                            # constraint do we scan the directory for the holder.
                            try {
                                Set-ADUser -Identity `$account -Server `$dc -Add @{ servicePrincipalName = `$s } -ErrorAction Stop
                            }
                            catch {
                                if (`$_.Exception.Message -match 'constraint|already exists|duplicate|not unique') {
                                    # SPN is held by another account — find and remove it
                                    `$holder = Get-ADObject -Filter { servicePrincipalName -eq `$s } -Server `$dc -Properties servicePrincipalName -ErrorAction SilentlyContinue
                                    if (`$holder) {
                                        foreach (`$h in `$holder) {
                                            Set-ADObject -Identity `$h -Server `$dc -Remove @{ servicePrincipalName = `$s } -ErrorAction SilentlyContinue
                                        }
                                    }
                                    # Retry the add after clearing
                                    Set-ADUser -Identity `$account -Server `$dc -Add @{ servicePrincipalName = `$s } -ErrorAction Stop
                                }
                                elseif (`$_.Exception.Message -match 'specified value already exists') {
                                    # SPN already on this account — nothing to do
                                }
                                else {
                                    throw
                                }
                            }
                        }
                    "
                }
                $spnDependency += '[Script]SetSQLSPNs'

                # Grant the SQL service account "Write servicePrincipalName" on
                # its own AD object. Without this, SQL Server's startup SPN
                # self-registration fails with 0x2098 (insufficient access) and
                # SQL marks Kerberos as unavailable, falling back to NTLM for
                # ALL inbound connections. We use WriteProperty on the
                # servicePrincipalName attribute (not the validated write, which
                # doesn't work for user service accounts).
                $sqlSvcAccountName = $ThisVM.SqlServiceAccount
                $sqlDCName = $deployConfig.parameters.DCName
                Script GrantSPNWritePermission {
                    GetScript  = { return @{ Result = "N/A" } }
                    TestScript = {
                        try {
                            $user = Get-ADUser -Identity $using:sqlSvcAccountName -Server $using:sqlDCName -ErrorAction Stop
                            $dn = $user.DistinguishedName
                            $acl = Get-Acl "AD:\$dn" -ErrorAction Stop
                            # servicePrincipalName attribute GUID
                            $spnAttrGuid = [Guid]'28630EBB-41D5-11D1-A9C1-0000F80367C1'
                            $sid = $user.SID
                            $hasRight = $acl.Access | Where-Object {
                                $_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]) -eq $sid -and
                                $_.ActiveDirectoryRights -band [System.DirectoryServices.ActiveDirectoryRights]::WriteProperty -and
                                $_.ObjectType -eq $spnAttrGuid -and
                                $_.AccessControlType -eq 'Allow'
                            }
                            return [bool]$hasRight
                        }
                        catch {
                            return $false
                        }
                    }
                    SetScript  = {
                        Import-Module ActiveDirectory -ErrorAction Stop
                        $dc = $using:sqlDCName
                        $user = Get-ADUser -Identity $using:sqlSvcAccountName -Server $dc -ErrorAction Stop
                        $dn = $user.DistinguishedName
                        $acl = Get-Acl "AD:\$dn" -ErrorAction Stop
                        # servicePrincipalName attribute GUID — grants WriteProperty
                        # so SQL Server can self-register SPNs at startup
                        $spnAttrGuid = [Guid]'28630EBB-41D5-11D1-A9C1-0000F80367C1'
                        $sid = New-Object System.Security.Principal.SecurityIdentifier($user.SID)
                        $ace = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
                            $sid,
                            [System.DirectoryServices.ActiveDirectoryRights]::WriteProperty,
                            [System.Security.AccessControl.AccessControlType]::Allow,
                            $spnAttrGuid
                        )
                        $acl.AddAccessRule($ace)
                        Set-Acl "AD:\$dn" $acl -ErrorAction Stop
                    }
                    DependsOn            = $spnDependency
                    PsDscRunAsCredential = $Admincreds
                }
                $spnDependency += '[Script]GrantSPNWritePermission'

                [System.Management.Automation.PSCredential]$sqlUser = New-Object System.Management.Automation.PSCredential ("$($NetBiosDomainName)\$($ThisVM.SqlServiceAccount)", $Admincreds.Password)
                [System.Management.Automation.PSCredential]$sqlAgentUser = New-Object System.Management.Automation.PSCredential ("$($NetBiosDomainName)\$($ThisVM.SqlAgentAccount)", $Admincreds.Password)


                WriteStatus SetSQLUser {
                    DependsOn = $spnDependency
                    Status    = "SQL setting new startup user to $($NetBiosDomainName)\$($ThisVM.SqlServiceAccount)"
                }
                #Change SQL Service Account
                SqlServiceAccount 'SetServiceAccountSQL_User' {
                    ServerName     = $thisvm.VmName
                    InstanceName   = $SQLInstanceName
                    ServiceType    = 'DatabaseEngine'
                    ServiceAccount = $sqlUser
                    RestartService = $true
                    DependsOn      = $spnDependency
                    Force          = $false
                }
                $nextDepend = "[SqlServiceAccount]SetServiceAccountSQL_User"

                if ($ThisVM.SqlAgentAccount -and ($ThisVM.SqlAgentAccount -ne "LocalSystem")) {
                    WriteStatus SetSQLAgentUser {
                        DependsOn = '[SqlServiceAccount]SetServiceAccountSQL_User'
                        Status    = "SQL setting new agent user to $($NetBiosDomainName)\$($ThisVM.SqlAgentAccount)"
                    }
                    #Change SQL Service Account
                    SqlServiceAccount 'SetServiceAccountAgent_User' {
                        ServerName     = $thisvm.VmName
                        InstanceName   = $SQLInstanceName
                        ServiceType    = 'SQLServerAgent'
                        ServiceAccount = $sqlAgentUser
                        RestartService = $true
                        DependsOn      = $nextDepend
                        Force          = $false
                    }

                    $agentName = if ($SQLInstanceName -eq "MSSQLSERVER") { "SQLSERVERAGENT" } else { 'SQLAgent$' + $SQLInstanceName }

                    WriteStatus SetSQLAgentStartup {
                        DependsOn = '[SqlServiceAccount]SetServiceAccountAgent_User', $nextDepend
                        Status    = "Setting $agentName Service to Automatic Start"
                    }
                    Service 'ChangeStartupAgent' {
                        Name        = $agentName
                        StartupType = "Automatic"
                        State       = "Running"
                        DependsOn   = '[SqlServiceAccount]SetServiceAccountAgent_User', $nextDepend
                    }
                    $nextDepend = "[Service]ChangeStartupAgent"
                }

            }
            else {
                WriteStatus ChangeToLocalSystem {
                    DependsOn = $nextDepend
                    Status    = "Configuring SQL services to use LocalSystem"
                }

                ChangeSQLServicesAccount ChangeToLocalSystem {
                    SQLInstanceName = $SQLInstanceName
                    Ensure          = "Present"
                    DependsOn       = $nextDepend
                }
                $nextDepend = '[ChangeSQLServicesAccount]ChangeToLocalSystem'
            }
        }

        # Ola Hallengren MaintenanceSolution requires STRING_AGG (SQL 2017+)
        $skipBackupSolution = $ThisVM.sqlVersion -match '201[0-6]'

        if (-not $skipBackupSolution) {
        WriteStatus DownloadBackupSolution {
            DependsOn = $nextDepend
            Status    = "Downloading '$($backupSolutionURL)'"
        }
        $sqlBackupPath = Join-Path "C:\staging\DSC\SQLScripts" (Split-Path -Path $backupSolutionURL -Leaf)
        $sqlBackupTest = "C:\staging\DSC\SQLScripts\MaintenanceSolution-Test.sql"
        $sqlBackupGet = "C:\staging\DSC\SQLScripts\MaintenanceSolution-Get.sql"

        DownloadFile DownloadBackupSolution {
            DownloadUrl = $backupSolutionURL
            FilePath    = $sqlBackupPath
            Ensure      = "Present"
            DependsOn   = $nextDepend
        }

        WriteStatus InstallBackupSolution {
            DependsOn = '[DownloadFile]DownloadBackupSolution'
            Status    = "Installing '$($backupSolutionURL)'"
        }

        SqlScript 'InstallBackupSolution' {
            Id               = 'InstallBackupSolution'
            ServerName       = $thisvm.VmName
            InstanceName     = $SQLInstanceName
            #Credential       = $Admincreds
            SetFilePath      = $sqlBackupPath
            TestFilePath     = $sqlBackupTest
            GetFilePath      = $sqlBackupGet
            DisableVariables = $true
            DependsOn        = '[DownloadFile]DownloadBackupSolution'
            Variable     = @('FilePath=C:\temp\')
            PsDscRunAsCredential =  $Admincreds
            Encrypt = "Optional"
        }

        $nextDepend = '[SqlScript]InstallBackupSolution'
        }


        $AgentJobSet = "C:\staging\DSC\SQLScripts\Index-AgentJob-Set.sql"
        $AgentJobTest = "C:\staging\DSC\SQLScripts\Index-AgentJob-Test.sql"
        $AgentJobGet = "C:\staging\DSC\SQLScripts\Index-AgentJob-Get.sql"


        WriteStatus InstallAgentJob {
            DependsOn = $nextDepend
            Status    = "Installing Index Agent Job"
        }

        SqlScript 'InstallAgentJob' {
            Id               = 'InstallAgentJob'
            ServerName       = $thisvm.VmName
            InstanceName     = $thisVM.sqlInstanceName
            #Credential       = $Admincreds
            SetFilePath      = $AgentJobSet
            TestFilePath     = $AgentJobTest
            GetFilePath      = $AgentJobGet
            DisableVariables = $true
            DependsOn        = $nextDepend
            Variable     = @('FilePath=C:\temp\')
            PsDscRunAsCredential = $Admincreds
            Encrypt = "Optional"
        }
        $nextDepend = '[SqlScript]InstallAgentJob'

        WriteStatus Complete {
            DependsOn = $nextDepend
            Status    = "Complete!"
        }

    }
}
