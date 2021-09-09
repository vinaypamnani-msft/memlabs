configuration PSConfiguration
{
    param
    (
        [Parameter(Mandatory)]
        [String]$DomainName,
        [Parameter(Mandatory)]
        [String]$DCName,
        [Parameter(Mandatory)]
        [String]$DPMPName,
        [Parameter(Mandatory)]
        [String]$CSName,
        [Parameter(Mandatory)]
        [String]$PSName,
        [Parameter(Mandatory)]
        [System.Array]$ClientName,
        [Parameter(Mandatory)]
        [String]$Configuration,
        [Parameter(Mandatory)]
        [String]$DNSIPAddress,
        [Parameter(Mandatory)]
        [String]$DefaultGateway,
        [Parameter(Mandatory)]
        [String]$DHCPScopeId,
        [Parameter(Mandatory)]
        [String]$DHCPScopeStart,
        [Parameter(Mandatory)]
        [String]$DHCPScopeEnd,
        [Parameter(Mandatory)]
        [bool]$InstallConfigMgr = $true,
        [Parameter(Mandatory)]
        [bool]$UpdateToLatest = $true,
        [Parameter(Mandatory)]
        [bool]$PushClients = $true,
        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$Admincreds
    )

    Import-DscResource -ModuleName 'TemplateHelpDSC'
    Import-DscResource -ModuleName 'PSDesiredStateConfiguration', 'NetworkingDsc', 'ComputerManagementDsc', 'SqlServerDsc'

    $LogFolder = "DSC"
    $LogPath = "c:\staging\$LogFolder"
    $CM = "CMCB"

    $DName = $DomainName.Split(".")[0]
    $CurrentRole = "PS"

    $Clients = [system.String]::Join(",", $ClientName)

    [System.Management.Automation.PSCredential]$DomainCreds = New-Object System.Management.Automation.PSCredential ("${DomainName}\$($Admincreds.UserName)", $Admincreds.Password)

    Node LOCALHOST
    {
        LocalConfigurationManager {
            ConfigurationMode  = 'ApplyOnly'
            RebootNodeIfNeeded = $true
        }

        WriteStatus Rename {
            Status = "Renaming the computer to $PSName"
        }

        Computer NewName {
            Name = $PSName
        }

        SetCustomPagingFile PagingSettings {
            DependsOn   = "[Computer]NewName"
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
            Features            = 'SQLENGINE,CONN,BC'
            SourcePath          = 'C:\temp\SQL'
            UpdateEnabled       = 'True'
            UpdateSource        = "C:\temp\SQL_CU"
            SQLSysAdminAccounts = @('Administrators')
            DependsOn           = '[InstallADK]ADKInstall'
        }

        WriteStatus SSMS {
            DependsOn = '[SqlSetup]InstallSQL'
            Status    = "Downloading and installing SQL Management Studio"
        }

        InstallSSMS SSMS {
            DownloadUrl = "https://aka.ms/ssmsfullsetup"
            Ensure      = "Present"
            DependsOn   = '[SqlSetup]InstallSQL'
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
                Role        = "DC"
                MachineName = $DCName
                LogFolder   = $LogFolder
                ReadNode    = "CSJoinDomain"
                Ensure      = "Present"
                DependsOn   = "[File]ShareFolder"
            }

            FileReadAccessShare DomainSMBShare {
                Name      = $LogFolder
                Path      = $LogPath
                DependsOn = "[WaitForConfigurationFile]WaitCSJoinDomain"
            }

        }

        WriteStatus WaitDelegate {
            DependsOn = "[FileReadAccessShare]DomainSMBShare"
            Status    = "Waiting for DC to assign permissions to Systems Management container"
        }

        WaitForConfigurationFile DelegateControl {
            Role        = "DC"
            MachineName = $DCName
            LogFolder   = $LogFolder
            ReadNode    = "DelegateControl"
            Ensure      = "Present"
            DependsOn   = "[FileReadAccessShare]DomainSMBShare"
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
                Status    = "Setting up ConfigMgr."
            }

            WriteFileOnce CMSvc {
                FilePath  = "$LogPath\cm_svc.txt"
                Content   = $Admincreds.GetNetworkCredentials().Password
                DependsOn = "[ChangeSQLServicesAccount]ChangeToLocalSystem"
            }

            RegisterTaskScheduler InstallAndUpdateSCCM {
                TaskName       = "ScriptWorkFlow"
                ScriptName     = "ScriptWorkFlow.ps1"
                ScriptPath     = $PSScriptRoot
                ScriptArgument = "$DomainName $CM $DName\admin $DPMPName $Clients $Configuration $CurrentRole $LogFolder $CSName $PSName $UpdateToLatest $PushClients"
                Ensure         = "Present"
                DependsOn      = "[WriteFileOnce]CMSvc"
            }

            WaitForFileToExist WorkflowComplete {
                FilePath  = "$LogPath\ScriptWorkflow.txt"
                DependsOn = "[RegisterTaskScheduler]InstallAndUpdateSCCM"
            }

            WriteStatus Complete {
                DependsOn = "[WaitForFileToExist]WorkflowComplete"
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