configuration PrimaryConfiguration
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
    $ThisMachineName = $deployConfig.thisParams.MachineName
    $ThisVM = $deployConfig.virtualMachines | Where-Object { $_.vmName -eq $ThisMachineName }
    $DomainName = $deployConfig.parameters.domainName
    $DName = $DomainName.Split(".")[0]
    $DCName = $deployConfig.parameters.DCName
    $CSName = $deployConfig.thisParams.ParentSiteServer.vmName
    $Scenario = "Standalone"
    if ($CSName){
        $Scenario = "Hierarchy"
    }

    if ($deployConfig.thisParams.PassiveVM){
        $containsPassive = $true
        $PassiveVM = $deployConfig.thisParams.PassiveVM
    }
    #$Scenario = $deployConfig.parameters.Scenario

    # Domain Admin User name
    $DomainAdminName = $deployConfig.vmOptions.adminName

    # CM Options
    $InstallConfigMgr = $deployConfig.cmOptions.install

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

    # DomainMembers to wait before running Script Workflow
    $waitOnServers = @()
    if ($ThisVM.remoteSQLVM -and -not $ThisVM.hidden) { $waitOnServers += $ThisVM.remoteSQLVM }
    $waitOnSiteCodes = @()
    $waitOnSiteCodes += $ThisVM.siteCode
    $waitOnSiteCodes += $deployConfig.thisParams.ReportingSecondaries
    $waitOnSiteCodes = $waitOnSiteCodes | Where-Object { $_ -and $_.Trim() }
    foreach ($dpmp in $deployConfig.virtualMachines | Where-Object { $_.role -eq "DPMP" -and $_.siteCode -in $waitOnSiteCodes }) {
        $waitOnServers += $dpmp.vmName
    }

    # Secondary Site
    $containsSecondary = $deployConfig.virtualMachines.role -contains "Secondary"
    if ($containsSecondary) {
        $SecondaryVM = $deployConfig.virtualMachines | Where-Object { $_.parentSiteCode -eq $ThisVM.siteCode -and $_.role -eq "Secondary" }
    }
    if ($SecondaryVM) { $waitOnServers += $SecondaryVM.vmName }

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
            DependsOn    = "[WriteEvent]WriteJoinDomain"
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

            WaitForEvent WaitCSJoinDomain {
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
                DependsOn = "[WaitForEvent]WaitCSJoinDomain"
            }

        }

        # There's a passive site server in config
        if ($containsPassive) {

            WriteStatus WaitPassive {
                DependsOn = "[FileReadAccessShare]DomainSMBShareDummy"
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
                    DependsOn = "[WaitForEvent]WaitPassive"
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

        WaitForEvent DelegateControl {
            MachineName   = $DCName
            LogFolder     = $LogFolder
            ReadNode      = "DelegateControl"
            ReadNodeValue = "Passed"
            Ensure        = "Present"
            DependsOn     = "[WriteStatus]WaitDelegate"
        }

        if ($InstallConfigMgr) {

            if ($waitOnServers) {

                $waitOnDependency = @()

                WriteStatus WaitServerReady {
                    DependsOn = "[WaitForEvent]DelegateControl"
                    Status    = "Waiting for $($waitOnServers -join ',') to be ready."
                }

                foreach ($server in $waitOnServers) {

                    WaitForEvent "WaitFor$server" {
                        MachineName   = $server
                        LogFolder     = $LogFolder
                        ReadNode      = "ReadyForPrimary"
                        ReadNodeValue = "Passed"
                        Ensure        = "Present"
                        DependsOn     = "[WriteStatus]WaitServerReady"
                    }

                    $waitOnDependency += "[WaitForEvent]WaitFor$server"
                }

                WriteStatus RunScriptWorkflow {
                    DependsOn = $waitOnDependency
                    Status    = "Setting up ConfigMgr. Waiting for workflow to begin."
                }

            }
            else {

                WriteStatus RunScriptWorkflow {
                    DependsOn = "[WaitForEvent]DelegateControl"
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

            WaitForEvent WorkflowComplete {
                MachineName   = $ThisMachineName
                LogFolder     = $LogFolder
                FileName      = "ScriptWorkflow"
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
                DependsOn = "[WaitForEvent]DelegateControl"
                Status    = "Complete!"
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
                DependsOn  = "[WriteStatus]Complete"
            }
            $addUserDependancy += "[AddUserToLocalAdminGroup]$NodeName"
        }

        WriteEvent WriteConfigFinished {
            LogPath   = $LogPath
            WriteNode = "ConfigurationFinished"
            Status    = "Passed"
            Ensure    = "Present"
            DependsOn = $addUserDependancy
        }
    }
}