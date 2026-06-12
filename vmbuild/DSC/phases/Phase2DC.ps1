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


    # DC-level provisioning (PKI cert templates, CM content pre-pop, BLM cert
    # templates) is shared across every hierarchy in this domain. Use OR-across-
    # top-levels: if ANY top-level site server (CAS or standalone Primary) has
    # the flag set, the DC publishes it. Over-provisioning is harmless; under-
    # provisioning breaks the hierarchy that needed it. Falls back to the
    # rehydrated global block when no per-VM cmOptions are present yet (mid-
    # migration shape) or when no site servers are in this deploy.
    $usePKI = $false
    $prePopulate = $false
    $topLevelCmOptions = @($deployConfig.virtualMachines | Where-Object {
            $_.Role -in 'CAS', 'Primary' -and -not $_.parentSiteCode -and $_.cmOptions
        }).cmOptions
    if (-not $topLevelCmOptions -and $deployConfig.cmOptions) {
        $topLevelCmOptions = @($deployConfig.cmOptions)
    }
    foreach ($cmo in $topLevelCmOptions) {
        if ($cmo.UsePKI) { $usePKI = $true }
        if ($cmo.PrePopulateObjects) { $prePopulate = $true }
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

        # Set the KDC default encryption types so all accounts (even those
        # without msDS-SupportedEncryptionTypes) get AES tickets. Without this,
        # Windows Server 2025 issues only RC4 tickets for accounts that lack
        # the attribute, and SQL Server rejects them — causing NTLM fallback
        # and transient 18452 errors during setup.
        # Value 28 = RC4_HMAC (4) + AES128 (8) + AES256 (16)
        Registry KdcDefaultEncryptionTypes {
            Ensure    = 'Present'
            Key       = 'HKLM:\SYSTEM\CurrentControlSet\Services\KDC'
            ValueName = 'DefaultDomainSupportedEncTypes'
            ValueType = 'Dword'
            ValueData = '28'
            DependsOn = '[ADDomain]FirstDS'
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
       
        # Stamp msDS-SupportedEncryptionTypes = 28 (RC4 + AES128 + AES256) on
        # every domain user/service account created above, then reset each
        # account's password (to the SAME credential ADUser already set) so
        # the DC regenerates AES long-term keys with the attribute in place.
        #
        # Why both steps?  On Windows Server 2025 the KDC issues RC4-only
        # SERVICE tickets for accounts without this attribute (it won't
        # assume AES long-term keys), causing SQL to fall back to NTLM.
        # The KdcDefaultEncryptionTypes registry only fixes TGTs.  Setting
        # the attribute alone may not regenerate the AES long-term keys
        # stored in supplementalCredentials — a password reset is the only
        # documented way to guarantee the DC derives and stores them.
        $allDomainUserAccounts = @($DomainAccounts) + @($DomainAccountsUPN) | Where-Object { $_ } | Select-Object -Unique
        $cvUserAccountList = ($allDomainUserAccounts | ForEach-Object { "'$_'" }) -join ','
        $cvEncPassB64 = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($Admincreds.GetNetworkCredential().Password))
        Script SetUserKerberosEncryptionTypes {
            DependsOn  = $adObjectDependency
            GetScript  = { return @{ Result = (Get-Date).ToString() } }
            TestScript = [string]"
                `$accounts = @($cvUserAccountList)
                foreach (`$a in `$accounts) {
                    `$u = Get-ADUser -Identity `$a -Properties 'msDS-SupportedEncryptionTypes' -ErrorAction SilentlyContinue
                    if (`$u -and `$u.'msDS-SupportedEncryptionTypes' -ne 28) { return `$false }
                }
                return `$true
            "
            SetScript  = [string]"
                `$pass = [System.Text.Encoding]::Unicode.GetString(
                             [Convert]::FromBase64String('$cvEncPassB64'))
                `$secPass = ConvertTo-SecureString `$pass -AsPlainText -Force
                `$accounts = @($cvUserAccountList)
                foreach (`$a in `$accounts) {
                    try {
                        Set-ADUser -Identity `$a -KerberosEncryptionType AES128,AES256,RC4 -ErrorAction Stop
                        Set-ADAccountPassword -Identity `$a -Reset -NewPassword `$secPass -ErrorAction Stop
                    }
                    catch {
                        Write-Verbose ""Failed to set Kerberos encryption types on `$a : `$(`$_.Exception.Message)""
                    }
                }
            "
        }
        $adObjectDependency += "[Script]SetUserKerberosEncryptionTypes"

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

        ADGroup AddToEnterpriseAdmin {
            GroupName        = "Enterprise Admins"
            MembersToInclude = @($DomainAdminName, $Admincreds.UserName)
            DependsOn        = "[ADGroup]AddToSchemaAdmin"
        }
        $nextDepend = "[ADGroup]AddToEnterpriseAdmin"



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
      
        # Reverse lookup zones: one AD-integrated /24 in-addr.arpa zone per
        # distinct VM network in this deployment. Provides PTR records for
        # every host the DC serves (Windows clients via Secure dynamic update,
        # Linux via Register-LinuxVmDns). Idempotent: DnsServerADZone is a
        # no-op when the zone already exists.
        $reverseZoneNames = @{}
        foreach ($vm in $deployConfig.virtualMachines) {
            if (-not $vm.network) { continue }
            $oct = $vm.network.Split('.')
            if ($oct.Count -ne 4) { continue }
            $reverseZoneNames["$($oct[2]).$($oct[1]).$($oct[0]).in-addr.arpa"] = $true
        }
        $revIdx = 0
        $reverseZoneDeps = @($nextDepend)
        foreach ($zoneName in $reverseZoneNames.Keys) {
            $revIdx++
            DnsServerADZone "ReverseZone$revIdx" {
                Name             = $zoneName
                DynamicUpdate    = 'Secure'
                ReplicationScope = 'Domain'
                Ensure           = 'Present'
                DependsOn        = $nextDepend
            }
            $reverseZoneDeps += "[DnsServerADZone]ReverseZone$revIdx"
        }
        if ($revIdx -gt 0) {
            $nextDepend = $reverseZoneDeps
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
                MachineName          = $ThisVM.ThisParams.ExternalTopLevelSiteServer
                ExtFolder            = "CMCB"
                Ensure               = "Present"
                DependsOn            = $waitOnDependency
                AdminCreds           = $groupCreds
                PsDscRunAsCredential = $DomainCreds
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