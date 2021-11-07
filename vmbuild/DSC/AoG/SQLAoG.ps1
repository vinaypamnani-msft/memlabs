Configuration SetupSQLAoG
{
    param
    (
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCredential]
        $SqlAdministratorCredential
    )

    Import-DscResource -ModuleName 'SqlServerDsc'
    Import-DscResource -ModuleName 'PSDesiredStateConfiguration'

     Node $AllNodes.Where{$_.Role -eq 'ClusterNode1' }.NodeName
    {
        #Change SQL Service Account
        SqlServiceAccount 'SetServiceAccountSQL_User'
        {
            ServerName     = $Node.NodeName
            InstanceName   = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).InstanceName
            ServiceType    = 'DatabaseEngine'
            ServiceAccount = $SqlAdministratorCredential
            RestartService = $true
            PsDscRunAsCredential = $SqlAdministratorCredential
        }

        #Change SQL Service Account
        SqlServiceAccount 'SetServiceAccountAgent_User'
        {
            ServerName     = $Node.NodeName
            InstanceName   = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).InstanceName
            ServiceType    = 'SQLServerAgent'
            ServiceAccount = $SqlAdministratorCredential
            RestartService = $true
            PsDscRunAsCredential = $SqlAdministratorCredential
        }
 
        SqlLogin 'Add_WindowsUser'
        {
            Ensure               = 'Present'
            Name                 = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).SQLAgentUser
            LoginType            = 'WindowsUser'
            ServerName           = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).NodeName
            InstanceName         = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).InstanceName
            PsDscRunAsCredential = $SqlAdministratorCredential
        }


        SqlRole 'Add_ServerRole'
        {
            Ensure               = 'Present'
            ServerRoleName       = 'SysAdmin'
            ServerName           = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).NodeName
            InstanceName         = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).InstanceName
            MembersToInclude     = (($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).SQLAgentUser), 'BUILTIN\Administrators'
            PsDscRunAsCredential = $SqlAdministratorCredential
            DependsOn = '[SqlLogin]Add_WindowsUser'
        }

        Service 'ChangeStartupAgent'
        {
            Name = 'SQLAgent$' + ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).InstanceName
            StartupType = "Automatic"
            State       = "Running"
            DependsOn   = '[SqlServiceAccount]SetServiceAccountAgent_User', '[SqlRole]Add_ServerRole'
            PsDscRunAsCredential = $SqlAdministratorCredential
        }

        # Adding the required service account to allow the cluster to log into SQL
        SqlLogin 'AddNTServiceClusSvc'
        {
            Ensure               = 'Present'
            Name                 = 'NT SERVICE\ClusSvc'
            LoginType            = 'WindowsUser'
            ServerName           = $Node.NodeName
            InstanceName         = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).InstanceName

            PsDscRunAsCredential = $SqlAdministratorCredential
        }

        # Add the required permissions to the cluster service login
        SqlPermission 'AddNTServiceClusSvcPermissions'
        {
            DependsOn            = '[SqlLogin]AddNTServiceClusSvc', '[Service]ChangeStartupAgent'
            Ensure               = 'Present'
            ServerName           = $Node.NodeName
            InstanceName         = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).InstanceName
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
            InstanceName         = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).InstanceName

            PsDscRunAsCredential = $SqlAdministratorCredential
        }

        # Ensure the HADR option is enabled for the instance
        SqlAlwaysOnService 'EnableHADR'
        {
            Ensure               = 'Present'
            InstanceName         = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).InstanceName
            ServerName           = $Node.NodeName

            PsDscRunAsCredential = $SqlAdministratorCredential
        }

        # Create the availability group on the instance tagged as the primary replica
        SqlAG 'CMCASAG'
        {
            Ensure                        = 'Present'
            Name                          = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).ClusterName
            InstanceName                  = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).InstanceName
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
            InstanceName         = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).InstanceName
            AvailabilityGroup    = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).ClusterName
            DHCP                 =  $true
            Name                 = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).ClusterName
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
            InstanceName   = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).InstanceName
            ServiceType    = 'DatabaseEngine'
            ServiceAccount = $SqlAdministratorCredential
            RestartService = $true
            PsDscRunAsCredential = $SqlAdministratorCredential
        }

        #Change SQL Service Account
        SqlServiceAccount 'SetServiceAccountAgent_User'
        {
            ServerName     = $Node.NodeName
            InstanceName   = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).InstanceName
            ServiceType    = 'SQLServerAgent'
            ServiceAccount = $SqlAdministratorCredential
            RestartService = $true
            PsDscRunAsCredential = $SqlAdministratorCredential
        }

        SqlLogin 'Add_WindowsUser'
        {
            Ensure               = 'Present'
            Name                 = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).SQLAgentUser
            LoginType            = 'WindowsUser'
            ServerName           = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode2' }).NodeName
            InstanceName         = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).InstanceName
            PsDscRunAsCredential = $SqlAdministratorCredential
        }


        SqlRole 'Add_ServerRole'
        {
            Ensure               = 'Present'
            ServerRoleName       = 'SysAdmin'
            ServerName           = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode2' }).NodeName
            InstanceName         = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).InstanceName
            MembersToInclude     = (($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).SQLAgentUser), 'BUILTIN\Administrators'
            PsDscRunAsCredential = $SqlAdministratorCredential
            DependsOn = '[SqlLogin]Add_WindowsUser'
        }

        Service 'ChangeStartupAgent'
        {
            Name = 'SQLAgent$' + ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).InstanceName
            StartupType = "Automatic"
            State       = "Running"
            DependsOn   = '[SqlServiceAccount]SetServiceAccountAgent_User', '[SqlRole]Add_ServerRole'
            PsDscRunAsCredential = $SqlAdministratorCredential
        }

        # Adding the required service account to allow the cluster to log into SQL
        SqlLogin 'AddNTServiceClusSvc'
        {
            Ensure               = 'Present'
            Name                 = 'NT SERVICE\ClusSvc'
            LoginType            = 'WindowsUser'
            ServerName           = $Node.NodeName
            InstanceName         = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).InstanceName

            PsDscRunAsCredential = $SqlAdministratorCredential
        }

        # Add the required permissions to the cluster service login
        SqlPermission 'AddNTServiceClusSvcPermissions'
        {
            DependsOn            = '[SqlLogin]AddNTServiceClusSvc', '[Service]ChangeStartupAgent'
            Ensure               = 'Present'
            ServerName           = $Node.NodeName
            InstanceName         = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).InstanceName
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
            InstanceName         = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).InstanceName

            PsDscRunAsCredential = $SqlAdministratorCredential
        }

        SqlAlwaysOnService EnableHADR
        {
            Ensure               = 'Present'
            InstanceName         = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).InstanceName
            ServerName           = $Node.NodeName

            PsDscRunAsCredential = $SqlAdministratorCredential
        }

        SqlWaitForAG 'SQLConfigureAG-WaitAG'
        {
            Name                 = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).ClusterName
            RetryIntervalSec     = 60
            RetryCount           = 3
            ServerName           = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).NodeName
            InstanceName         = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).InstanceName

            PsDscRunAsCredential = $SqlAdministratorCredential
        }

        # Add the availability group replica to the availability group
        SqlAGReplica 'AddReplica'
        {
            
            Ensure                     = 'Present'
            Name                       = (($AllNodes | Where-Object { $_.Role -eq 'ClusterNode2' }).NodeName) + '\' + ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).InstanceName
            AvailabilityGroupName      = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).ClusterName
            ServerName                 = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode2' }).NodeName
            InstanceName               = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).InstanceName
            AvailabilityMode              = 'SynchronousCommit'
            BackupPriority                = 50
            ConnectionModeInPrimaryRole   = 'AllowAllConnections'
            ConnectionModeInSecondaryRole = 'AllowAllConnections'
            FailoverMode                  = 'Manual'
            PrimaryReplicaServerName   = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode2' }).PrimaryReplicaServerName
            PrimaryReplicaInstanceName = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' }).InstanceName
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
            Role                     = 'ClusterNode1'
            InstanceName             = 'CAS'
            ClusterName              = 'CASAlwaysOn'
            SQLAgentUser             = 'contosomd\SQLAgentCAS'
        },

        # Node02 - Second cluster node
        @{
            # Replace with the name of the actual target node.
            NodeName = 'SCCM-CASClust2'

            # This is used in the configuration to know which resource to compile.
            Role     = 'ClusterNode2'
            PrimaryReplicaServerName = 'SCCM-CASClust1.contosomd.com'
        },
        @{
            NodeName                     = "*"
            PSDscAllowDomainUser         = $true
            PSDscAllowPlainTextPassword  = $true
        }
    )
}

SetupSQLAoG -ConfigurationData $Configuration -OutputPath C:\temp\SQLAoG