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
    Import-DscResource -ModuleName 'PSDesiredStateConfiguration', 'ComputerManagementDsc', 'SqlServerDsc', 'ActiveDirectoryDsc'

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
        WriteStatus SQLInstallStarted {
            Status = "Preparing to Install SQL '$($ThisVM.sqlVersion)'"
        }

        ModuleAdd SQLServerModule {
            Key             = 'Always'
            CheckModuleName = 'SqlServer'
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

            # The host mounts the SQL ISO to this VM's DVD drive before Phase 4.
            # Assign it the deterministic letter S: so SqlSetup -SourcePath is
            # stable (raw CD-ROM letters float, and a reboot happened above).
            Script AssignSqlIsoDriveLetter {
                GetScript  = { @{ Result = '' } }
                TestScript = { Test-Path 'S:\setup.exe' }
                SetScript  = {
                    # Find the optical volume holding the SQL media (setup.exe at
                    # its root) and relabel it S:. DriveType 5 = CD-ROM, which is
                    # how a mounted ISO presents.
                    $assigned = $false
                    foreach ($vol in (Get-CimInstance -ClassName Win32_Volume -Filter 'DriveType = 5' -ErrorAction SilentlyContinue)) {
                        if (-not $vol.DriveLetter) { continue }
                        if (Test-Path (Join-Path "$($vol.DriveLetter)\" 'setup.exe')) {
                            if ($vol.DriveLetter -ne 'S:') {
                                $vol.DriveLetter = 'S:'
                                Set-CimInstance -InputObject $vol -ErrorAction Stop
                            }
                            $assigned = $true
                            break
                        }
                    }
                    if (-not $assigned) {
                        throw "SQL ISO not found on any CD-ROM volume (expected setup.exe at the optical drive root). The host should have mounted it before Phase 4."
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

        # Add roles explicitly, for re-runs to make sure new accounts are added as sysadmin
        $sqlDependency = @('[WriteStatus]AddSQLPermissions')
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
