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
    Import-DscResource -ModuleName 'PSDesiredStateConfiguration', 'ComputerManagementDsc'

    # Read deployConfig
    $deployConfig = Get-Content -Path $DeployConfigPath | ConvertFrom-Json
    $DomainName = $deployConfig.parameters.domainName

    $SQLInstanceDir = "C:\Program Files\Microsoft SQL Server"
    $SQLInstanceName = "MSSQLSERVER"
    $sqlUpdateEnabled = $false


    Node $AllNodes.NodeName
    {
        $ThisVM = $deployConfig.virtualMachines | Where-Object { $_.vmName -eq $node.NodeName }


        # SQL Setup



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
        WriteStatus SQLInstallStarted {
            Status = "Preparing to Install SQL '$($ThisVM.sqlVersion)'"
        }

        $nextDepend = '[WriteStatus]SQLInstallStarted'
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


        WriteStatus InstallSQL {
            DependsOn = $nextDepend
            Status    = "Installing '$($ThisVM.sqlVersion)' ($SQLInstanceName instance)"
        }

        SqlSetup InstallSQL {
            InstanceName        = $SQLInstanceName
            InstanceDir         = $SQLInstanceDir
            SQLCollation        = 'SQL_Latin1_General_CP1_CI_AS'
            Features            = 'SQLENGINE,CONN,BC'
            SourcePath          = 'C:\temp\SQL'
            UpdateEnabled       = $sqlUpdateEnabled
            UpdateSource        = "C:\temp\SQL_CU"
            SQLSysAdminAccounts = $SQLSysAdminAccounts
            TcpEnabled          = $true
            UseEnglish          = $true
            DependsOn           = '[WriteStatus]InstallSQL'
        }

        WriteStatus AddSQLPermissions {
            DependsOn = "[SqlSetup]InstallSQL"
            Status    = "Adding SQL logins and roles"
        }

        # Add roles explicitly, for re-runs to make sure new accounts are added as sysadmin
        $sqlDependency = @('[WriteStatus]AddSQLPermissions')
        $i = 0
        foreach ($account in $SQLSysAdminAccounts | Where-Object { $_ -notlike "BUILTIN*" } ) {
            $i++

            SqlLogin "AddSqlLogin$i" {
                Ensure                  = 'Present'
                Name                    = $account
                LoginType               = 'WindowsUser'
                InstanceName            = $SQLInstanceName
                LoginMustChangePassword = $false
                PsDscRunAsCredential    = $CMAdmin
                DependsOn               = '[WriteStatus]AddSQLPermissions'
            }

            $sqlDependency += "[SqlLogin]AddSqlLogin$i"
        }

        SqlRole SqlRole {
            Ensure               = 'Present'
            ServerRoleName       = 'sysadmin'
            MembersToInclude     = $SQLSysAdminAccounts
            InstanceName         = $SQLInstanceName
            PsDscRunAsCredential = $CMAdmin
            DependsOn            = $sqlDependency
        }

        SqlMemory SetSqlMemory {
            DependsOn    = '[SqlRole]SqlRole'
            Ensure       = 'Present'
            DynamicAlloc = $false
            MinMemory    = 2048
            MaxMemory    = 6144
            InstanceName = $SQLInstanceName
        }

        ChangeSqlInstancePort SqlInstancePort {
            SQLInstanceName = $SQLInstanceName
            SQLInstancePort = 2433
            Ensure          = "Present"
            DependsOn       = "[SqlMemory]SetSqlMemory"
        }

        $nextDepend = '[ChangeSqlInstancePort]SqlInstancePort'
        if ($ThisVM.SqlServiceAccount) {

            WriteStatus SetSQLSPN {
                DependsOn = $nextDepend
                Status    = "SQL setting new startup user to ${DName}\$($ThisVM.SqlServiceAccount)"
            }


            $SPNs = @()
            $SPNs += "MSSQLSvc/" + $thisvm.VmName
            $SPNs += "MSSQLSvc/" + $thisvm.VmName + "." + $DomainName
            if ($SQLInstanceName -eq "MSSQLSERVER") {
                $port = "1433"
            }
            else {
                $port = "2433"
                $SPNs += "MSSQLSvc/" + $thisvm.VmName + ":" + $SQLInstanceName
                $SPNs += "MSSQLSvc/" + $thisvm.VmName + "." + $DomainName + ":" + $SQLInstanceName

            }
            $SPNs += "MSSQLSvc/" + $thisvm.VmName + ":" + $port
            $SPNs += "MSSQLSvc/" + $thisvm.VmName + "." + $DomainName + ":" + $port



            # Add roles explicitly, for re-runs to make sure new accounts are added as sysadmin
            $spnDependency = @($nextDepend)
            $i = 0
            foreach ($spn in $SPNs ) {
                $i++

                ADServicePrincipalName "spn$i" {
                    Ensure               = 'Absent'
                    ServicePrincipalName = $spn
                    Account              = $thisvm.VmName + "$"
                    Dependson            = $nextDepend
                    PsDscRunAsCredential = $CMAdmin
                }

                $spnDependency += "[ADServicePrincipalName]spn$i"
            }


            [System.Management.Automation.PSCredential]$sqlUser = New-Object System.Management.Automation.PSCredential ("${DName}\$($ThisVM.SqlServiceAccount)", $Admincreds.Password)
            [System.Management.Automation.PSCredential]$sqlAgentUser = New-Object System.Management.Automation.PSCredential ("${DName}\$($ThisVM.SqlAgentAccount)", $Admincreds.Password)

            #Change SQL Service Account
            SqlServiceAccount 'SetServiceAccountSQL_User' {
                ServerName           = $thisvm.VmName
                InstanceName         = $SQLInstanceName
                ServiceType          = 'DatabaseEngine'
                ServiceAccount       = $sqlUser
                RestartService       = $true
                DependsOn            = $spnDependency
                PsDscRunAsCredential = $CMAdmin
                Force                = $true
            }

            #Change SQL Service Account
            SqlServiceAccount 'SetServiceAccountAgent_User' {
                ServerName           = $thisvm.VmName
                InstanceName         = $SQLInstanceName
                ServiceType          = 'SQLServerAgent'
                ServiceAccount       = $sqlAgentUser
                RestartService       = $true
                PsDscRunAsCredential = $CMAdmin
                DependsOn            = '[SqlServiceAccount]SetServiceAccountSQL_User'
            }

            $agentName = if ($SQLInstanceName -eq "MSSQLSERVER") { "SQLSERVERAGENT" } else { 'SQLAgent$' + $SQLInstanceName }
            Service 'ChangeStartupAgent' {
                Name                 = $agentName
                StartupType          = "Automatic"
                State                = "Running"
                DependsOn            = '[SqlServiceAccount]SetServiceAccountAgent_User', $nextDepend
                PsDscRunAsCredential = $CMAdmin
            }
            $nextDepend = "[Service]ChangeStartupAgent"

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

        WriteStatus AddLocalAdmin {
            DependsOn = $nextDepend
            Status    = "Adding cm_svc domain account to Local Administrators group"
        }

        WriteStatus Complete {
            DependsOn = "[WriteStatus]AddLocalAdmin"
            Status    = "Complete!"
        }

    }
}


