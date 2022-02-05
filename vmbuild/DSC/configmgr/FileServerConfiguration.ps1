configuration FileServerConfiguration
{
    param
    (
        [Parameter(Mandatory)]
        [string]$ConfigFilePath,
        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$Admincreds
    )

    Set-ExecutionPolicy -ExecutionPolicy Bypass -Force
    Import-DscResource -ModuleName 'TemplateHelpDSC'
    Import-DscResource -ModuleName 'PSDesiredStateConfiguration', 'NetworkingDsc', 'ComputerManagementDsc', 'AccessControlDsc'

    # Read config
    $deployConfig = Get-Content -Path $ConfigFilePath | ConvertFrom-Json
    $ThisMachineName = $deployConfig.thisParams.MachineName
    $ThisVM = $deployConfig.virtualMachines | Where-Object { $_.vmName -eq $ThisMachineName }
    $DomainName = $deployConfig.parameters.domainName
    $DCName = $deployConfig.parameters.DCName
    $DomainAdminName = $deployConfig.vmOptions.adminName
    $waitOnDomainJoin = $deployconfig.thisParams.WaitOnDomainJoin

    # SQL AO
    $SQLAO = $deployConfig.thisParams.SQLAO

    # Log share
    $LogFolder = "DSC"
    $LogPath = "c:\staging\$LogFolder"

    # Domain creds
    [System.Management.Automation.PSCredential]$DomainCreds = New-Object System.Management.Automation.PSCredential ("${DomainName}\$($Admincreds.UserName)", $Admincreds.Password)


    Node localhost
    {
        LocalConfigurationManager {
            ConfigurationMode  = 'ApplyOnly'
            RebootNodeIfNeeded = $true
        }

        WriteStatus Rename {
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

        SetCustomPagingFile PagingSettings {
            DependsOn   = "[InitializeDisks]InitDisks"
            Drive       = 'C:'
            InitialSize = '8192'
            MaximumSize = '8192'
        }

        WriteStatus InstallFeature {
            DependsOn = "[SetCustomPagingFile]PagingSettings"
            Status    = "Installing required windows features"
        }

        InstallFeatureForSCCM InstallFeature {
            Name      = "DummyName"
            Role      = "Distribution Point", "Management Point"
            DependsOn = "[SetCustomPagingFile]PagingSettings"
        }

        WriteStatus WaitDomain {
            DependsOn = "[InstallFeatureForSCCM]InstallFeature"
            Status    = "Waiting for domain to be ready"
        }

        WaitForDomainReady WaitForDomain {
            DependsOn  = "[WriteStatus]WaitDomain"
            Ensure     = "Present"
            DomainName = $DomainName
            DCName     = $DCName
        }

        WriteStatus DomainJoin {
            DependsOn = "[WaitForDomainReady]WaitForDomain"
            Status    = "Joining computer to the domain"
        }

        JoinDomain JoinDomain {
            DomainName = $DomainName
            Credential = $DomainCreds
            DependsOn  = "[WaitForDomainReady]WaitForDomain"
        }

        WriteStatus OpenPorts {
            DependsOn = "[JoinDomain]JoinDomain"
            Status    = "Open required firewall ports"
        }

        AddNtfsPermissions AddNtfsPerms {
            Ensure    = "Present"
            DependsOn = "[JoinDomain]JoinDomain"
        }

        OpenFirewallPortForSCCM OpenFirewall {
            DependsOn = "[AddNtfsPermissions]AddNtfsPerms"
            Name      = "DomainMember"
            Role      = "DomainMember"
        }

        WriteStatus InstallDotNet {
            DependsOn = '[OpenFirewallPortForSCCM]OpenFirewall'
            Status    = "Installing .NET 4.8"
        }

        InstallDotNet4 DotNet {
            DownloadUrl = "https://download.visualstudio.microsoft.com/download/pr/7afca223-55d2-470a-8edc-6a1739ae3252/abd170b4b0ec15ad0222a809b761a036/ndp48-x86-x64-allos-enu.exe"
            FileName    = "ndp48-x86-x64-allos-enu.exe"
            NetVersion  = "528040"
            Ensure      = "Present"
            DependsOn   = "[WriteStatus]InstallDotNet"
        }

        File ShareFolder {
            DestinationPath = $LogPath
            Type            = 'Directory'
            Ensure          = 'Present'
            DependsOn       = '[InstallDotNet4]DotNet'
        }

        FileReadAccessShare DomainSMBShare {
            Name      = $LogFolder
            Path      = $LogPath
            DependsOn = "[File]ShareFolder"
        }

        WriteEvent WriteJoinDomain {
            LogPath   = $LogPath
            WriteNode = "MachineJoinDomain"
            Status    = "Passed"
            Ensure    = "Present"
            DependsOn = "[FileReadAccessShare]DomainSMBShare"
        }

        WriteStatus WaitDomainJoin {
            DependsOn = '[WriteEvent]WriteJoinDomain'
            Status    = "Waiting for $($waitOnDomainJoin -join ',') to join the domain"
        }

        $waitOnDependency = @('[WriteStatus]WaitDomainJoin')
        foreach ($server in $waitOnDomainJoin) {

            VerifyComputerJoinDomain "WaitFor$server" {
                ComputerName = $server
                Ensure       = "Present"
                DependsOn    = "[WriteStatus]WaitDomainJoin"
            }

            $waitOnDependency += "[VerifyComputerJoinDomain]WaitFor$server"
        }

        if ($SQLAO) {

            WriteStatus ClusterShare {
                DependsOn = $waitOnDependency
                Status    = "Configuring Cluster Share"
            }

            File ClusterWitness {
                DestinationPath = $deployConfig.thisParams.SQLAO.WitnessLocalPath
                Type            = 'Directory'
                Ensure          = "Present"
                DependsOn       = '[WriteStatus]ClusterShare'
            }

            NTFSAccessEntry ClusterWitnessPermissions {
                Path              = $deployConfig.thisParams.SQLAO.WitnessLocalPath
                AccessControlList = @(
                    NTFSAccessControlList {
                        Principal          = "$DomainName\$($deployConfig.thisParams.SQLAO.GroupMembers[0])"
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
                        Principal          = "$DomainName\$($deployConfig.thisParams.SQLAO.GroupMembers[1])"
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
                        Principal          = "$DomainName\$($deployConfig.thisParams.SQLAO.GroupMembers[2])"
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
                        Principal          = "$DomainName\$DomainAdminName"
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

            SmbShare ClusterShare {
                Name                  = $deployConfig.thisParams.SQLAO.WitnessShare
                Path                  = $deployConfig.thisParams.SQLAO.WitnessLocalPath
                Description           = $deployConfig.thisParams.SQLAO.WithessShare
                FolderEnumerationMode = 'AccessBased'
                FullAccess            = $deployConfig.thisParams.SQLAO.GroupMembers
                ReadAccess            = "Everyone"
                DependsOn             = '[NTFSAccessEntry]ClusterWitnessPermissions'
            }

            WriteStatus AddLocalAdmin {
                DependsOn = '[SmbShare]ClusterShare'
                Status    = "Adding cm_svc domain account to Local Administrators group"
            }

        }
        else {
            WriteStatus AddLocalAdmin {
                DependsOn = '[WriteEvent]WriteJoinDomain'
                Status    = "Adding cm_svc domain account to Local Administrators group"
            }
        }

        $addUserDependancy = @('[WriteStatus]AddLocalAdmin')
        $i = 0
        foreach ($user in $deployConfig.thisParams.LocalAdminAccounts) {
            $i++
            $NodeName = "AddADUserToLocalAdminGroup$($i)"
            AddUserToLocalAdminGroup "$NodeName" {
                Name       = $user
                DomainName = $DomainName
                DependsOn  = "[WriteStatus]AddLocalAdmin"
            }
            $addUserDependancy += "[AddUserToLocalAdminGroup]$NodeName"
        }

        WriteStatus Complete {
            DependsOn = $addUserDependancy
            Status    = "Complete!"
        }

        WriteEvent ReadyForPrimary {
            LogPath   = $LogPath
            WriteNode = "ReadyForPrimary"
            Status    = "Passed"
            Ensure    = "Present"
            DependsOn = "[WriteStatus]Complete"
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