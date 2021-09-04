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
        [System.Management.Automation.PSCredential]$Admincreds
    )

    Import-DscResource -ModuleName 'TemplateHelpDSC'
    Import-DscResource -ModuleName 'PSDesiredStateConfiguration', 'NetworkingDsc', 'ComputerManagementDsc', 'SqlServerDsc'
    
    $LogFolder = "TempLog"
    $CM = "CMCB"
    $LogPath = "c:\$LogFolder"
    $DName = $DomainName.Split(".")[0]
    $DCComputerAccount = "$DName\$DCName$"
    $CurrentRole = "PS"
    
    if ($Configuration -ne "Standalone") {
        $CSComputerAccount = "$DName\$CSName$"
    }
    $DPMPComputerAccount = "$DName\$DPMPName$"

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

        if ($Configuration -eq "Standalone") {
            WriteStatus DownLoadSCCM {
                DependsOn = "[SqlSetup]InstallSQL"
                Status    = "Downloading Configuration Manager current branch (latest baseline version)"
            }

            DownloadSCCM DownLoadSCCM {
                CM        = $CM
                Ensure    = "Present"
                DependsOn = "[InstallADK]ADKInstall"
            }

            FileReadAccessShare DomainSMBShare {
                Name      = $LogFolder
                Path      = $LogPath
                Account   = $DCComputerAccount
                DependsOn = "[File]ShareFolder"
            }

            FileReadAccessShare CMSourceSMBShare {
                Name      = $CM
                Path      = "c:\$CM"
                Account   = $DCComputerAccount
                DependsOn = "[ChangeSQLServicesAccount]ChangeToLocalSystem"
            }

            WriteStatus InstallAndUpdateSCCM {
                DependsOn = "[FileReadAccessShare]CMSourceSMBShare"
                Status    = "Setting up ConfigMgr."
            }

            RegisterTaskScheduler InstallAndUpdateSCCM {
                TaskName       = "ScriptWorkFlow"
                ScriptName     = "ScriptWorkFlow.ps1"
                ScriptPath     = $PSScriptRoot
                ScriptArgument = "$DomainName $CM $DName\admin $DPMPName $Clients $Configuration $CurrentRole $LogFolder $CSName $PSName"
                Ensure         = "Present"
                DependsOn      = "[FileReadAccessShare]CMSourceSMBShare"
            }
        }
        else {
            # Hierarchy

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
                Account   = $DCComputerAccount, $CSComputerAccount
                DependsOn = "[WaitForConfigurationFile]WaitCSJoinDomain"
            }

            RegisterTaskScheduler InstallAndUpdateSCCM {
                TaskName       = "ScriptWorkFlow"
                ScriptName     = "ScriptWorkFlow.ps1"
                ScriptPath     = $PSScriptRoot
                ScriptArgument = "$DomainName $CM $DName\$($Admincreds.UserName) $DPMPName $Clients $Configuration $CurrentRole $LogFolder $CSName $PSName"
                Ensure         = "Present"
                DependsOn      = "[ChangeSQLServicesAccount]ChangeToLocalSystem"
            }
        }
        
        File ShareFolder {            
            DestinationPath = $LogPath     
            Type            = 'Directory'            
            Ensure          = 'Present'
            DependsOn       = "[DownloadSCCM]DownloadSCCM"
        }        

        WaitForConfigurationFile DelegateControl {
            Role        = "DC"
            MachineName = $DCName
            LogFolder   = $LogFolder
            ReadNode    = "DelegateControl"
            Ensure      = "Present"
            DependsOn   = "[JoinDomain]JoinDomain"
        }

        AddBuiltinPermission AddSQLPermission {
            Ensure    = "Present"            
            DependsOn = @("[DownloadSCCM]DownloadSCCM", "[InstallSSMS]SSMS")
        }

        ChangeSQLServicesAccount ChangeToLocalSystem {
            SQLInstanceName = "MSSQLSERVER"
            Ensure          = "Present"
            DependsOn       = "[AddBuiltinPermission]AddSQLPermission"
        }
    }
}