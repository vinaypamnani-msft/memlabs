configuration Phase2BDC
{
    param
    (
        [Parameter(Mandatory)]
        [string]$DeployConfigPath,
        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$Admincreds
    )

    Import-DscResource -ModuleName 'TemplateHelpDSC'
    Import-DscResource -ModuleName 'PSDesiredStateConfiguration', 'NetworkingDsc', 'xDhcpServer', 'DnsServerDsc', 'ComputerManagementDsc', 'ActiveDirectoryDsc'

    # Define log share
    $LogFolder = "DSC"
    $LogPath = "c:\staging\$LogFolder"

    # Read config
    $deployConfig = Get-Content -Path $DeployConfigPath | ConvertFrom-Json
    $DomainName = $deployConfig.parameters.domainName

    # This VM
    $ThisMachineName = $deployConfig.parameters.ThisMachineName
    $ThisVM = $deployConfig.virtualMachines | Where-Object { $_.vmName -eq $ThisMachineName }
    $PDC = $deployConfig.virtualMachines | Where-Object { $_.role -eq "DC" }

    # Domain creds
    [System.Management.Automation.PSCredential]$DomainCreds = New-Object System.Management.Automation.PSCredential ("${DomainName}\$($Admincreds.UserName)", $Admincreds.Password)

    Node LOCALHOST
    {
        LocalConfigurationManager {
            ConfigurationMode  = 'ApplyOnly'
            RebootNodeIfNeeded = $true
        }

        WriteStatus NewName {
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
            Name      = 'DC'
            Role      = 'DC'
            DependsOn = "[SetCustomPagingFile]PagingSettings"
        }

        $nextDepend = "[InstallFeatureForSCCM]InstallFeature"

        WriteStatus WaitDomain {
            DependsOn = $nextDepend
            Status    = "Waiting for domain to be ready"
        }

        WaitForDomainReady WaitForDomain {
            DependsOn  = "[WriteStatus]WaitDomain"
            Ensure     = "Present"
            DomainName = $DomainName
            DCName     = $PDC.vmName
        }

        $nextDepend = "[WaitForDomainReady]WaitForDomain"

        WriteStatus NewDS {
            DependsOn = $nextDepend
            Status    = "Configuring ADDS and setting up the domain Controller."
        }

        WaitForADDomain 'WaitForestAvailability' {
            DomainName              = $DomainName
            Credential              = $DomainCreds
            RestartCount            = 2
            WaitForValidCredentials = $true
            WaitTimeout             = 900
            DependsOn               = $nextDepend
        }

        ADDomainController 'DomainControllerAllProperties' {
            DomainName                    = $DomainName
            Credential                    = $DomainCreds
            SafeModeAdministratorPassword = $DomainCreds
            DatabasePath                  = 'C:\Windows\NTDS'
            LogPath                       = 'C:\Windows\Logs'
            SysvolPath                    = 'C:\Windows\SYSVOL'
            #SiteName                      = 'Europe'
            IsGlobalCatalog               = $true
            InstallDns                    = $false
            DependsOn                     = '[WaitForADDomain]WaitForestAvailability'
        }

        $nextDepend = '[ADDomainController]DomainControllerAllProperties'
        AddNtfsPermissions AddNtfsPerms {
            Ensure    = "Present"
            DependsOn = $nextDepend
        }

        OpenFirewallPortForSCCM OpenFirewall {
            DependsOn = "[AddNtfsPermissions]AddNtfsPerms"
            Name      = "DC"
            Role      = "DC"
        }

        $nextDepend = "[OpenFirewallPortForSCCM]OpenFirewall"
        if ($ThisVM.InstallCA) {

            WriteStatus ADCS {
                DependsOn = $nextDepend
                Status    = "Installing Certificate Authority"
            }

            InstallCA InstallCA {
                DependsOn     = $nextDepend
                HashAlgorithm = "SHA256"
            }

            $nextDepend = "[InstallCA]InstallCA"
        }

        WriteStatus InstallDotNet {
            DependsOn = $nextDepend
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
            DependsOn       = "[InstallDotNet4]DotNet"
        }

        FileReadAccessShare DomainSMBShare {
            Name      = $LogFolder
            Path      = $LogPath
            DependsOn = "[File]ShareFolder"
        }
        $nextDepend = "[FileReadAccessShare]DomainSMBShare"

        RemoteDesktopAdmin RemoteDesktopSettings {
            IsSingleInstance   = 'yes'
            Ensure             = 'Present'
            UserAuthentication = 'NonSecure'
            DependsOn          = $nextDepend
        }

        WriteStatus Complete {
            DependsOn = "[RemoteDesktopAdmin]RemoteDesktopSettings"
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