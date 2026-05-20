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
    Import-DscResource -ModuleName 'GroupPolicyDsc'

    # Define log share
    $LogFolder = "DSC"
    $LogPath = "c:\staging\$LogFolder"

    # Read config
    $deployConfig = Get-Content -Path $DeployConfigPath | ConvertFrom-Json
    $DomainName = $deployConfig.parameters.domainName
    $DomainAdminName = $deployConfig.vmOptions.adminName


    $usePKI = $false
    $prePopulate = $false
    $enableBLM = $false
    if ($deployConfig.cmOptions) {
        if ($deployConfig.cmOptions.UsePKI) {
            $usePKI = $deployConfig.cmOptions.UsePKI
        }
        if ($deployConfig.cmOptions.PrePopulateObjects) {
            $prePopulate = $deployConfig.cmOptions.PrePopulateObjects
        }
        if ($deployConfig.cmOptions.EnableBLM) {
            $enableBLM = $deployConfig.cmOptions.EnableBLM
        }
    }


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
    [System.Collections.ArrayList]$waitOnDomainJoin = @($ThisVM.thisParams.ServersToWaitOn)


    $Domain = $deployConfig.vmOptions.domainName
    $DNName = 'DC=' + $Domain.Replace('.',',DC=')    
    #$domainNameSplit = ($deployConfig.vmOptions.domainName).Split(".")
    #$DNName = "DC=$($domainNameSplit[0]),DC=$($domainNameSplit[1])"

    $OtherDC = $false

    $OtherDCVM = $deployConfig.virtualMachines | Where-Object { $_.role -eq "OtherDC" }
    if ($OtherDCVM) {
        $OtherDC = $true
    }

 
    $sitecount = 0
    $GroupMembersList = @()
    $GroupMembersList += $deployConfig.virtualMachines | Where-Object { $_.role -in ("CAS", "Primary", "PassiveSite", "Secondary") -and -not $_.Hidden }
    [System.Collections.ArrayList]$cmgroupMembers = @()
    foreach ($member in $GroupMembersList) {
        $memberName = $member.vmName + "$"
        if (-not $cmgroupMembers.Contains($memberName)) {
            $sitecount = $cmgroupMembers.Add($memberName)
            $sitecount++
        }
    }

    $GroupMembersList += $deployConfig.virtualMachines | Where-Object { $_.InstallMP -and -not $_.Hidden }
    $GroupMembersList += $deployConfig.virtualMachines | Where-Object { $_.InstallDP -and -not $_.Hidden }
    $GroupMembersList += $deployConfig.virtualMachines | Where-Object { $_.InstallRP -and -not $_.Hidden }
    $GroupMembersList += $deployConfig.virtualMachines | Where-Object { $_.InstallSUP -and -not $_.Hidden }
    $iiscount = 0
    [System.Collections.ArrayList]$iisgroupMembers = @()
    foreach ($member in $GroupMembersList) {
        $memberName = $member.vmName + "$"
        if (-not $iisgroupMembers.Contains($memberName)) {
            $iiscount = $iisgroupMembers.Add($memberName)
            $iiscount++
        }

        if (-not $waitOnDomainJoin.Contains($member.vmName)) {
            $waitOnDomainJoin += $member.vmName
        }
    }

    # BitLocker Management: collect VMs that should be moved to the BLM OU
    [System.Collections.ArrayList]$blmVMs = @()
    if ($enableBLM) {
        foreach ($vm in $deployConfig.virtualMachines) {
            if ($vm.BitLocker -eq $true -and -not $vm.Hidden) {
                [void]$blmVMs.Add($vm.vmName)
                if (-not $waitOnDomainJoin.Contains($vm.vmName)) {
                    $waitOnDomainJoin += $vm.vmName
                }
            }
        }
    }

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

       

        WriteStatus SetIPDG {
            DependsOn = "[Computer]NewName"
            Status    = "Assigning Static IP '$DHCP_DNSAddress' and Default Gateway '$DHCP_DefaultGateway'"
        }


        $alias = (Get-NetAdapter).Name | Select-Object -First 1
    
        IPAddress DCIPAddress {
            DependsOn      = "[WriteStatus]SetIPDG"
            IPAddress      = "$DHCP_DNSAddress/24"
            InterfaceAlias = $alias
            AddressFamily  = 'IPV4'
        }

        DefaultGatewayAddress SetDefaultGateway {
            DependsOn      = "[IPAddress]DCIPAddress"
            Address        = $DHCP_DefaultGateway
            InterfaceAlias = $alias
            AddressFamily  = 'IPv4'
        }

        DnsServerAddress SetDNS {
            Address        = $DHCP_DNSAddress
            InterfaceAlias = $alias
            AddressFamily  = 'IPv4'
            Validate       = $false
            DependsOn      = "[DefaultGatewayAddress]SetDefaultGateway"
        }

        WriteStatus InstallFeature {
            DependsOn = "[DefaultGatewayAddress]SetDefaultGateway"
            Status    = "Installing required windows features"
        }

        InstallFeatureForSCCM InstallFeature {
            Name      = 'DC'
            Role      = 'DC'
            DependsOn = "[InitializeDisks]InitDisks"
        }

        WriteStatus FirstDS {
            DependsOn = "[InstallFeatureForSCCM]InstallFeature"
            Status    = "Configuring ADDS and setting up the domain. The computer will reboot a couple of times."
        }

        $netbiosName = $deployConfig.vmOptions.domainNetBiosName

        ADDomain FirstDS {
            DomainName                    = $DomainName
            Credential                    = $DomainCreds
            SafemodeAdministratorPassword = $DomainCreds
            ForestMode                    = 'WinThreshold'
            DomainMode                    = 'WinThreshold'
            DependsOn                     = "[WriteStatus]FirstDS"
            DomainNetBiosName             = $netbiosName
        }

        $PageFileSize = ($thisVM.memory) / 2MB
        SetCustomPagingFile PagingSettings {
            DependsOn   = "[ADDomain]FirstDS"
            Drive       = 'C:'
            InitialSize = $PageFileSize
            MaximumSize = $PageFileSize
        }

        WriteStatus CreateAccounts {
            DependsOn = "[SetCustomPagingFile]PagingSettings"
            Status    = "Creating user accounts and groups"
        }

        $nextDepend = "[WriteStatus]CreateAccounts"

        WriteStatus InstallDotNet {
            DependsOn = $nextDepend
            Status    = "Installing .NET 4.8"
        }

        InstallDotNet4 DotNet {
            DownloadUrl = $deployConfig.URLS.DotNet
            FileName    = "ndp48-x86-x64-allos-enu.exe"
            NetVersion  = "528040"
            Ensure      = "Present"
            DependsOn   = "[WriteStatus]InstallDotNet"
        }

        $nextDepend = "[InstallDotNet4]DotNet"

        AddNtfsPermissions AddNtfsPerms {
            Ensure    = "Present"
            DependsOn = $nextDepend
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

        $IPAddresses = @('1.1.1.1', '8.8.8.8', '9.9.9.9')
        if ($deployConfig.DNSForwarders) {
            $IPAddresses = $deployConfig.DNSForwarders
        }
                
        DnsServerForwarder DnsServerForwarder {
            DependsOn        = "[DefaultGatewayAddress]SetDefaultGateway"
            IsSingleInstance = 'Yes'
            IPAddresses      = $IPAddresses
            UseRootHint      = $true
            EnableReordering = $true
        }

        $nextDepend = "[DnsServerForwarder]DnsServerForwarder"
        $waitOnDependency = "[DnsServerForwarder]DnsServerForwarder"

        Service ADWS {
            Name      = "ADWS"
            State     = "Running"
            DependsOn = $nextDepend
        }

        $nextDepend = "[Service]ADWS"
        $waitOnDependency = "[Service]ADWS"

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

       
        AddToAdminGroup AddLocalAdmins {
            DomainName   = "NONE"
            AccountNames = @($DomainAdminName, $Admincreds.UserName)
            TargetGroup  = "Administrators"
            DependsOn    = $adObjectDependency
        }

        ADGroup AddToDomainAdmin {
            GroupName        = "Domain Admins"
            MembersToInclude = @($DomainAdminName, $Admincreds.UserName)
            DependsOn        = $adObjectDependency
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

            ADReplicationSiteLink "HQSiteLink$($i)" {
                Name                          = "SiteLink Default-First-Site-Name to $($site.SiteCode) 2-way"
                SitesIncluded                 = @('Default-First-Site-Name', $site.SiteCode)
                Cost                          = 99
                ReplicationFrequencyInMinutes = 1
                Ensure                        = 'Present'
                OptionChangeNotification      = $true
                OptionTwoWaySync              = $true
                DependsOn                     = "[ADReplicationSite]ADSite$($i)"
            }
            $adSiteDependency += "[ADReplicationSiteLink]HQSiteLink$($i)"
            $adSiteDependency += "[ADReplicationSubnet]ADSubnet$($i)"
            $nextDepend = $adSiteDependency
        }
      

        if ($OtherDC) {
            DnsServerConditionalForwarder 'Forwarder1' {
                Name             = $($OtherDCVM.thisParams.Domain)
                MasterServers    = @($($OtherDCVM.thisParams.IPAddr))
                ReplicationScope = 'Forest'
                Ensure           = 'Present'
                DependsOn        = $nextDepend
            }

            $nextDepend = "[DnsServerConditionalForwarder]Forwarder1"
            $waitOnDependency = "[DnsServerConditionalForwarder]Forwarder1"
            [System.Management.Automation.PSCredential]$RemoteDomainCreds = New-Object System.Management.Automation.PSCredential ("$($OtherDCVM.thisParams.Domain)\$($Admincreds.UserName)", $Admincreds.Password)
            ADDomainTrust 'Trust' {
                Ensure               = 'Present'
                SourceDomainName     = $DomainName
                TargetDomainName     = $($OtherDCVM.thisParams.Domain)
                TargetCredential     = $RemoteDomainCreds
                TrustDirection       = 'Bidirectional'
                TrustType            = 'Forest'
                AllowTrustRecreation = $false
                DependsOn            = $nextDepend
            }

            $nextDepend = "[ADDomainTrust]Trust"
            $waitOnDependency = "[ADDomainTrust]Trust"
        }

        if ($prePopulate) {
            ADOrganizationalUnit 'MEMLABS-OSDComputers'
            {
                Name                            = "MEMLABS-OSDComputers"
                Path                            = $DNName
                ProtectedFromAccidentalDeletion = $false
                Description                     = "MEMLABS OSD Computers"
                Ensure                          = 'Present'
                DependsOn                       = $nextDepend
            }

            ADOrganizationalUnit 'MEMLABS-SecurityGroups'
            {
                Name                            = "MEMLABS-SecurityGroups"
                Path                            = $DNName
                ProtectedFromAccidentalDeletion = $false
                Description                     = "MEMLABS auto created security groups"
                Ensure                          = 'Present'
                DependsOn                       = $nextDepend
            }
            $nextDepend2 = "[ADOrganizationalUnit]MEMLABS-SecurityGroups"

            ADOrganizationalUnit 'MEMLABS-Users'
            {
                Name                            = "MEMLABS-Users"
                Path                            = $DNName
                ProtectedFromAccidentalDeletion = $false
                Description                     = "MEMLABS auto created users"
                Ensure                          = 'Present'
                DependsOn                       = $nextDepend
            }

            $nextDepend = "[ADOrganizationalUnit]MEMLABS-Users"

            $waitOnDependency = @($nextDepend)
            # Loop to create 50 users
            for ($i = 1; $i -le 50; $i++) {
                # Generate a random username
                $Username = "MEMLABS-User" + $i
            
            
                # Create the new user
                ADUser "MEMLABS-User$($i)" {
                    Ensure               = 'Present'
                    UserPrincipalName    = $Username + '@' + $DomainName
                    UserName             = $Username
                    Password             = $DomainCreds
                    PasswordNeverResets  = $true
                    PasswordNeverExpires = $true
                    CannotChangePassword = $true
                    DomainName           = $DomainName
                    DependsOn            = $nextDepend
                    Path                 = "OU=MEMLABS-Users,$DNName"
                }
                $waitOnDependency += "[ADUser]MEMLABS-User$($i)"
            }

            

            # List of department names
            $Departments = @(
                "HR",
                "Finance",
                "IT",
                "Marketing",
                "Sales",
                "Operations",
                "Legal",
                "Customer Service",
                "Engineering",
                "Product Management",
                "Research and Development",
                "Quality Assurance",
                "Supply Chain",
                "Administration",
                "Facilities",
                "Procurement",
                "Training",
                "Security",
                "Public Relations",
                "Compliance"
            )

            # Loop to create security groups for each department
            foreach ($Department in $Departments) {
                $GroupName = "MEMLABS-$Department-SecurityGroup"

                ADGroup $Department {
                    Ensure      = 'Present'
                    GroupName   = $GroupName
                    GroupScope  = "Global"
                    Category    = "Security"
                    Description = $GroupName
                    DependsOn   = $nextDepend2
                    Path        = "OU=MEMLABS-SecurityGroups,$DNName"
                }
                $waitOnDependency += "[ADGroup]$Department"
            }
        }

        if ($enableBLM) {
            WriteStatus BLMConfig {
                DependsOn = $waitOnDependency
                Status    = "Configuring BitLocker Management OU and Group Policy"
            }

            ADOrganizationalUnit 'MEMLABS-BitLockerClients'
            {
                Name                            = "MEMLABS-BitLockerClients"
                Path                            = $DNName
                ProtectedFromAccidentalDeletion = $false
                Description                     = "MEMLABS BitLocker Management target computers"
                Ensure                          = 'Present'
                DependsOn                       = $waitOnDependency
            }

            $blmGPOName = "BitLocker Drive Encryption"

            GroupPolicy BLMGroupPolicy {
                Name      = $blmGPOName
                DependsOn = "[ADOrganizationalUnit]MEMLABS-BitLockerClients"
            }

            GPLink BLMGPLink {
                Path      = "OU=MEMLABS-BitLockerClients,$DNName"
                GPOName   = $blmGPOName
                DependsOn = "[GroupPolicy]BLMGroupPolicy"
            }

            # OS Drive encryption method: XTS-AES 256
            GPRegistryValue BLMEncryptionMethod {
                Name      = $blmGPOName
                Key       = "HKLM\SOFTWARE\Policies\Microsoft\FVE"
                ValueName = "EncryptionMethodWithXtsOs"
                ValueType = "DWord"
                Value     = "7"
                DependsOn = "[GPLink]BLMGPLink"
            }

            # Require TPM (value 2 = require TPM)
            GPRegistryValue BLMUseTPM {
                Name      = $blmGPOName
                Key       = "HKLM\SOFTWARE\Policies\Microsoft\FVE"
                ValueName = "UseAdvancedStartup"
                ValueType = "DWord"
                Value     = "1"
                DependsOn = "[GPLink]BLMGPLink"
            }

            GPRegistryValue BLMRequireTPM {
                Name      = $blmGPOName
                Key       = "HKLM\SOFTWARE\Policies\Microsoft\FVE"
                ValueName = "EnableBDEWithNoTPM"
                ValueType = "DWord"
                Value     = "0"
                DependsOn = "[GPLink]BLMGPLink"
            }

            GPRegistryValue BLMUseTPMOnly {
                Name      = $blmGPOName
                Key       = "HKLM\SOFTWARE\Policies\Microsoft\FVE"
                ValueName = "UseTPM"
                ValueType = "DWord"
                Value     = "2"
                DependsOn = "[GPLink]BLMGPLink"
            }

            # No PIN or startup key required (unattended boot)
            GPRegistryValue BLMNoTPMPIN {
                Name      = $blmGPOName
                Key       = "HKLM\SOFTWARE\Policies\Microsoft\FVE"
                ValueName = "UseTPMPIN"
                ValueType = "DWord"
                Value     = "0"
                DependsOn = "[GPLink]BLMGPLink"
            }

            GPRegistryValue BLMNoTPMKey {
                Name      = $blmGPOName
                Key       = "HKLM\SOFTWARE\Policies\Microsoft\FVE"
                ValueName = "UseTPMKey"
                ValueType = "DWord"
                Value     = "0"
                DependsOn = "[GPLink]BLMGPLink"
            }

            GPRegistryValue BLMNoTPMKeyPIN {
                Name      = $blmGPOName
                Key       = "HKLM\SOFTWARE\Policies\Microsoft\FVE"
                ValueName = "UseTPMKeyPIN"
                ValueType = "DWord"
                Value     = "0"
                DependsOn = "[GPLink]BLMGPLink"
            }

            # Store recovery info in Active Directory
            GPRegistryValue BLMADBackup {
                Name      = $blmGPOName
                Key       = "HKLM\SOFTWARE\Policies\Microsoft\FVE"
                ValueName = "ActiveDirectoryBackup"
                ValueType = "DWord"
                Value     = "1"
                DependsOn = "[GPLink]BLMGPLink"
            }

            GPRegistryValue BLMRequireADBackup {
                Name      = $blmGPOName
                Key       = "HKLM\SOFTWARE\Policies\Microsoft\FVE"
                ValueName = "RequireActiveDirectoryBackup"
                ValueType = "DWord"
                Value     = "1"
                DependsOn = "[GPLink]BLMGPLink"
            }

            # OS Recovery options
            GPRegistryValue BLMOSRecovery {
                Name      = $blmGPOName
                Key       = "HKLM\SOFTWARE\Policies\Microsoft\FVE"
                ValueName = "OSRecovery"
                ValueType = "DWord"
                Value     = "1"
                DependsOn = "[GPLink]BLMGPLink"
            }

            GPRegistryValue BLMOSRecoveryPassword {
                Name      = $blmGPOName
                Key       = "HKLM\SOFTWARE\Policies\Microsoft\FVE"
                ValueName = "OSRecoveryPassword"
                ValueType = "DWord"
                Value     = "2"
                DependsOn = "[GPLink]BLMGPLink"
            }

            GPRegistryValue BLMOSRecoveryKey {
                Name      = $blmGPOName
                Key       = "HKLM\SOFTWARE\Policies\Microsoft\FVE"
                ValueName = "OSRecoveryKey"
                ValueType = "DWord"
                Value     = "0"
                DependsOn = "[GPLink]BLMGPLink"
            }

            GPRegistryValue BLMOSActiveDirectoryBackup {
                Name      = $blmGPOName
                Key       = "HKLM\SOFTWARE\Policies\Microsoft\FVE"
                ValueName = "OSActiveDirectoryBackup"
                ValueType = "DWord"
                Value     = "1"
                DependsOn = "[GPLink]BLMGPLink"
            }

            GPRegistryValue BLMOSActiveDirectoryInfoToStore {
                Name      = $blmGPOName
                Key       = "HKLM\SOFTWARE\Policies\Microsoft\FVE"
                ValueName = "OSActiveDirectoryInfoToStore"
                ValueType = "DWord"
                Value     = "1"
                DependsOn = "[GPLink]BLMGPLink"
            }

            $waitOnDependency = "[GPRegistryValue]BLMOSActiveDirectoryInfoToStore"
        }

        if ($ThisVM.InstallCA) {
            # CA installation is handled by the host-driven PKI orchestrator
            # (Install-PKI) after Phase2 completes. This ensures consistent
            # behavior regardless of whether the CA is on a DC or member server.
            WriteStatus ADCS {
                DependsOn = $waitOnDependency
                Status    = "Skipping CA install (will be configured post-Phase2 by PKI orchestrator)"
            }
        }

       
        File ShareFolder {
            DestinationPath = $LogPath
            Type            = 'Directory'
            Ensure          = 'Present'
            DependsOn       = $waitOnDependency
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

        # Move BitLocker-enabled VMs to the BLM OU after they join the domain
        if ($blmVMs.Count -gt 0) {
            WriteStatus MoveBLMComputers {
                DependsOn = $waitOnDependency
                Status    = "Moving BitLocker-targeted VMs to MEMLABS-BitLockerClients OU"
            }

            $blmOUPath = "OU=MEMLABS-BitLockerClients,$DNName"
            foreach ($blmVM in $blmVMs) {
                MoveComputerToOU "MoveBLM_$blmVM" {
                    ComputerName = $blmVM
                    TargetOU     = $blmOUPath
                    Ensure       = "Present"
                    DependsOn    = "[DelegateControl]Add$blmVM"
                }
                $waitOnDependency += "[MoveComputerToOU]MoveBLM_$blmVM"
            }
        }

        if ($sitecount) {

            ADGroup ConfigMgrSiteServers {
                Ensure           = 'Present'
                GroupName        = 'ConfigMgr Site Servers'
                GroupScope       = "Global"
                Category         = "Security"
                Description      = 'ConfigMgr Site Servers'
                MembersToInclude = $cmgroupMembers
                DependsOn        = $waitOnDependency
            }
            $waitOnDependency = "[ADGroup]ConfigMgrSiteServers"
        }

        if ($iiscount) {

            ADGroup ConfigMgrIISServers {
                Ensure           = 'Present'
                GroupName        = 'ConfigMgr IIS Servers'
                GroupScope       = "Global"
                Category         = "Security"
                Description      = 'ConfigMgr IIS Servers'
                MembersToInclude = $iisgroupMembers
                DependsOn        = $waitOnDependency
            }
            $waitOnDependency = "[ADGroup]ConfigMgrIISServers"
        }


        if ($usePKI) {
            WriteStatus GroupPolicyStatus {
                DependsOn = $waitOnDependency
                Status    = "Installing Auto Enrollment Group Policy"
            }

            $GPOName = "Certificate AutoEnrollment"

            GroupPolicy GroupPolicyConfig {
                Name      = $GPOName
                DependsOn = $waitOnDependency
            }

            GPLink GPLinkConfig {
                Path      = $DNName
                GPOName   = $GPOName
                DependsOn = "[GroupPolicy]GroupPolicyConfig"
            }

            GPRegistryValue GPRegistryValueConfig1 {
                Name      = $GPOName
                Key       = "HKLM\SOFTWARE\Policies\Microsoft\Cryptography\AutoEnrollment"
                ValueName = "AEPolicy"
                ValueType = "DWord"
                Value     = "7"
                DependsOn = "[GPLink]GPLinkConfig"
            }

            GPRegistryValue GPRegistryValueConfig2 {
                Name      = $GPOName
                Key       = "HKLM\SOFTWARE\Policies\Microsoft\Cryptography\AutoEnrollment"
                ValueName = "OfflineExpirationPercent"
                ValueType = "DWord"
                Value     = "10"
                DependsOn = "[GPLink]GPLinkConfig"
            }

            GPRegistryValue GPRegistryValueConfig3 {
                Name      = $GPOName
                Key       = "HKLM\SOFTWARE\Policies\Microsoft\Cryptography\AutoEnrollment"
                ValueName = "OfflineExpirationStoreNames"
                ValueType = "String"
                Value     = "MY"
                DependsOn = "[GPLink]GPLinkConfig"
            }
            $nextDepend = "[GPRegistryValue]GPRegistryValueConfig3"
            $waitOnDependency = $nextDepend
        }

        # Certificate template import and publishing is handled by the
        # host-driven PKI orchestrator (Install-PKI) after Phase2 completes.

        if ($ThisVM.externalDomainJoinSiteCode -and $ThisVM.externalDomainJoinSiteCode -ne "NONE") {
            [System.Management.Automation.PSCredential]$groupCreds = New-Object System.Management.Automation.PSCredential ("$($ThisVM.ForestTrust)\Admin", $Admincreds.Password)

            WriteStatus WaitExtSchema {
                DependsOn = $waitOnDependency
                Status    = "Waiting for site to download ConfigMgr source files, before extending schema for Configuration Manager"
            }

            WaitForExtendSchemaFile WaitForExtendSchemaFile {
                MachineName = $ThisVM.ThisParams.ExternalTopLevelSiteServer
                ExtFolder   = "CMCB"
                Ensure      = "Present"
                DependsOn   = $waitOnDependency
                AdminCreds  = $groupCreds
            }
            $waitOnDependency = "[WaitForExtendSchemaFile]WaitForExtendSchemaFile"

            WriteStatus WaitIISGroup {
                DependsOn = $waitOnDependency
                Status    = "Waiting for $($ThisVM.ForestTrust)\'ConfigMgr IIS Servers' to be a member on System Management Container"
            }

            DelegateControl "AddremoteIISGroup" {
                Machine        = 'ConfigMgr IIS Servers'
                DomainFullName = $ThisVM.ForestTrust
                Ensure         = "Present"
                DependsOn      = $waitOnDependency
                IsGroup        = $true
            }
            $waitOnDependency = "[DelegateControl]AddremoteIISGroup"
        }

        
        if ($ThisVM.ForestTrust -and $ThisVM.ForestTrust -ne "NONE") {
            AddToAdminGroup AddRemoteAdmins {
                DomainName   = $ThisVM.ForestTrust
                AccountNames = @($DomainAdminName, $Admincreds.UserName)
                RemoteCreds  = $groupCreds
                TargetGroup  = "Administrators"
                DependsOn    = $waitOnDependency
            }
            $waitOnDependency = "[AddToAdminGroup]AddRemoteAdmins"

            if ($ThisVM.ThisParams.RootCA) {
                AddToAdminGroup AddCertPublisher {
                    DomainName   = $ThisVM.ForestTrust
                    AccountNames = "$($OtherDCVM.VmName)$"
                    RemoteCreds  = $groupCreds
                    TargetGroup  = "Cert Publishers"
                    DependsOn    = $waitOnDependency
                }
                $waitOnDependency = "[AddToAdminGroup]AddCertPublisher"

                InstallRootCertificate InstallRootCertificate {
                    CAName    = $ThisVM.ThisParams.RootCA
                    DependsOn = $waitOnDependency
                }
                $waitOnDependency = "[InstallRootCertificate]InstallRootCertificate"

                RunPkiSync RunPkiSync {
                    SourceForest = $ThisVM.ForestTrust
                    TargetForest = $DomainName
                    DependsOn    = $waitOnDependency
                }
                $waitOnDependency = "[RunPkiSync]RunPkiSync"
            }
        }



        
        RemoteDesktopAdmin RemoteDesktopSettings {
            IsSingleInstance   = 'yes'
            Ensure             = 'Present'
            UserAuthentication = 'NonSecure'
            DependsOn          = $waitOnDependency
        }


        WriteEvent WriteConfigFinished {
            LogPath   = $LogPath
            WriteNode = "ConfigurationFinished"
            Status    = "Passed"
            Ensure    = "Present"
            DependsOn = "[RemoteDesktopAdmin]RemoteDesktopSettings"
        }

        WriteStatus Complete {
            DependsOn = "[WriteEvent]WriteConfigFinished"
            Status    = "Complete!"
        }
    }
}