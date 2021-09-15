configuration PSConfiguration
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
    $cm_admin = "$DNAME\admin"
    $DCName = $deployConfig.parameters.DCName
    $Configuration = $deployConfig.parameters.Scenario

    # CM Options
    $InstallConfigMgr = $deployConfig.cmOptions.install

    # SQL Instance Location
    $SQLInstanceDir = "C:\Program Files\Microsoft SQL Server"
    if ($ThisVM.sqlInstanceDir) { $SQLInstanceDir = $ThisVM.sqlInstanceDir }

    # Log share
    $LogFolder = "DSC"
    $LogPath = "c:\staging\$LogFolder"

    # CM Files folder/share
    $CM = if ($deployConfig.cmOptions.version -eq "tech-preview") { "CMTP" } else { "CMCB" }

    # Domain creds
    [System.Management.Automation.PSCredential]$DomainCreds = New-Object System.Management.Automation.PSCredential ("${DomainName}\$($Admincreds.UserName)", $Admincreds.Password)
    [System.Management.Automation.PSCredential]$CMAdmin = New-Object System.Management.Automation.PSCredential ("${DomainName}\admin", $Admincreds.Password)

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
            NAME      = "PS"
            Role      = "Site Server"
            DependsOn = "[SetCustomPagingFile]PagingSettings"
        }

        WriteStatus WaitDomain {
            DependsOn = "[InstallFeatureForSCCM]InstallFeature"
            Status    = "Waiting for domain to be ready to obtain an IP"
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

        OpenFirewallPortForSCCM OpenFirewall {
            DependsOn = "[JoinDomain]JoinDomain"
            Name      = "PS"
            Role      = "Site Server"
        }

        WriteStatus ADKInstall {
            DependsOn = "[OpenFirewallPortForSCCM]OpenFirewall"
            Status    = "Downloading and installing ADK"
        }

        InstallADK ADKInstall {
            ADKPath      = "C:\temp\adksetup.exe"
            ADKWinPEPath = "c:\temp\adksetupwinpe.exe"
            Ensure       = "Present"
            DependsOn    = "[OpenFirewallPortForSCCM]OpenFirewall"
        }

        WriteStatus InstallSQL {
            DependsOn = '[InstallADK]ADKInstall'
            Status    = "Installing SQL Server (default instance)"
        }

        SqlSetup InstallSQL {
            InstanceName        = 'MSSQLSERVER'
            InstanceDir         = $SQLInstanceDir
            SQLCollation        = 'SQL_Latin1_General_CP1_CI_AS'
            Features            = 'SQLENGINE,CONN,BC'
            SourcePath          = 'C:\temp\SQL'
            UpdateEnabled       = 'True'
            UpdateSource        = "C:\temp\SQL_CU"
            SQLSysAdminAccounts = @('Administrators', $cm_admin)
            TcpEnabled          = $true
            UseEnglish          = $true
            DependsOn           = '[InstallADK]ADKInstall'
        }

        SqlMemory SetSqlMemory {
            DependsOn    = '[SqlSetup]InstallSQL'
            Ensure       = 'Present'
            DynamicAlloc = $false
            MinMemory    = 2048
            MaxMemory    = 8192
            InstanceName = 'MSSQLSERVER'
        }

        WriteStatus SSMS {
            DependsOn = '[SqlMemory]SetSqlMemory'
            Status    = "Downloading and installing SQL Management Studio"
        }

        InstallSSMS SSMS {
            DownloadUrl = "https://aka.ms/ssmsfullsetup"
            Ensure      = "Present"
            DependsOn   = '[SqlMemory]SetSqlMemory'
        }

        File ShareFolder {
            DestinationPath = $LogPath
            Type            = 'Directory'
            Ensure          = 'Present'
            DependsOn       = "[InstallSSMS]SSMS"
        }

        if ($Configuration -eq "Standalone") {

            WriteStatus DownLoadSCCM {
                DependsOn = "[File]ShareFolder"
                Status    = "Downloading Configuration Manager current branch (latest baseline version)"
            }

            DownloadSCCM DownLoadSCCM {
                CM        = $CM
                Ensure    = "Present"
                DependsOn = "[InstallADK]ADKInstall"
            }

            FileReadAccessShare CMSourceSMBShare {
                Name      = $CM
                Path      = "c:\$CM"
                DependsOn = "[DownloadSCCM]DownLoadSCCM"
            }

            FileReadAccessShare DomainSMBShare {
                Name      = $LogFolder
                Path      = $LogPath
                DependsOn = "[FileReadAccessShare]CMSourceSMBShare"
            }

        }
        else {
            # Hierarchy

            WriteStatus WaitCS {
                DependsOn = "[File]ShareFolder"
                Status    = "Waiting for CS Server to join domain"
            }

            WaitForConfigurationFile WaitCSJoinDomain {
                Role          = "DC"
                MachineName   = $DCName
                LogFolder     = $LogFolder
                ReadNode      = "CSJoinDomain"
                ReadNodeValue = "Passed"
                Ensure        = "Present"
                DependsOn     = "[File]ShareFolder"
            }

            FileReadAccessShare DomainSMBShare {
                Name      = $LogFolder
                Path      = $LogPath
                DependsOn = "[WaitForConfigurationFile]WaitCSJoinDomain"
            }

        }

        WriteStatus WaitDelegate {
            DependsOn = "[FileReadAccessShare]DomainSMBShare"
            Status    = "Verifying Systems Management container and SQL permissions"
        }

        WaitForConfigurationFile DelegateControl {
            Role          = "DC"
            MachineName   = $DCName
            LogFolder     = $LogFolder
            ReadNode      = "DelegateControl"
            ReadNodeValue = "Passed"
            Ensure        = "Present"
            DependsOn     = "[FileReadAccessShare]DomainSMBShare"
        }

        AddBuiltinPermission AddSQLPermission {
            Ensure    = "Present"
            DependsOn = "[WaitForConfigurationFile]DelegateControl"
        }

        ChangeSQLServicesAccount ChangeToLocalSystem {
            SQLInstanceName = "MSSQLSERVER"
            Ensure          = "Present"
            DependsOn       = "[AddBuiltinPermission]AddSQLPermission"
        }

        if ($InstallConfigMgr) {

            WriteStatus InstallAndUpdateSCCM {
                DependsOn = "[ChangeSQLServicesAccount]ChangeToLocalSystem"
                Status    = "Setting up ConfigMgr. Waiting for installation to begin."
            }

            if ($Configuration -eq "Standalone") {

                WriteFileOnce CMSvc {
                    FilePath  = "$LogPath\cm_svc.txt"
                    Content   = $Admincreds.GetNetworkCredential().Password
                    DependsOn = "[ChangeSQLServicesAccount]ChangeToLocalSystem"
                }

                RegisterTaskScheduler InstallAndUpdateSCCM {
                    TaskName       = "ScriptWorkFlow"
                    ScriptName     = "ScriptWorkFlow.ps1"
                    ScriptPath     = $PSScriptRoot
                    ScriptArgument = "$ConfigFilePath $LogPath"
                    AdminCreds     = $CMAdmin
                    Ensure         = "Present"
                    DependsOn      = "[WriteFileOnce]CMSvc"
                }

            }
            else {

                RegisterTaskScheduler InstallAndUpdateSCCM {
                    TaskName       = "ScriptWorkFlow"
                    ScriptName     = "ScriptWorkFlow.ps1"
                    ScriptPath     = $PSScriptRoot
                    ScriptArgument = "$ConfigFilePath $LogPath"
                    AdminCreds     = $CMAdmin
                    Ensure         = "Present"
                    DependsOn      = "[ChangeSQLServicesAccount]ChangeToLocalSystem"
                }

            }

            WaitForConfigurationFile WorkflowComplete {
                Role          = "ScriptWorkflow"
                MachineName   = $ThisMachineName
                LogFolder     = $LogFolder
                ReadNode      = "ScriptWorkflow"
                ReadNodeValue = "Completed"
                Ensure        = "Present"
                DependsOn     = "[RegisterTaskScheduler]InstallAndUpdateSCCM"
            }

            WriteStatus Complete {
                DependsOn = "[WaitForConfigurationFile]WorkflowComplete"
                Status    = "Complete!"
            }

        }
        else {

            WriteStatus Complete {
                DependsOn = "[ChangeSQLServicesAccount]ChangeToLocalSystem"
                Status    = "Complete!"
            }

        }
    }
}