Configuration Phase5
{
    param
    (
        [Parameter(Mandatory)]
        [string]$DeployConfigPath,
        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$Admincreds
    )

    Import-DscResource -ModuleName 'PSDesiredStateConfiguration', 'TemplateHelpDSC', 'ActiveDirectoryDsc', 'ComputerManagementDsc', 'FailoverClusterDsc', 'AccessControlDsc', 'SqlServerDsc'

    # Read config
    $deployConfig = Get-Content -Path $DeployConfigPath | ConvertFrom-Json
    $DomainName = $deployConfig.parameters.domainName
    #$netbiosName = $DomainName.Split(".")[0]
    $netbiosName = $deployConfig.vmOptions.domainNetBiosName
    $DomainAdminName = $deployConfig.vmOptions.adminName

    # Derive the DC name from deployConfig (the full VM list in the JSON), NOT from
    # $AllNodes. Under the in-guest local-recovery compile path $AllNodes is minimal
    # (the current node only, no DC entry), so ($AllNodes | Where Role -eq 'DC') is
    # empty and DCName ends up unset -> the apply fails with "Could not find mandatory
    # property DCName". deployConfig always has every VM, so this works for both the
    # DC-pushed compile and the local-recovery compile.
    $DCNameFromConfig = ($deployConfig.virtualMachines | Where-Object { $_.Role -eq 'DC' } | Select-Object -First 1).vmName
    if (-not $DCNameFromConfig) { $DCNameFromConfig = $deployConfig.parameters.DCName }

    # Log share
    $LogFolder = "DSC"
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '')]
    $LogPath = "c:\staging\$LogFolder"

    # Domain Creds
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '')]
    [System.Management.Automation.PSCredential]$DomainCreds = New-Object System.Management.Automation.PSCredential ("${DomainName}\$($Admincreds.UserName)", $Admincreds.Password)
    [System.Management.Automation.PSCredential]$CMAdmin = New-Object System.Management.Automation.PSCredential ("${DomainName}\$DomainAdminName", $Admincreds.Password)


    Node $AllNodes.Where{ $_.Role -eq 'FileServer' }.NodeName
    {

        $thisVM = $deployConfig.virtualMachines | where-object { $_.vmName -eq $node.NodeName }
        $primaryVMs = $deployConfig.virtualMachines | Where-Object { $_.Role -eq "SQLAO" -and $_.FileServerVM -eq $node.NodeName }

        WriteStatus ClusterShare {
            Status = "Configuring Cluster Share"
        }

        $i = 0
        $WaitDepend = @('[WriteStatus]ClusterShare')
        foreach ($primaryVM in $primaryVMs) {
            $i++
            File "ClusterBackup$i" {
                DestinationPath = $primaryVM.thisParams.SQLAO.BackupLocalPath
                Type            = 'Directory'
                Ensure          = "Present"
                DependsOn       = "[WriteStatus]ClusterShare"
            }
            $nextDepend = "[File]ClusterBackup$i"

            $_groupName = $primaryVM.thisParams.SQLAO.GroupName

            WriteStatus "WaitForDC$($primaryVM.vmName)" {
                Status    = "Waiting for AD group '$_groupName' to be created by DC"
                DependsOn = $nextDepend
            }

            Script "WaitForADGroup$($primaryVM.vmName)" {
                SetScript = {
                    $groupName = $using:_groupName
                    for ($i = 1; $i -le 400; $i++) {
                        try {
                            $null = Get-ADGroup -Identity $groupName -ErrorAction Stop
                            Write-Verbose "AD group '$groupName' found on attempt $i"
                            return
                        } catch {}
                        Start-Sleep -Seconds 5
                    }
                    throw "AD group '$groupName' not found after 400 retries (33 min)"
                }
                TestScript = {
                    try {
                        $null = Get-ADGroup -Identity $using:_groupName -ErrorAction Stop
                        return $true
                    } catch {
                        return $false
                    }
                }
                GetScript  = { @{ Result = "N/A" } }
                PsDscRunAsCredential = $Admincreds
                DependsOn            = $nextDepend
            }
            $nextDepend = "[Script]WaitForADGroup$($primaryVM.vmName)"

            File "ClusterWitness$i" {
                DestinationPath = $primaryVM.thisParams.SQLAO.WitnessLocalPath
                Type            = 'Directory'
                Ensure          = "Present"
                DependsOn       = $nextDepend
            }

            NTFSAccessEntry "ClusterWitnessPermissions$i" {
                Path              = $primaryVM.thisParams.SQLAO.WitnessLocalPath
                AccessControlList = @(
                    NTFSAccessControlList {
                        Principal          = "$netbiosName\$($primaryVM.thisParams.SQLAO.GroupName)"
                        ForcePrincipal     = $false
                        AccessControlEntry = @(
                            NTFSAccessControlEntry {
                                AccessControlType = 'Allow'
                                FileSystemRights  = 'FullControl'
                                Inheritance       = 'This folder subfolders and files'
                                Ensure            = 'Present'
                            }
                        )
                    }
                    #NTFSAccessControlList {
                    #    Principal          = "$DomainName\$($primaryVM.thisParams.SQLAO.GroupMembers[0])"
                    #    ForcePrincipal     = $true
                    #    AccessControlEntry = @(
                    #        NTFSAccessControlEntry {
                    #            AccessControlType = 'Allow'
                    #            FileSystemRights  = 'FullControl'
                    #            Inheritance       = 'This folder subfolders and files'
                    #            Ensure            = 'Present'
                    #        }
                    #    )
                    #}
                    #NTFSAccessControlList {
                    #    Principal          = "$DomainName\$($primaryVM.thisParams.SQLAO.GroupMembers[1])"
                    #    ForcePrincipal     = $false
                    #    AccessControlEntry = @(
                    #        NTFSAccessControlEntry {
                    #            AccessControlType = 'Allow'
                    #            FileSystemRights  = 'FullControl'
                    #            Inheritance       = 'This folder subfolders and files'
                    #            Ensure            = 'Present'
                    #        }
                    #    )
                    #}
                    #NTFSAccessControlList {
                    #    Principal          = "$DomainName\$($primaryVM.thisParams.SQLAO.GroupMembers[2])"
                    #    ForcePrincipal     = $false
                    #    AccessControlEntry = @(
                    #        NTFSAccessControlEntry {
                    #            AccessControlType = 'Allow'
                    #            FileSystemRights  = 'FullControl'
                    #            Inheritance       = 'This folder subfolders and files'
                    #            Ensure            = 'Present'
                    #        }
                    #    )
                    #}
                    NTFSAccessControlList {
                        Principal          = "$netbiosName\$DomainAdminName"
                        ForcePrincipal     = $false
                        AccessControlEntry = @(
                            NTFSAccessControlEntry {
                                AccessControlType = 'Allow'
                                FileSystemRights  = 'FullControl'
                                Inheritance       = 'This folder subfolders and files'
                                Ensure            = 'Present'
                            }
                        )
                    }
                )
                DependsOn         = "[File]ClusterWitness$i"
            }


            NTFSAccessEntry "ClusterBackupPermissions$i" {
                Path              = $primaryVM.thisParams.SQLAO.BackupLocalPath
                AccessControlList = @(
                    NTFSAccessControlList {
                        Principal          = $primaryVM.thisParams.SQLAO.SqlServiceAccountFQ
                        ForcePrincipal     = $true
                        AccessControlEntry = @(
                            NTFSAccessControlEntry {
                                AccessControlType = 'Allow'
                                FileSystemRights  = 'FullControl'
                                Inheritance       = 'This folder subfolders and files'
                                Ensure            = 'Present'
                            }
                        )
                    }
                    NTFSAccessControlList {
                        Principal          = $primaryVM.thisParams.SQLAO.SqlAgentServiceAccountFQ
                        ForcePrincipal     = $false
                        AccessControlEntry = @(
                            NTFSAccessControlEntry {
                                AccessControlType = 'Allow'
                                FileSystemRights  = 'FullControl'
                                Inheritance       = 'This folder subfolders and files'
                                Ensure            = 'Present'
                            }
                        )
                    }
                    NTFSAccessControlList {
                        Principal          = "$netbiosName\$DomainAdminName"
                        ForcePrincipal     = $false
                        AccessControlEntry = @(
                            NTFSAccessControlEntry {
                                AccessControlType = 'Allow'
                                FileSystemRights  = 'FullControl'
                                Inheritance       = 'This folder subfolders and files'
                                Ensure            = 'Present'
                            }
                        )
                    }
                    NTFSAccessControlList {
                        Principal          = "$netbiosName\vmbuildadmin"
                        ForcePrincipal     = $false
                        AccessControlEntry = @(
                            NTFSAccessControlEntry {
                                AccessControlType = 'Allow'
                                FileSystemRights  = 'FullControl'
                                Inheritance       = 'This folder subfolders and files'
                                Ensure            = 'Present'
                            }
                        )
                    }
                )
                DependsOn         = "[File]ClusterBackup$i"
            }

            SmbShare "ClusterShare$i" {
                Name                  = $primaryVM.thisParams.SQLAO.WitnessShare
                Path                  = $primaryVM.thisParams.SQLAO.WitnessLocalPath
                Description           = $primaryVM.thisParams.SQLAO.WitnessShare
                FolderEnumerationMode = 'AccessBased'
                FullAccess            = $primaryVM.thisParams.SQLAO.GroupMembersFQ
                ReadAccess            = "Everyone"
                DependsOn             = "[NTFSAccessEntry]ClusterWitnessPermissions$i"
            }

            SmbShare "BackupShare$i" {
                Name                  = $primaryVM.thisParams.SQLAO.BackupShare
                Path                  = $primaryVM.thisParams.SQLAO.BackupLocalPath
                Description           = $primaryVM.thisParams.SQLAO.BackupShare
                FolderEnumerationMode = 'AccessBased'
                FullAccess            = $primaryVM.thisParams.SQLAO.SqlServiceAccountFQ, $primaryVM.thisParams.SQLAO.SqlAgentServiceAccountFQ, "$netbiosName\$DomainAdminName", "$netbiosName\vmbuildadmin"
                ReadAccess            = "Everyone"
                DependsOn             = "[NTFSAccessEntry]ClusterBackupPermissions$i"
            }
            $WaitDepend += "[SmbShare]BackupShare$i"
            $WaitDepend += "[SmbShare]ClusterShare$i"
        }

        WriteStatus Complete {
            DependsOn = $WaitDepend
            Status    = "Complete!"
        }

    }

    Node $AllNodes.Where{ $_.Role -eq 'ClusterNode1' }.NodeName
    {
        $thisVM = $deployConfig.VirtualMachines | where-object { $_.vmName -eq $node.NodeName }
        $node2 = ($deployConfig.VirtualMachines | Where-Object { $_.vmName -eq $thisVM.OtherNode }).vmName

        #$node2 = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode2' }).NodeName

        # Detect legacy labs where the cluster IP is on the 10.250.250.x heartbeat
        # subnet. Skip all cluster setup steps for those — the cluster is already
        # running. New labs set up the cluster fresh with proper network roles.
        $clusterIPOnHeartbeat = $thisVM.thisParams.SQLAO.ClusterIPAddress -match '^10\.250\.250\.'

        ModuleAdd SQLServerModule {
            Key             = 'Always'
            CheckModuleName = 'SqlServer'
        }

        $nextDepend = "[ModuleAdd]SQLServerModule"

        if (-not $clusterIPOnHeartbeat) {
        $DC = $DCNameFromConfig

        WriteStatus PreClusterNicConfig {
            DependsOn = $nextDepend
            Status    = "Disabling DNS registration on cluster NIC (pre-cluster)"
        }

        DisableClusterNicDnsRegistration PreClusterNicConfig {
            Stage                = 'PreCluster'
            ClusterSubnet        = '10.250.251.'
            DomainName           = $DomainName
            DCName               = $DC
            DependsOn            = $nextDepend
            PsDscRunAsCredential = $Admincreds
        }
        $nextDepend = '[DisableClusterNicDnsRegistration]PreClusterNicConfig'

        WriteStatus CreateCluster {
            DependsOn = $nextDepend
            Status    = "Creating Cluster $($thisVM.ClusterName) on $($thisVM.thisParams.SQLAO.ClusterIPAddress)"
        }

        JoinClusterByIP CreateCluster {
            ClusterName                   = $thisVM.ClusterName
            ClusterIPAddress              = $thisVM.thisParams.SQLAO.ClusterIPAddress
            Role                          = 'Create'
            DomainAdministratorCredential = $Admincreds
            DependsOn                     = $nextDepend
        }
        $nextDepend = '[JoinClusterByIP]CreateCluster'

        WriteStatus EnsureClusterDns {
            DependsOn = $nextDepend
            Status    = "Ensuring Cluster '$($thisVM.ClusterName)' DNS is registered and accessible"
        }

        WaitForClusterAccess EnsureClusterDns {
            ClusterName          = $thisVM.ClusterName
            ClusterIPAddress     = $thisVM.thisParams.SQLAO.ClusterIPAddress
            RetryIntervalSec     = 15
            RetryCount           = 10
            DependsOn            = $nextDepend
            PsDscRunAsCredential = $Admincreds
        }
        $nextDepend = '[WaitForClusterAccess]EnsureClusterDns'

        WriteStatus JoinCluster {
            DependsOn = $nextDepend
            Status    = "Waiting on $node2 To Join Cluster"
        }

        WaitForAny CreateCluster {
            NodeName             = $node2
            ResourceName         = "[JoinClusterByIP]JoinSecondNodeToCluster"
            RetryIntervalSec     = 10
            RetryCount           = 360
            PsDscRunAsCredential = $Admincreds
            DependsOn            = $nextDepend
        }
        $nextDepend = '[WaitForAny]CreateCluster'

        WriteStatus 'ChangeNetwork-10' {
            DependsOn = $nextDepend
            Status    = "Setting 10.250.251.0 to cluster-only (Role 1)"
        }

        ClusterNetwork 'ChangeNetwork-10' {
            Address              = '10.250.251.0'
            AddressMask          = '255.255.255.0'
            Name                 = 'Cluster Network'
            Role                 = '1'
            DependsOn            = $nextDepend
            PsDscRunAsCredential = $Admincreds
        }
        $nextDepend = '[ClusterNetwork]ChangeNetwork-10'

        WriteStatus WaitForFS {
            Status    = "Waiting for '$($thisVM.fileServerVM)' to Complete"
            DependsOn = $nextDepend
        }

        WaitForAny FileShareComplete {
            NodeName             = $thisVM.fileServerVM
            ResourceName         = "[WriteStatus]Complete"
            RetryIntervalSec     = 10
            RetryCount           = 360
            PsDscRunAsCredential = $Admincreds
            DependsOn            = $nextDepend
        }

        WriteStatus ClusterJoin {
            DependsOn = "[WaitForAny]FileShareComplete"
            Status    = "Waiting for '$node2' to join Cluster Quorum ClusterWitness"
        }

        WaitForAny WaitForClusterJoin {
            NodeName             = $node2
            ResourceName         = '[ClusterQuorum]ClusterWitness'
            RetryIntervalSec     = 10
            RetryCount           = 360
            PsDscRunAsCredential = $Admincreds
            DependsOn            = '[JoinClusterByIP]CreateCluster'
        }

        $nextDepend = "[WaitForAny]WaitForClusterJoin"

        WriteStatus ClusterSetOwnerNodes {
            DependsOn = $nextDepend
            Status    = "Setting OwnerNodes $($thisVM.ClusterName) to $($thisVM.thisParams.SQLAO.ClusterNodes -Join ',')"
        }

        ClusterSetOwnerNodes ClusterSetOwnerNodes {
            ClusterName          = $thisVM.ClusterName
            #Nodes                = ($AllNodes.Where{ $_.Role -eq 'ClusterNode1' }.NodeName), ($AllNodes.Where{ $_.Role -eq 'ClusterNode2' }.NodeName)
            Nodes                = $thisVM.thisParams.SQLAO.ClusterNodes
            PsDscRunAsCredential = $Admincreds
            DependsOn            = $nextDepend
        }
        $nextDepend = '[ClusterSetOwnerNodes]ClusterSetOwnerNodes'

        WriteStatus PostClusterDnsConfig {
            DependsOn = $nextDepend
            Status    = "Setting RegisterAllProvidersIP=0 on cluster '$($thisVM.ClusterName)'"
        }

        DisableClusterNicDnsRegistration PostClusterDnsConfig {
            Stage                = 'PostCluster'
            ClusterSubnet        = '10.250.251.'
            DomainName           = $DomainName
            DCName               = $DC
            ClusterName          = $thisVM.ClusterName
            DependsOn            = $nextDepend
            PsDscRunAsCredential = $Admincreds
        }
        $nextDepend = '[DisableClusterNicDnsRegistration]PostClusterDnsConfig'
        } # end if (-not $clusterIPOnHeartbeat)

        WriteStatus SvcAccount {
            DependsOn = $nextDepend
            Status    = "Configuring SQL Service Accounts and SQL Logins"
        }

        #Change SQL Service Account
        SqlLogin 'Add_WindowsUserAgent' {
            Ensure       = 'Present'
            Name         = $thisVM.thisParams.SQLAO.SqlAgentServiceAccountFQ
            LoginType    = 'WindowsUser'
            ServerName   = $thisVM.vmName
            InstanceName = $thisVM.sqlInstanceName
            #PsDscRunAsCredential = $Admincreds
            DependsOn    = '[WriteStatus]SvcAccount'
        }

        SqlLogin 'Add_WindowsUser' {
            Ensure       = 'Present'
            Name         = $thisVM.thisParams.SQLAO.SqlServiceAccountFQ
            LoginType    = 'WindowsUser'
            ServerName   = $thisVM.vmName
            InstanceName = $thisVM.sqlInstanceName
            #PsDscRunAsCredential = $Admincreds
            DependsOn    = '[WriteStatus]SvcAccount'
        }


        SqlRole 'Add_ServerRole' {
            Ensure           = 'Present'
            ServerRoleName   = 'SysAdmin'
            ServerName       = $thisVM.vmName
            InstanceName     = $thisVM.sqlInstanceName
            MembersToInclude = $thisVM.thisParams.SQLAO.SqlAgentServiceAccountFQ, $thisVM.thisParams.SQLAO.SqlServiceAccountFQ, 'BUILTIN\Administrators'
            #PsDscRunAsCredential = $Admincreds
            DependsOn        = '[SqlLogin]Add_WindowsUser'
        }


        # Adding the required service account to allow the cluster to log into SQL
        SqlLogin 'AddNTServiceClusSvc' {
            Ensure       = 'Present'
            Name         = 'NT SERVICE\ClusSvc'
            LoginType    = 'WindowsUser'
            ServerName   = $Node.NodeName
            InstanceName = $thisVM.sqlInstanceName
            #PsDscRunAsCredential = $Admincreds
            DependsOn    = '[SqlRole]Add_ServerRole'
        }

        # Add the required permissions to the cluster service login
        SqlPermission 'AddNTServiceClusSvcPermissions' {
            DependsOn    = '[SqlLogin]AddNTServiceClusSvc'
            ServerName   = $Node.NodeName
            InstanceName = $thisVM.sqlInstanceName
            Name         = 'NT SERVICE\ClusSvc'
            Permission   = @(
                ServerPermission
                {
                    State      = 'Grant'
                    Permission = @('AlterAnyAvailabilityGroup', 'ViewServerState')
                }
                ServerPermission
                {
                    State      = 'GrantWithGrant'
                    Permission = @()
                }
                ServerPermission
                {
                    State      = 'Deny'
                    Permission = @()
                }
            )
            #Credential = $Admincreds
        }
        $nextDepend = '[SqlPermission]AddNTServiceClusSvcPermissions'

        WriteStatus HADREndpoint {
            DependsOn = $nextDepend
            Status    = "Configuring HADR Database Mirroring"
        }

        # Create a DatabaseMirroring endpoint
        SqlEndpoint 'HADREndpoint' {
            EndPointName = 'HADR'
            EndpointType = 'DatabaseMirroring'
            Ensure       = 'Present'
            Port         = 5022
            ServerName   = $Node.NodeName
            InstanceName = $thisVM.sqlInstanceName
            DependsOn    = $nextDepend
            #PsDscRunAsCredential = $Admincreds
        }
        $nextDepend = '[SqlEndpoint]HADREndpoint'

        # Ensure the HADR option is enabled for the instance
        SqlAlwaysOnService 'EnableHADR' {
            Ensure       = 'Present'
            InstanceName = $thisVM.sqlInstanceName
            ServerName   = $Node.NodeName
            DependsOn    = $nextDepend
            #PsDscRunAsCredential = $Admincreds
        }
        $nextDepend = '[SqlAlwaysOnService]EnableHADR'

        if (-not $clusterIPOnHeartbeat) {
        WriteStatus 'ChangeNetwork-192' {
            DependsOn = $nextDepend
            Status    = "Setting $($thisVM.thisParams.vmNetwork) to cluster + client (Role 3)"
        }

        ClusterNetwork 'ChangeNetwork-192' {
            Address              = $thisVM.thisParams.vmNetwork
            AddressMask          = '255.255.255.0'
            Name                 = 'Domain Network'
            Role                 = '3'
            DependsOn            = $nextDepend
            PsDscRunAsCredential = $Admincreds
        }
        $nextDepend = '[ClusterNetwork]ChangeNetwork-192'
        } # end if (-not $clusterIPOnHeartbeat)

        WriteStatus SQLAG {
            DependsOn = $nextDepend
            Status    = "Creating Availability Group $($thisVM.thisParams.SQLAO.AlwaysOnGroupName) on $($Node.NodeName)\$($thisVM.sqlInstanceName)"
        }

        # Create the availability group on the instance tagged as the primary replica
        SqlAG 'CMCASAG' {
            Ensure                        = 'Present'
            Name                          = $thisVM.thisParams.SQLAO.AlwaysOnGroupName
            InstanceName                  = $thisVM.sqlInstanceName
            ServerName                    = $Node.NodeName
            AvailabilityMode              = 'SynchronousCommit'
            BackupPriority                = 50
            ConnectionModeInPrimaryRole   = 'AllowAllConnections'
            ConnectionModeInSecondaryRole = 'AllowAllConnections'
            FailoverMode                  = 'Manual'
            HealthCheckTimeout            = 30000
            ProcessOnlyOnActiveNode       = $true
            BasicAvailabilityGroup        = $false
            DatabaseHealthTrigger         = $false
            DtcSupportEnabled             = $false
            DependsOn                     = $nextDepend
            PsDscRunAsCredential          = $Admincreds
        }
        $nextDepend = '[SqlAG]CMCASAG'

        WriteStatus SqlAGListener {
            DependsOn = $nextDepend
            Status    = "Creating Availability Group Listener"
        }

        $AOSqlPort = $thisVM.thisParams.SQLAO.SQLAOPort
        SqlAGListener 'AvailabilityGroupListener' {
            Ensure               = 'Present'
            ServerName           = $Node.NodeName
            InstanceName         = $thisVM.sqlInstanceName
            AvailabilityGroup    = $thisVM.thisParams.SQLAO.AlwaysOnGroupName
            DHCP                 = $false
            Name                 = $thisVM.thisParams.SQLAO.AlwaysOnListenerName
            IpAddress            = $thisVM.thisParams.SQLAO.AGIPAddress
            Port                 = $AOSqlPort
            DependsOn            = $nextDepend
            PsDscRunAsCredential = $Admincreds
        }
        $nextDepend = '[SqlAGListener]AvailabilityGroupListener'

        if (-not $clusterIPOnHeartbeat) {
        WriteStatus ClusterRemoveUnwantedIPs {
            DependsOn = $nextDepend
            Status    = "Removing DHCP IPs from Cluster"
        }

        ClusterRemoveUnwantedIPs ClusterRemoveUnwantedIPs {
            ClusterName          = $thisVM.ClusterName
            ClusterIPAddress     = $thisVM.thisParams.SQLAO.ClusterIPAddress
            PsDscRunAsCredential = $Admincreds
            DependsOn            = $nextDepend
        }
        $nextDepend = '[ClusterRemoveUnwantedIPs]ClusterRemoveUnwantedIPs'
        } # end if (-not $clusterIPOnHeartbeat)


        $lspn1 = "MSSQLSvc/" + $thisVM.thisParams.SQLAO.AlwaysOnListenerName
        $lspn2 = "MSSQLSvc/" + $thisVM.thisParams.SQLAO.AlwaysOnListenerNameFQDN
        $lspn3 = $lspn1 + ":" + $AOSqlPort
        $lspn4 = $lspn2 + ":" + $AOSqlPort
        $account = $thisVM.thisParams.SQLAO.SqlServiceAccount

        WriteStatus SPNS {
            DependsOn = $nextDepend
            Status    = "Adding SQLAO SPNs $lspn1, $lspn2, $lspn3, $lspn4 to $account"
        }

        ADServicePrincipalName 'lspn1' {
            Ensure               = 'Present'
            ServicePrincipalName = $lspn1
            Account              = $account
            DependsOn            = $nextDepend
            PsDscRunAsCredential = $Admincreds
        }

        ADServicePrincipalName 'lspn2' {
            Ensure               = 'Present'
            ServicePrincipalName = $lspn2
            Account              = $account
            DependsOn            = $nextDepend
            PsDscRunAsCredential = $Admincreds
        }

        ADServicePrincipalName 'lspn3' {
            Ensure               = 'Present'
            ServicePrincipalName = $lspn3
            Account              = $account
            DependsOn            = $nextDepend
            PsDscRunAsCredential = $Admincreds
        }

        ADServicePrincipalName 'lspn4' {
            Ensure               = 'Present'
            ServicePrincipalName = $lspn4
            Account              = $account
            DependsOn            = $nextDepend
            PsDscRunAsCredential = $Admincreds
        }

        $nextDepend = '[ADServicePrincipalName]lspn1', '[ADServicePrincipalName]lspn2', '[ADServicePrincipalName]lspn3', '[ADServicePrincipalName]lspn4'

        # Verify the AG listener's DNS A record exists. The cluster service is
        # supposed to register it automatically when the listener comes online,
        # but this fails silently when the domain adapter's DNS registration is
        # in a transient state (e.g. after DisableClusterNicDnsRegistration
        # strips DNS from the heartbeat NIC and re-registers only the domain
        # adapter). When the A record is missing, Phase 8 setup.exe fails with
        # "untrusted domain" because FQDN resolution is required for Kerberos.
        $listenerNameForDns  = $thisVM.thisParams.SQLAO.AlwaysOnListenerName
        $listenerFqdnForDns  = $thisVM.thisParams.SQLAO.AlwaysOnListenerNameFQDN
        $listenerIpForDns    = ($thisVM.thisParams.SQLAO.AGIPAddress -split '/')[0]  # strip CIDR if present
        $dcForDns            = $DCNameFromConfig

        Script VerifyListenerDns {
            GetScript  = { @{ Result = 'N/A' } }
            TestScript = {
                # Query ALL DCs' DNS records directly — Resolve-DnsName can
                # return LLMNR results that mask a missing A record.
                # With multiple DCs (DC + BDC), the record might exist on one
                # but not the other due to replication lag.
                $vlog = { param($m) try { Write-VerboseEx -Message $m -Component 'VerifyListenerDns/Test' } catch { Write-Verbose $m } }
                try {
                    $allDCs = @(Get-ADDomainController -Filter * -ErrorAction SilentlyContinue | Select-Object -ExpandProperty HostName)
                    if ($allDCs.Count -eq 0) { $allDCs = @($using:dcForDns) }
                    foreach ($dc in $allDCs) {
                        & $vlog "query A '$($using:listenerNameForDns)' on DC '$dc'"
                        $rec = @(Get-DnsServerResourceRecord -ZoneName $using:DomainName -Name $using:listenerNameForDns `
                            -RRType A -ComputerName $dc -ErrorAction SilentlyContinue)
                        if ($rec.Count -eq 0) {
                            & $vlog "DNS A record for '$($using:listenerNameForDns)' missing on DC '$dc'"
                            return $false
                        }
                    }
                    return $true
                }
                catch { return $false }
            }
            SetScript  = {
                # Listener DNS A record missing on one or more DCs.
                # Retry with escalating recovery until ALL DCs have the record.
                # Phase 5 must not proceed without listener DNS — Phase 8
                # setup.exe will fail with 'untrusted domain' if FQDN
                # resolution is missing.
                #
                # Every call below is an unbounded CIM/cluster round trip with no
                # native timeout, and this resource posts no status of its own, so a
                # hang here freezes the phase under the PREVIOUS caption (the SPN
                # step). Bracket each one so the breadcrumb names the call we did not
                # come back from.
                $vlog = { param($m) try { Write-VerboseEx -Message $m -Component 'VerifyListenerDns/Set' } catch { Write-Verbose $m } }
                & $vlog 'enter Get-ADDomainController -Filter *'
                $allDCs = @(Get-ADDomainController -Filter * -ErrorAction SilentlyContinue | Select-Object -ExpandProperty HostName)
                if ($allDCs.Count -eq 0) { $allDCs = @($using:dcForDns) }
                & $vlog "DCs: $($allDCs -join ', ')"
                $dcShortNames = @($allDCs | ForEach-Object { ($_ -split '\.')[0] })
                $listenerName = $using:listenerNameForDns
                $listenerIP   = $using:listenerIpForDns
                $zoneName     = $using:DomainName
                $primaryDC    = $using:dcForDns
                $maxAttempts  = 5
                $registered   = $false
                $addedRecord  = $false

                for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
                    & $vlog "VerifyListenerDns: attempt $attempt/$maxAttempts"

                    # Attempt a) Register the A record on the primary DC (idempotent).
                    if (-not $registered) {
                        try {
                            & $vlog "enter Get-DnsServerResourceRecord on '$primaryDC'"
                            $existing = @(Get-DnsServerResourceRecord -ZoneName $zoneName -Name $listenerName `
                                -RRType A -ComputerName $primaryDC -ErrorAction SilentlyContinue)
                            if ($existing.Count -eq 0) {
                                & $vlog "enter Add-DnsServerResourceRecordA $listenerName -> $listenerIP on '$primaryDC'"
                                Add-DnsServerResourceRecordA -ZoneName $zoneName -Name $listenerName `
                                    -IPv4Address $listenerIP -ComputerName $primaryDC -ErrorAction Stop
                                & $vlog "Registered DNS A record: $listenerName -> $listenerIP on DC '$primaryDC'"
                                $addedRecord = $true
                            }
                            else {
                                & $vlog "DNS A record already exists on primary DC '$primaryDC'"
                            }
                            $registered = $true
                        }
                        catch {
                            & $vlog "DNS registration attempt $attempt failed: $($_.Exception.Message)"
                        }
                    }

                    # Attempt b) Bounce the listener's Network Name resource so
                    # the cluster service re-registers DNS for future failovers.
                    # Only when the record was genuinely absent on the primary DC:
                    # the common case here is a record that exists but has not
                    # replicated to the BDC yet, and taking the AG listener offline
                    # to fix a replication delay is both useless and disruptive.
                    if ($addedRecord -and $attempt -le 2) {
                        & $vlog 'enter Get-ClusterResource (Network Name)'
                        $nnRes = Get-ClusterResource -ErrorAction SilentlyContinue |
                            Where-Object { $_.ResourceType -eq 'Network Name' -and $_.OwnerGroup -eq $listenerName }
                        if ($nnRes) {
                            & $vlog "enter Stop-ClusterResource '$($nnRes.Name)'"
                            $nnRes | Stop-ClusterResource -ErrorAction SilentlyContinue
                            Start-Sleep -Seconds 2
                            & $vlog "enter Start-ClusterResource '$($nnRes.Name)'"
                            $nnRes | Start-ClusterResource -ErrorAction SilentlyContinue
                            & $vlog "Bounced cluster Network Name resource for '$listenerName'"
                        }
                    }

                    # Attempt c) Force AD replication so all DCs pick up the record.
                    if ($allDCs.Count -gt 1) {
                        & $vlog "Forcing AD replication across $($allDCs.Count) DCs"
                        $replJob = Start-Job -ScriptBlock {
                            param($dcNames)
                            $dcNames | ForEach-Object { repadmin /syncall $_ /AdeP 2>&1 | Out-Null }
                        } -ArgumentList (,$dcShortNames)
                        $null = Wait-Job $replJob -Timeout 30
                        if ($replJob.State -eq 'Running') { Stop-Job $replJob -ErrorAction SilentlyContinue }
                        Remove-Job $replJob -Force -ErrorAction SilentlyContinue
                        & $vlog 'AD replication job drained'
                    }
                    Start-Sleep -Seconds 5

                    # Verify the record exists on ALL DCs.
                    $missingDCs = @()
                    foreach ($dc in $allDCs) {
                        & $vlog "enter verify Get-DnsServerResourceRecord on '$dc'"
                        $verify = @(Get-DnsServerResourceRecord -ZoneName $zoneName -Name $listenerName `
                            -RRType A -ComputerName $dc -ErrorAction SilentlyContinue)
                        if ($verify.Count -eq 0) {
                            $missingDCs += $dc
                        }
                    }
                    if ($missingDCs.Count -eq 0) {
                        & $vlog "Verified: DNS A record exists on all $($allDCs.Count) DC(s) (attempt ${attempt})"
                        return
                    }
                    & $vlog "Attempt ${attempt}: record still missing on DC(s): $($missingDCs -join ', ')"
                    if ($attempt -lt $maxAttempts) {
                        Start-Sleep -Seconds 10
                    }
                }

                # All attempts exhausted — throw so DSC reports failure and
                # Phase 5 does not proceed.
                throw "DNS A record for '$listenerName' could not be verified on all DCs after $maxAttempts attempts. Missing on: $($missingDCs -join ', '). Phase 5 cannot continue without listener DNS."
            }
            DependsOn            = $nextDepend
            PsDscRunAsCredential = $Admincreds
        }
        $nextDepend = '[Script]VerifyListenerDns'

        WriteStatus AgListen {
            DependsOn = $nextDepend
            Status    = "Waiting on $node2 to Join the Sql Availability Group Listener"
        }

        WaitForAll AddReplica {
            ResourceName     = '[SqlAGReplica]AddReplica'
            NodeName         = $node2
            RetryIntervalSec = 6
            RetryCount       = 900
            DependsOn        = $nextDepend
            PsDscRunAsCredential = $Admincreds
        }

        $dbName = "TESTDB"

        $nextDepend = '[WaitForAll]AddReplica'
        if ($dbName) {

            WriteStatus SetRecoveryModel {
                DependsOn = $nextDepend
                Status    = "Creating $dbName and setting to Full Recovery Model"
            }

            SqlDatabase 'SetRecoveryModel' {
                Ensure        = 'Present'
                ServerName    = $Node.NodeName
                InstanceName  = $thisVM.sqlInstanceName
                Name          = $dbName
                RecoveryModel = 'Full'

                # PsDscRunAsCredential = $Admincreds
                DependsOn     = $nextDepend
            }
            $nextDepend = '[SqlDatabase]SetRecoveryModel'

            WriteStatus AddAGDatabaseMemberships {
                DependsOn = $nextDepend
                Status    = "Adding $dbName to Always On Group"
            }
            SqlAGDatabase 'AddAGDatabaseMemberships' {
                AvailabilityGroupName   = $thisVM.thisParams.SQLAO.AlwaysOnGroupName
                BackupPath              = $thisVM.thisParams.SQLAO.BackupShareFQ
                DatabaseName            = $dbName
                InstanceName            = $thisVM.sqlInstanceName
                ServerName              = $Node.NodeName
                Ensure                  = 'Present'
                ProcessOnlyOnActiveNode = $true
                MatchDatabaseOwner      = $true
                PsDscRunAsCredential    = $Admincreds
                DependsOn               = $nextDepend
            }
            $nextDepend = '[SqlAGDatabase]AddAGDatabaseMemberships'
        }


        $AgentJobSet = "C:\staging\DSC\SQLScripts\SQLAO-AgentJob-Set.sql"
        $AgentJobTest = "C:\staging\DSC\SQLScripts\SQLAO-AgentJob-Test.sql"
        $AgentJobGet = "C:\staging\DSC\SQLScripts\SQLAO-AgentJob-Get.sql"


        WriteStatus InstallAgentJob {
            DependsOn = $nextDepend
            Status    = "Installing Log Backup Agent Job"
        }

        SqlScript 'InstallAgentJob' {
            Id               = 'InstallAgentJob'
            ServerName       = $thisvm.VmName
            InstanceName     = $thisVM.sqlInstanceName
            #Credential       = $Admincreds
            SetFilePath      = $AgentJobSet
            TestFilePath     = $AgentJobTest
            GetFilePath      = $AgentJobGet
            DisableVariables = $true
            DependsOn        = $nextDepend
            Variable     = @('FilePath=C:\temp\')
            PsDscRunAsCredential =  $Admincreds
            Encrypt = "Optional"
        }
        $nextDepend = '[SqlScript]InstallAgentJob'

        WriteStatus Complete {
            DependsOn = $nextDepend
            Status    = "Complete!"
        }
    }

    Node $AllNodes.Where{ $_.Role -eq 'ClusterNode2' }.NodeName
    {
        $thisVM = $deployConfig.VirtualMachines | where-object { $_.vmName -eq $node.NodeName }
        $node1VM = $deployConfig.VirtualMachines | Where-Object { $_.OtherNode -eq $node.NodeName }
        $node1 = $node1VM.vmName

        #$node1 = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).NodeName

        # Detect legacy labs where the cluster IP is on the 10.250.250.x heartbeat
        # subnet. Skip all cluster setup steps for those — the cluster is already
        # running. New labs set up the cluster fresh with proper network roles.
        $clusterIPOnHeartbeat = $Node1VM.thisParams.SQLAO.ClusterIPAddress -match '^10\.250\.250\.'

        ModuleAdd SQLServerModule {
            Key             = 'Always'
            CheckModuleName = 'SqlServer'
        }

        $nextDepend = "[ModuleAdd]SQLServerModule"

        if (-not $clusterIPOnHeartbeat) {
        $DC = $DCNameFromConfig

        WriteStatus PreClusterNicConfig {
            DependsOn = $nextDepend
            Status    = "Disabling DNS registration on cluster NIC (pre-cluster)"
        }

        DisableClusterNicDnsRegistration PreClusterNicConfig {
            Stage                = 'PreCluster'
            ClusterSubnet        = '10.250.251.'
            DomainName           = $DomainName
            DCName               = $DC
            DependsOn            = $nextDepend
            PsDscRunAsCredential = $Admincreds
        }
        $nextDepend = '[DisableClusterNicDnsRegistration]PreClusterNicConfig'

        $_groupName = $Node1VM.thisParams.SQLAO.GroupName

        WriteStatus WaitForDC {
            Status    = "Waiting for AD group '$_groupName' to be created by DC"
            DependsOn = $nextDepend
        }

        Script WaitForADGroup {
            SetScript = {
                $groupName = $using:_groupName
                for ($i = 1; $i -le 300; $i++) {
                    try {
                        $null = Get-ADGroup -Identity $groupName -ErrorAction Stop
                        Write-Verbose "AD group '$groupName' found on attempt $i"
                        return
                    } catch {}
                    Start-Sleep -Seconds 5
                }
                throw "AD group '$groupName' not found after 300 retries (25 min)"
            }
            TestScript = {
                try {
                    $null = Get-ADGroup -Identity $using:_groupName -ErrorAction Stop
                    return $true
                } catch {
                    return $false
                }
            }
            GetScript  = { @{ Result = "N/A" } }
            PsDscRunAsCredential = $Admincreds
            DependsOn            = $nextDepend
        }
        $nextDepend = "[Script]WaitForADGroup"

        WriteStatus WaitCluster {
            Status    = "Waiting for Cluster '$($Node1VM.ClusterName)' to become active"
            DependsOn = $nextDepend
        }

        WaitForCluster WaitForCluster {
            Name                 = $Node1VM.ClusterName
            RetryIntervalSec     = 180
            RetryCount           = 20
            DependsOn            = $nextDepend
            PsDscRunAsCredential = $Admincreds
        }
        $nextDepend = '[WaitForCluster]WaitForCluster'

        WriteStatus JoinCluster {
            Status    = "Joining Windows Cluster '$($Node1VM.ClusterName)' via IP"
            DependsOn = $nextDepend
        }

        JoinClusterByIP JoinSecondNodeToCluster {
            ClusterName                   = $Node1VM.ClusterName
            ClusterIPAddress              = $Node1VM.thisParams.SQLAO.ClusterIPAddress
            DomainAdministratorCredential = $Admincreds
            DependsOn                     = $nextDepend
        }
        $nextDepend = '[JoinClusterByIP]JoinSecondNodeToCluster'

        WriteStatus PostClusterDnsConfig {
            DependsOn = $nextDepend
            Status    = "Setting RegisterAllProvidersIP=0 on cluster '$($Node1VM.ClusterName)'"
        }

        DisableClusterNicDnsRegistration PostClusterDnsConfig {
            Stage                = 'PostCluster'
            ClusterSubnet        = '10.250.251.'
            DomainName           = $DomainName
            DCName               = $DC
            ClusterName          = $Node1VM.ClusterName
            DependsOn            = $nextDepend
            PsDscRunAsCredential = $Admincreds
        }
        $nextDepend = '[DisableClusterNicDnsRegistration]PostClusterDnsConfig'

        WriteStatus "ChangeNetwork-10" {
            Status    = "Setting 10.250.251.0 to cluster-only (Role 1)"
            DependsOn = $nextDepend
        }

        ClusterNetwork 'ChangeNetwork-10' {
            Address              = '10.250.251.0'
            AddressMask          = '255.255.255.0'
            Name                 = 'Cluster Network'
            Role                 = '1'
            DependsOn            = $nextDepend
            PsDscRunAsCredential = $Admincreds
        }
        $nextDepend = '[ClusterNetwork]ChangeNetwork-10'



        WriteStatus WaitForFS {
            Status    = "Waiting for '$($Node1VM.fileServerVM)' to Complete"
            DependsOn = $nextDepend
        }

        WaitForAny FileShareComplete {
            NodeName             = $node1VM.fileServerVM
            ResourceName         = "[WriteStatus]Complete"
            RetryIntervalSec     = 5
            RetryCount           = 900
            PsDscRunAsCredential = $Admincreds
            DependsOn            = $nextDepend
        }


        WriteStatus WaitForQuorum {
            Status    = "Joining Quorum on '$($node1VM.thisParams.SQLAO.WitnessShareFQ)'"
            DependsOn = '[WaitForAny]FileShareComplete'
        }


        ClusterQuorum 'ClusterWitness' {
            IsSingleInstance     = 'Yes'
            Type                 = 'NodeAndFileShareMajority'
            Resource             = $node1VM.thisParams.SQLAO.WitnessShareFQ
            DependsOn            = '[WaitForAny]FileShareComplete'
            PsDscRunAsCredential = $Admincreds
        }
        $nextDepend = '[ClusterQuorum]ClusterWitness'
        } # end if (-not $clusterIPOnHeartbeat)

        WriteStatus SqlLogins {
            Status    = "Adding SQL Logins"
            DependsOn = $nextDepend
        }

        SqlLogin 'Add_WindowsUserAgent' {
            Ensure               = 'Present'
            Name                 = $node1vm.thisParams.SQLAO.SqlAgentServiceAccountFQ
            LoginType            = 'WindowsUser'
            ServerName           = $node.NodeName
            InstanceName         = $node1vm.sqlInstanceName
            DependsOn            = $nextDepend
            PsDscRunAsCredential = $Admincreds
        }

        SqlLogin 'Add_WindowsUser' {
            Ensure               = 'Present'
            Name                 = $node1vm.thisParams.SQLAO.SqlServiceAccountFQ
            LoginType            = 'WindowsUser'
            ServerName           = $node.NodeName
            InstanceName         = $node1vm.sqlInstanceName
            DependsOn            = $nextDepend
            PsDscRunAsCredential = $Admincreds
        }

        SqlLogin 'AddNTServiceClusSvc' {
            Ensure               = 'Present'
            Name                 = 'NT SERVICE\ClusSvc'
            LoginType            = 'WindowsUser'
            ServerName           = $Node.NodeName
            InstanceName         = $node1vm.sqlInstanceName
            DependsOn            = $nextDepend
            PsDscRunAsCredential = $Admincreds
        }

        $nextDepend = '[SqlLogin]Add_WindowsUserAgent', '[SqlLogin]Add_WindowsUser', '[SqlLogin]AddNTServiceClusSvc'

        SqlRole 'Add_ServerRole' {
            Ensure               = 'Present'
            ServerRoleName       = 'SysAdmin'
            ServerName           = $node.NodeName
            InstanceName         = $node1vm.sqlInstanceName
            MembersToInclude     = $node1vm.thisParams.SQLAO.SqlAgentServiceAccountFQ, $node1vm.thisParams.SQLAO.SqlServiceAccountFQ, 'BUILTIN\Administrators'
            PsDscRunAsCredential = $Admincreds
            DependsOn            = $nextDepend
        }

        # Add the required permissions to the cluster service login
        SqlPermission 'AddNTServiceClusSvcPermissions' {
            DependsOn            = $nextDepend
            ServerName           = $Node.NodeName
            InstanceName         = $node1vm.sqlInstanceName
            Name            = 'NT SERVICE\ClusSvc'
            Permission   = @(
                ServerPermission
                {
                    State      = 'Grant'
                    Permission = @('AlterAnyAvailabilityGroup', 'ViewServerState')
                }
                ServerPermission
                {
                    State      = 'GrantWithGrant'
                    Permission = @()
                }
                ServerPermission
                {
                    State      = 'Deny'
                    Permission = @()
                }
            )
            #Credential = $Admincreds
        }
        $nextDepend = '[SqlRole]Add_ServerRole', '[SqlPermission]AddNTServiceClusSvcPermissions'

        # Create a DatabaseMirroring endpoint
        SqlEndpoint 'HADREndpoint' {
            EndPointName         = 'HADR'
            EndpointType         = 'DatabaseMirroring'
            Ensure               = 'Present'
            Port                 = 5022
            ServerName           = $Node.NodeName
            InstanceName         = $node1vm.sqlInstanceName
            DependsOn            = $nextDepend
            PsDscRunAsCredential = $Admincreds
        }

        SqlAlwaysOnService EnableHADR {
            Ensure               = 'Present'
            InstanceName         = $node1vm.sqlInstanceName
            ServerName           = $Node.NodeName
            PsDscRunAsCredential = $Admincreds
            DependsOn            = '[SqlEndpoint]HADREndpoint'
        }

        WriteStatus SQLAOWait {
            DependsOn = '[SqlAlwaysOnService]EnableHADR'
            Status    = "Waiting for '$node1' to create the Availability Group"
        }

        SqlWaitForAG 'SQLConfigureAG-WaitAG' {
            Name                 = $node1VM.thisParams.SQLAO.AlwaysOnGroupName
            RetryIntervalSec     = 10
            RetryCount           = 300
            ServerName           = $node1
            InstanceName         = $node1vm.sqlInstanceName
            DependsOn            = '[SqlAlwaysOnService]EnableHADR'
            PsDscRunAsCredential = $Admincreds
        }
        $nextDepend = '[SqlAlwaysOnService]EnableHADR', '[SqlWaitForAG]SQLConfigureAG-WaitAG'

        WriteStatus SQLAO1 {
            DependsOn = $nextDepend
            Status    = "Waiting for $node1 to complete"
        }

        WaitForAll AG {
            ResourceName     = '[SqlAGListener]AvailabilityGroupListener'
            NodeName         = $node1
            RetryIntervalSec = 5
            RetryCount       = 450
            DependsOn        = $nextDepend
            PsDscRunAsCredential = $Admincreds
        }
        $nextDepend = '[WaitForAll]AG'

        if (-not $clusterIPOnHeartbeat) {
        WriteStatus "ChangeNetwork-192" {
            Status    = "Setting Domain Network $($Node1VM.thisParams.vmNetwork) to cluster + client (Role 3)"
            DependsOn = $nextDepend
        }

        ClusterNetwork 'ChangeNetwork-192' {
            Address              = $Node1VM.thisParams.vmNetwork
            AddressMask          = '255.255.255.0'
            Name                 = 'Domain Network'
            Role                 = '3'
            DependsOn            = $nextDepend
            PsDscRunAsCredential = $Admincreds
        }
        $nextDepend = '[ClusterNetwork]ChangeNetwork-192'
        } # end if (-not $clusterIPOnHeartbeat)

        WriteStatus SQLAO2 {
            DependsOn = $nextDepend
            Status    = "Adding replica to the Availability Group"
        }

        # Add the availability group replica to the availability group
        $nodename = ($node.NodeName) + '\' + $node1vm.sqlInstanceName
        if ($node1vm.sqlInstanceName -eq "MSSQLSERVER") {
            $nodename = $node.NodeName
        }

        SqlAGReplica 'AddReplica' {
            Ensure                        = 'Present'
            Name                          = $nodename
            AvailabilityGroupName         = $node1VM.thisParams.SQLAO.AlwaysOnGroupName
            ServerName                    = $node.NodeName
            InstanceName                  = $node1vm.sqlInstanceName
            AvailabilityMode              = 'SynchronousCommit'
            BackupPriority                = 50
            ConnectionModeInPrimaryRole   = 'AllowAllConnections'
            ConnectionModeInSecondaryRole = 'AllowAllConnections'
            FailoverMode                  = 'Manual'
            PrimaryReplicaServerName      = $node1VM.thisParams.SQLAO.PrimaryReplicaServerName
            PrimaryReplicaInstanceName    = $node1vm.sqlInstanceName
            ProcessOnlyOnActiveNode       = $true
            DependsOn                     = $nextDepend
            PsDscRunAsCredential          = $Admincreds
        }

        $nextDepend = '[SqlAGReplica]AddReplica'
        if ($Node.DBName) {

            WaitForAll RecoveryModel {
                ResourceName     = '[SqlDatabase]SetRecoveryModel'
                NodeName         = $node1
                RetryIntervalSec = 5
                RetryCount       = 450
                DependsOn        = $nextDepend
                PsDscRunAsCredential = $Admincreds
            }

            WaitForAll AddAGDatabaseMemberships {
                ResourceName     = '[SqlAGDatabase]AddAGDatabaseMemberships'
                NodeName         = $node1
                RetryIntervalSec = 5
                RetryCount       = 450
                DependsOn        = '[WaitForAll]RecoveryModel'
                PsDscRunAsCredential = $Admincreds
            }

            $nextDepend = '[WaitForAll]AddAGDatabaseMemberships'

        }
        $AgentJobSet = "C:\staging\DSC\SQLScripts\SQLAO-AgentJob-Set.sql"
        $AgentJobTest = "C:\staging\DSC\SQLScripts\SQLAO-AgentJob-Test.sql"
        $AgentJobGet = "C:\staging\DSC\SQLScripts\SQLAO-AgentJob-Get.sql"


        WriteStatus InstallAgentJob {
            DependsOn = $nextDepend
            Status    = "Installing Log Backup Agent Job"
        }

        SqlScript 'InstallAgentJob' {
            Id               = 'InstallAgentJob'
            ServerName       = $node.nodename
            InstanceName     = $node1vm.sqlInstanceName
            #Credential       = $Admincreds
            SetFilePath      = $AgentJobSet
            TestFilePath     = $AgentJobTest
            GetFilePath      = $AgentJobGet
            DisableVariables = $true
            DependsOn        = $nextDepend
            PsDscRunAsCredential =  $Admincreds
            Variable     = @('FilePath=C:\temp\')
            Encrypt = "Optional"
        }
        $nextDepend = '[SqlScript]InstallAgentJob'

        WriteStatus Complete {
            DependsOn = $nextDepend
            Status    = "Complete!"
        }
    }

    Node $AllNodes.Where{ $_.Role -eq 'DC' }.NodeName
    {
        WriteStatus SQLAOGroup {
            Status = "Creating AD Group and assigning SPN for SQL Availability Group"
        }

        $adGroupDependency = @('[WriteStatus]SQLAOGroup')
        $sqlAOPrimaryNodes = $deployConfig.VirtualMachines | Where-Object { $_.role -eq "SQLAO" -and $_.OtherNode }

        $i = 0
        foreach ($pNode in $sqlAOPrimaryNodes) {
            $i++
            ADGroup "SQLAOGroup$($pNode.vmName)" {
                Ensure      = 'Present'
                GroupName   = $pNode.thisParams.SQLAO.GroupName
                GroupScope  = "Global"
                Category    = "Security"
                Description = "$($pNode.thisParams.SQLAO.GroupName) Group for SQL Always On"
                Members     = $pNode.thisParams.SQLAO.GroupMembers
                DependsOn   = '[WriteStatus]SQLAOGroup'
            }

            $adGroupDependency += "[ADGroup]SQLAOGroup$($pNode.vmName)"

            # Grant the CNO (cluster computer account) Full Control on the
            # prestaged listener VCO so the cluster service can set "Protect
            # from accidental deletion" and manage the object without
            # Event ID 1222 warnings.
            $_cnoName = $pNode.ClusterName
            $_listenerName = $pNode.thisParams.SQLAO.AlwaysOnListenerName

            Script "GrantCnoVcoPermissions$i" {
                SetScript  = {
                    Import-Module ActiveDirectory -ErrorAction Stop
                    $cnoAccount = Get-ADComputer -Identity $using:_cnoName -ErrorAction Stop
                    $cnoSID = [System.Security.Principal.SecurityIdentifier]$cnoAccount.SID

                    $vcoNames = @($using:_cnoName, $using:_listenerName) | Where-Object { $_ }
                    foreach ($vcoName in $vcoNames) {
                        $vco = Get-ADComputer -Identity $vcoName -ErrorAction SilentlyContinue
                        if (-not $vco) { continue }

                        $vcoPath = "AD:\$($vco.DistinguishedName)"
                        $acl = Get-Acl $vcoPath
                        $hasFullControl = $acl.Access | Where-Object {
                            $_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value -eq $cnoSID.Value -and
                            $_.ActiveDirectoryRights -band [System.DirectoryServices.ActiveDirectoryRights]::GenericAll
                        }
                        if (-not $hasFullControl) {
                            $identity = [System.Security.Principal.NTAccount]"$($env:USERDOMAIN)\$($using:_cnoName)$"
                            $adRights = [System.DirectoryServices.ActiveDirectoryRights]::GenericAll
                            $type = [System.Security.AccessControl.AccessControlType]::Allow
                            $inherit = [System.DirectoryServices.ActiveDirectorySecurityInheritance]::None
                            $ace = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
                                $identity, $adRights, $type, $inherit
                            )
                            $acl.AddAccessRule($ace)
                            Set-Acl $vcoPath $acl
                        }
                    }
                }
                TestScript = {
                    Import-Module ActiveDirectory -ErrorAction Stop
                    $cnoAccount = Get-ADComputer -Identity $using:_cnoName -ErrorAction SilentlyContinue
                    if (-not $cnoAccount) { return $false }
                    $cnoSID = [System.Security.Principal.SecurityIdentifier]$cnoAccount.SID

                    $vcoNames = @($using:_cnoName, $using:_listenerName) | Where-Object { $_ }
                    foreach ($vcoName in $vcoNames) {
                        $vco = Get-ADComputer -Identity $vcoName -ErrorAction SilentlyContinue
                        if (-not $vco) { continue }

                        $acl = Get-Acl "AD:\$($vco.DistinguishedName)"
                        $hasFullControl = $acl.Access | Where-Object {
                            $_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value -eq $cnoSID.Value -and
                            $_.ActiveDirectoryRights -band [System.DirectoryServices.ActiveDirectoryRights]::GenericAll
                        }
                        if (-not $hasFullControl) { return $false }
                    }
                    return $true
                }
                GetScript  = { return @{ Result = "N/A" } }
                DependsOn  = "[ADGroup]SQLAOGroup$($pNode.vmName)"
            }
            $adGroupDependency += "[Script]GrantCnoVcoPermissions$i"

            # Create PTR records for the cluster IP and AG listener IP so that
            # reverse DNS lookups work. OpenCluster() and other cluster APIs may
            # need reverse resolution. Skip legacy labs on the heartbeat subnet.
            $_clusterIP = $pNode.thisParams.SQLAO.ClusterIPAddress -replace '/.*$', ''
            $_agIP = $pNode.thisParams.SQLAO.AGIPAddress -replace '/.*$', ''
            $_clusterFqdn = "$($pNode.ClusterName).$DomainName"
            $_listenerFqdn = "$($pNode.thisParams.SQLAO.AlwaysOnListenerName).$DomainName"

            Script "ClusterPtrRecords$i" {
                SetScript  = {
                    $entries = @(
                        @{ IP = $using:_clusterIP; FQDN = $using:_clusterFqdn },
                        @{ IP = $using:_agIP; FQDN = $using:_listenerFqdn }
                    )
                    foreach ($entry in $entries) {
                        if ($entry.IP -match '^10\.250\.250\.') { continue }
                        # PTR records are a nice-to-have for reverse lookups; never let a
                        # DNS hiccup here fail the resource and block the DC's final
                        # [WriteStatus]Complete (which DependsOn this script). Swallow and
                        # continue on any per-entry error.
                        try {
                            $octets = $entry.IP.Split('.')
                            $zoneName = "$($octets[2]).$($octets[1]).$($octets[0]).in-addr.arpa"
                            $hostOctet = $octets[3]

                            $zone = Get-DnsServerZone -Name $zoneName -ErrorAction SilentlyContinue
                            if (-not $zone) {
                                $networkId = "$($octets[0]).$($octets[1]).$($octets[2]).0/24"
                                Add-DnsServerPrimaryZone -NetworkId $networkId -ReplicationScope Domain -DynamicUpdate Secure -ErrorAction Stop
                            }

                            $existing = Get-DnsServerResourceRecord -ZoneName $zoneName -Name $hostOctet -RRType Ptr -ErrorAction SilentlyContinue
                            if ($existing) {
                                Remove-DnsServerResourceRecord -ZoneName $zoneName -InputObject $existing -Force -ErrorAction SilentlyContinue
                            }
                            Add-DnsServerResourceRecordPtr -ZoneName $zoneName -Name $hostOctet -PtrDomainName "$($entry.FQDN)." -ErrorAction Stop
                        }
                        catch {
                            Write-Verbose "ClusterPtrRecords: failed to set PTR for $($entry.IP) -> $($entry.FQDN): $_"
                        }
                    }
                }
                TestScript = {
                    $entries = @(
                        @{ IP = $using:_clusterIP; FQDN = $using:_clusterFqdn },
                        @{ IP = $using:_agIP; FQDN = $using:_listenerFqdn }
                    )
                    foreach ($entry in $entries) {
                        if ($entry.IP -match '^10\.250\.250\.') { continue }
                        # Wrap per-entry so Test NEVER throws -- a thrown Test fails the
                        # whole resource and DSC then SKIPS SetScript, so the missing
                        # reverse zone is never created and, because [WriteStatus]Complete
                        # DependsOn this script, the DC config never reaches 'Complete!'
                        # (Phase 5 hangs ~30 min, then force-restarts). Any error -> $false
                        # so SetScript runs and remediates.
                        try {
                            $octets = $entry.IP.Split('.')
                            $zoneName = "$($octets[2]).$($octets[1]).$($octets[0]).in-addr.arpa"
                            $hostOctet = $octets[3]

                            # Probing a missing zone with Get-DnsServerResourceRecord raises
                            # a terminating 'zone was not found' error that -ErrorAction
                            # can't suppress. Check zone existence first; if absent we're not
                            # in desired state -> $false (SetScript creates it).
                            $zone = Get-DnsServerZone -Name $zoneName -ErrorAction SilentlyContinue
                            if (-not $zone) { return $false }

                            $ptr = Get-DnsServerResourceRecord -ZoneName $zoneName -Name $hostOctet -RRType Ptr -ErrorAction SilentlyContinue
                            if (-not $ptr -or $ptr.RecordData.PtrDomainName -ne "$($entry.FQDN).") {
                                return $false
                            }
                        }
                        catch {
                            Write-Verbose "ClusterPtrRecords Test: $($entry.IP): $_"
                            return $false
                        }
                    }
                    return $true
                }
                GetScript  = { return @{ Result = "N/A" } }
                DependsOn  = '[WriteStatus]SQLAOGroup'
            }
            $adGroupDependency += "[Script]ClusterPtrRecords$i"
        }

        WriteStatus Complete {
            DependsOn = $adGroupDependency
            Status    = "Complete!"
        }

    }


}