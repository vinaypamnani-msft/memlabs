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
    $ThisMachineName = $deployConfig.parameters.ThisMachineName
    $ThisVM = $deployConfig.virtualMachines | Where-Object { $_.vmName -eq $ThisMachineName }
    $DomainName = $deployConfig.parameters.domainName
    $DName = $DomainName.Split(".")[0]
    $DCName = $deployConfig.parameters.DCName

    if ($ThisVm.siteCode) {
        $PSName = ($deployConfig.virtualMachines | Where-Object { $_.role -eq "Primary" -and $_.siteCode -eq $ThisVM.siteCode }).vmName
        $PSPassiveName =  ($deployConfig.virtualMachines | Where-Object { $_.role -eq "PassiveSite" -and $_.siteCode -eq $ThisVM.siteCode }).vmName
        if (-not $PSPassiveName){
            $PSPassiveName =  ($deployConfig.existingVMs | Where-Object { $_.role -eq "PassiveSite" -and $_.siteCode -eq $ThisVM.siteCode }).vmName
        }
    }

    if (-not $PSName){
        $PSName = $deployConfig.parameters.PSName
    }
    $CSName = $deployConfig.parameters.CSName
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

    # Domain Admin Name
    $DomainAdminName = $deployConfig.vmOptions.adminName
    $cm_admin = "$DNAME\$DomainAdminName"

    # SQL Setup
    $installSQL = $false
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
    }

    $SQLSysAdminAccounts = @($cm_admin)
    $containsPassive = $deployConfig.virtualMachines.role -contains "PassiveSite"
    if ($containsPassive) {
        $PassiveVM = $deployConfig.virtualMachines | Where-Object { $_.role -eq "PassiveSite" }
        foreach ($vm in $PassiveVM) {
            $SQLSysAdminAccounts += "$DName\$($vm.vmName)$"
        }
    }

    # Set PS name to existing PS name, if PS not in config
    if (-not $PSName) {
        $PSName = $deployConfig.parameters.ExistingPSName
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
            Role      = "DomainMember"
            LogPath   = $LogPath
            WriteNode = "MachineJoinDomain"
            Status    = "Passed"
            Ensure    = "Present"
            DependsOn = "[FileReadAccessShare]DomainSMBShare"
        }

        if ($installSQL) {

            WriteStatus InstallSQL {
                DependsOn = '[WriteConfigurationFile]WriteJoinDomain'
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
                DependsOn           = '[OpenFirewallPortForSCCM]OpenFirewall'
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

                WaitForConfigurationFile WaitPassive {
                    Role          = "PassiveSite"
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
                DependsOn = '[WriteConfigurationFile]WriteJoinDomain'
                Status    = "Adding cm_svc domain account to Local Administrators group"
            }

        }

        AddUserToLocalAdminGroup AddADUserToLocalAdminGroup {
            Name       = "cm_svc"
            DomainName = $DomainName
            DependsOn       = "[WriteStatus]AddLocalAdmin"
        }

        if ($PSName) {
            AddUserToLocalAdminGroup AddPSLocalAdmin {
                Name       = "$PSName$"
                DomainName = $DomainName
                DependsOn  = "[WriteStatus]AddLocalAdmin"
            }
        }

        if ($PSPassiveName) {
            AddUserToLocalAdminGroup AddPassiveLocalAdmin {
                Name       = "$PSPassiveName$"
                DomainName = $DomainName
                DependsOn  = "[WriteStatus]AddLocalAdmin"
            }
        }

        if ($CSName) {
            AddUserToLocalAdminGroup AddCSLocalAdmin {
                Name       = "$CSName$"
                DomainName = $DomainName
                DependsOn  = "[WriteStatus]AddLocalAdmin"
            }
        }

        WriteConfigurationFile WriteDomainMemberFinished {
            Role      = "DomainMember"
            LogPath   = $LogPath
            WriteNode = "DomainMemberFinished"
            Status    = "Passed"
            Ensure    = "Present"
            DependsOn = "[AddUserToLocalAdminGroup]AddADUserToLocalAdminGroup"
        }

        WriteStatus Complete {
            DependsOn = "[AddUserToLocalAdminGroup]AddADUserToLocalAdminGroup"
            Status    = "Complete!"
        }
    }
}