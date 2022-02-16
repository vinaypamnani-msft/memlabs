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
    $DomainAdminName = $deployConfig.vmOptions.adminName
    $DName = $DomainName.Split(".")[0]
    $DCName = $deployConfig.parameters.DCName
    $CSName = $deployConfig.thisParams.ParentSiteServer.vmName

    $Scenario = "Standalone"
    if ($CSName) {
        $Scenario = "Hierarchy"
    }

    if ($deployConfig.thisParams.PassiveVM) {
        $containsPassive = $true
        $PassiveVM = $deployConfig.thisParams.PassiveVM
    }

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

    # SQL Sysadmin accounts
    $waitOnDomainJoin = $deployconfig.thisParams.WaitOnDomainJoin
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

    # Servers to wait before running Script Workflow (should include DPMP/Secondary, but not Passive Site)
    $waitonReadyForPSServers = @()
    $waitOnSiteCodes = @($ThisVM.siteCode)
    $waitOnSiteCodes += $deployConfig.thisParams.ReportingSecondaries
    $waitOnSiteCodes = $waitOnSiteCodes | Where-Object { $_ -and $_.Trim() }
    if ($ThisVM.remoteSQLVM -and -not $ThisVM.hidden) { $waitonReadyForPSServers += $ThisVM.remoteSQLVM }
    foreach ($dpmp in $deployConfig.virtualMachines | Where-Object { $_.role -eq "DPMP" -and $_.siteCode -in $waitOnSiteCodes }) {
        $waitonReadyForPSServers += $dpmp.vmName
    }
    foreach ($secondary in $deployConfig.virtualMachines | Where-Object { $_.role -eq "Secondary" -and $_.parentSiteCode -eq $ThisVM.siteCode }) {
        $waitonReadyForPSServers += $secondary.vmName
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

                WriteStatus WaitDomainJoin {
                    DependsOn = "[DownloadFile]DownloadSQLCU"
                    Status    = "Waiting for $($waitOnDomainJoin -join ',') to join the domain"
                }

            }
            else {
                WriteStatus WaitDomainJoin {
                    DependsOn = '[InstallADK]ADKInstall'
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
                DependsOn = $waitOnDependency
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
        else {
            FileReadAccessShare DomainSMBShareDummy {
                Name      = $LogFolder
                Path      = $LogPath
                DependsOn = "[InstallSSMS]SSMS"
            }
        }

        WriteStatus AddLocalAdmins {
            DependsOn = "[FileReadAccessShare]DomainSMBShareDummy"
            Status    = "Adding $($deployConfig.thisParams.LocalAdminAccounts -join ',') accounts to Local Administrators group"
        }

        $addUserDependancy = @('[WriteStatus]AddLocalAdmins')
        $i = 0
        foreach ($user in $deployConfig.thisParams.LocalAdminAccounts) {
            $i++
            $NodeName = "AddADUserToLocalAdminGroup$($i)"
            AddUserToLocalAdminGroup "$NodeName" {
                Name       = $user
                DomainName = $DomainName
                DependsOn  = "[WriteStatus]AddLocalAdmins"
            }
            $addUserDependancy += "[AddUserToLocalAdminGroup]$NodeName"
        }

        # There's a passive site server in config
        if ($containsPassive) {

            WriteStatus WaitPassive {
                DependsOn = $addUserDependancy
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

            WriteStatus WaitDelegate {
                DependsOn = "[WaitForEvent]WaitPassive"
                Status    = "Wait for DC to assign permissions to Systems Management container"
            }

        }
        else {

            WriteStatus WaitDelegate {
                DependsOn = $addUserDependancy
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

        $nextDepend = "[WaitForEvent]DelegateControl"

        if ($InstallConfigMgr) {

            if ($waitonReadyForPSServers) {

                $waitOnDependency = @()

                WriteStatus WaitServerReady {
                    DependsOn = $nextDepend
                    Status    = "Waiting for $($waitonReadyForPSServers -join ',') to be ready."
                }

                foreach ($server in $waitonReadyForPSServers) {

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

                if ($waitOnDependency) {
                    $nextDepend = $waitOnDependency
                }
            }
        }

        WriteStatus Complete {
            DependsOn = $nextDepend
            Status    = "Complete!"
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