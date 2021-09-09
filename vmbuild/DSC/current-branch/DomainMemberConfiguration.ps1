configuration DomainMemberConfiguration
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
        [String]$ClientName,
        [Parameter(Mandatory)]
        [String]$Configuration,
        [Parameter(Mandatory)]
        [String]$DNSIPAddress,
        [Parameter(Mandatory)]
        [String]$DefaultGateway,
        [Parameter(Mandatory)]
        [String]$DHCPScopeId,
        [Parameter(Mandatory)]
        [String]$DHCPScopeStart,
        [Parameter(Mandatory)]
        [String]$DHCPScopeEnd,
        [Parameter(Mandatory)]
        [bool]$InstallConfigMgr=$true,
        [Parameter(Mandatory)]
        [bool]$UpdateToLatest=$true,
        [Parameter(Mandatory)]
        [bool]$PushClients=$true,
        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$Admincreds
    )

    Set-ExecutionPolicy -ExecutionPolicy Bypass -Force
    Import-DscResource -ModuleName 'TemplateHelpDSC'
    Import-DscResource -ModuleName 'PSDesiredStateConfiguration', 'NetworkingDsc', 'ComputerManagementDsc'

    $LogFolder = "DSC"
    $LogPath = "c:\staging\$LogFolder"
    [System.Management.Automation.PSCredential]$DomainCreds = New-Object System.Management.Automation.PSCredential ("${DomainName}\$($Admincreds.UserName)", $Admincreds.Password)

    Node localhost
    {
        LocalConfigurationManager {
            ConfigurationMode  = 'ApplyOnly'
            RebootNodeIfNeeded = $true
        }

        WriteStatus Rename {
            Status = "Renaming the computer to $ClientName"
        }

        Computer NewName {
            Name = $ClientName
        }

        SetCustomPagingFile PagingSettings {
            DependsOn   = "[Computer]NewName"
            Drive       = 'C:'
            InitialSize = '8192'
            MaximumSize = '8192'
        }

        WriteStatus WaitDomain {
            DependsOn = "[SetCustomPagingFile]PagingSettings"
            Status    = "Waiting for domain to be ready to obtain an IP"
        }

        WaitForDomainReady WaitForDomain {
            DependsOn = "[SetCustomPagingFile]PagingSettings"
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

        OpenFirewallPortForSCCM OpenFirewall {
            Name      = "DomainMember"
            Role      = "DomainMember"
            DependsOn = "[JoinDomain]JoinDomain"
        }

        WriteStatus AddLocalAdmin {
            DependsOn = "[OpenFirewallPortForSCCM]OpenFirewall"
            Status    = "Adding cm_svc domain account to Local Administrators group"
        }

        File ShareFolder {
            DestinationPath = $LogPath
            Type            = 'Directory'
            Ensure          = 'Present'
            DependsOn       = "[OpenFirewallPortForSCCM]OpenFirewall"
        }

        FileReadAccessShare DomainSMBShare {
            Name      = $LogFolder
            Path      = $LogPath
            DependsOn = "[File]ShareFolder"
        }

        AddUserToLocalAdminGroup AddADUserToLocalAdminGroup {
            Name       = "cm_svc"
            DomainName = $DomainName
            DependsOn  = "[FileReadAccessShare]DomainSMBShare"
        }

        WriteConfigurationFile WriteDomainMemberFinished {
            Role      = "DomainMember"
            LogPath   = $LogPath
            WriteNode = "DomainMemberFinished"
            Status    = "Passed"
            Ensure    = "Present"
            DependsOn = "[AddUserToLocalAdminGroup]AddADUserToLocalAdminGroup"
        }

        WriteStatus Complete {
            DependsOn = "[AddUserToLocalAdminGroup]AddADUserToLocalAdminGroup"
            Status    = "Complete!"
        }
    }
}