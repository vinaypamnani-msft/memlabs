﻿configuration PrimaryConfiguration
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
    $CSName = $deployConfig.parameters.CSName
    $Scenario = $deployConfig.parameters.Scenario

    # Domain Admin User name
    $DomainAdminName = $deployConfig.vmOptions.adminName
    $cm_admin = "$DNAME\$DomainAdminName"

    # CM Options
    $InstallConfigMgr = $deployConfig.cmOptions.install

    if ($ThisVM.remoteSQLVM -or $ThisVM.Hidden) {
        $installSQL = $false
    }
    else {
        # SQL Instance Location
        $installSQL = $true
        $SQLInstanceDir = "C:\Program Files\Microsoft SQL Server"
        $SQLInstanceName = "MSSQLSERVER"
        if ($ThisVM.sqlInstanceDir) {
            $SQLInstanceDir = $ThisVM.sqlInstanceDir
        }
        if ($ThisVM.sqlInstanceName) {
            $SQLInstanceName = $ThisVM.sqlInstanceName
        }
    }

    # Passive Site Server
    $SQLSysAdminAccounts = @($cm_admin, 'BUILTIN\Administrators')
    $containsPassive = $deployConfig.virtualMachines | Where-Object { $_.role -eq "PassiveSite" -and $_.siteCode -eq $ThisVM.siteCode }
    if ($containsPassive) {
        $PassiveVM = $containsPassive
        foreach ($vm in $PassiveVM) {
            $SQLSysAdminAccounts += "$DName\$($vm.vmName)$"
        }
    }

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

    # Domain creds
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
            NAME      = "Primary"
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
            Name      = "Primary"
            Role      = "Site Server"
        }

        File ShareFolder {
            DestinationPath = $LogPath
            Type            = 'Directory'
            Ensure          = 'Present'
            DependsOn       = '[OpenFirewallPortForSCCM]OpenFirewall'
        }

        FileReadAccessShare DomainSMBShare {
            Name      = $LogFolder
            Path      = $LogPath
            DependsOn = "[File]ShareFolder"
        }

        WriteConfigurationFile WriteJoinDomain {
            Role      = "Primary"
            LogPath   = $LogPath
            WriteNode = "MachineJoinDomain"
            Status    = "Passed"
            Ensure    = "Present"
            DependsOn = "[FileReadAccessShare]DomainSMBShare"
        }

        WriteStatus ADKInstall {
            DependsOn = "[WriteConfigurationFile]WriteJoinDomain"
            Status    = "Downloading and installing ADK"
        }

        InstallADK ADKInstall {
            ADKPath      = "C:\temp\adksetup.exe"
            ADKWinPEPath = "c:\temp\adksetupwinpe.exe"
            Ensure       = "Present"
            DependsOn    = "[WriteConfigurationFile]WriteJoinDomain"
        }

        if ($installSQL) {

            WriteStatus InstallSQL {
                DependsOn = '[InstallADK]ADKInstall'
                Status    = "Installing SQL Server ($SQLInstanceName instance)"
            }

            SqlSetup InstallSQL {
                InstanceName        = $SQLInstanceName
                InstanceDir         = $SQLInstanceDir
                SQLCollation        = 'SQL_Latin1_General_CP1_CI_AS'
                Features            = 'SQLENGINE,CONN,BC'
                SourcePath          = 'C:\temp\SQL'
                UpdateEnabled       = 'True'
                UpdateSource        = "C:\temp\SQL_CU"
                SQLSysAdminAccounts = $SQLSysAdminAccounts
                TcpEnabled          = $true
                UseEnglish          = $true
                DependsOn           = '[InstallADK]ADKInstall'
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


        if ($Scenario -eq "Standalone") {

            WriteStatus DownLoadSCCM {
                DependsOn = "[InstallSSMS]SSMS"
                Status    = $CMDownloadStatus
            }

            DownloadSCCM DownLoadSCCM {
                CM        = $CM
                Ensure    = "Present"
                DependsOn = "[InstallSSMS]SSMS"
            }

            FileReadAccessShare CMSourceSMBShare {
                Name      = $CM
                Path      = "c:\$CM"
                DependsOn = "[DownloadSCCM]DownLoadSCCM"
            }

            FileReadAccessShare DomainSMBShareDummy {
                Name      = $LogFolder
                Path      = $LogPath
                DependsOn = "[FileReadAccessShare]CMSourceSMBShare"
            }

        }

        if ($Scenario -eq "Hierarchy") {

            WriteStatus WaitCS {
                DependsOn = "[InstallSSMS]SSMS"
                Status    = "Waiting for CAS Server $CSName to join domain"
            }

            WaitForConfigurationFile WaitCSJoinDomain {
                Role          = "CAS"
                MachineName   = $CSName
                LogFolder     = $LogFolder
                ReadNode      = "MachineJoinDomain"
                ReadNodeValue = "Passed"
                Ensure        = "Present"
                DependsOn     = "[InstallSSMS]SSMS"
            }

            FileReadAccessShare DomainSMBShareDummy {
                Name      = $LogFolder
                Path      = $LogPath
                DependsOn = "[WaitForConfigurationFile]WaitCSJoinDomain"
            }

        }

        # There's a passive site server in config
        if ($containsPassive) {

            WriteStatus WaitPassive {
                DependsOn = "[FileReadAccessShare]DomainSMBShareDummy"
                Status    = "Wait for Passive Site Server $($PassiveVM.vmName) to be ready"
            }

            WaitForConfigurationFile WaitPassive {
                Role          = "PassiveSite"
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
                    DependsOn               = '[WaitForConfigurationFile]WaitPassive'
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
                    DependsOn = "[WaitForConfigurationFile]WaitPassive"
                    Status    = "Wait for DC to assign permissions to Systems Management container"
                }

            }
        }
        else {

            WriteStatus WaitDelegate {
                DependsOn = "[FileReadAccessShare]DomainSMBShareDummy"
                Status    = "Wait for DC to assign permissions to Systems Management container"
            }

        }

        WaitForConfigurationFile DelegateControl {
            Role          = "DC"
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
                    DependsOn = "[WaitForConfigurationFile]DelegateControl"
                    Status    = "Setting up ConfigMgr. Waiting for workflow to begin."
                }

            }
            else {

                # Wait for SQLVM
                WriteStatus WaitSQL {
                    DependsOn = "[WaitForConfigurationFile]DelegateControl"
                    Status    = "Waiting for remote SQL VM $($ThisVM.remoteSQLVM) to finish configuration."
                }

                WaitForConfigurationFile WaitSQL {
                    Role          = "DomainMember"
                    MachineName   = $ThisVM.remoteSQLVM
                    LogFolder     = $LogFolder
                    ReadNode      = "DomainMemberFinished"
                    ReadNodeValue = "Passed"
                    Ensure        = "Present"
                    DependsOn     = "[WaitForConfigurationFile]DelegateControl"
                }

                WriteStatus RunScriptWorkflow {
                    DependsOn = "[WaitForConfigurationFile]WaitSQL"
                    Status    = "Setting up ConfigMgr. Waiting for workflow to begin."
                }

            }

            WriteFileOnce CMSvc {
                FilePath  = "$LogPath\cm_svc.txt"
                Content   = $Admincreds.GetNetworkCredential().Password
                DependsOn = "[WriteStatus]RunScriptWorkflow"
            }

            RegisterTaskScheduler RunScriptWorkflow {
                TaskName       = "ScriptWorkFlow"
                ScriptName     = "ScriptWorkFlow.ps1"
                ScriptPath     = $PSScriptRoot
                ScriptArgument = "$ConfigFilePath $LogPath"
                AdminCreds     = $CMAdmin
                Ensure         = "Present"
                DependsOn      = "[WriteFileOnce]CMSvc"
            }

            WaitForConfigurationFile WorkflowComplete {
                Role          = "ScriptWorkflow"
                MachineName   = $ThisMachineName
                LogFolder     = $LogFolder
                ReadNode      = "ScriptWorkflow"
                ReadNodeValue = "Completed"
                Ensure        = "Present"
                DependsOn     = "[RegisterTaskScheduler]RunScriptWorkflow"
            }

            WriteStatus Complete {
                DependsOn = "[WaitForConfigurationFile]WorkflowComplete"
                Status    = "Complete!"
            }

        }
        else {

            WriteStatus Complete {
                DependsOn = "[WaitForConfigurationFile]DelegateControl"
                Status    = "Complete!"
            }

        }
    }
}