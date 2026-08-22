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
    # Authoritative NetBIOS name (never derive it from the FQDN's first label).
    $DomainNetBios = $deployConfig.vmOptions.domainNetBiosName
    if (-not $DomainNetBios) { $DomainNetBios = $DomainName }

    # This VM
    $ThisMachineName = $deployConfig.parameters.ThisMachineName
    $ThisVM = $deployConfig.virtualMachines | Where-Object { $_.vmName -eq $ThisMachineName }


    # OR-across-top-levels: DC-level PKI templates publish if ANY hierarchy in
    # this domain wants PKI. Over-provisioning is harmless; under-provisioning
    # breaks the hierarchy that needed it. Falls back to global mirror when no
    # per-VM blocks are stamped yet (mid-migration shape).
    $usePKI = $false
    $dcDomain = if ($ThisVM.Domain) { $ThisVM.Domain } else { $deployConfig.parameters.domainName }
    $domainTopCmOptions = @($deployConfig.virtualMachines | Where-Object {
            $_.Role -in 'CAS', 'Primary' -and -not $_.parentSiteCode -and
            (-not $_.Domain -or $_.Domain -eq $dcDomain) -and $_.cmOptions
        }).cmOptions
    if (-not $domainTopCmOptions -and $deployConfig.cmOptions) {
        $domainTopCmOptions = @($deployConfig.cmOptions)
    }
    foreach ($_cmo in $domainTopCmOptions) {
        if ($_cmo.UsePKI) { $usePKI = $true }
    }

    # Cross-forest PKI: this OtherDC is the remote CA for a trusted domain whose
    # clients must autoenroll their ConfigMgr client-auth cert cross-forest (the
    # trusted domain's DC has ForestTrust set AND a remote RootCA). The per-domain
    # heuristic above can't detect this -- the remote managing site (e.g. the
    # cstest8 Primary) is a HIDDEN stub in this deploy with no cmOptions, and the
    # trusted domain itself runs no CM site -- so $usePKI stays false and the
    # AddCertificateTemplate grants below get skipped. That leaves the trusted
    # domain's "Domain Computers" without Enroll/AutoEnroll on
    # ConfigMgrClientCertificate, so its clients never get a client cert and
    # ccmsetup fails with CCM_E_NO_CLIENT_PKI_CERT (80092004). main published these
    # templates unconditionally; restore that behavior for the cross-forest case.
    if (-not $usePKI) {
        $crossForestPkiDC = @($deployConfig.virtualMachines | Where-Object {
                $_.role -eq 'DC' -and $_.ForestTrust -and $_.ForestTrust -ne 'NONE' -and
                $_.thisParams -and $_.thisParams.RootCA
            })
        if ($crossForestPkiDC.Count -gt 0) { $usePKI = $true }
    }

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

    
    $Domain = $deployConfig.vmOptions.domainName
    $DNName = 'DC=' + $Domain.Replace('.',',DC=')    


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
            PsDscRunAsCredential = $Admincreds
        }

        $nextDepend = "[DnsServerConditionalForwarder]Forwarder1"

        if ($usePKI) {
            UpdateCAPrefs UpdateCAPrefs {
                DependsOn     = $nextDepend
                RootCa        = $ThisVM.vmName
            }

            $nextDepend = "[UpdateCAPrefs]UpdateCAPrefs"
        }

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

        $waitOnDependency = @($nextDepend)
        if ($usePKI) {
            if ($iisCount) {
                AddCertificateTemplate ConfigMgrClientDistributionPointCertificate {
                    TemplateName = "ConfigMgrClientDistributionPointCertificate"
                    GroupName    = "$DomainName\ConfigMgr IIS Servers"
                    GroupAlt     = "$DomainNetBios\ConfigMgr IIS Servers"
                    RemoteCreds  = $DomainCreds
                    Permissions  = 'Read, Enroll'
                    PermissionsOnly = $true
                    SkipIfNotExist = $true
                    DependsOn    = $nextDepend
                }
                $waitOnDependency += "[AddCertificateTemplate]ConfigMgrClientDistributionPointCertificate"

                AddCertificateTemplate ConfigMgrWebServerCertificate {
                    TemplateName = "ConfigMgrWebServerCertificate"
                    GroupName    = "$DomainName\ConfigMgr IIS Servers"
                    GroupAlt     = "$DomainNetBios\ConfigMgr IIS Servers"
                    RemoteCreds  = $DomainCreds
                    Permissions  = 'Read, Enroll'
                    PermissionsOnly = $true
                    SkipIfNotExist = $true
                    DependsOn    = $nextDepend
                }
                $waitOnDependency += "[AddCertificateTemplate]ConfigMgrWebServerCertificate"
            }

            AddCertificateTemplate ConfigMgrClientCertificate {
                TemplateName = "ConfigMgrClientCertificate"
                GroupName    = "$DomainName\Domain Computers"
                GroupAlt     = "$DomainNetBios\Domain Computers"
                RemoteCreds  = $DomainCreds
                Permissions  = 'Read, Enroll, AutoEnroll'
                PermissionsOnly = $true
                SkipIfNotExist = $true
                DependsOn    = $nextDepend
            }
            $waitOnDependency += "[AddCertificateTemplate]ConfigMgrClientCertificate"
        }


       

        WriteEvent WriteConfigFinished {
            LogPath   = $LogPath
            WriteNode = "ConfigurationFinished"
            Status    = "Passed"
            Ensure    = "Present"
            DependsOn = $waitOnDependency
        }

        WriteStatus Complete {
            DependsOn = "[WriteEvent]WriteConfigFinished"
            Status    = "Complete!"
        }
    }
}