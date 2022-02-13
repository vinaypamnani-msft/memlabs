﻿configuration DomainMemberConfiguration
{
    param
    (
        [Parameter(Mandatory)]
        [string]$ConfigFilePath,
        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$Admincreds
    )

    Set-ExecutionPolicy -ExecutionPolicy Bypass -Force
    Import-DscResource -ModuleName 'TemplateHelpDSC'
    Import-DscResource -ModuleName 'PSDesiredStateConfiguration', 'NetworkingDsc', 'ComputerManagementDsc', 'SqlServerDsc', 'ActiveDirectoryDsc'

    # Read config
    $deployConfig = Get-Content -Path $ConfigFilePath | ConvertFrom-Json
    $ThisMachineName = $deployConfig.thisParams.MachineName
    $ThisVM = $deployConfig.virtualMachines | Where-Object { $_.vmName -eq $ThisMachineName }
    $DomainName = $deployConfig.parameters.domainName
    $DName = $DomainName.Split(".")[0]
    $DCName = $deployConfig.parameters.DCName
    $DomainAdminName = $deployConfig.vmOptions.adminName

    # Server OS?
    $os = Get-WmiObject -Class Win32_OperatingSystem -ErrorAction SilentlyContinue
    if ($os) {
        $IsServerOS = $true
        if ($os.ProductType -eq 1) {
            $IsServerOS = $false
        }
    }
    else {
        $IsServerOS = $false
    }

    # SQL Setup
    $installSQL = $false
    $sqlUpdateEnabled = $false
    if ($ThisVM.sqlVersion) {
        $installSQL = $true
        $SQLInstanceDir = "C:\Program Files\Microsoft SQL Server"
        $SQLInstanceName = "MSSQLSERVER"
        if ($ThisVM.sqlInstanceDir) {
            $SQLInstanceDir = $ThisVM.sqlInstanceDir
        }
        if ($ThisVM.sqlInstanceName) {
            $SQLInstanceName = $ThisVM.sqlInstanceName
        }
        if ($deployConfig.thisParams.sqlCUURL) {
            $sqlUpdateEnabled = $true
            $sqlCUURL = $deployConfig.thisParams.sqlCUURL
            $sqlCuDownloadPath = Join-Path "C:\Temp\SQL_CU" (Split-Path -Path $sqlCUURL -Leaf)
        }
    }

    # SQL Sysadmin accounts
    $waitOnDomainJoin = $deployconfig.thisParams.WaitOnDomainJoin
    $SQLSysAdminAccounts = $deployConfig.thisParams.SQLSysAdminAccounts

    # Windows Feature to install for role
    $featureRole = @("Distribution Point", "Management Point")

    # SQL AO
    if ($ThisVM.role -eq "SQLAO") {
        $featureRole += "SQLAO"
    }

    # Log share
    $LogFolder = "DSC"
    $LogPath = "c:\staging\$LogFolder"

    # Domain creds
    [System.Management.Automation.PSCredential]$DomainCreds = New-Object System.Management.Automation.PSCredential ("${DomainName}\$($Admincreds.UserName)", $Admincreds.Password)
    [System.Management.Automation.PSCredential]$CMAdmin = New-Object System.Management.Automation.PSCredential ("${DomainName}\$DomainAdminName", $Admincreds.Password)

    Node localhost
    {
        LocalConfigurationManager {
            ConfigurationMode  = 'ApplyOnly'
            RebootNodeIfNeeded = $true
        }

        WriteStatus Rename {
            Status = "Renaming the computer to $ThisMachineName"
        }

        Computer NewName {
            Name = $ThisMachineName
        }

        WriteStatus InitDisks {
            DependsOn = "[Computer]NewName"
            Status    = "Initializing disks"
        }

        InitializeDisks InitDisks {
            DependsOn = "[Computer]NewName"
            DummyKey  = "Dummy"
            VM        = $ThisVM | ConvertTo-Json
        }

        SetCustomPagingFile PagingSettings {
            DependsOn   = "[InitializeDisks]InitDisks"
            Drive       = 'C:'
            InitialSize = '8192'
            MaximumSize = '8192'
        }

        if ($IsServerOS) {

            WriteStatus InstallFeature {
                DependsOn = "[SetCustomPagingFile]PagingSettings"
                Status    = "Installing required windows features"
            }

            InstallFeatureForSCCM InstallFeature {
                Name      = "DummyName"
                Role      = $featureRole
                DependsOn = "[SetCustomPagingFile]PagingSettings"
            }

            WriteStatus WaitDomain {
                DependsOn = "[InstallFeatureForSCCM]InstallFeature"
                Status    = "Waiting for domain to be ready"
            }
        }
        else {
            WriteStatus WaitDomain {
                DependsOn = "[SetCustomPagingFile]PagingSettings"
                Status    = "Waiting for domain to be ready"
            }
        }

        WaitForDomainReady WaitForDomain {
            DependsOn  = "[WriteStatus]WaitDomain"
            Ensure     = "Present"
            DomainName = $DomainName
            DCName     = $DCName
        }

        WriteStatus DomainJoin {
            DependsOn = "[WaitForDomainReady]WaitForDomain"
            Status    = "Joining computer to the domain"
        }

        JoinDomain JoinDomain {
            DomainName = $DomainName
            Credential = $DomainCreds
            DependsOn  = "[WaitForDomainReady]WaitForDomain"
        }

        WriteStatus OpenPorts {
            DependsOn = "[JoinDomain]JoinDomain"
            Status    = "Open required firewall ports"
        }

        AddNtfsPermissions AddNtfsPerms {
            Ensure    = "Present"
            DependsOn = "[JoinDomain]JoinDomain"
        }

        OpenFirewallPortForSCCM OpenFirewall {
            DependsOn = "[AddNtfsPermissions]AddNtfsPerms"
            Name      = "DomainMember"
            Role      = "DomainMember"
        }

        WriteStatus InstallDotNet {
            DependsOn = '[OpenFirewallPortForSCCM]OpenFirewall'
            Status    = "Installing .NET 4.8"
        }

        InstallDotNet4 DotNet {
            DownloadUrl = "https://download.visualstudio.microsoft.com/download/pr/7afca223-55d2-470a-8edc-6a1739ae3252/abd170b4b0ec15ad0222a809b761a036/ndp48-x86-x64-allos-enu.exe"
            FileName    = "ndp48-x86-x64-allos-enu.exe"
            NetVersion  = "528040"
            Ensure      = "Present"
            DependsOn   = "[WriteStatus]InstallDotNet"
        }

        File ShareFolder {
            DestinationPath = $LogPath
            Type            = 'Directory'
            Ensure          = 'Present'
            DependsOn       = '[InstallDotNet4]DotNet'
        }

        FileReadAccessShare DomainSMBShare {
            Name      = $LogFolder
            Path      = $LogPath
            DependsOn = "[File]ShareFolder"
        }

        WriteEvent WriteJoinDomain {
            LogPath   = $LogPath
            WriteNode = "MachineJoinDomain"
            Status    = "Passed"
            Ensure    = "Present"
            DependsOn = "[FileReadAccessShare]DomainSMBShare"
        }

        if ($installSQL) {

            if ($sqlUpdateEnabled) {

                WriteStatus DownloadSQLCU {
                    DependsOn = '[WriteEvent]WriteJoinDomain'
                    Status    = "Downloading CU File for '$($ThisVM.sqlVersion)'"
                }

                DownloadFile DownloadSQLCU {
                    DownloadUrl = $sqlCUURL
                    FilePath    = $sqlCuDownloadPath
                    Ensure      = "Present"
                    DependsOn   = "[WriteStatus]DownloadSQLCU"

                }

                WriteStatus WaitDomainJoin {
                    DependsOn = "[DownloadFile]DownloadSQLCU"
                    Status    = "Waiting for $($waitOnDomainJoin -join ',') to join the domain"
                }

            }
            else {
                WriteStatus WaitDomainJoin {
                    DependsOn = '[WriteEvent]WriteJoinDomain'
                    Status    = "Waiting for $($waitOnDomainJoin -join ',') to join the domain"
                }
            }

            $waitOnDependency = @('[WriteStatus]WaitDomainJoin')
            foreach ($server in $waitOnDomainJoin) {

                VerifyComputerJoinDomain "WaitFor$server" {
                    ComputerName = $server
                    Ensure       = "Present"
                    DependsOn    = "[WriteStatus]WaitDomainJoin"
                }

                $waitOnDependency += "[VerifyComputerJoinDomain]WaitFor$server"
            }

            WriteStatus InstallSQL {
                DependsOn = $waitOnDependency
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

                 # Add roles explicitly, for re-runs to make sure new accounts are added as sysadmin
                 $spnDependency = @("[Service]ChangeStartupAgent")
                 $i = 0
                 foreach ($spn in $SPNs ) {
                     $i++

                  #   ADServicePrincipalName "spnset$i" {
                  #       Ensure               = 'present'
                  #       ServicePrincipalName = $spn
                  #       Account              = $ThisVM.SqlServiceAccount
                  #       Dependson            = "[Service]ChangeStartupAgent"
                  #       PsDscRunAsCredential = $CMAdmin
                  #   }

                  #   $spnDependency += "[ADServicePrincipalName]spnset$i"
                 }

                $nextDepend = $spnDependency
            }

            WriteStatus SSMS {
                DependsOn = $nextDepend
                Status    = "Downloading and installing SQL Management Studio"
            }

            InstallSSMS SSMS {
                DownloadUrl = "https://aka.ms/ssmsfullsetup"
                Ensure      = "Present"
                DependsOn   = $nextDepend
            }


            $nextDepend = "[InstallSSMS]SSMS"
            if (-not $ThisVM.SqlServiceAccount) {

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

        }
        else {

            WriteStatus AddLocalAdmin {
                DependsOn = '[WriteEvent]WriteJoinDomain'
                Status    = "Adding cm_svc domain account to Local Administrators group"
            }

        }

        $addUserDependancy = @('[WriteStatus]AddLocalAdmin')
        $i = 0
        foreach ($user in $deployConfig.thisParams.LocalAdminAccounts) {
            $i++
            $NodeName = "AddADUserToLocalAdminGroup$($i)"
            AddUserToLocalAdminGroup "$NodeName" {
                Name       = $user
                DomainName = $DomainName
                DependsOn  = "[WriteStatus]AddLocalAdmin"
            }
            $addUserDependancy += "[AddUserToLocalAdminGroup]$NodeName"
        }

        WriteStatus Complete {
            DependsOn = $addUserDependancy
            Status    = "Complete!"
        }

        WriteEvent ReadyForPrimary {
            LogPath   = $LogPath
            WriteNode = "ReadyForPrimary"
            Status    = "Passed"
            Ensure    = "Present"
            DependsOn = "[WriteStatus]Complete"
        }

        WriteEvent WriteConfigFinished {
            LogPath   = $LogPath
            WriteNode = "ConfigurationFinished"
            Status    = "Passed"
            Ensure    = "Present"
            DependsOn = "[WriteStatus]Complete"
        }
    }
}