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
    $IsDPMP = $deployConfig.parameters.ThisMachineRole -eq "DPMP"

    # Set DC name ot existing DC
    if (-not $DCName) {
        $DCName = $deployConfig.vmOptions.existingDCNameWithPrefix
    }

    # Domain Admin Name
    $DomainAdminName = $deployConfig.vmOptions.domainAdminName
    $cm_admin = "$DNAME\$DomainAdminName"

    # SQL Setup
    $installSQL = $false
    if ($ThisVM.sqlVersion) {
        $installSQL = $true
        $SQLInstanceDir = "C:\Program Files\Microsoft SQL Server"
        if ($ThisVM.sqlInstanceDir) {
            $SQLInstanceDir = $ThisVM.sqlInstanceDir
        }
    }

    # Log share
    $LogFolder = "DSC"
    $LogPath = "c:\staging\$LogFolder"

    # Domain creds
    [System.Management.Automation.PSCredential]$DomainCreds = New-Object System.Management.Automation.PSCredential ("${DomainName}\$($Admincreds.UserName)", $Admincreds.Password)

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

        if ($IsDPMP) {

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

        if ($installSQL) {

            WriteStatus InstallSQL {
                DependsOn = '[OpenFirewallPortForSCCM]OpenFirewall'
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
                DependsOn           = '[OpenFirewallPortForSCCM]OpenFirewall'
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

            WriteStatus AddLocalAdmin {
                DependsOn = "[InstallSSMS]SSMS"
                Status    = "Adding cm_svc domain account to Local Administrators group"
            }

        }
        else {

            WriteStatus AddLocalAdmin {
                DependsOn = "[OpenFirewallPortForSCCM]OpenFirewall"
                Status    = "Adding cm_svc domain account to Local Administrators group"
            }

        }

        File ShareFolder {
            DestinationPath = $LogPath
            Type            = 'Directory'
            Ensure          = 'Present'
            DependsOn       = "[WriteStatus]AddLocalAdmin"
        }

        FileReadAccessShare DomainSMBShare {
            Name      = $LogFolder
            Path      = $LogPath
            DependsOn = "[File]ShareFolder"
        }

        AddUserToLocalAdminGroup AddADUserToLocalAdminGroup {
            Name       = "cm_svc"
            DomainName = $DomainName
            DependsOn  = "[FileReadAccessShare]DomainSMBShare"
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