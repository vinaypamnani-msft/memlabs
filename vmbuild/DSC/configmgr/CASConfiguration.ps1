configuration CASConfiguration
{
    param
    (
        [Parameter(Mandatory)]
        [string]$ConfigFilePath,
        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$Admincreds
    )

    Import-DscResource -ModuleName 'TemplateHelpDSC'
    Import-DscResource -ModuleName 'PSDesiredStateConfiguration', 'NetworkingDsc', 'ComputerManagementDsc', 'SqlServerDsc'

    # Read config
    $deployConfig = Get-Content -Path $ConfigFilePath | ConvertFrom-Json
    $ThisMachineName = $deployConfig.parameters.ThisMachineName
    $ThisVM = $deployConfig.virtualMachines | Where-Object { $_.vmName -eq $ThisMachineName }
    $DomainName = $deployConfig.parameters.domainName
    $DName = $DomainName.Split(".")[0]
    $DCName = $deployConfig.parameters.DCName
    $PSName = $deployConfig.parameters.PSName
    $PrimarySiteName = "$PSName$"

    # Domain Admin User name
    $DomainAdminName = $deployConfig.vmOptions.adminName
    $cm_admin = "$DNAME\$DomainAdminName"

    # CM Options
    $InstallConfigMgr = $deployConfig.cmOptions.install

    # SQL Instance Location
    if ($ThisVM.remoteSQLVM) {
        $installSQL = $false
    }
    else {
        # SQL Instance Location
        $installSQL = $true
        $sqlUpdateEnabled = $false
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

    # Passive Site Server
    $SQLSysAdminAccounts = $deployConfig.thisParams.SQLSysAdminAccounts

    # Log share
    $LogFolder = "DSC"
    $LogPath = "c:\staging\$LogFolder"

    # CM Files folder/share
    $CM = if ($deployConfig.cmOptions.version -eq "tech-preview") { "CMTP" } else { "CMCB" }

    # ConfigMgr Display version
    if ($CM -eq "CMTP") {
        $CMDownloadStatus = "Downloading Configuration Manager technical preview"
    }
    else {
        $CMDownloadStatus = "Downloading Configuration Manager current branch (latest baseline version)"
    }

    $CurrentRole = "CAS"


    [System.Management.Automation.PSCredential]$DomainCreds = New-Object System.Management.Automation.PSCredential ("${DomainName}\$($Admincreds.UserName)", $Admincreds.Password)
    [System.Management.Automation.PSCredential]$CMAdmin = New-Object System.Management.Automation.PSCredential ("${DomainName}\$DomainAdminName", $Admincreds.Password)

    Node LOCALHOST
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

        WriteStatus InstallFeature {
            DependsOn = "[SetCustomPagingFile]PagingSettings"
            Status    = "Installing required windows features"
        }

        InstallFeatureForSCCM InstallFeature {
            NAME      = $CurrentRole
            Role      = "Site Server"
            DependsOn = "[SetCustomPagingFile]PagingSettings"
        }

        WriteStatus WaitDomain {
            DependsOn = "[InstallFeatureForSCCM]InstallFeature"
            Status    = "Waiting for domain to be ready"
        }

        WaitForDomainReady WaitForDomain {
            Ensure     = "Present"
            DomainName = $DomainName
            DCName     = $DCName
            DependsOn  = "[InstallFeatureForSCCM]InstallFeature"
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
            Name      = $CurrentRole
            Role      = "Site Server"
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

        WriteStatus ADKInstall {
            DependsOn = "[WriteEvent]WriteJoinDomain"
            Status    = "Downloading and installing ADK"
        }

        InstallADK ADKInstall {
            ADKPath      = "C:\temp\adksetup.exe"
            ADKWinPEPath = "c:\temp\adksetupwinpe.exe"
            Ensure       = "Present"
            DependsOn    = "[OpenFirewallPortForSCCM]OpenFirewall"
        }

        if ($installSQL) {

            if ($sqlUpdateEnabled) {

                WriteStatus DownloadSQLCU {
                    DependsOn = '[InstallADK]ADKInstall'
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
                    DependsOn = '[InstallADK]ADKInstall'
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

            WriteStatus ChangeToLocalSystem {
                DependsOn = "[SqlMemory]SetSqlMemory"
                Status    = "Configuring SQL services to use LocalSystem"
            }

            ChangeSqlInstancePort SqlInstancePort {
                SQLInstanceName = $SQLInstanceName
                SQLInstancePort = 2433
                Ensure          = "Present"
                DependsOn       = "[SqlMemory]SetSqlMemory"
            }

            ChangeSQLServicesAccount ChangeToLocalSystem {
                SQLInstanceName = $SQLInstanceName
                Ensure          = "Present"
                DependsOn       = "[ChangeSqlInstancePort]SqlInstancePort"
            }

            WriteStatus SSMS {
                DependsOn = "[ChangeSQLServicesAccount]ChangeToLocalSystem"
                Status    = "Downloading and installing SQL Management Studio"
            }

        }
        else {

            WriteStatus SSMS {
                DependsOn = '[InstallADK]ADKInstall'
                Status    = "Downloading and installing SQL Management Studio"
            }

        }

        InstallSSMS SSMS {
            DownloadUrl = "https://aka.ms/ssmsfullsetup"
            Ensure      = "Present"
            DependsOn   = "[WriteStatus]SSMS"
        }

        WriteStatus DownLoadSCCM {
            DependsOn = "[InstallSSMS]SSMS"
            Status    = $CMDownloadStatus
        }

        DownloadSCCM DownLoadSCCM {
            CM        = $CM
            Ensure    = "Present"
            DependsOn = "[WriteStatus]DownLoadSCCM"
        }

        if ($PSName) {
            WriteStatus WaitPSJoinDomain {
                DependsOn = "[DownloadSCCM]DownLoadSCCM"
                Status    = "Wait for $PSName to join domain"
            }

            WaitForEvent WaitPSJoinDomain {
                MachineName   = $PSName
                LogFolder     = $LogFolder
                ReadNode      = "MachineJoinDomain"
                ReadNodeValue = "Passed"
                Ensure        = "Present"
                DependsOn     = "[DownloadSCCM]DownLoadSCCM"
            }

            #AddUserToLocalAdminGroup AddUserToLocalAdminGroup {
            #    Name       = $PrimarySiteName
            #    DomainName = $DomainName
            #    DependsOn  = "[WaitForEvent]WaitPSJoinDomain"
            #}
            $addUserDependancy = @()
            foreach ($user in $deployConfig.thisParams.LocalAdminAccounts) {

                AddUserToLocalAdminGroup "AddADUserToLocalAdminGroup$user" {
                    Name       = $user
                    DomainName = $DomainName
                    DependsOn  = "[WaitForEvent]WaitPSJoinDomain"
                }
                $addUserDependancy += "[AddUserToLocalAdminGroup]AddADUserToLocalAdminGroup$user"
            }

            FileReadAccessShare CMSourceSMBShare {
                Name      = $CM
                Path      = "c:\$CM"
                DependsOn = $addUserDependancy
            }
        }
        else {

            FileReadAccessShare CMSourceSMBShare {
                Name      = $CM
                Path      = "c:\$CM"
                DependsOn = "[DownloadSCCM]DownLoadSCCM"
            }

        }

        # There's a passive site server in config
        if ($containsPassive) {

            WriteStatus WaitPassive {
                DependsOn = "[FileReadAccessShare]CMSourceSMBShare"
                Status    = "Wait for Passive Site Server $($PassiveVM.vmName) to be ready"
            }

            WaitForEvent WaitPassive {
                MachineName   = $PassiveVM.vmName
                LogFolder     = $LogFolder
                ReadNode      = "PassiveReady"
                ReadNodeValue = "Passed"
                Ensure        = "Present"
                DependsOn     = "[WriteStatus]WaitPassive"
            }

            if ($installSQL) {

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

                WriteStatus WaitDelegate {
                    DependsOn = "[SqlRole]addsysadmin"
                    Status    = "Wait for DC to assign permissions to Systems Management container"
                }
            }
            else {

                WriteStatus WaitDelegate {
                    DependsOn = "[FileReadAccessShare]CMSourceSMBShare"
                    Status    = "Wait for DC to assign permissions to Systems Management container"
                }

            }
        }
        else {

            WriteStatus WaitDelegate {
                DependsOn = "[FileReadAccessShare]CMSourceSMBShare"
                Status    = "Wait for DC to assign permissions to Systems Management container"
            }

        }

        WaitForEvent DelegateControl {
            MachineName   = $DCName
            LogFolder     = $LogFolder
            ReadNode      = "DelegateControl"
            ReadNodeValue = "Passed"
            Ensure        = "Present"
            DependsOn     = "[WriteStatus]WaitDelegate"
        }

        if ($InstallConfigMgr) {

            if ($installSQL) {

                WriteStatus RunScriptWorkflow {
                    DependsOn = "[WaitForEvent]DelegateControl"
                    Status    = "Setting up ConfigMgr. Waiting for workflow to begin."
                }

            }
            else {

                # Wait for SQLVM
                WriteStatus WaitSQL {
                    DependsOn = "[WaitForEvent]DelegateControl"
                    Status    = "Waiting for remote SQL VM $($ThisVM.remoteSQLVM) to finish configuration."
                }

                WaitForEvent WaitSQL {
                    MachineName   = $ThisVM.remoteSQLVM
                    LogFolder     = $LogFolder
                    ReadNode      = "ConfigurationFinished"
                    ReadNodeValue = "Passed"
                    Ensure        = "Present"
                    DependsOn     = "[WaitForEvent]DelegateControl"
                }

                WriteStatus RunScriptWorkflow {
                    DependsOn = "[WaitForEvent]WaitSQL"
                    Status    = "Setting up ConfigMgr. Waiting for workflow to begin."
                }

            }

            RegisterTaskScheduler RunScriptWorkflow {
                TaskName       = "ScriptWorkFlow"
                ScriptName     = "ScriptWorkFlow.ps1"
                ScriptPath     = $PSScriptRoot
                ScriptArgument = "$ConfigFilePath $LogPath"
                AdminCreds     = $CMAdmin
                Ensure         = "Present"
                DependsOn      = "[WriteStatus]RunScriptWorkflow"
            }

            WaitForEvent WorkflowComplete {
                FileName      = "ScriptWorkflow"
                MachineName   = $ThisMachineName
                LogFolder     = $LogFolder
                ReadNode      = "ScriptWorkflow"
                ReadNodeValue = "Completed"
                Ensure        = "Present"
                DependsOn     = "[RegisterTaskScheduler]RunScriptWorkflow"
            }

            WriteStatus Complete {
                DependsOn = "[WaitForEvent]WorkflowComplete"
                Status    = "Complete!"
            }

        }

        else {
            WriteStatus Complete {
                DependsOn = "[ChangeSQLServicesAccount]ChangeToLocalSystem"
                Status    = "Complete!"
            }
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