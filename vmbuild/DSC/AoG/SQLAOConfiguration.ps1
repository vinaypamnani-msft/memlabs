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

    Node $AllNodes.Where{ $_.Role -eq 'ADSetup' }.NodeName
    {

        WindowsFeature ADDADPS {
            Ensure = 'Present'
            Name   = 'RSAT-AD-PowerShell'
        }

        ADComputer 'ClusterAccount' {
            ComputerName         = ($AllNodes | Where-Object { $_.Role -eq 'ADSetup' }).ComputerName
            EnabledOnCreation    = $false
            Dependson            = '[WindowsFeature]ADDADPS'
            PsDscRunAsCredential = $SqlAdministratorCredential
        }

        ADGroup 'CASCluster' {
            GroupName            = $GroupName
            GroupScope           = $Scope
            Category             = $Category
            Description          = $Description
            Ensure               = 'Present'
            Members              = @($AllNodes | Where-Object { $_.Role -eq 'ADSetup' }).ADmembers
            Dependson            = '[WindowsFeature]ADDADPS', '[ADComputer]ClusterAccount'
            PsDscRunAsCredential = $SqlAdministratorCredential
        }

        ADUser 'SQLServiceAccount' {
            Ensure               = 'Present'
            CannotChangePassword = $true
            PasswordNeverExpires = $true
            UserPrincipalName    = (($AllNodes | Where-Object { $_.Role -eq 'ADSetup' }).SQLServiceAccount) + '@' + ($AllNodes | Where-Object { $_.Role -eq 'ADSetup' }).DomainName
            UserName             = ($AllNodes | Where-Object { $_.Role -eq 'ADSetup' }).SQLServiceAccount
            Password             = $SqlAdministratorCredential
            DomainName           = ($AllNodes | Where-Object { $_.Role -eq 'ADSetup' }).DomainName
            Path                 = ($AllNodes | Where-Object { $_.Role -eq 'ADSetup' }).OUUserPath
            Dependson            = '[ADGroup]CASCluster'
            PsDscRunAsCredential = $SqlAdministratorCredential
        }

        ADUser 'SQLServiceAgent' {
            Ensure               = 'Present'
            CannotChangePassword = $true
            PasswordNeverExpires = $true
            UserPrincipalName    = (($AllNodes | Where-Object { $_.Role -eq 'ADSetup' }).SQLServiceAgent) + '@' + ($AllNodes | Where-Object { $_.Role -eq 'ADSetup' }).DomainName
            UserName             = ($AllNodes | Where-Object { $_.Role -eq 'ADSetup' }).SQLServiceAgent
            Password             = $SqlAdministratorCredential
            DomainName           = ($AllNodes | Where-Object { $_.Role -eq 'ADSetup' }).DomainName
            Path                 = ($AllNodes | Where-Object { $_.Role -eq 'ADSetup' }).OUUserPath
            Dependson            = '[ADUser]SQLServiceAccount'
            PsDscRunAsCredential = $SqlAdministratorCredential
        }

        ActiveDirectorySPN 'SQLServiceAccountSPNSetup' {
            Key                  = 'Always'
            UserName             = ($AllNodes | Where-Object { $_.Role -eq 'ADSetup' }).SQLServiceAccount
            FQDNDomainName       = ($AllNodes | Where-Object { $_.Role -eq 'ADSetup' }).DomainName
            OULocationUser       = ($AllNodes | Where-Object { $_.Role -eq 'ADSetup' }).OUUserPath
            ClusterDevice        = @($AllNodes | Where-Object { $_.Role -eq 'ClusterNode1' -or $_.role -eq 'ClusterNode2' }).NodeName
            UserNameCluster      = ($AllNodes | Where-Object { $_.Role -eq 'ADSetup' }).UserNameCluster
            Dependson            = '[ADUser]SQLServiceAgent'
            PsDscRunAsCredential = $SqlAdministratorCredential
        }

    }

    Node $AllNodes.Where{ $_.Role -eq 'FileServer' }.NodeName
    {
        WaitForAll AD {
            ResourceName     = '[ActiveDirectorySPN]SQLServiceAccountSPNSetup'
            NodeName         = $AllNodes.Where{ $_.Role -eq 'ADSetup' }.NodeName
            RetryIntervalSec = 10
            RetryCount       = 10
        }

        File ClusterWitness {
            Type            = 'Directory'
            DestinationPath = ($AllNodes | Where-Object { $_.Role -eq 'FileServer' }).WitnessPath
            Ensure          = "Present"
        }

        NTFSAccessEntry ClusterWitnessPermissions {
            Path              = ($AllNodes | Where-Object { $_.Role -eq 'FileServer' }).WitnessPath
            AccessControlList = @(
                NTFSAccessControlList {
                    Principal          = ($AllNodes | Where-Object { $_.Role -eq 'FileServer' }).Principal1
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
                    Principal          = ($AllNodes | Where-Object { $_.Role -eq 'FileServer' }).Principal2
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
                    Principal          = ($AllNodes | Where-Object { $_.Role -eq 'FileServer' }).Principal3
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
                    Principal          = ($AllNodes | Where-Object { $_.Role -eq 'FileServer' }).Principal4
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
            Dependson         = '[File]ClusterWitness'
        }

        SmbShare 'CASClusterShare' {
            Name                  = ($AllNodes | Where-Object { $_.Role -eq 'FileServer' }).Name
            Path                  = ($AllNodes | Where-Object { $_.Role -eq 'FileServer' }).Path
            Description           = ($AllNodes | Where-Object { $_.Role -eq 'FileServer' }).Description
            FolderEnumerationMode = 'AccessBased'
            FullAccess            = @($AllNodes | Where-Object { $_.Role -eq 'FileServer' }).FullAccess
            ReadAccess            = @($AllNodes | Where-Object { $_.Role -eq 'FileServer' }).ReadAccess
            DependsOn             = '[NTFSAccessEntry]ClusterWitnessPermissions'
        }
    }

    Node $AllNodes.Where{ $_.Role -eq 'ClusterNode1' }.NodeName
    {
        WaitForAll FS {
            ResourceName     = '[SmbShare]CASClusterShare'
            NodeName         = $AllNodes.Where{ $_.Role -eq 'FileServer' }.NodeName
            RetryIntervalSec = 60
            RetryCount       = 4
        }

        WindowsFeature ADDADPS {
            Ensure = 'Present'
            Name   = 'RSAT-AD-PowerShell'
        }

        ModuleAdd SQLServerModule {
            Key             = 'Always'
            CheckModuleName = $AllNodes.Where{ $_.Role -eq 'ClusterNode1' }.CheckModuleName

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

        xCluster CreateCluster {
            Name                          = $Node.ClusterName
            #StaticIPAddress              = $Node.ClusterIPAddress
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

        ADGroup 'CASCluster' {
            GroupName            = $GroupName
            GroupScope           = $Scope
            Category             = $Category
            Description          = $Description
            Ensure               = 'Present'
            Members              = @($AllNodes | Where-Object { $_.Role -eq 'ADSetup' }).ADmembers
            DependsOn            = '[WindowsFeature]ADDADPS', '[xClusterNetwork]ChangeNetwork-192'
            PsDscRunAsCredential = $SqlAdministratorCredential
        }
    }

    Node $AllNodes.Where{ $_.Role -eq 'ClusterNode2' }.NodeName
    {
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

        xWaitForCluster WaitForCluster {
            Name                 = $Node.ClusterName
            RetryIntervalSec     = 60
            RetryCount           = 6
            DependsOn            = '[WindowsFeature]AddRemoteServerAdministrationToolsClusteringMgmtInterfaceFeature'
            PsDscRunAsCredential = $SqlAdministratorCredential
        }

        WaitForAny WaitForClusteringNetworking {
            NodeName             = $AllNodes.Where{ $_.Role -eq 'ClusterNode1' }.NodeName
            ResourceName         = '[xClusterNetwork]ChangeNetwork-10'
            RetryIntervalSec     = 60
            RetryCount           = 6
            PsDscRunAsCredential = $SqlAdministratorCredential
        }

        xCluster JoinSecondNodeToCluster {
            Name                 = $Node.ClusterName
            #StaticIPAddress               = $Node.ClusterIPAddress
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
    }
}