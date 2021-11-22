configuration DomainMemberConfiguration
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
    Import-DscResource -ModuleName 'PSDesiredStateConfiguration', 'NetworkingDsc', 'ComputerManagementDsc', 'SqlServerDsc'

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

    $SQLSysAdminAccounts = $deployConfig.thisParams.SQLSysAdminAccounts

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
                Name      = "DPMP"
                Role      = "Distribution Point", "Management Point"
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
            Status    = "Installing .NET 4.7.2"
        }

        InstallDotNet472 DotNet {
            DownloadUrl = "https://download.visualstudio.microsoft.com/download/pr/1f5af042-d0e4-4002-9c59-9ba66bcf15f6/089f837de42708daacaae7c04b7494db/ndp472-kb4054530-x86-x64-allos-enu.exe"
            Ensure      = "Present"
            DependsOn   = "[WriteStatus]InstallDotNet"
        }

        File ShareFolder {
            DestinationPath = $LogPath
            Type            = 'Directory'
            Ensure          = 'Present'
            DependsOn       = '[InstallDotNet472]DotNet'
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

                WriteStatus InstallSQL {
                    DependsOn = '[DownloadFile]DownloadSQLCU'
                    Status    = "Installing '$($ThisVM.sqlVersion)' ($SQLInstanceName instance)"
                }

            }
            else {
                WriteStatus InstallSQL {
                    DependsOn = '[WriteEvent]WriteJoinDomain'
                    Status    = "Installing '$($ThisVM.sqlVersion)' ($SQLInstanceName instance)"
                }
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

            SqlMemory SetSqlMemory {
                DependsOn    = '[SqlSetup]InstallSQL'
                Ensure       = 'Present'
                DynamicAlloc = $false
                MinMemory    = 2048
                MaxMemory    = 6144
                InstanceName = $SQLInstanceName
            }

            if ($containsPassive) {

                WriteStatus WaitPassive {
                    DependsOn = "[SqlMemory]SetSqlMemory"
                    Status    = "Wait for Passive Site Server $($PassiveVM.vmName) to join domain"
                }

                WaitForEvent WaitPassive {
                    MachineName   = $PassiveVM.vmName
                    LogFolder     = $LogFolder
                    ReadNode      = "MachineJoinDomain"
                    ReadNodeValue = "Passed"
                    Ensure        = "Present"
                    DependsOn     = "[WriteStatus]WaitPassive"
                }

                SqlLogin addsysadmin {
                    Ensure                  = 'Present'
                    Name                    = "$DName\$($PassiveVM.vmName)$"
                    LoginType               = 'WindowsUser'
                    InstanceName            = $SQLInstanceName
                    LoginMustChangePassword = $false
                    PsDscRunAsCredential    = $CMAdmin
                    DependsOn               = '[WaitForEvent]WaitPassive'
                }

                SqlRole addsysadmin {
                    Ensure               = 'Present'
                    ServerRoleName       = 'sysadmin'
                    MembersToInclude     = $SQLSysAdminAccounts
                    InstanceName         = $SQLInstanceName
                    PsDscRunAsCredential = $CMAdmin
                    DependsOn            = '[SqlLogin]addsysadmin'
                }

                WriteStatus SSMS {
                    DependsOn = '[SqlRole]addsysadmin'
                    Status    = "Downloading and installing SQL Management Studio"
                }
            }

            else {

                WriteStatus SSMS {
                    DependsOn = '[SqlMemory]SetSqlMemory'
                    Status    = "Downloading and installing SQL Management Studio"
                }

            }

            InstallSSMS SSMS {
                DownloadUrl = "https://aka.ms/ssmsfullsetup"
                Ensure      = "Present"
                DependsOn   = '[SqlMemory]SetSqlMemory'
            }

            WriteStatus ChangeToLocalSystem {
                DependsOn = "[InstallSSMS]SSMS"
                Status    = "Configuring SQL services to use LocalSystem"
            }

            ChangeSqlInstancePort SqlInstancePort {
                SQLInstanceName = $SQLInstanceName
                SQLInstancePort = 2433
                Ensure          = "Present"
                DependsOn       = "[InstallSSMS]SSMS"
            }

            ChangeSQLServicesAccount ChangeToLocalSystem {
                SQLInstanceName = $SQLInstanceName
                Ensure          = "Present"
                DependsOn       = "[ChangeSqlInstancePort]SqlInstancePort"
            }

            WriteStatus AddLocalAdmin {
                DependsOn = "[ChangeSQLServicesAccount]ChangeToLocalSystem"
                Status    = "Adding cm_svc domain account to Local Administrators group"
            }

        }
        else {

            WriteStatus AddLocalAdmin {
                DependsOn = '[WriteEvent]WriteJoinDomain'
                Status    = "Adding cm_svc domain account to Local Administrators group"
            }

        }

        $addUserDependancy = @()
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

        WriteEvent DPMPReady {
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