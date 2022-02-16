Configuration SQLAOConfiguration
{
    param
    (
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCredential]
        $SqlAdministratorCredential,

        [parameter(Mandatory = $true)]
        [System.String]
        $GroupName,

        [ValidateSet('DomainLocal', 'Global', 'Universal')]
        [System.String]
        $Scope = 'Global',

        [ValidateSet('Security', 'Distribution')]
        [System.String]
        $Category = 'Security',

        [ValidateNotNullOrEmpty()]
        [System.String]
        $Description
    )

    Import-DscResource -ModuleName 'ActiveDirectoryDsc'
    Import-DscResource -ModuleName 'PSDesiredStateConfiguration'
    Import-DscResource -ModuleName 'TemplateHelpDSC'
    Import-DscResource -ModuleName 'ComputerManagementDsc'
    Import-DscResource -ModuleName 'xFailOverCluster'
    Import-DscResource -ModuleName 'AccessControlDsc'
    Import-DscResource -ModuleName 'SqlServerDsc'


    Node $AllNodes.Where{ $_.Role -eq 'ClusterNode1' }.NodeName
    {

        $node2 = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode2' }).NodeName

        WriteStatus WindowsFeature {
            Status = "Adding Windows Features"
        }

        WindowsFeature ADDADPS {
            Ensure    = 'Present'
            Name      = 'RSAT-AD-PowerShell'
            DependsOn = "[WriteStatus]WindowsFeature"
        }

        ModuleAdd SQLServerModule {
            Key             = 'Always'
            CheckModuleName = $AllNodes.Where{ $_.Role -eq 'ClusterNode1' }.CheckModuleName
            DependsOn       = "[WriteStatus]WindowsFeature"
        }

        WindowsFeature AddFailoverFeature {
            Ensure    = 'Present'
            Name      = 'Failover-clustering'
            DependsOn = "[WriteStatus]WindowsFeature"
        }

        WindowsFeature AddRemoteServerAdministrationToolsClusteringPowerShellFeature {
            Ensure    = 'Present'
            Name      = 'RSAT-Clustering-PowerShell'
            DependsOn = '[WindowsFeature]AddFailoverFeature'
        }

        WindowsFeature AddRemoteServerAdministrationToolsClusteringCmdInterfaceFeature {
            Ensure    = 'Present'
            Name      = 'RSAT-Clustering-CmdInterface'
            DependsOn = '[WindowsFeature]AddRemoteServerAdministrationToolsClusteringPowerShellFeature'
        }

        WindowsFeature AddRemoteServerAdministrationToolsClusteringMgmtInterfaceFeature {
            Ensure    = 'Present'
            Name      = 'RSAT-Clustering-Mgmt'
            DependsOn = '[WindowsFeature]AddRemoteServerAdministrationToolsClusteringCmdInterfaceFeature'
        }

        WriteStatus Cluster {
            DependsOn = "[WindowsFeature]AddRemoteServerAdministrationToolsClusteringMgmtInterfaceFeature"
            Status    = "Creating Windows Cluster and Network"
        }

        xCluster CreateCluster {
            Name                          = $Node.ClusterName
            StaticIPAddress               = $Node.ClusterIPAddress
            # This user must have the permission to create the CNO (Cluster Name Object) in Active Directory, unless it is prestaged.
            DomainAdministratorCredential = $SqlAdministratorCredential
            DependsOn                     = '[WindowsFeature]AddRemoteServerAdministrationToolsClusteringMgmtInterfaceFeature'
        }

        xClusterNetwork 'ChangeNetwork-192' {
            Address              = $AllNodes.Where{ $_.Role -eq 'ClusterNode1' }.Address
            AddressMask          = $AllNodes.Where{ $_.Role -eq 'ClusterNode1' }.AddressMask
            Name                 = $AllNodes.Where{ $_.Role -eq 'ClusterNode1' }.Name
            Role                 = '0'
            DependsOn            = '[xCluster]CreateCluster'
            PsDscRunAsCredential = $SqlAdministratorCredential
        }

        xClusterNetwork 'ChangeNetwork-10' {
            Address              = $AllNodes.Where{ $_.Role -eq 'ClusterNode1' }.Address2
            AddressMask          = $AllNodes.Where{ $_.Role -eq 'ClusterNode1' }.AddressMask2
            Name                 = $AllNodes.Where{ $_.Role -eq 'ClusterNode1' }.Name2
            Role                 = '3'
            DependsOn            = '[xCluster]CreateCluster'
            PsDscRunAsCredential = $SqlAdministratorCredential
        }

        #WaitForAny WaitForCluster {
        #    NodeName             = $AllNodes.Where{ $_.Role -eq 'ClusterNode2' }.NodeName
        #    ResourceName         = '[xCluster]JoinSecondNodeToCluster'
        #    RetryIntervalSec     = 10
        #    RetryCount           = 90
        #    PsDscRunAsCredential = $SqlAdministratorCredential
        #    DependsOn            = '[xClusterNetwork]ChangeNetwork-10', '[xClusterNetwork]ChangeNetwork-192'
        #}

        WriteStatus ClusterJoin {
            DependsOn = "[xClusterNetwork]ChangeNetwork-10"
            Status    = "Waiting for '$node2' to join Cluster"
        }

        WaitForAny WaitForClusterJoin {
            NodeName             = $AllNodes.Where{ $_.Role -eq 'ClusterNode2' }.NodeName
            ResourceName         = '[xClusterQuorum]ClusterWitness'
            RetryIntervalSec     = 10
            RetryCount           = 90
            PsDscRunAsCredential = $SqlAdministratorCredential
            DependsOn            = '[xCluster]CreateCluster'
        }

        ClusterRemoveUnwantedIPs ClusterRemoveUnwantedIPs {
            ClusterName          = $Node.ClusterName
            PsDscRunAsCredential = $SqlAdministratorCredential
            DependsOn            = '[WaitForAny]WaitForClusterJoin'
        }
        ClusterSetOwnerNodes ClusterSetOwnerNodes {
            ClusterName          = $Node.ClusterName
            Nodes                = ($AllNodes.Where{ $_.Role -eq 'ClusterNode1' }.NodeName), ($AllNodes.Where{ $_.Role -eq 'ClusterNode2' }.NodeName)
            PsDscRunAsCredential = $SqlAdministratorCredential
            DependsOn            = '[ClusterRemoveUnwantedIPs]ClusterRemoveUnwantedIPs'
        }
        WriteStatus SvcAccount {
            DependsOn = '[ClusterSetOwnerNodes]ClusterSetOwnerNodes'
            Status    = "Configuring SQL Service Accounts and SQL Logins"
        }


        #Change SQL Service Account
        SqlLogin 'Add_WindowsUserAgent' {
            Ensure               = 'Present'
            Name                 = $node.SqlAgentServiceAccount
            LoginType            = 'WindowsUser'
            ServerName           = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).NodeName
            InstanceName         = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).InstanceName
            PsDscRunAsCredential = $SqlAdministratorCredential
            DependsOn            = '[WaitForAny]WaitForClusterJoin'
        }
        SqlLogin 'Add_WindowsUser' {
            Ensure               = 'Present'
            Name                 = $node.SqlServiceAccount
            LoginType            = 'WindowsUser'
            ServerName           = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).NodeName
            InstanceName         = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).InstanceName
            PsDscRunAsCredential = $SqlAdministratorCredential
            DependsOn            = '[WaitForAny]WaitForClusterJoin'
        }


        SqlRole 'Add_ServerRole' {
            Ensure               = 'Present'
            ServerRoleName       = 'SysAdmin'
            ServerName           = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).NodeName
            InstanceName         = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).InstanceName
            MembersToInclude     = $node.SqlServiceAccount, $node.SqlAgentServiceAccount, 'BUILTIN\Administrators'
            PsDscRunAsCredential = $SqlAdministratorCredential
            DependsOn            = '[SqlLogin]Add_WindowsUser'
        }


        # Adding the required service account to allow the cluster to log into SQL
        SqlLogin 'AddNTServiceClusSvc' {
            Ensure               = 'Present'
            Name                 = 'NT SERVICE\ClusSvc'
            LoginType            = 'WindowsUser'
            ServerName           = $Node.NodeName
            InstanceName         = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).InstanceName
            PsDscRunAsCredential = $SqlAdministratorCredential
            DependsOn            = '[SqlLogin]Add_WindowsUser'
        }

        # Add the required permissions to the cluster service login
        SqlPermission 'AddNTServiceClusSvcPermissions' {
            DependsOn            = '[SqlLogin]AddNTServiceClusSvc'
            Ensure               = 'Present'
            ServerName           = $Node.NodeName
            InstanceName         = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).InstanceName
            Principal            = 'NT SERVICE\ClusSvc'
            Permission           = 'AlterAnyAvailabilityGroup', 'ViewServerState'
            PsDscRunAsCredential = $SqlAdministratorCredential
        }

        # Create a DatabaseMirroring endpoint
        SqlEndpoint 'HADREndpoint' {
            EndPointName         = 'HADR'
            EndpointType         = 'DatabaseMirroring'
            Ensure               = 'Present'
            Port                 = 5022
            ServerName           = $Node.NodeName
            InstanceName         = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).InstanceName
            PsDscRunAsCredential = $SqlAdministratorCredential
        }

        # Ensure the HADR option is enabled for the instance
        SqlAlwaysOnService 'EnableHADR' {
            Ensure               = 'Present'
            InstanceName         = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).InstanceName
            ServerName           = $Node.NodeName
            PsDscRunAsCredential = $SqlAdministratorCredential
        }

        WriteStatus SQLAG {
            DependsOn = '[SqlAlwaysOnService]EnableHADR', '[SqlEndpoint]HADREndpoint', '[SqlPermission]AddNTServiceClusSvcPermissions'
            Status    = "Creating Availability Group and Listener"
        }

        # Create the availability group on the instance tagged as the primary replica
        SqlAG 'CMCASAG' {
            Ensure                        = 'Present'
            Name                          = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).ClusterNameAoG
            InstanceName                  = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).InstanceName
            ServerName                    = $Node.NodeName
            AvailabilityMode              = 'SynchronousCommit'
            BackupPriority                = 50
            ConnectionModeInPrimaryRole   = 'AllowAllConnections'
            ConnectionModeInSecondaryRole = 'AllowAllConnections'
            FailoverMode                  = 'Manual'
            HealthCheckTimeout            = 15000
            DependsOn                     = '[SqlAlwaysOnService]EnableHADR', '[SqlEndpoint]HADREndpoint', '[SqlPermission]AddNTServiceClusSvcPermissions'
            PsDscRunAsCredential          = $SqlAdministratorCredential
        }
        SqlAGListener 'AvailabilityGroupListener' {
            Ensure               = 'Present'
            ServerName           = $Node.NodeName
            InstanceName         = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).InstanceName
            AvailabilityGroup    = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).ClusterNameAoG
            DHCP                 = $false
            Name                 = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).ClusterNameAoG
            IpAddress            = $Node.AGIPAddress

            Port                 = 1500
            DependsOn            = '[SqlAG]CMCASAG'
            PsDscRunAsCredential = $SqlAdministratorCredential
        }

        $lspn1 = "MSSQLSvc/" + $Node.ClusterNameAoG
        $lspn2 = "MSSQLSvc/" + $Node.ClusterNameAoGFQDN
        $lspn3 = $lspn1 + ":1500"
        $lspn4 = $lspn2 + ":1500"
        $account = ($Node.SqlServiceAccount -Split "\\")[1]

        ADServicePrincipalName 'lspn1' {
            Ensure               = 'Present'
            ServicePrincipalName = $lspn1
            Account              = $account
            Dependson            = '[SqlAGListener]AvailabilityGroupListener'
            PsDscRunAsCredential = $SqlAdministratorCredential
        }
        ADServicePrincipalName 'lspn2' {
            Ensure               = 'Present'
            ServicePrincipalName = $lspn2
            Account              = $account
            Dependson            = '[SqlAGListener]AvailabilityGroupListener'
            PsDscRunAsCredential = $SqlAdministratorCredential
        }
        ADServicePrincipalName 'lspn3' {
            Ensure               = 'Present'
            ServicePrincipalName = $lspn3
            Account              = $account
            Dependson            = '[SqlAGListener]AvailabilityGroupListener'
            PsDscRunAsCredential = $SqlAdministratorCredential
        }
        ADServicePrincipalName 'lspn4' {
            Ensure               = 'Present'
            ServicePrincipalName = $lspn4
            Account              = $account
            Dependson            = '[SqlAGListener]AvailabilityGroupListener'
            PsDscRunAsCredential = $SqlAdministratorCredential
        }


        WriteStatus AgListen {
            DependsOn = '[ADServicePrincipalName]lspn4'
            Status    = "Waiting on $node2 to Join the Sql Availability Group Listener"
        }

        WaitForAll AddReplica {
            ResourceName     = '[SqlAGReplica]AddReplica'
            NodeName         = $node2
            RetryIntervalSec = 2
            RetryCount       = 450
            Dependson        = '[SqlAGListener]AvailabilityGroupListener'
        }

        $dbName = "TESTDB"
        if ($Node.DBName){
            $dbName = $Node.DBName
        }

        $nextDepend = '[WaitForAll]AddReplica'
        if ($dbName) {

            SqlDatabase 'SetRecoveryModel' {
                Ensure               = 'Present'
                ServerName           = $Node.NodeName
                InstanceName         = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).InstanceName
                Name                 = $dbName
                RecoveryModel        = 'Full'

                PsDscRunAsCredential = $SqlAdministratorCredential
                DependsOn            = $nextDepend
            }

            SqlAGDatabase 'AddAGDatabaseMemberships' {
                AvailabilityGroupName   = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).ClusterNameAoG
                BackupPath              = $Node.BackupShare
                DatabaseName            = $dbName
                InstanceName            = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).InstanceName
                ServerName              = $Node.NodeName
                Ensure                  = 'Present'
                ProcessOnlyOnActiveNode = $true
                MatchDatabaseOwner      = $true
                PsDscRunAsCredential    = $SqlAdministratorCredential
                DependsOn               = '[SqlDatabase]SetRecoveryModel'
            }
            $nextDepend = '[SqlAGDatabase]AddAGDatabaseMemberships'
        }
        WriteStatus Complete {
            DependsOn = $nextDepend
            Status    = "Complete!"
        }
    }

    Node $AllNodes.Where{ $_.Role -eq 'ClusterNode2' }.NodeName
    {

        $node1 = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).NodeName

        WriteStatus WindowsFeature {
            Status = "Adding Windows Features"
        }

        WindowsFeature ADDADPS {
            Ensure    = 'Present'
            Name      = 'RSAT-AD-PowerShell'
            DependsOn = "[WriteStatus]WindowsFeature"
        }

        WindowsFeature AddFailoverFeature {
            Ensure = 'Present'
            Name   = 'Failover-clustering'
        }

        WindowsFeature AddRemoteServerAdministrationToolsClusteringPowerShellFeature {
            Ensure    = 'Present'
            Name      = 'RSAT-Clustering-PowerShell'
            DependsOn = '[WindowsFeature]AddFailoverFeature'
        }

        WindowsFeature AddRemoteServerAdministrationToolsClusteringCmdInterfaceFeature {
            Ensure    = 'Present'
            Name      = 'RSAT-Clustering-CmdInterface'
            DependsOn = '[WindowsFeature]AddRemoteServerAdministrationToolsClusteringPowerShellFeature'
        }

        WindowsFeature AddRemoteServerAdministrationToolsClusteringMgmtInterfaceFeature {
            Ensure    = 'Present'
            Name      = 'RSAT-Clustering-Mgmt'
            DependsOn = '[WindowsFeature]AddRemoteServerAdministrationToolsClusteringCmdInterfaceFeature'
        }

        WriteStatus WaitCluster {
            Status    = "Waiting for Cluster '$($Node.ClusterName)' to become active"
            DependsOn = '[WindowsFeature]AddRemoteServerAdministrationToolsClusteringMgmtInterfaceFeature'
        }

        xWaitForCluster WaitForCluster {
            Name                 = $Node.ClusterName
            RetryIntervalSec     = 15
            RetryCount           = 60
            DependsOn            = '[WindowsFeature]AddRemoteServerAdministrationToolsClusteringMgmtInterfaceFeature'
            PsDscRunAsCredential = $SqlAdministratorCredential
        }

        WriteStatus WaitClusterNetwork {
            Status    = "Waiting for '$node1' to create Windows Cluster Network"
            DependsOn = '[xWaitForCluster]WaitForCluster'
        }

        WaitForAny WaitForClusteringNetworking {
            NodeName             = $AllNodes.Where{ $_.Role -eq 'ClusterNode1' }.NodeName
            ResourceName         = '[xClusterNetwork]ChangeNetwork-10'
            RetryIntervalSec     = 10
            RetryCount           = 90
            PsDscRunAsCredential = $SqlAdministratorCredential
        }

        WriteStatus JoinCluster {
            Status    = "Joining Windows Cluster '$( $Node.ClusterName)' on '$node1'"
            DependsOn = '[xWaitForCluster]WaitForCluster'
        }

        xCluster JoinSecondNodeToCluster {
            Name                 = $Node.ClusterName
            StaticIPAddress      = $Node.ClusterIPAddress
            PsDscRunAsCredential = $SqlAdministratorCredential
            DependsOn            = '[xWaitForCluster]WaitForCluster', '[WaitForAny]WaitForClusteringNetworking'
        }

        xClusterNetwork 'ChangeNetwork-192' {
            Address              = $AllNodes.Where{ $_.Role -eq 'ClusterNode1' }.Address
            AddressMask          = $AllNodes.Where{ $_.Role -eq 'ClusterNode1' }.AddressMask
            Name                 = $AllNodes.Where{ $_.Role -eq 'ClusterNode1' }.Name
            Role                 = '0'
            DependsOn            = '[xCluster]JoinSecondNodeToCluster'
            PsDscRunAsCredential = $SqlAdministratorCredential
        }

        xClusterNetwork 'ChangeNetwork-10' {
            Address              = $AllNodes.Where{ $_.Role -eq 'ClusterNode1' }.Address2
            AddressMask          = $AllNodes.Where{ $_.Role -eq 'ClusterNode1' }.AddressMask2
            Name                 = $AllNodes.Where{ $_.Role -eq 'ClusterNode1' }.Name2
            Role                 = '3'
            DependsOn            = '[xCluster]JoinSecondNodeToCluster'
            PsDscRunAsCredential = $SqlAdministratorCredential
        }

        xClusterQuorum 'ClusterWitness' {
            IsSingleInstance     = 'Yes'
            Type                 = 'NodeAndFileShareMajority'
            Resource             = $Node.WitnessShare
            DependsOn            = '[xClusterNetwork]ChangeNetwork-10', '[xClusterNetwork]ChangeNetwork-192'
            PsDscRunAsCredential = $SqlAdministratorCredential
        }

        SqlLogin 'Add_WindowsUserAgent' {
            Ensure               = 'Present'
            Name                 = $node.SqlAgentServiceAccount
            LoginType            = 'WindowsUser'
            ServerName           = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode2' }).NodeName
            InstanceName         = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).InstanceName
            Dependson            = '[xClusterQuorum]ClusterWitness'
            PsDscRunAsCredential = $SqlAdministratorCredential
        }
        SqlLogin 'Add_WindowsUser' {
            Ensure               = 'Present'
            Name                 = $node.SqlServiceAccount
            LoginType            = 'WindowsUser'
            ServerName           = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode2' }).NodeName
            InstanceName         = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).InstanceName
            Dependson            = '[xClusterQuorum]ClusterWitness'
            PsDscRunAsCredential = $SqlAdministratorCredential
        }

        SqlRole 'Add_ServerRole' {
            Ensure               = 'Present'
            ServerRoleName       = 'SysAdmin'
            ServerName           = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode2' }).NodeName
            InstanceName         = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).InstanceName
            MembersToInclude     = $node.SqlAgentServiceAccount, $node.SqlServiceAccount, 'BUILTIN\Administrators'
            PsDscRunAsCredential = $SqlAdministratorCredential
            DependsOn            = '[SqlLogin]Add_WindowsUser'
        }

        # Adding the required service account to allow the cluster to log into SQL
        SqlLogin 'AddNTServiceClusSvc' {
            Ensure               = 'Present'
            Name                 = 'NT SERVICE\ClusSvc'
            LoginType            = 'WindowsUser'
            ServerName           = $Node.NodeName
            InstanceName         = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).InstanceName
            Dependson            = '[xClusterQuorum]ClusterWitness'
            PsDscRunAsCredential = $SqlAdministratorCredential
        }

        # Add the required permissions to the cluster service login
        SqlPermission 'AddNTServiceClusSvcPermissions' {
            DependsOn            = '[SqlLogin]AddNTServiceClusSvc'
            Ensure               = 'Present'
            ServerName           = $Node.NodeName
            InstanceName         = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).InstanceName
            Principal            = 'NT SERVICE\ClusSvc'
            Permission           = 'AlterAnyAvailabilityGroup', 'ViewServerState'
            PsDscRunAsCredential = $SqlAdministratorCredential
        }

        # Create a DatabaseMirroring endpoint
        SqlEndpoint 'HADREndpoint' {
            EndPointName         = 'HADR'
            EndpointType         = 'DatabaseMirroring'
            Ensure               = 'Present'
            Port                 = 5022
            ServerName           = $Node.NodeName
            InstanceName         = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).InstanceName
            DependsOn            = "[SqlPermission]AddNTServiceClusSvcPermissions"
            PsDscRunAsCredential = $SqlAdministratorCredential
        }

        SqlAlwaysOnService EnableHADR {
            Ensure               = 'Present'
            InstanceName         = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).InstanceName
            ServerName           = $Node.NodeName
            PsDscRunAsCredential = $SqlAdministratorCredential
        }

        WriteStatus SQLAOWait {
            Dependson = '[SqlEndpoint]HADREndpoint'
            Status    = "Waiting for '$node1' to create the Availability Group"
        }

        SqlWaitForAG 'SQLConfigureAG-WaitAG' {
            Name                 = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).ClusterNameAoG
            RetryIntervalSec     = 10
            RetryCount           = 90
            ServerName           = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).NodeName
            InstanceName         = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).InstanceName
            Dependson            = '[SqlEndpoint]HADREndpoint'
            PsDscRunAsCredential = $SqlAdministratorCredential
        }

        WriteStatus SQLAO1 {
            DependsOn = '[SqlAlwaysOnService]EnableHADR', '[SqlWaitForAG]SQLConfigureAG-WaitAG'
            Status    = "Waiting for $node1 to complete"
        }

        WaitForAll AG {
            ResourceName     = '[SqlAGListener]AvailabilityGroupListener'
            NodeName         = $node1
            RetryIntervalSec = 2
            RetryCount       = 450
            Dependson        = '[WriteStatus]SQLAO1'
        }

        WriteStatus SQLAO2 {
            DependsOn = '[WaitForAll]AG'
            Status    = "Adding replica to the Availability Group"
        }

        # Add the availability group replica to the availability group
        $nodename = (($AllNodes | Where-Object { $_.Role -eq 'ClusterNode2' }).NodeName) + '\' + ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).InstanceName
        if (($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).InstanceName -eq "MSSQLSERVER") {
            $nodename = (($AllNodes | Where-Object { $_.Role -eq 'ClusterNode2' }).NodeName)
        }
        SqlAGReplica 'AddReplica' {
            Ensure                        = 'Present'
            Name                          = $nodename
            AvailabilityGroupName         = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).ClusterNameAoG
            ServerName                    = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode2' }).NodeName
            InstanceName                  = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).InstanceName
            AvailabilityMode              = 'SynchronousCommit'
            BackupPriority                = 50
            ConnectionModeInPrimaryRole   = 'AllowAllConnections'
            ConnectionModeInSecondaryRole = 'AllowAllConnections'
            FailoverMode                  = 'Manual'
            PrimaryReplicaServerName      = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode2' }).PrimaryReplicaServerName
            PrimaryReplicaInstanceName    = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).InstanceName
            ProcessOnlyOnActiveNode       = $true
            DependsOn                     = '[SqlAlwaysOnService]EnableHADR', '[SqlWaitForAG]SQLConfigureAG-WaitAG'
            PsDscRunAsCredential          = $SqlAdministratorCredential
        }
        $nextDepend = '[SqlAGReplica]AddReplica'
        if ($Node.DBName) {

            WaitForAll RecoveryModel {
                ResourceName     = '[SqlDatabase]SetRecoveryModel'
                NodeName         = $node1
                RetryIntervalSec = 2
                RetryCount       = 450
                Dependson        = $nextDepend
            }
            WaitForAll AddAGDatabaseMemberships {
                ResourceName     = '[SqlAGDatabase]AddAGDatabaseMemberships'
                NodeName         = $node1
                RetryIntervalSec = 2
                RetryCount       = 450
                Dependson        = '[WaitForAll]RecoveryModel'
            }
            $nextDepend = '[WaitForAll]AddAGDatabaseMemberships'
            #SqlAGDatabase 'AddAGDatabaseMemberships' {
            #    AvailabilityGroupName   = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).ClusterNameAoG
            #    BackupPath              = $Node.BackupShare
            #    DatabaseName            = $Node.DBName
            #    InstanceName            = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).InstanceName
            #    ServerName              = $node1
            #    Ensure                  = 'Present'
            #    ProcessOnlyOnActiveNode = $true
            #    MatchDatabaseOwner      = $true
            #    PsDscRunAsCredential    = $SqlAdministratorCredential
            #    DependsOn = '[WaitForAll]RecoveryModel'
            #}
            #$nextDepend = '[SqlAGDatabase]AddAGDatabaseMemberships'
        }
        WriteStatus Complete {
            DependsOn = $nextDepend
            Status    = "Complete!"
        }
    }
}