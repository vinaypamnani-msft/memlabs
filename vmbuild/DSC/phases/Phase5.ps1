Configuration Phase5
{
    param
    (
        [Parameter(Mandatory)]
        [string]$DeployConfigPath,
        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$Admincreds
    )

    Import-DscResource -ModuleName 'PSDesiredStateConfiguration', 'TemplateHelpDSC', 'ActiveDirectoryDsc', 'ComputerManagementDsc', 'xFailOverCluster', 'AccessControlDsc', 'SqlServerDsc'

    # Read config
    $deployConfig = Get-Content -Path $DeployConfigPath | ConvertFrom-Json
    $DomainName = $deployConfig.parameters.domainName
    $netbiosName = $DomainName.Split(".")[0]
    $DomainAdminName = $deployConfig.vmOptions.adminName

    # Log share
    $LogFolder = "DSC"
    $LogPath = "c:\staging\$LogFolder"

    # Domain Creds
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

            WriteStatus "WaitForDC$($primaryVM.vmName)" {
                Status    = "Waiting for DC to Complete"
                DependsOn = $nextDepend
            }

            WaitForAny "DCComplete$($primaryVM.vmName)" {
                ResourceName     = "[ADGroup]SQLAOGroup$($primaryVM.vmName)"
                NodeName         = ($AllNodes | Where-Object { $_.Role -eq 'DC' }).NodeName
                RetryIntervalSec = 5
                RetryCount       = 450
                Dependson        = $nextDepend
                PsDscRunAsCredential = $Admincreds
            }
            $nextDepend = "[WaitForAny]DCComplete$($primaryVM.vmName)"

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
                Dependson         = "[File]ClusterWitness$i"
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
                Dependson         = "[File]ClusterBackup$i"
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
            Dependson = $WaitDepend
            Status    = "Complete!"
        }

    }

    Node $AllNodes.Where{ $_.Role -eq 'ClusterNode1' }.NodeName
    {
        $thisVM = $deployConfig.VirtualMachines | where-object { $_.vmName -eq $node.NodeName }
        $node2 = ($deployConfig.VirtualMachines | Where-Object { $_.vmName -eq $thisVM.OtherNode }).vmName

        #$node2 = ($AllNodes | Where-Object { $_.Role -eq 'ClusterNode2' }).NodeName

        WriteStatus WindowsFeature {
            Status = "Adding Windows Features"
        }

        WindowsFeatureSet WindowsFeatureSet
        {
            Name                 = @('RSAT-AD-PowerShell', 'Failover-clustering', 'RSAT-Clustering-PowerShell', 'RSAT-Clustering-CmdInterface', 'RSAT-Clustering-Mgmt' )
            Ensure               = 'Present'
            IncludeAllSubFeature = $true
        }

        ModuleAdd SQLServerModule {
            Key             = 'Always'
            CheckModuleName = 'SqlServer'
        }

        $nextDepend = "[WindowsFeatureSet]WindowsFeatureSet", "[ModuleAdd]SQLServerModule"


        WriteStatus CreateCluster {
            DependsOn = $nextDepend
            Status    = "Creating Cluster $($thisVM.ClusterName) on $($thisVM.thisParams.SQLAO.ClusterIPAddress)"
        }

        xCluster CreateCluster {
            Name                          = $thisVM.ClusterName
            StaticIPAddress               = $thisVM.thisParams.SQLAO.ClusterIPAddress
            # This user must have the permission to create the CNO (Cluster Name Object) in Active Directory, unless it is prestaged.
            DomainAdministratorCredential = $Admincreds
            DependsOn                     = $nextDepend
        }
        $nextDepend = '[xCluster]CreateCluster'

        WriteStatus JoinCluster {
            DependsOn = $nextDepend
            Status    = "Waiting on $node2 To Join Cluster"
        }

        WaitForAny CreateCluster {
            NodeName             = $node2
            ResourceName         = "[xCluster]JoinSecondNodeToCluster"
            RetryIntervalSec     = 120
            RetryCount           = 30
            PsDscRunAsCredential = $Admincreds
            DependsOn            = $nextDepend
        }
        $nextDepend = '[WaitForAny]CreateCluster'

        WriteStatus 'ChangeNetwork-10' {
            DependsOn = $nextDepend
            Status    = "Adding '10.250.250.0' to Cluster"
        }

        xClusterNetwork 'ChangeNetwork-10' {
            Address              = '10.250.250.0'
            AddressMask          = '255.255.255.0'
            Name                 = 'Cluster Network'
            Role                 = '3'
            DependsOn            = $nextDepend
            PsDscRunAsCredential = $Admincreds
        }
        $nextDepend = '[xClusterNetwork]ChangeNetwork-10'

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
            ResourceName         = '[xClusterQuorum]ClusterWitness'
            RetryIntervalSec     = 10
            RetryCount           = 360
            PsDscRunAsCredential = $Admincreds
            DependsOn            = '[xCluster]CreateCluster'
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

        #WriteStatus WaitForDC {
        #    DependsOn = $nextDepend
        #    Status    = "Waiting for DC $(($AllNodes | Where-Object { $_.Role -eq 'DC' }).NodeName) to Complete"
        #}

        #WaitForAny DCComplete {
        #    ResourceName     = '[WriteStatus]Complete'
        #    NodeName         = ($AllNodes | Where-Object { $_.Role -eq 'DC' }).NodeName
        #    RetryIntervalSec = 5
        #    RetryCount       = 450
        #    Dependson        = $nextDepend
        #}
        #$nextDepend = '[WaitForAny]DCComplete'


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
            Ensure       = 'Present'
            ServerName   = $Node.NodeName
            InstanceName = $thisVM.sqlInstanceName
            Principal    = 'NT SERVICE\ClusSvc'
            Permission   = 'AlterAnyAvailabilityGroup', 'ViewServerState'
            #PsDscRunAsCredential = $Admincreds
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

        WriteStatus 'ChangeNetwork-192' {
            DependsOn = $nextDepend
            Status    = "Adding $($thisVM.thisParams.vmNetwork) to Cluster"
        }

        xClusterNetwork 'ChangeNetwork-192' {
            Address              = $thisVM.thisParams.vmNetwork
            AddressMask          = '255.255.255.0'
            Name                 = 'Domain Network'
            Role                 = '0'
            DependsOn            = $nextDepend
            PsDscRunAsCredential = $Admincreds
        }
        $nextDepend = '[xClusterNetwork]ChangeNetwork-192'

        WriteStatus SQLAG {
            DependsOn = $nextDepend
            Status    = "Creating Availability Group $($thisVM.thisParams.SQLAO.ClusterNameAoG) on $($Node.NodeName)\$($thisVM.sqlInstanceName)"
        }

        # Create the availability group on the instance tagged as the primary replica
        SqlAG 'CMCASAG' {
            Ensure                        = 'Present'
            Name                          = $thisVM.thisParams.SQLAO.ClusterNameAoG
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
            AvailabilityGroup    = $thisVM.thisParams.SQLAO.ClusterNameAoG
            DHCP                 = $false
            Name                 = $thisVM.thisParams.SQLAO.ClusterNameAoG
            IpAddress            = $thisVM.thisParams.SQLAO.AGIPAddress
            Port                 = $AOSqlPort
            DependsOn            = $nextDepend
            PsDscRunAsCredential = $Admincreds
        }
        $nextDepend = '[SqlAGListener]AvailabilityGroupListener'

        WriteStatus ClusterRemoveUnwantedIPs {
            DependsOn = $nextDepend
            Status    = "Removing DHCP IPs from Cluster"
        }

        ClusterRemoveUnwantedIPs ClusterRemoveUnwantedIPs {
            ClusterName          = $thisVM.ClusterName
            PsDscRunAsCredential = $Admincreds
            DependsOn            = $nextDepend
        }
        $nextDepend = '[ClusterRemoveUnwantedIPs]ClusterRemoveUnwantedIPs'


        $lspn1 = "MSSQLSvc/" + $thisVM.thisParams.SQLAO.ClusterNameAoG
        $lspn2 = "MSSQLSvc/" + $thisVM.thisParams.SQLAO.ClusterNameAoGFQDN
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
            Dependson            = $nextDepend
            PsDscRunAsCredential = $Admincreds
        }

        ADServicePrincipalName 'lspn2' {
            Ensure               = 'Present'
            ServicePrincipalName = $lspn2
            Account              = $account
            Dependson            = $nextDepend
            PsDscRunAsCredential = $Admincreds
        }

        ADServicePrincipalName 'lspn3' {
            Ensure               = 'Present'
            ServicePrincipalName = $lspn3
            Account              = $account
            Dependson            = $nextDepend
            PsDscRunAsCredential = $Admincreds
        }

        ADServicePrincipalName 'lspn4' {
            Ensure               = 'Present'
            ServicePrincipalName = $lspn4
            Account              = $account
            Dependson            = $nextDepend
            PsDscRunAsCredential = $Admincreds
        }

        $nextDepend = '[ADServicePrincipalName]lspn1', '[ADServicePrincipalName]lspn2', '[ADServicePrincipalName]lspn3', '[ADServicePrincipalName]lspn4'

        WriteStatus AgListen {
            DependsOn = $nextDepend
            Status    = "Waiting on $node2 to Join the Sql Availability Group Listener"
        }

        WaitForAll AddReplica {
            ResourceName     = '[SqlAGReplica]AddReplica'
            NodeName         = $node2
            RetryIntervalSec = 4
            RetryCount       = 900
            Dependson        = $nextDepend
            PsDscRunAsCredential = $Admincreds
        }

        $dbName = "TESTDB"

        $nextDepend = '[WaitForAll]AddReplica'
        if ($dbName) {

            WriteStatus SetRecoveryModel {
                DependsOn = $nextDepend
                Status    = "Creaing $dbName and setting to Full Recovery Model"
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
                AvailabilityGroupName   = $thisVM.thisParams.SQLAO.ClusterNameAoG
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
            ServerName       = $thisvm.VmName
            InstanceName     = $thisVM.sqlInstanceName
            #Credential       = $Admincreds
            SetFilePath      = $AgentJobSet
            TestFilePath     = $AgentJobTest
            GetFilePath      = $AgentJobGet
            DisableVariables = $true
            DependsOn        = $nextDepend
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

        WriteStatus WindowsFeature {
            Status = "Adding Windows Features"
        }

        WindowsFeatureSet WindowsFeatureSet
        {
            Name                 = @('RSAT-AD-PowerShell', 'Failover-clustering', 'RSAT-Clustering-PowerShell', 'RSAT-Clustering-CmdInterface', 'RSAT-Clustering-Mgmt' )
            Ensure               = 'Present'
            IncludeAllSubFeature = $true
        }

        ModuleAdd SQLServerModule {
            Key             = 'Always'
            CheckModuleName = 'SqlServer'
        }

        $nextDepend = "[WindowsFeatureSet]WindowsFeatureSet", "[ModuleAdd]SQLServerModule"

        WriteStatus WaitCluster {
            Status    = "Waiting for Cluster '$($Node1VM.ClusterName)' to become active"
            DependsOn = $nextDepend
        }

        xWaitForCluster WaitForCluster {
            Name                 = $Node1VM.ClusterName
            RetryIntervalSec     = 180
            RetryCount           = 20
            DependsOn            = $nextDepend
            PsDscRunAsCredential = $Admincreds
        }
        $nextDepend = '[xWaitForCluster]WaitForCluster'


        WriteStatus JoinCluster {
            Status    = "Joining Windows Cluster '$($Node1VM.ClusterName)' on '$node1'"
            DependsOn = $nextDepend
        }

        xCluster JoinSecondNodeToCluster {
            Name                 = $Node1VM.ClusterName
            StaticIPAddress      = $Node1VM.thisParams.SQLAO.ClusterIPAddress
            PsDscRunAsCredential = $Admincreds
            DependsOn            = $nextDepend
        }
        $nextDepend = '[xCluster]JoinSecondNodeToCluster'



        #WaitForAny WaitForClusteringNetworking {
        #    NodeName             = $node1
        #    ResourceName         = '[xClusterNetwork]ChangeNetwork-10'
        #    RetryIntervalSec     = 10
        #    RetryCount           = 90
        #    PsDscRunAsCredential = $Admincreds
        #    DependsOn = $nextDepend
        #}
        #$nextDepend = '[WaitForAny]WaitForClusteringNetworking'


        WriteStatus "ChangeNetwork-10" {
            Status    = "Setting Cluster Network 10.250.250.0 to Type 3"
            DependsOn = $nextDepend
        }

        xClusterNetwork 'ChangeNetwork-10' {
            Address              = '10.250.250.0'
            AddressMask          = '255.255.255.0'
            Name                 = 'Cluster Network'
            Role                 = '3'
            DependsOn            = $nextDepend
            PsDscRunAsCredential = $Admincreds
        }
        $nextDepend = '[xClusterNetwork]ChangeNetwork-10'



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


        xClusterQuorum 'ClusterWitness' {
            IsSingleInstance     = 'Yes'
            Type                 = 'NodeAndFileShareMajority'
            Resource             = $node1VM.thisParams.SQLAO.WitnessShareFQ
            DependsOn            = '[WaitForAny]FileShareComplete'
            PsDscRunAsCredential = $Admincreds
        }
        $nextDepend = '[xClusterQuorum]ClusterWitness'

        WriteStatus WaitForDC {
            Status    = "Waiting for DC to Complete"
            DependsOn = $nextDepend
        }

        WaitForAny DCComplete {
            ResourceName     = "[ADGroup]SQLAOGroup$node1"
            NodeName         = ($AllNodes | Where-Object { $_.Role -eq 'DC' }).NodeName
            RetryIntervalSec = 5
            RetryCount       = 900
            Dependson        = $nextDepend
            PsDscRunAsCredential = $Admincreds
        }
        $nextDepend = "[WaitForAny]DCComplete"

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
            Dependson            = $nextDepend
            PsDscRunAsCredential = $Admincreds
        }

        SqlLogin 'Add_WindowsUser' {
            Ensure               = 'Present'
            Name                 = $node1vm.thisParams.SQLAO.SqlServiceAccountFQ
            LoginType            = 'WindowsUser'
            ServerName           = $node.NodeName
            InstanceName         = $node1vm.sqlInstanceName
            Dependson            = $nextDepend
            PsDscRunAsCredential = $Admincreds
        }

        SqlLogin 'AddNTServiceClusSvc' {
            Ensure               = 'Present'
            Name                 = 'NT SERVICE\ClusSvc'
            LoginType            = 'WindowsUser'
            ServerName           = $Node.NodeName
            InstanceName         = $node1vm.sqlInstanceName
            Dependson            = $nextDepend
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
            Ensure               = 'Present'
            ServerName           = $Node.NodeName
            InstanceName         = $node1vm.sqlInstanceName
            Principal            = 'NT SERVICE\ClusSvc'
            Permission           = 'AlterAnyAvailabilityGroup', 'ViewServerState'
            PsDscRunAsCredential = $Admincreds
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
            Dependson            = '[SqlEndpoint]HADREndpoint'
        }

        WriteStatus SQLAOWait {
            Dependson = '[SqlAlwaysOnService]EnableHADR'
            Status    = "Waiting for '$node1' to create the Availability Group"
        }

        SqlWaitForAG 'SQLConfigureAG-WaitAG' {
            Name                 = $node1VM.thisParams.SQLAO.ClusterNameAoG
            RetryIntervalSec     = 5
            RetryCount           = 450
            ServerName           = $node1
            InstanceName         = $node1vm.sqlInstanceName
            Dependson            = '[SqlAlwaysOnService]EnableHADR'
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
            Dependson        = $nextDepend
            PsDscRunAsCredential = $Admincreds
        }
        $nextDepend = '[WaitForAll]AG'

        WriteStatus "ChangeNetwork-192" {
            Status    = "Setting Domain Network $($Node1VM.thisParams.vmNetwork) to Type 0"
            DependsOn = $nextDepend
        }

        xClusterNetwork 'ChangeNetwork-192' {
            Address              = $Node1VM.thisParams.vmNetwork
            AddressMask          = '255.255.255.0'
            Name                 = 'Domain Network'
            Role                 = '0'
            DependsOn            = $nextDepend
            PsDscRunAsCredential = $Admincreds
        }
        $nextDepend = '[xClusterNetwork]ChangeNetwork-192'

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
            AvailabilityGroupName         = $node1VM.thisParams.SQLAO.ClusterNameAoG
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
                Dependson        = $nextDepend
                PsDscRunAsCredential = $Admincreds
            }

            WaitForAll AddAGDatabaseMemberships {
                ResourceName     = '[SqlAGDatabase]AddAGDatabaseMemberships'
                NodeName         = $node1
                RetryIntervalSec = 5
                RetryCount       = 450
                Dependson        = '[WaitForAll]RecoveryModel'
                PsDscRunAsCredential = $Admincreds
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
            #    PsDscRunAsCredential    = $Admincreds
            #    DependsOn = '[WaitForAll]RecoveryModel'
            #}
            #$nextDepend = '[SqlAGDatabase]AddAGDatabaseMemberships'
        }
        $AgentJobSet = "C:\staging\DSC\SQLScripts\SQLAO-AgentJob-Set.sql"
        $AgentJobTest = "C:\staging\DSC\SQLScripts\SQLAO-AgentJob-Test.sql"
        $AgentJobGet = "C:\staging\DSC\SQLScripts\SQLAO-AgentJob-Get.sql"


        WriteStatus InstallAgentJob {
            DependsOn = $nextDepend
            Status    = "Installing Log Backup Agent Job"
        }

        SqlScript 'InstallAgentJob' {
            ServerName       = $node.nodename
            InstanceName     = $node1vm.sqlInstanceName
            #Credential       = $Admincreds
            SetFilePath      = $AgentJobSet
            TestFilePath     = $AgentJobTest
            GetFilePath      = $AgentJobGet
            DisableVariables = $true
            DependsOn        = $nextDepend
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

        $adGroupDependancy = @('[WriteStatus]SQLAOGroup')
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

            $adGroupDependancy += "[ADGroup]SQLAOGroup$($pNode.vmName)"
            #ActiveDirectorySPN "SQLAOSPN$i" {
            #    Key              = "SQLAOSPN$i"
            #    UserName         = $pNode.thisParams.SQLAO.SqlServiceAccount
            #    FQDNDomainName   = $DomainName
            #    OULocationUser   = $pNode.thisParams.SQLAO.OULocationUser
            #    OULocationDevice = $pNode.thisParams.SQLAO.OULocationDevice
            #    ClusterDevice    = $pNode.thisParams.SQLAO.ClusterNodes
            #    UserNameCluster  = $pNode.thisParams.SQLAO.SqlServiceAccount
            #    Dependson        = "[ADGroup]SQLAOGroup$i"
            #}
            #$adGroupDependancy += "[ActiveDirectorySPN]SQLAOSPN$i"
        }

        WriteStatus Complete {
            Dependson = $adGroupDependancy
            Status    = "Complete!"
        }

    }


}