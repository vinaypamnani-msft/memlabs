configuration WorkgroupMemberConfiguration
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
    Import-DscResource -ModuleName 'PSDesiredStateConfiguration', 'NetworkingDsc', 'ComputerManagementDsc'

    # Read config
    $deployConfig = Get-Content -Path $ConfigFilePath | ConvertFrom-Json
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

    # Log share
    $LogFolder = "DSC"
    $LogPath = "c:\staging\$LogFolder"

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

        WriteStatus InstallDotNet {
            DependsOn = "[InitializeDisks]InitDisks"
            Status    = "Installing .NET 4.7.2"
        }

        InstallDotNet472 DotNet {
            DownloadUrl = "https://download.visualstudio.microsoft.com/download/pr/1f5af042-d0e4-4002-9c59-9ba66bcf15f6/089f837de42708daacaae7c04b7494db/ndp472-kb4054530-x86-x64-allos-enu.exe"
            Ensure      = "Present"
            DependsOn   = "[WriteStatus]InstallDotNet"
        }

        SetCustomPagingFile PagingSettings {
            DependsOn   = "[InstallDotNet472]DotNet"
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

            WriteStatus AddLocalUser {
                DependsOn = "[InstallFeatureForSCCM]InstallFeature"
                Status    = "Adding $AdminName as a local Administrator"
            }
        }
        else {
            WriteStatus AddLocalUser {
                DependsOn = "[SetCustomPagingFile]PagingSettings"
                Status    = "Adding $AdminName as a local Administrator"
            }
        }

        User AddLocalUser {
            Ensure               = "Present"
            UserName             = $AdminName
            Password             = $Admincreds
            PasswordNeverExpires = $true
            DependsOn            = "[WriteStatus]AddLocalUser"
        }

        Group AddUserToLocalAdminGroup {
            GroupName        = 'Administrators'
            Ensure           = 'Present'
            MembersToInclude = $AdminName
            DependsOn        = "[User]AddLocalUser"
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

        WriteStatus Complete {
            DependsOn = "[FileReadAccessShare]SMBShare"
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