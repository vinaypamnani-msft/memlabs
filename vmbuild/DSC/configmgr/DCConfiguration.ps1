configuration DCConfiguration
{
    param
    (
        [Parameter(Mandatory)]
        [string]$ConfigFilePath,
        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$Admincreds
    )

    Import-DscResource -ModuleName 'TemplateHelpDSC'
    Import-DscResource -ModuleName 'PSDesiredStateConfiguration', 'NetworkingDsc', 'xDhcpServer', 'DnsServerDsc', 'ComputerManagementDsc', 'ActiveDirectoryDsc'

    # Read config
    $deployConfig = Get-Content -Path $ConfigFilePath | ConvertFrom-Json
    $ThisMachineName = $deployConfig.thisParams.MachineName
    $ThisVM = $deployConfig.virtualMachines | Where-Object { $_.vmName -eq $ThisMachineName }
    $DomainName = $deployConfig.parameters.domainName
    $DomainAdminName = $deployConfig.vmOptions.adminName
    $PSName = $deployConfig.thisParams.PSName
    $CSName = $deployConfig.thisParams.CSName

    $DHCP_DNSAddress = $deployConfig.parameters.DHCPDNSAddress
    $DHCP_DefaultGateway = $deployConfig.parameters.DHCPDefaultGateway

    $setNetwork = $true
    if ($ThisVM.hidden) {
        $setNetwork = $false
    }

    # AD Sites
    $adsites = $deployConfig.thisParams.sitesAndNetworks

    # Define log share
    $LogFolder = "DSC"
    $LogPath = "c:\staging\$LogFolder"

    # CM Files folder/share
    $CM = if ($deployConfig.cmOptions.version -eq "tech-preview") { "CMTP" } else { "CMCB" }

    # Servers for which permissions need to be added to systems management contaienr
    $waitOnDomainJoin = $deployConfig.thisParams.ServersToWaitOn

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

        WriteStatus FirstDS {
            DependsOn = "[InstallFeatureForSCCM]InstallFeature"
            Status    = "Configuring ADDS and setting up the domain. The computer will reboot a couple of times."
        }

        SetupDomain FirstDS {
            DependsOn                     = "[InstallFeatureForSCCM]InstallFeature"
            DomainFullName                = $DomainName
            SafemodeAdministratorPassword = $DomainCreds
        }

        ADUser Admin {
            Ensure               = 'Present'
            UserName             = $DomainAdminName
            Password             = $DomainCreds
            PasswordNeverResets  = $true
            PasswordNeverExpires = $true
            CannotChangePassword = $true
            DomainName           = $DomainName
            DependsOn            = "[SetupDomain]FirstDS"
        }

        ADUser administrator {
            Ensure               = 'Present'
            UserName             = 'administrator'
            Password             = $DomainCreds
            PasswordNeverResets  = $true
            PasswordNeverExpires = $true
            CannotChangePassword = $true
            DomainName           = $DomainName
            DependsOn            = "[ADUser]Admin"
        }

        ADUser cm-svc {
            Ensure               = 'Present'
            UserName             = 'cm_svc'
            Password             = $DomainCreds
            PasswordNeverResets  = $true
            PasswordNeverExpires = $true
            CannotChangePassword = $true
            DomainName           = $DomainName
            DependsOn            = "[SetupDomain]FirstDS"
        }

        ADUser vmbuildadmin {
            Ensure               = 'Present'
            UserName             = 'vmbuildadmin'
            Password             = $DomainCreds
            PasswordNeverResets  = $true
            PasswordNeverExpires = $true
            CannotChangePassword = $true
            DomainName           = $DomainName
            DependsOn            = "[SetupDomain]FirstDS"
        }

        ADGroup AddToAdmin {
            GroupName        = "Administrators"
            MembersToInclude = @($DomainAdminName)
            DependsOn        = "[ADUser]Admin"
        }

        ADGroup AddToDomainAdmin {
            GroupName        = "Domain Admins"
            MembersToInclude = @($DomainAdminName, $Admincreds.UserName)
            DependsOn        = @("[ADUser]Admin", "[ADUser]cm-svc")
        }

        ADGroup AddToSchemaAdmin {
            GroupName        = "Schema Admins"
            MembersToInclude = @($DomainAdminName)
            DependsOn        = "[ADUser]Admin"
        }

        $adSiteDependency = @()
        $i = 0
        foreach ($site in $adsites) {
            $i++
            ADReplicationSite "ADSite$($i)" {
                Ensure    = 'Present'
                Name      = $site.SiteCode
                DependsOn = "[ADGroup]AddToSchemaAdmin"
            }

            ADReplicationSubnet "ADSubnet$($i)" {
                Name        = "$($site.Subnet)/24"
                Site        = $site.SiteCode
                Location    = $site.SiteCode
                Description = 'Created by vmbuild'
                DependsOn   = "[ADReplicationSite]ADSite$($i)"
            }

            $adSiteDependency += "[ADReplicationSubnet]ADSubnet$($i)"
        }

        AddNtfsPermissions AddNtfsPerms {
            Ensure    = "Present"
            DependsOn = $adSiteDependency
        }

        OpenFirewallPortForSCCM OpenFirewall {
            DependsOn = "[AddNtfsPermissions]AddNtfsPerms"
            Name      = "DC"
            Role      = "DC"
        }

        if ($setNetwork) {

            WriteStatus NetworkDNS {
                DependsOn = "[SetupDomain]FirstDS"
                Status    = "Setting Primary DNS, Default Gateway and DNS Forwarders"
            }

            IPAddress NewIPAddressDC {
                DependsOn      = "[SetupDomain]FirstDS"
                IPAddress      = $DHCP_DNSAddress
                InterfaceAlias = 'Ethernet'
                AddressFamily  = 'IPV4'
            }

            DefaultGatewayAddress SetDefaultGateway {
                DependsOn      = "[IPAddress]NewIPAddressDC"
                Address        = $DHCP_DefaultGateway
                InterfaceAlias = 'Ethernet'
                AddressFamily  = 'IPv4'
            }

            DnsServerForwarder DnsServerForwarder {
                DependsOn        = "[DefaultGatewayAddress]SetDefaultGateway"
                IsSingleInstance = 'Yes'
                IPAddresses      = @('1.1.1.1', '8.8.8.8', '9.9.9.9')
                UseRootHint      = $true
                EnableReordering = $true
            }

            WriteStatus ADCS {
                DependsOn = "[DnsServerForwarder]DnsServerForwarder"
                Status    = "Installing Certificate Authority"
            }
        }
        else {
            WriteStatus ADCS {
                DependsOn = "[SetupDomain]FirstDS"
                Status    = "Installing Certificate Authority"
            }
        }

        InstallCA InstallCA {
            DependsOn     = "[WriteStatus]ADCS"
            HashAlgorithm = "SHA256"
        }

        WriteStatus InstallDotNet {
            DependsOn = "[InstallCA]InstallCA"
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
            DependsOn       = "[InstallDotNet472]DotNet"
        }

        FileReadAccessShare DomainSMBShare {
            Name      = $LogFolder
            Path      = $LogPath
            DependsOn = "[File]ShareFolder"
        }

        WriteStatus WaitDomainJoin {
            DependsOn = "[FileReadAccessShare]DomainSMBShare"
            Status    = "Waiting for $($waitOnDomainJoin -join ',') to join the domain"
        }

        $waitOnDependency = @()
        foreach ($server in $waitOnDomainJoin) {

            VerifyComputerJoinDomain "WaitFor$server" {
                ComputerName = $server
                Ensure       = "Present"
                DependsOn    = "[WriteStatus]WaitDomainJoin"
            }

            DelegateControl "Add$server" {
                Machine        = $server
                DomainFullName = $DomainName
                Ensure         = "Present"
                DependsOn      = "[VerifyComputerJoinDomain]WaitFor$server"
            }

            $waitOnDependency += "[DelegateControl]Add$server"
        }

        WriteEvent WriteDelegateControlfinished {
            LogPath   = $LogPath
            WriteNode = "DelegateControl"
            Status    = "Passed"
            Ensure    = "Present"
            DependsOn = $waitOnDependency
        }

        if (-not ($PSName -or $CSName)) {

            WriteStatus Complete {
                DependsOn = "[WriteEvent]WriteDelegateControlfinished"
                Status    = "Complete!"
            }

        }
        else {

            WriteStatus WaitExtSchema {
                DependsOn = "[WriteEvent]WriteDelegateControlfinished"
                Status    = "Waiting for site to download ConfigMgr source files, before extending schema for Configuration Manager"
            }

            WaitForExtendSchemaFile WaitForExtendSchemaFile {
                MachineName = if ($CSName) { $CSName } else { $PSName }
                ExtFolder   = $CM
                Ensure      = "Present"
                DependsOn   = "[WriteEvent]WriteDelegateControlfinished"
            }

            WriteStatus Complete {
                DependsOn = "[WaitForExtendSchemaFile]WaitForExtendSchemaFile"
                Status    = "Complete!"
            }

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