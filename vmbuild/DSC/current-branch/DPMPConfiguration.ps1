configuration DPMPConfiguration
{
   param
   (
        [Parameter(Mandatory)]
        [String]$DomainName,
        [Parameter(Mandatory)]
        [String]$DCName,
        [Parameter(Mandatory)]
        [String]$DPMPName,
        [Parameter(Mandatory)]
        [String]$CSName,
        [Parameter(Mandatory)]
        [String]$PSName,
        [Parameter(Mandatory)]
        [System.Array]$ClientName,
        [Parameter(Mandatory)]
        [String]$Configuration,
        [Parameter(Mandatory)]
        [String]$DNSIPAddress,
        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$Admincreds
    )

    Import-DscResource -ModuleName 'TemplateHelpDSC'
    Import-DscResource -ModuleName 'PSDesiredStateConfiguration', 'NetworkingDsc', 'ComputerManagementDsc'

    $LogFolder = "TempLog"
    $LogPath = "c:\$LogFolder"
    $DName = $DomainName.Split(".")[0]
    $DCComputerAccount = "$DName\$DCName$"
    $PSComputerAccount = "$DName\$PSName$"

    [System.Management.Automation.PSCredential]$DomainCreds = New-Object System.Management.Automation.PSCredential ("${DomainName}\$($Admincreds.UserName)", $Admincreds.Password)
    $PrimarySiteName = $PSName.split(".")[0] + "$"

    Node localhost
    {
        LocalConfigurationManager
        {
            ConfigurationMode = 'ApplyOnly'
            RebootNodeIfNeeded = $true
        }

        WriteStatus Rename
        {
            Status = "Renaming the computer to $DPMPName"
        }

        Computer NewName
        {            
            Name          = $DPMPName
        }

        SetCustomPagingFile PagingSettings
        {
            DependsOn = "[Computer]NewName"
            Drive       = 'C:'
            InitialSize = '8192'
            MaximumSize = '8192'
        }

        WriteStatus InstallFeature
        {
            DependsOn = "[SetCustomPagingFile]PagingSettings"
            Status = "Installing required windows features"
        }

        InstallFeatureForSCCM InstallFeature
        {
            Name = "DPMP"
            Role = "Distribution Point","Management Point"
            DependsOn = "[SetCustomPagingFile]PagingSettings"
        }

        WriteStatus WaitDomain
        {
            DependsOn = "[InstallFeatureForSCCM]InstallFeature"
            Status = "Waiting for domain to be ready to obtain an IP"
        }

        WaitForDomainReady WaitForDomain
        {
            
            DependsOn = "[InstallFeatureForSCCM]InstallFeature"
            Ensure      = "Present"
            DomainName  = $DomainName
            DCName      = $DCName            
        }

        WriteStatus DomainJoin
        {
            DependsOn = "[WaitForDomainReady]WaitForDomain"
            Status = "Joining computer to the domain"
        }

        JoinDomain JoinDomain
        {
            DomainName = $DomainName
            Credential = $DomainCreds
            DependsOn = "[WaitForDomainReady]WaitForDomain"
        }

        WriteStatus OpenPorts
        {
            DependsOn = "[JoinDomain]JoinDomain"
            Status = "Open required firewall ports"
        }

        OpenFirewallPortForSCCM OpenFirewallPortForSCCM
        {
            Name = "DPMP"
            Role = "Distribution Point","Management Point"
            DependsOn = "[JoinDomain]JoinDomain"
        }

        WriteStatus WaitPrimaryJoinDomain
        {
            DependsOn = "[OpenFirewallPortForSCCM]OpenFirewallPortForSCCM"
            Status = "Waiting for Primary Site to join domain, before adding it to Local Administrators group"
        }

        WaitForConfigurationFile WaitForPSJoinDomain
        {
            Role = "DC"
            MachineName = $DCName
            LogFolder = $LogFolder
            ReadNode = "PSJoinDomain"
            Ensure = "Present"
            DependsOn = "[OpenFirewallPortForSCCM]OpenFirewallPortForSCCM"
        }

        File ShareFolder
        {            
            DestinationPath = $LogPath     
            Type = 'Directory'            
            Ensure = 'Present'
            DependsOn = "[WaitForConfigurationFile]WaitForPSJoinDomain"
        }        

        FileReadAccessShare DomainSMBShare
        {
            Name = $LogFolder
            Path = $LogPath
            Account = $DCComputerAccount,$PSComputerAccount
            DependsOn = "[File]ShareFolder"
        }

        AddUserToLocalAdminGroup AddADUserToLocalAdminGroup {
            Name = $($Admincreds.UserName)
            DomainName = $DomainName
            DependsOn = "[FileReadAccessShare]DomainSMBShare"
        }

        AddUserToLocalAdminGroup AddADComputerToLocalAdminGroup {
            Name = "$PrimarySiteName"
            DomainName = $DomainName
            DependsOn = "[FileReadAccessShare]DomainSMBShare"
        }

        WriteConfigurationFile WriteDPMPFinished
        {
            Role = "DPMP"
            LogPath = $LogPath
            WriteNode = "DPMPFinished"
            Status = "Passed"
            Ensure = "Present"
            DependsOn = "[AddUserToLocalAdminGroup]AddADUserToLocalAdminGroup","[AddUserToLocalAdminGroup]AddADComputerToLocalAdminGroup"
        }

        WriteStatus Complete
        {
            DependsOn = "[AddUserToLocalAdminGroup]AddADUserToLocalAdminGroup","[AddUserToLocalAdminGroup]AddADComputerToLocalAdminGroup"
            Status = "Complete!"
        }
    }
}