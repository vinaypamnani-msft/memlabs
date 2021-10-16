﻿configuration WorkgroupMemberConfiguration
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

        WriteConfigurationFile WriteWorkgroupMemberFinished {
            Role      = "WorkgroupMember"
            LogPath   = $LogPath
            WriteNode = "WorkgroupMemberFinished"
            Status    = "Passed"
            Ensure    = "Present"
            DependsOn = "[FileReadAccessShare]SMBShare"
        }

        WriteStatus Complete {
            DependsOn = "[WriteConfigurationFile]WriteWorkgroupMemberFinished"
            Status    = "Complete!"
        }
    }
}