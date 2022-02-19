configuration Phase2WorkgroupMember
{
    param
    (
        [Parameter(Mandatory)]
        [string]$DeployConfigPath,
        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$Admincreds
    )

    Set-ExecutionPolicy -ExecutionPolicy Bypass -Force
    Import-DscResource -ModuleName 'TemplateHelpDSC'
    Import-DscResource -ModuleName 'PSDesiredStateConfiguration', 'NetworkingDsc', 'ComputerManagementDsc'

    # Log share
    $LogFolder = "DSC"
    $LogPath = "c:\staging\$LogFolder"

    # Read config
    $deployConfig = Get-Content -Path $DeployConfigPath | ConvertFrom-Json
    $ThisMachineName = $deployConfig.parameters.ThisMachineName
    $ThisVM = $deployConfig.virtualMachines | Where-Object { $_.vmName -eq $ThisMachineName }

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

    # Admin Name
    $AdminName = $deployConfig.vmOptions.adminName

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

        WriteStatus AddLocalUser {
            DependsOn = "[InitializeDisks]InitDisks"
            Status    = "Adding $AdminName as a local Administrator"
        }

        User vmbuildadmin {
            Ensure                   = "Present"
            UserName                 = "vmbuildadmin"
            Password                 = $Admincreds
            PasswordNeverExpires     = $true
            DependsOn                = "[WriteStatus]AddLocalUser"
        }

        User adminUser {
            Ensure                   = "Present"
            UserName                 = $AdminName
            Password                 = $Admincreds
            PasswordNeverExpires     = $true
            DependsOn        = "[User]vmbuildadmin"
        }

        Group AddUserToLocalAdminGroup {
            GroupName        = 'Administrators'
            Ensure           = 'Present'
            MembersToInclude = @($AdminName, "vmbuildadmin")
            DependsOn        = "[User]adminUser"
        }

        File ShareFolder {
            DestinationPath = $LogPath
            Type            = 'Directory'
            Ensure          = 'Present'
            DependsOn       = "[Group]AddUserToLocalAdminGroup"
        }

        FileReadAccessShare SMBShare {
            Name      = $LogFolder
            Path      = $LogPath
            DependsOn = "[File]ShareFolder"
        }

        AddNtfsPermissions AddNtfsPerms {
            Ensure    = "Present"
            DependsOn = "[FileReadAccessShare]SMBShare"
        }

        WriteStatus OpenPorts {
            DependsOn = "[FileReadAccessShare]SMBShare"
            Status    = "Open required firewall ports"
        }

        OpenFirewallPortForSCCM OpenFirewall {
            DependsOn = "[WriteStatus]OpenPorts"
            Name      = "WorkgroupMember"
            Role      = "WorkgroupMember"
        }

        WriteStatus InstallDotNet {
            DependsOn = "[OpenFirewallPortForSCCM]OpenFirewall"
            Status    = "Installing .NET 4.8"
        }

        InstallDotNet4 DotNet {
            DownloadUrl = "https://download.visualstudio.microsoft.com/download/pr/7afca223-55d2-470a-8edc-6a1739ae3252/abd170b4b0ec15ad0222a809b761a036/ndp48-x86-x64-allos-enu.exe"
            FileName    = "ndp48-x86-x64-allos-enu.exe"
            NetVersion  = "528040"
            Ensure      = "Present"
            DependsOn   = "[WriteStatus]InstallDotNet"
        }

        SetCustomPagingFile PagingSettings {
            DependsOn   = "[InstallDotNet4]DotNet"
            Drive       = 'C:'
            InitialSize = '8192'
            MaximumSize = '8192'
        }

        $nextDepend = "[SetCustomPagingFile]PagingSettings"
        if ($IsServerOS) {

            WriteStatus InstallFeature {
                DependsOn = $nextDepend
                Status    = "Installing required windows features"
            }

            InstallFeatureForSCCM InstallFeature {
                Name      = "DPMP"
                Role      = "Distribution Point", "Management Point"
                DependsOn = "[SetCustomPagingFile]PagingSettings"
            }

            $nextDepend = "[InstallFeatureForSCCM]InstallFeature"
        }

        WriteStatus Complete {
            DependsOn = $nextDepend
            Status    = "Complete!"
        }

    }
}