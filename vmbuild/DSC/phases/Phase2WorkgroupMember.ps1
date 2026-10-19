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

    # Admin Name
    $AdminName = $deployConfig.vmOptions.adminName

    $clientSetupTest = {
        . 'C:\staging\DSC\phases\WindowsSetupReadiness.ps1'
        $state = Get-MemLabsWindowsClientSetupState
        return ($state.Ready -is [bool] -and $state.Ready)
    }
    $clientSetupSet = {
        . 'C:\staging\DSC\phases\WindowsSetupReadiness.ps1'
        $state = Get-MemLabsWindowsClientSetupState
        if ($state.Ready -isnot [bool] -or -not $state.Ready) {
            throw "Windows client setup is not complete; refusing workgroup rename. $($state.Detail)"
        }
    }
    if ($ThisVM.role -eq 'AADClient') {
        $clientSetupTest = { return $true }
        $clientSetupSet = {}
    }

    Node localhost
    {
        LocalConfigurationManager {
            ConfigurationMode  = 'ApplyOnly'
            RebootNodeIfNeeded = $true
        }

        Script ClientSetupBeforeRename {
            GetScript = { @{ Result = 'Read-only Windows client setup guard' } }
            TestScript = $clientSetupTest
            SetScript = $clientSetupSet
        }

        WriteStatus Rename {
            DependsOn = '[Script]ClientSetupBeforeRename'
            Status = "Renaming the computer to $ThisMachineName"
        }

        Computer NewName {
            Name = $ThisMachineName
            DependsOn = '[WriteStatus]Rename'
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
            Ensure               = "Present"
            UserName             = "vmbuildadmin"
            Password             = $Admincreds
            PasswordNeverExpires = $true
            DependsOn            = "[WriteStatus]AddLocalUser"
        }

        User adminUser {
            Ensure               = "Present"
            UserName             = $AdminName
            Password             = $Admincreds
            PasswordNeverExpires = $true
            DependsOn            = "[User]vmbuildadmin"
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
            DownloadUrl = $deployConfig.URLS.DotNet
            FileName    = "ndp48-x86-x64-allos-enu.exe"
            NetVersion  = "528040"
            Ensure      = "Present"
            DependsOn   = "[WriteStatus]InstallDotNet"
        }

        $PageFileSize = ($thisVM.memory)/2MB
        SetCustomPagingFile PagingSettings {
            DependsOn   = "[InitializeDisks]InitDisks"
            Drive       = 'C:'
            InitialSize = $PageFileSize
            MaximumSize = $PageFileSize
        }

        WriteStatus InstallFeature {
            DependsOn = "[SetCustomPagingFile]PagingSettings"
            Status    = "Installing required windows features"
        }

        InstallFeatureForSCCM InstallFeature {
            Name            = "WorkgroupMember"
            Role            = "WorkgroupMember"
            InstallCA       = [bool]$thisVM.InstallCA
            IsOfflineRootCA = ($thisVM.role -eq 'StandaloneRootCA')
            DependsOn       = "[SetCustomPagingFile]PagingSettings"
        }

        WriteStatus Complete {
            DependsOn = "[InstallFeatureForSCCM]InstallFeature"
            Status    = "Complete!"
        }

    }
}