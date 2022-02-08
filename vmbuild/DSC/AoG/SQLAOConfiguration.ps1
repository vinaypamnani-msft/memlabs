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

        WriteStatus ClusterJoin {
            DependsOn = "[xClusterNetwork]ChangeNetwork-10"
            Status    = "Waiting for '$node2' to join Cluster"
        }

        WaitForAny WaitForClusterJoin {
            NodeName             = $AllNodes.Where{ $_.Role -eq 'ClusterNode2' }.NodeName
            ResourceName         = '[xClusterQuorum]ClusterWitness'
            RetryIntervalSec     = 30
            RetryCount           = 30
            PsDscRunAsCredential = $SqlAdministratorCredential
        }

        WriteStatus SvcAccount {
            DependsOn = '[WaitForAny]WaitForClusterJoin'
            Status    = "Configuring SQL Service Accounts and SQL Logins"
        }
        $spn1 = "MSSQLSvc/" + $Node.PrimaryReplicaServerName
        $spn2 = $spn1 + ":1433"

        ADServicePrincipalName 'spn1' {
            Ensure               = 'Absent'
            ServicePrincipalName = $SPN1
            Account              = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).NodeName + "$"
            Dependson            = '[WaitForAny]WaitForClusterJoin'
            PsDscRunAsCredential = $SqlAdministratorCredential
        }
        ADServicePrincipalName 'spn2' {
            Ensure               = 'Absent'
            ServicePrincipalName = $SPN2
            Account              = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).NodeName + "$"
            Dependson            = '[WaitForAny]WaitForClusterJoin'
            PsDscRunAsCredential = $SqlAdministratorCredential
        }


        #Change SQL Service Account
        SqlServiceAccount 'SetServiceAccountSQL_User' {
            ServerName           = $Node.NodeName
            InstanceName         = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).InstanceName
            ServiceType          = 'DatabaseEngine'
            ServiceAccount       = $SqlAdministratorCredential
            RestartService       = $true
            DependsOn            = '[ADServicePrincipalName]spn2'
            PsDscRunAsCredential = $SqlAdministratorCredential
            Force                = $true
        }

        #Change SQL Service Account
        SqlServiceAccount 'SetServiceAccountAgent_User' {
            ServerName           = $Node.NodeName
            InstanceName         = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).InstanceName
            ServiceType          = 'SQLServerAgent'
            ServiceAccount       = $SqlAdministratorCredential
            RestartService       = $true
            PsDscRunAsCredential = $SqlAdministratorCredential
            DependsOn            = '[SqlServiceAccount]SetServiceAccountSQL_User'
        }

        SqlLogin 'Add_WindowsUser' {
            Ensure               = 'Present'
            Name                 = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).SQLAgentUser
            LoginType            = 'WindowsUser'
            ServerName           = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).NodeName
            InstanceName         = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).InstanceName
            PsDscRunAsCredential = $SqlAdministratorCredential
            DependsOn            = '[SqlServiceAccount]SetServiceAccountAgent_User'
        }


        SqlRole 'Add_ServerRole' {
            Ensure               = 'Present'
            ServerRoleName       = 'SysAdmin'
            ServerName           = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).NodeName
            InstanceName         = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).InstanceName
            MembersToInclude     = (($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).SQLAgentUser), 'BUILTIN\Administrators'
            PsDscRunAsCredential = $SqlAdministratorCredential
            DependsOn            = '[SqlLogin]Add_WindowsUser'
        }

        $agentName = if (($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).InstanceName -eq "MSSQLSERVER") { "SQLSERVERAGENT" } else { 'SQLAgent$' + ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).InstanceName }
        Service 'ChangeStartupAgent' {
            Name                 = $agentName
            StartupType          = "Automatic"
            State                = "Running"
            DependsOn            = '[SqlServiceAccount]SetServiceAccountAgent_User', '[SqlRole]Add_ServerRole'
            PsDscRunAsCredential = $SqlAdministratorCredential
        }

        # Adding the required service account to allow the cluster to log into SQL
        SqlLogin 'AddNTServiceClusSvc' {
            Ensure               = 'Present'
            Name                 = 'NT SERVICE\ClusSvc'
            LoginType            = 'WindowsUser'
            ServerName           = $Node.NodeName
            InstanceName         = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).InstanceName
            PsDscRunAsCredential = $SqlAdministratorCredential
        }

        # Add the required permissions to the cluster service login
        SqlPermission 'AddNTServiceClusSvcPermissions' {
            DependsOn            = '[SqlLogin]AddNTServiceClusSvc', '[Service]ChangeStartupAgent'
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

        WriteStatus Complete {
            DependsOn = '[SqlAGListener]AvailabilityGroupListener'
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
            RetryIntervalSec     = 30
            RetryCount           = 30
            PsDscRunAsCredential = $SqlAdministratorCredential
        }

        WriteStatus JoinCluster {
            Status    = "Joining Windows Cluster '$( $Node.ClusterName)'on '$node1'"
            DependsOn = '[xWaitForCluster]WaitForCluster'
        }

        xCluster JoinSecondNodeToCluster {
            Name                 = $Node.ClusterName
            StaticIPAddress      = $Node.ClusterIPAddress
            PsDscRunAsCredential = $SqlAdministratorCredential
            DependsOn            = '[xWaitForCluster]WaitForCluster', '[WaitForAny]WaitForClusteringNetworking'
        }

        xClusterQuorum 'ClusterWitness' {
            IsSingleInstance     = 'Yes'
            Type                 = 'NodeAndFileShareMajority'
            Resource             = $AllNodes.Where{ $_.Role -eq 'ClusterNode2' }.Resource
            DependsOn            = '[xCluster]JoinSecondNodeToCluster'
            PsDscRunAsCredential = $SqlAdministratorCredential
        }


        $ADComputerName = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode2' }).NodeName + "$"
        $spn3 = "MSSQLSvc/" + $Node.SecondaryReplicaServerName
        $spn4 = $spn3 + ":1433"

        WriteStatus SpnAccount {
            Dependson = '[xClusterQuorum]ClusterWitness'
            Status    = "Removing SQL SPNs ($spn3 $spn4) from $ADComputerName"
        }


        ADServicePrincipalName 'spn3' {
            Ensure               = 'Absent'
            ServicePrincipalName = $spn3
            Account              = $ADComputerName
            Dependson            = '[xClusterQuorum]ClusterWitness'
            PsDscRunAsCredential = $SqlAdministratorCredential
        }
        ADServicePrincipalName 'spn4' {
            Ensure               = 'Absent'
            ServicePrincipalName = $spn4
            Account              = $ADComputerName
            Dependson            = '[xClusterQuorum]ClusterWitness'
            PsDscRunAsCredential = $SqlAdministratorCredential
        }

        WriteStatus SvcAccount {
            Dependson = '[ADServicePrincipalName]spn4'
            Status    = "Configuring SQL Service Accounts and SQL Logins"
        }
        #Change SQL Service Account
        SqlServiceAccount 'SetServiceAccountSQL_User' {
            ServerName           = $Node.NodeName
            InstanceName         = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).InstanceName
            ServiceType          = 'DatabaseEngine'
            ServiceAccount       = $SqlAdministratorCredential
            RestartService       = $true
            Dependson            = '[ADServicePrincipalName]spn4'
            PsDscRunAsCredential = $SqlAdministratorCredential
            Force                = $true
        }

        #Change SQL Service Account
        SqlServiceAccount 'SetServiceAccountAgent_User' {
            ServerName           = $Node.NodeName
            InstanceName         = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).InstanceName
            ServiceType          = 'SQLServerAgent'
            ServiceAccount       = $SqlAdministratorCredential
            RestartService       = $true
            Dependson            = '[SqlServiceAccount]SetServiceAccountSQL_User'
            PsDscRunAsCredential = $SqlAdministratorCredential
        }

        SqlLogin 'Add_WindowsUser' {
            Ensure               = 'Present'
            Name                 = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).SQLAgentUser
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
            MembersToInclude     = (($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).SQLAgentUser), 'BUILTIN\Administrators'
            PsDscRunAsCredential = $SqlAdministratorCredential
            DependsOn            = '[SqlLogin]Add_WindowsUser'
        }

        $agentName = if (($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).InstanceName -eq "MSSQLSERVER") { "SQLSERVERAGENT" } else { 'SQLAgent$' + ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).InstanceName }
        Service 'ChangeStartupAgent' {
            Name                 = $agentName
            StartupType          = "Automatic"
            State                = "Running"
            DependsOn            = '[SqlServiceAccount]SetServiceAccountAgent_User', '[SqlRole]Add_ServerRole'
            PsDscRunAsCredential = $SqlAdministratorCredential
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
            DependsOn            = '[SqlLogin]AddNTServiceClusSvc', '[Service]ChangeStartupAgent'
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
            RetryIntervalSec     = 30
            RetryCount           = 30
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

        WriteStatus Complete {
            DependsOn = '[SqlAGReplica]AddReplica'
            Status    = "Complete!"
        }
    }
}