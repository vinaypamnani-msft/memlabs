Configuration SetupSQLAoG
{
    param
    (
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCredential]
        $SqlAdministratorCredential
    )

    Import-DscResource -ModuleName 'SqlServerDsc'

     Node $AllNodes.Where{$_.Role -eq 'ClusterNode1' }.NodeName
    {
        #Change SQL Service Account
        SqlServiceAccount 'SetServiceAccountSQL_User'
        {
            ServerName     = $Node.NodeName
            InstanceName   = 'CAS'
            ServiceType    = 'DatabaseEngine'
            ServiceAccount = $SqlAdministratorCredential
            RestartService = $true
        }

        #Change SQL Service Account
        SqlServiceAccount 'SetServiceAccountAgent_User'
        {
            ServerName     = $Node.NodeName
            InstanceName   = 'CAS'
            ServiceType    = 'SQLServerAgent'
            ServiceAccount = $SqlAdministratorCredential
            RestartService = $true
        }

        # Adding the required service account to allow the cluster to log into SQL
        SqlLogin 'AddNTServiceClusSvc'
        {
            Ensure               = 'Present'
            Name                 = 'NT SERVICE\ClusSvc'
            LoginType            = 'WindowsUser'
            ServerName           = $Node.NodeName
            InstanceName         = 'CAS'

            PsDscRunAsCredential = $SqlAdministratorCredential
        }

        # Add the required permissions to the cluster service login
        SqlPermission 'AddNTServiceClusSvcPermissions'
        {
            DependsOn            = '[SqlLogin]AddNTServiceClusSvc'
            Ensure               = 'Present'
            ServerName           = $Node.NodeName
            InstanceName         = 'CAS'
            Principal            = 'NT SERVICE\ClusSvc'
            Permission           = 'AlterAnyAvailabilityGroup', 'ViewServerState'

            PsDscRunAsCredential = $SqlAdministratorCredential
        }

        # Create a DatabaseMirroring endpoint
        SqlEndpoint 'HADREndpoint'
        {
            EndPointName         = 'HADR'
            EndpointType         = 'DatabaseMirroring'
            Ensure               = 'Present'
            Port                 = 5022
            ServerName           = $Node.NodeName
            InstanceName         = 'CAS'

            PsDscRunAsCredential = $SqlAdministratorCredential
        }

        # Ensure the HADR option is enabled for the instance
        SqlAlwaysOnService 'EnableHADR'
        {
            Ensure               = 'Present'
            InstanceName         = 'CAS'
            ServerName           = $Node.NodeName

            PsDscRunAsCredential = $SqlAdministratorCredential
        }

        # Create the availability group on the instance tagged as the primary replica
        SqlAG 'CMCASAG'
        {
            Ensure                        = 'Present'
            Name                          = 'CASAlwaysOn'
            InstanceName                  = 'CAS'
            ServerName                    = $Node.NodeName
            AvailabilityMode              = 'SynchronousCommit'
            BackupPriority                = 50
            ConnectionModeInPrimaryRole   = 'AllowAllConnections'
            ConnectionModeInSecondaryRole = 'AllowAllConnections'
            FailoverMode                  = 'Manual'
            HealthCheckTimeout            = 15000

            DependsOn            = '[SqlAlwaysOnService]EnableHADR', '[SqlEndpoint]HADREndpoint', '[SqlPermission]AddNTServiceClusSvcPermissions'

            PsDscRunAsCredential = $SqlAdministratorCredential
        }

        SqlAGListener 'AvailabilityGroupListener'
        {
            Ensure               = 'Present'
            ServerName           = $Node.NodeName
            InstanceName         = 'CAS'
            AvailabilityGroup    = 'CASAlwaysOn'
            DHCP                 =  $true
            Name                 = 'CASAlwaysOn'
            IpAddress            = '10.250.250.1/255.255.255.0'
            Port                 =  1500

            DependsOn            = '[SqlAG]CMCASAG'

            PsDscRunAsCredential = $SqlAdministratorCredential
        }
    }
    Node $AllNodes.Where{$_.Role -eq 'ClusterNode2' }.NodeName
    {
        #Change SQL Service Account
        SqlServiceAccount 'SetServiceAccountSQL_User'
        {
            ServerName     = $Node.NodeName
            InstanceName   = 'CAS'
            ServiceType    = 'DatabaseEngine'
            ServiceAccount = $SqlAdministratorCredential
            RestartService = $true
        }

        #Change SQL Service Account
        SqlServiceAccount 'SetServiceAccountAgent_User'
        {
            ServerName     = $Node.NodeName
            InstanceName   = 'CAS'
            ServiceType    = 'SQLServerAgent'
            ServiceAccount = $SqlAdministratorCredential
            RestartService = $true
        }

        # Adding the required service account to allow the cluster to log into SQL
        SqlLogin 'AddNTServiceClusSvc'
        {
            Ensure               = 'Present'
            Name                 = 'NT SERVICE\ClusSvc'
            LoginType            = 'WindowsUser'
            ServerName           = $Node.NodeName
            InstanceName         = 'CAS'

            PsDscRunAsCredential = $SqlAdministratorCredential
        }

        # Add the required permissions to the cluster service login
        SqlPermission 'AddNTServiceClusSvcPermissions'
        {
            DependsOn            = '[SqlLogin]AddNTServiceClusSvc'
            Ensure               = 'Present'
            ServerName           = $Node.NodeName
            InstanceName         = 'CAS'
            Principal            = 'NT SERVICE\ClusSvc'
            Permission           = 'AlterAnyAvailabilityGroup', 'ViewServerState'

            PsDscRunAsCredential = $SqlAdministratorCredential
        }

        # Create a DatabaseMirroring endpoint
        SqlEndpoint 'HADREndpoint'
        {
            EndPointName         = 'HADR'
            EndpointType         = 'DatabaseMirroring'
            Ensure               = 'Present'
            Port                 = 5022
            ServerName           = $Node.NodeName
            InstanceName         = 'CAS'

            PsDscRunAsCredential = $SqlAdministratorCredential
        }

        SqlAlwaysOnService EnableHADR
        {
            Ensure               = 'Present'
            InstanceName         = 'CAS'
            ServerName           = $Node.NodeName

            PsDscRunAsCredential = $SqlAdministratorCredential
        }

        SqlWaitForAG 'SQLConfigureAG-WaitAG'
        {
            Name                 = 'CASAlwaysOn'
            RetryIntervalSec     = 20
            RetryCount           = 30
            ServerName           = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).NodeName
            InstanceName         = 'CAS'

            PsDscRunAsCredential = $SqlAdministratorCredential
        }

        # Add the availability group replica to the availability group
        SqlAGReplica 'AddReplica'
        {
               
            Ensure                     = 'Present'
            Name                       = "$(($AllNodes | Where-Object { $_.Role -eq 'ClusterNode2' }).NodeName)\CAS"
            AvailabilityGroupName      = 'CASAlwaysOn'
            ServerName                 = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode2' }).NodeName
            InstanceName               = 'CAS'
            AvailabilityMode              = 'SynchronousCommit'
            BackupPriority                = 50
            ConnectionModeInPrimaryRole   = 'AllowAllConnections'
            ConnectionModeInSecondaryRole = 'AllowAllConnections'
            FailoverMode                  = 'Manual'
            PrimaryReplicaServerName   = 'SCCM-CASClust1.contosomd.com'
            PrimaryReplicaInstanceName = 'CAS'
            ProcessOnlyOnActiveNode    = $true

            DependsOn                  = '[SqlAlwaysOnService]EnableHADR', '[SqlWaitForAG]SQLConfigureAG-WaitAG'

            PsDscRunAsCredential       = $SqlAdministratorCredential
        }
    }
}

$Configuration = @{
    AllNodes = @(
        # Node01 - First cluster node.
        @{
            # Replace with the name of the actual target node.
            NodeName = 'SCCM-CASClust1'

            # This is used in the configuration to know which resource to compile.
            Role     = 'ClusterNode1'
        },

        # Node02 - Second cluster node
        @{
            # Replace with the name of the actual target node.
            NodeName = 'SCCM-CASClust2'

            # This is used in the configuration to know which resource to compile.
            Role     = 'ClusterNode2'
        },
        @{
            NodeName                     = "*"
            PSDscAllowDomainUser         = $true
            PSDscAllowPlainTextPassword  = $true
        }
    )
}

SetupSQLAoG -ConfigurationData $Configuration -OutputPath C:\temp\SQLAoG