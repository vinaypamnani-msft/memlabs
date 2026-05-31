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

<<<<<<< Updated upstream
=======
            # Ensure sqlncli.msi is present at the Windows Installer registered
            # source path so the CU can patch the SQL Native Client (error 1706).
            # The MSI may be absent because:
            #  - It was baked into the base image and never downloaded on this VM
            #  - Compact-Disks purged C:\temp\*.msi and C:\Windows\Temp\*
            #  - Phase3 skipped the download because the registry showed installed
            # Copy from the SQL media to both possible registered source paths.
            Script RestoreSqlNcliSource {
                GetScript  = { @{ Result = (Test-Path 'C:\temp\sqlncli.msi') -and (Test-Path 'C:\Windows\Temp\sqlncli.msi') } }
                TestScript = { (Test-Path 'C:\temp\sqlncli.msi') -and (Test-Path 'C:\Windows\Temp\sqlncli.msi') }
                SetScript  = {
                    $ncli = Get-ChildItem 'C:\temp\SQL' -Recurse -Filter 'sqlncli.msi' -ErrorAction SilentlyContinue | Select-Object -First 1
                    if ($ncli) {
                        foreach ($dir in @('C:\temp', 'C:\Windows\Temp')) {
                            if (-not (Test-Path "$dir\sqlncli.msi")) {
                                Copy-Item $ncli.FullName "$dir\sqlncli.msi" -Force
                            }
                        }
                    }
                }
                DependsOn  = $nextDepend
            }
            $nextDepend = '[Script]RestoreSqlNcliSource'
>>>>>>> Stashed changes

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
                SourcePath          = 'C:\temp\SQL'
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
                $i = 0

                WriteStatus SetSQLSPN {
                    DependsOn = $nextDepend
                    Status    = "Updating SQL SPNs ($($SPNs -join ",")) for $($ThisVM.SqlServiceAccount)"
                }

                foreach ($spn in $SPNs ) {
                    $i++

                    ADServicePrincipalName "spn$i" {
                        Ensure               = 'Present'
                        ServicePrincipalName = $spn
                        Account              = $ThisVM.SqlServiceAccount
                        DependsOn            = $nextDepend
                        PsDscRunAsCredential = $Admincreds
                    }

                    $spnDependency += "[ADServicePrincipalName]spn$i"
                }

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
