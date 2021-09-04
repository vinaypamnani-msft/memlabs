configuration DCConfiguration
{
    param
    (
        [Parameter(Mandatory)]
        [String]$DomainName,
        [Parameter(Mandatory)]
        [String]$DCName,
        [Parameter(Mandatory)]
        [String]$DPMPName,
        [Parameter(Mandatory)]
        [String]$CSName,
        [Parameter(Mandatory)]
        [String]$PSName,
        [Parameter(Mandatory)]
        [System.Array]$ClientName,
        [Parameter(Mandatory)]
        [String]$Configuration,
        [Parameter(Mandatory)]
        [String]$DNSIPAddress,
        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$Admincreds
    )

    Import-DscResource -ModuleName 'TemplateHelpDSC'
    Import-DscResource -ModuleName 'PSDesiredStateConfiguration', 'NetworkingDsc', 'xDhcpServer', 'DnsServerDsc', 'ComputerManagementDsc', 'ActiveDirectoryDsc'


    $LogFolder = "TempLog"
    $LogPath = "c:\$LogFolder"
    $CM = "CMCB"
    $DName = $DomainName.Split(".")[0]
    if ($Configuration -ne "Standalone") {
        $CSComputerAccount = "$DName\$CSName$"
    }
    $PSComputerAccount = "$DName\$PSName$"
    $DPMPComputerAccount = "$DName\$DPMPName$"
    $Clients = [system.String]::Join(",", $ClientName)
    $ClientComputerAccount = "$DName\$Clients$"

    [System.Management.Automation.PSCredential]$DomainCreds = New-Object System.Management.Automation.PSCredential ("${DomainName}\$($Admincreds.UserName)", $Admincreds.Password)

    $DHCPScopeId = "192.168.1.0"

    Node LOCALHOST
    {
        LocalConfigurationManager {
            ConfigurationMode  = 'ApplyOnly'
            RebootNodeIfNeeded = $true
        }

        WriteStatus NewName {
            Status = "Renaming the computer to $DCName"
        }

        Computer NewName {            
            Name = $DCName
        }

        SetCustomPagingFile PagingSettings {
            DependsOn   = "[Computer]NewName"
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
            Ensure              = 'Present'
            UserName            = 'admin'
            Password            = $DomainCreds
            PasswordNeverResets = $true
            DomainName          = $DomainName
            DependsOn           = "[SetupDomain]FirstDS"
        }

        ADGroup AddToAdmin {
            GroupName        = "Administrators"
            MembersToInclude = @("admin")
            DependsOn        = "[ADUser]Admin"
        }

        ADGroup AddToDomainAdmin {
            GroupName        = "Domain Admins"
            MembersToInclude = @("admin")
            DependsOn        = "[ADUser]Admin"
        }

        ADGroup AddToSchemaAdmin {
            GroupName        = "Schema Admins"
            MembersToInclude = @("admin")
            DependsOn        = "[ADUser]Admin"
        }

        WriteStatus NetworkDNS {
            DependsOn = "[SetupDomain]FirstDS"
            Status    = "Setting Primary DNS, Default Gateway and configuring DNS Forwarders"
        }

        IPAddress NewIPAddressDC {
            DependsOn      = "[SetupDomain]FirstDS"
            IPAddress      = $DNSIPAddress
            InterfaceAlias = 'Ethernet'
            AddressFamily  = 'IPV4'
        }

        DefaultGatewayAddress SetDefaultGateway {
            DependsOn      = "[IPAddress]NewIPAddressDC"
            Address        = '192.168.1.200'
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

        WriteStatus NetworkDHCP {
            DependsOn = "[DnsServerForwarder]DnsServerForwarder"
            Status    = "Installing DHCP and configuring DHCP scopes & options"
        }

        WindowsFeature DHCP {
            DependsOn            = "[DnsServerForwarder]DnsServerForwarder"
            Name                 = 'DHCP'
            Ensure               = 'Present'
            IncludeAllSubFeature = $true
        }

        WindowsFeature RSAT-DHCP {
            DependsOn            = "[WindowsFeature]DHCP"
            Name                 = 'RSAT-DHCP'
            Ensure               = 'Present'
            IncludeAllSubFeature = $true
        }
    
        xDhcpServerAuthorization LocalServerActivation {
            DependsOn        = "[WindowsFeature]RSAT-DHCP"
            IsSingleInstance = 'Yes'
            Ensure           = 'Present'
        }

        xDhcpServerScope Scope {
            DependsOn     = "[xDhcpServerAuthorization]LocalServerActivation"
            Ensure        = 'Present'
            ScopeId       = $DHCPScopeId
            IPStartRange  = '192.168.1.20'
            IPEndRange    = '192.168.1.199'
            Name          = 'ScopeCB1'
            SubnetMask    = '255.255.255.0'
            LeaseDuration = ((New-TimeSpan -Hours 72).ToString())
            State         = 'Active'
            AddressFamily = 'IPv4'
        }

        DhcpScopeOptionValue ScopeOptionGateway {
            DependsOn     = "[xDhcpServerScope]Scope"
            OptionId      = 3
            Value         = '192.168.1.200'
            ScopeId       = $DHCPScopeId
            VendorClass   = ''
            UserClass     = ''
            AddressFamily = 'IPv4'
        }

        DhcpScopeOptionValue ScopeOptionDNS {
            DependsOn     = "[DhcpScopeOptionValue]ScopeOptionGateway"
            OptionId      = 6
            Value         = @($DNSIPAddress)
            ScopeId       = $DHCPScopeId
            VendorClass   = ''
            UserClass     = ''
            AddressFamily = 'IPv4'
        }

        WriteStatus ADCS {
            DependsOn = "[DhcpScopeOptionValue]ScopeOptionDNS"
            Status    = "Installing Certificate Authority"
        }

        InstallCA InstallCA {
            DependsOn     = "[DhcpScopeOptionValue]ScopeOptionDNS"
            HashAlgorithm = "SHA256"
        }

        WriteStatus WaitDomainJoin {
            DependsOn = "[InstallCA]InstallCA"
            Status    = "Waiting for required servers to join the domain"
        }

        VerifyComputerJoinDomain WaitForPS {
            ComputerName = $PSName
            Ensure       = "Present"
            DependsOn    = "[InstallCA]InstallCA"
        }

        VerifyComputerJoinDomain WaitForDPMP {
            ComputerName = $DPMPName
            Ensure       = "Present"
            DependsOn    = "[InstallCA]InstallCA"
        }        

        VerifyComputerJoinDomain WaitForClient {
            ComputerName = $Clients
            Ensure       = "Present"
            DependsOn    = "[InstallCA]InstallCA"
        }

        if ($Configuration -eq 'Standalone') {

            File ShareFolder {            
                DestinationPath = $LogPath     
                Type            = 'Directory'            
                Ensure          = 'Present'
                DependsOn       = @("[VerifyComputerJoinDomain]WaitForPS", "[VerifyComputerJoinDomain]WaitForDPMP", "[VerifyComputerJoinDomain]WaitForClient")
            }

            FileReadAccessShare DomainSMBShare {
                Name      = $LogFolder
                Path      = $LogPath
                Account   = $PSComputerAccount, $DPMPComputerAccount, $ClientComputerAccount
                DependsOn = "[File]ShareFolder"
            }

            WriteConfigurationFile WriteDelegateControlfinished {
                Role      = "DC"
                LogPath   = $LogPath
                WriteNode = "DelegateControl"
                Status    = "Passed"
                Ensure    = "Present"
                DependsOn = @("[DelegateControl]AddPS", "[DelegateControl]AddDPMP")
            }

            WaitForExtendSchemaFile WaitForExtendSchemaFile {
                MachineName = $PSName
                ExtFolder   = $CM
                Ensure      = "Present"
                DependsOn   = "[WriteConfigurationFile]WriteDelegateControlfinished"
            }

            WriteStatus Complete {
                DependsOn = "[WriteConfigurationFile]WriteDelegateControlfinished"
                Status    = "Complete!"
            }

        }
        else {

            # Hierarchy

            VerifyComputerJoinDomain WaitForCS {
                ComputerName = $CSName
                Ensure       = "Present"
                DependsOn    = "[InstallCA]InstallCA"
            }

            File ShareFolder {            
                DestinationPath = $LogPath     
                Type            = 'Directory'            
                Ensure          = 'Present'
                DependsOn       = @("[VerifyComputerJoinDomain]WaitForCS", "[VerifyComputerJoinDomain]WaitForPS", "[VerifyComputerJoinDomain]WaitForDPMP", "[VerifyComputerJoinDomain]WaitForClient")
            }

            FileReadAccessShare DomainSMBShare {
                Name      = $LogFolder
                Path      = $LogPath
                Account   = $CSComputerAccount, $PSComputerAccount, $DPMPComputerAccount, $ClientComputerAccount
                DependsOn = "[File]ShareFolder"
            }
            
            WriteConfigurationFile WriteCSJoinDomain {
                Role      = "DC"
                LogPath   = $LogPath
                WriteNode = "CSJoinDomain"
                Status    = "Passed"
                Ensure    = "Present"
                DependsOn = "[FileReadAccessShare]DomainSMBShare"
            }

            DelegateControl AddCS {
                Machine        = $CSName
                DomainFullName = $DomainName
                Ensure         = "Present"
                DependsOn      = "[WriteConfigurationFile]WriteCSJoinDomain"
            }

            WriteConfigurationFile WriteDelegateControlfinished {
                Role      = "DC"
                LogPath   = $LogPath
                WriteNode = "DelegateControl"
                Status    = "Passed"
                Ensure    = "Present"
                DependsOn = @("[DelegateControl]AddCS", "[DelegateControl]AddPS", "[DelegateControl]AddDPMP")
            }

            WaitForExtendSchemaFile WaitForExtendSchemaFile {
                MachineName = $CSName
                ExtFolder   = $CM
                Ensure      = "Present"
                DependsOn   = "[WriteConfigurationFile]WriteDelegateControlfinished"
            }

            WriteStatus Complete {
                DependsOn = "[WriteConfigurationFile]WriteDelegateControlfinished"
                Status    = "Complete!"
            }

        }

        WriteConfigurationFile WritePSJoinDomain {
            Role      = "DC"
            LogPath   = $LogPath
            WriteNode = "PSJoinDomain"
            Status    = "Passed"
            Ensure    = "Present"
            DependsOn = "[FileReadAccessShare]DomainSMBShare"
        }

        WriteConfigurationFile WriteDPMPJoinDomain {
            Role      = "DC"
            LogPath   = $LogPath
            WriteNode = "DPMPJoinDomain"
            Status    = "Passed"
            Ensure    = "Present"
            DependsOn = "[FileReadAccessShare]DomainSMBShare"
        }

        WriteStatus AddPS {
            DependsOn = "[WriteConfigurationFile]WritePSJoinDomain"
            Status    = "Waiting for Configuration Manager installation"
        }

        DelegateControl AddPS {
            Machine        = $PSName
            DomainFullName = $DomainName
            Ensure         = "Present"
            DependsOn      = "[WriteConfigurationFile]WritePSJoinDomain"
        }

        DelegateControl AddDPMP {
            Machine        = $DPMPName
            DomainFullName = $DomainName
            Ensure         = "Present"
            DependsOn      = "[WriteConfigurationFile]WriteDPMPJoinDomain"
        }
    }
}