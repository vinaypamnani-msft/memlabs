configuration Phase2DC
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
    $DomainAdminName = $deployConfig.vmOptions.adminName

    # This VM
    $ThisMachineName = $deployConfig.parameters.ThisMachineName
    $ThisVM = $deployConfig.virtualMachines | Where-Object { $_.vmName -eq $ThisMachineName }

    # DC's IP and DG
    $DHCP_DNSAddress = $ThisVM.thisParams.DCIPAddress
    $DHCP_DefaultGateway = $ThisVM.thisParams.DCDefaultGateway

    # Accounts to create
    $DomainAccounts = $ThisVM.thisParams.DomainAccounts
    $DomainAccountsUPN = $ThisVM.thisParams.DomainAccountsUPN
    $DomainComputers = $ThisVM.thisParams.DomainComputers

    # AD Sites
    $adsites = $ThisVM.thisParams.sitesAndNetworks

    # Wait on machines to join domain
    $waitOnDomainJoin = $ThisVM.thisParams.ServersToWaitOn

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

        WriteStatus SetIPDG {
            DependsOn = "[Computer]NewName"
            Status    = "Assigning Static IP '$DHCP_DNSAddress' and Default Gateway '$DHCP_DefaultGateway'"
        }

        IPAddress DCIPAddress {
            DependsOn      = "[WriteStatus]SetIPDG"
            IPAddress      = "$DHCP_DNSAddress/24"
            InterfaceAlias = 'Ethernet'
            AddressFamily  = 'IPV4'
        }

        DefaultGatewayAddress SetDefaultGateway {
            DependsOn      = "[IPAddress]DCIPAddress"
            Address        = $DHCP_DefaultGateway
            InterfaceAlias = 'Ethernet'
            AddressFamily  = 'IPv4'
        }

        WriteStatus InstallFeature {
            DependsOn = "[DefaultGatewayAddress]SetDefaultGateway"
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

        #SetupDomain FirstDS {
        #    DependsOn                     = "[InstallFeatureForSCCM]InstallFeature"
        #    DomainFullName                = $DomainName
        #    SafemodeAdministratorPassword = $DomainCreds
        #}

        ADDomain FirstDS
        {
            DomainName                    = $DomainName
            Credential                    = $DomainCreds
            SafemodeAdministratorPassword = $DomainCreds
            ForestMode                    = 'WinThreshold'
            DomainMode                    = 'WinThreshold'
        }

        WriteStatus CreateAccounts {
            DependsOn = "[ADDomain]FirstDS"
            Status    = "Creating user accounts and groups"
        }

        $nextDepend = "[WriteStatus]CreateAccounts"
        $adObjectDependency = @($nextDepend)
        $i = 0
        foreach ($user in $DomainAccounts) {
            $i++
            ADUser "User$($i)" {
                Ensure               = 'Present'
                UserName             = $user
                Password             = $DomainCreds
                PasswordNeverResets  = $true
                PasswordNeverExpires = $true
                CannotChangePassword = $true
                DomainName           = $DomainName
                DependsOn            = $nextDepend
            }
            $adObjectDependency += "[ADUser]User$($i)"
        }

        foreach ($userWithUPN in $DomainAccountsUPN) {
            $i++
            ADUser "User$($i)" {
                Ensure               = 'Present'
                UserPrincipalName    = $userWithUPN + '@' + $DomainName
                UserName             = $userWithUPN
                Password             = $DomainCreds
                PasswordNeverResets  = $true
                PasswordNeverExpires = $true
                CannotChangePassword = $true
                DomainName           = $DomainName
                DependsOn            = $nextDepend
            }
            $adObjectDependency += "[ADUser]User$($i)"
        }

        $i = 0
        foreach ($computer in $DomainComputers) {
            $i++
            ADComputer "Computer$($i)" {
                ComputerName      = $computer
                EnabledOnCreation = $false
                DependsOn         = $nextDepend
            }
            $adObjectDependency += "[ADComputer]Computer$($i)"
        }

        ADGroup AddToAdmin {
            GroupName        = "Administrators"
            MembersToInclude = @($DomainAdminName, $Admincreds.UserName)
            DependsOn        = $adObjectDependency
        }

        ADGroup AddToDomainAdmin {
            GroupName        = "Domain Admins"
            MembersToInclude = @($DomainAdminName, $Admincreds.UserName)
            DependsOn        = "[ADGroup]AddToAdmin"
        }

        ADGroup AddToSchemaAdmin {
            GroupName        = "Schema Admins"
            MembersToInclude = @($DomainAdminName, $Admincreds.UserName)
            DependsOn        = "[ADGroup]AddToDomainAdmin"
        }

        $nextDepend = "[ADGroup]AddToSchemaAdmin"
        $adSiteDependency = @($nextDepend)
        $i = 0
        foreach ($site in $adsites) {
            $i++
            ADReplicationSite "ADSite$($i)" {
                Ensure    = 'Present'
                Name      = $site.SiteCode
                DependsOn = $nextDepend
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

        WriteStatus NetworkDNS {
            DependsOn = "[OpenFirewallPortForSCCM]OpenFirewall"
            Status    = "Setting Primary DNS, and DNS Forwarders"
        }

        DnsServerForwarder DnsServerForwarder {
            DependsOn        = "[DefaultGatewayAddress]SetDefaultGateway"
            IsSingleInstance = 'Yes'
            IPAddresses      = @('1.1.1.1', '8.8.8.8', '9.9.9.9')
            UseRootHint      = $true
            EnableReordering = $true
        }

        $nextDepend = "[DnsServerForwarder]DnsServerForwarder"
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

        WriteStatus WaitDomainJoin {
            DependsOn = "[FileReadAccessShare]DomainSMBShare"
            Status    = "Waiting for $($waitOnDomainJoin -join ',') to join the domain"
        }

        $nextDepend = "[WriteStatus]WaitDomainJoin"
        $waitOnDependency = @($nextDepend)
        foreach ($server in $waitOnDomainJoin) {

            VerifyComputerJoinDomain "WaitFor$server" {
                ComputerName = $server
                Ensure       = "Present"
                DependsOn    = $nextDepend
            }

            DelegateControl "Add$server" {
                Machine        = $server
                DomainFullName = $DomainName
                Ensure         = "Present"
                DependsOn      = "[VerifyComputerJoinDomain]WaitFor$server"
            }

            $waitOnDependency += "[DelegateControl]Add$server"
        }

        RemoteDesktopAdmin RemoteDesktopSettings {
            IsSingleInstance   = 'yes'
            Ensure             = 'Present'
            UserAuthentication = 'NonSecure'
            DependsOn          = $waitOnDependency
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