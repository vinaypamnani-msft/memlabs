configuration Phase2OtherDC
{
    param
    (
        [Parameter(Mandatory)]
        [string]$DeployConfigPath,
        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$Admincreds
    )

    Import-DscResource -ModuleName 'TemplateHelpDSC'
    Import-DscResource -ModuleName 'PSDesiredStateConfiguration', 'NetworkingDsc', 'xDhcpServer', 'DnsServerDsc', 'ComputerManagementDsc', 'ActiveDirectoryDsc', 'GroupPolicyDsc'

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


    $RealDC = $deployConfig.virtualMachines | Where-Object { $_.role -in ("DC") }

    $DCIPAddr = $RealDC.thisParams.DCIPAddress
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

    $domainNameSplit = ($deployConfig.vmOptions.domainName).Split(".")
    $DNName = "DC=$($domainNameSplit[0]),DC=$($domainNameSplit[1])"

    # Domain creds
    [System.Management.Automation.PSCredential]$DomainCreds = New-Object System.Management.Automation.PSCredential ("${DomainName}\$($Admincreds.UserName)", $Admincreds.Password)

    Node LOCALHOST
    {
        LocalConfigurationManager {
            ConfigurationMode  = 'ApplyOnly'
            RebootNodeIfNeeded = $true
        }

        RemoteDesktopAdmin RemoteDesktopSettings {
            IsSingleInstance   = 'yes'
            Ensure             = 'Present'
            UserAuthentication = 'NonSecure'
            #DependsOn          = $waitOnDependency
        }

        DnsServerConditionalForwarder 'Forwarder1' {
            Name             = ($deployConfig.vmOptions.domainName)
            MasterServers    = @($DCIPAddr)
            ReplicationScope = 'Forest'
            Ensure           = 'Present'
            DependsOn        = "[RemoteDesktopAdmin]RemoteDesktopSettings"
        }

        $nextDepend = "[DnsServerConditionalForwarder]Forwarder1"

        UpdateCAPrefs UpdateCAPrefs {
            DependsOn     = $nextDepend
            RootCa        = $ThisVM.vmName
        }

        $nextDepend = "[UpdateCAPrefs]UpdateCAPrefs"

        AddToAdminGroup AddRemoteAdmins {
            DomainName   = ($deployConfig.vmOptions.domainName)
            RemoteCreds  = $DomainCreds
            AccountNames = @($DomainAdminName, $Admincreds.UserName)
            TargetGroup = "Administrators"
            DependsOn    = $nextDepend
        }
        $nextDepend = "[AddToAdminGroup]AddRemoteAdmins"

        #AddCertificateTemplate SubCACert {
        #    TemplateName    = "SubCA"
        #    GroupName       = "$DomainName\$($RealDC.vmName)$"
        #    Permissions     = 'Read, Enroll'
        #    PermissionsOnly = $true
        #    DependsOn       = $nextDepend
        #}

        #$nextDepend = "[AddCertificateTemplate]SubCACert"

        $iiscount = 0
        $GroupMembersList = @()
        $GroupMembersList += $deployConfig.virtualMachines | Where-Object { $_.role -in ("CAS", "Primary", "PassiveSite", "Secondary")-and -not $_.Hidden}
        $GroupMembersList += $deployConfig.virtualMachines | Where-Object { $_.InstallMP -and -not $_.Hidden}
        $GroupMembersList += $deployConfig.virtualMachines | Where-Object { $_.InstallDP -and -not $_.Hidden}
        $GroupMembersList += $deployConfig.virtualMachines | Where-Object { $_.InstallRP -and -not $_.Hidden}
        $GroupMembersList += $deployConfig.virtualMachines | Where-Object { $_.InstallSUP -and -not $_.Hidden}
        [System.Collections.ArrayList]$iisgroupMembers = @()
        foreach ($member in $GroupMembersList) {
            $memberName = $member.vmName + "$"
            if (-not $iisgroupMembers.Contains($memberName)) {
                $iiscount = $iisgroupMembers.Add($memberName)
                $iiscount++
            }
        }

        if ($iisCount) {
            AddCertificateTemplate ConfigMgrClientDistributionPointCertificate {
                TemplateName = "ConfigMgrClientDistributionPointCertificate"
                GroupName    = "$DomainName\ConfigMgr IIS Servers"
                Permissions  = 'Read, Enroll'
                PermissionsOnly = $true
                DependsOn    = $nextDepend
            }
            $waitOnDependency += "[AddCertificateTemplate]ConfigMgrClientDistributionPointCertificate"

            AddCertificateTemplate ConfigMgrWebServerCertificate {
                TemplateName = "ConfigMgrWebServerCertificate"
                GroupName    = "$DomainName\ConfigMgr IIS Servers"
                Permissions  = 'Read, Enroll'
                PermissionsOnly = $true
                DependsOn    = $nextDepend
            }
            $waitOnDependency += "[AddCertificateTemplate]ConfigMgrWebServerCertificate"
        }
        AddCertificateTemplate ConfigMgrClientCertificate {
            TemplateName = "ConfigMgrClientCertificate"
            GroupName    = "$DomainName\Domain Computers"
            Permissions  = 'Read, Enroll, AutoEnroll'
            PermissionsOnly = $true
            DependsOn    = $nextDepend
        }
        $waitOnDependency += "[AddCertificateTemplate]ConfigMgrClientCertificate"


        WriteStatus Complete {
            DependsOn = $nextDepend
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