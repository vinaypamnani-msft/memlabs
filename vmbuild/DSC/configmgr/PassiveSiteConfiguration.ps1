configuration PassiveSiteConfiguration
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
    $DCName = $deployConfig.parameters.DCName

    # Passive Site Config Props
    $ContentLibVMName = $ThisVM.remoteContentLibVM
    $ActiveVMName = $deployConfig.parameters.ActiveVMName
    if (-not $ActiveVMName) {
        $ActiveVMName = $deployConfig.parameters.ExistingActiveName
    }

    # Log share
    $LogFolder = "DSC"
    $LogPath = "c:\staging\$LogFolder"

    # Domain creds
    [System.Management.Automation.PSCredential]$DomainCreds = New-Object System.Management.Automation.PSCredential ("${DomainName}\$($Admincreds.UserName)", $Admincreds.Password)

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

        OpenFirewallPortForSCCM OpenFirewall {
            DependsOn = "[JoinDomain]JoinDomain"
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

        AddNtfsPermissions AddNtfsPerms {
            Ensure    = "Present"
            DependsOn = "[WriteConfigurationFile]WriteJoinDomain"
        }

        WriteStatus ADKInstall {
            DependsOn = "[AddNtfsPermissions]AddNtfsPerms"
            Status    = "Downloading and installing ADK"
        }

        InstallADK ADKInstall {
            ADKPath      = "C:\temp\adksetup.exe"
            ADKWinPEPath = "c:\temp\adksetupwinpe.exe"
            Ensure       = "Present"
            DependsOn    = "[AddNtfsPermissions]AddNtfsPerms"
        }

        WriteStatus SSMS {
            DependsOn = "[InstallADK]ADKInstall"
            Status    = "Downloading and installing SQL Management Studio"
        }

        InstallSSMS SSMS {
            DownloadUrl = "https://aka.ms/ssmsfullsetup"
            Ensure      = "Present"
            DependsOn   = "[InstallADK]ADKInstall"
        }

        # TODO: DelegateControl won't work for passive, but it'll just pass this since the node had been set before... Need DC DSC re-run.
        WriteStatus WaitDelegate {
            DependsOn = "[InstallSSMS]SSMS"
            Status    = "Wait for DC to assign permissions to Systems Management container"
        }

        WaitForConfigurationFile DelegateControl {
            Role          = "DC"
            MachineName   = $DCName
            LogFolder     = $LogFolder
            ReadNode      = "DelegateControl"
            ReadNodeValue = "Passed"
            Ensure        = "Present"
            DependsOn     = "[InstallSSMS]SSMS"
        }

        WriteStatus WaitFS {
            DependsOn = "[WaitForConfigurationFile]DelegateControl"
            Status    = "Waiting for Content Lib VM $ContentLibVMName to finish configuration."
        }

        AddUserToLocalAdminGroup AddActiveLocalAdmin {
            Name       = "$ActiveVMName$"
            DomainName = $DomainName
            DependsOn  = "[WaitForConfigurationFile]DelegateControl"
        }

        WaitForConfigurationFile WaitFS {
            Role          = "DomainMember"
            MachineName   = $ContentLibVMName
            LogFolder     = $LogFolder
            ReadNode      = "DomainMemberFinished"
            ReadNodeValue = "Passed"
            Ensure        = "Present"
            DependsOn     = "[AddUserToLocalAdminGroup]AddActiveLocalAdmin"
        }

        WriteConfigurationFile WritePassiveReady {
            Role      = "PassiveSite"
            LogPath   = $LogPath
            WriteNode = "PassiveReady"
            Status    = "Passed"
            Ensure    = "Present"
            DependsOn = "[WaitForConfigurationFile]WaitFS"
        }

        WriteStatus WaitActive {
            DependsOn = "[WriteConfigurationFile]WritePassiveReady"
            Status    = "Waiting for Site Server $ActiveVMName to finish configuration."
        }

        WaitForConfigurationFile WaitActive {
            Role          = "ScriptWorkflow"
            MachineName   = $ActiveVMName
            LogFolder     = $LogFolder
            ReadNode      = "ScriptWorkflow"
            ReadNodeValue = "Completed"
            Ensure        = "Present"
            DependsOn     = "[WriteStatus]WaitActive"
        }

        WriteStatus Complete {
            DependsOn = "[WaitForConfigurationFile]WaitActive"
            Status    = "Complete!"
        }

    }

}