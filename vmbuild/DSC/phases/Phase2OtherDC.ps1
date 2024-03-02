configuration Phase2OtherDC
{
    param
    (
        [Parameter(Mandatory)]
        [string]$DeployConfigPath,
        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$Admincreds
    )

    Import-DscResource -ModuleName 'TemplateHelpDSC'
    Import-DscResource -ModuleName 'PSDesiredStateConfiguration', 'NetworkingDsc', 'xDhcpServer', 'DnsServerDsc', 'ComputerManagementDsc', 'ActiveDirectoryDsc', 'GroupPolicyDsc'

    # Define log share
    $LogFolder = "DSC"
    $LogPath = "c:\staging\$LogFolder"

    # Read config
    $deployConfig = Get-Content -Path $DeployConfigPath | ConvertFrom-Json
    $DomainName = $deployConfig.parameters.domainName
    $DomainAdminName = $deployConfig.vmOptions.adminName

    # This VM
    $ThisMachineName = $deployConfig.parameters.ThisMachineName
    $ThisVM = $deployConfig.virtualMachines | Where-Object { $_.vmName -eq $ThisMachineName }


    $RealDC = $deployConfig.virtualMachines | Where-Object { $_.role -in ("DC") }

    $DCIPAddr = $RealDC.thisParams.DCIPAddress
    # DC's IP and DG
    $DHCP_DNSAddress = $ThisVM.thisParams.DCIPAddress
    $DHCP_DefaultGateway = $ThisVM.thisParams.DCDefaultGateway

    # Accounts to create
    $DomainAccounts = $ThisVM.thisParams.DomainAccounts
    $DomainAccountsUPN = $ThisVM.thisParams.DomainAccountsUPN
    $DomainComputers = $ThisVM.thisParams.DomainComputers

    # AD Sites
    $adsites = $ThisVM.thisParams.sitesAndNetworks

    # Wait on machines to join domain
    $waitOnDomainJoin = $ThisVM.thisParams.ServersToWaitOn

    $domainNameSplit = ($deployConfig.vmOptions.domainName).Split(".")
    $DNName = "DC=$($domainNameSplit[0]),DC=$($domainNameSplit[1])"

    $iiscount = 0
    [System.Collections.ArrayList]$groupMembers = @()
    $GroupMembersList = @()
    $GroupMembersList += $deployConfig.virtualMachines | Where-Object { $_.role -in ("CAS", "Primary", "PassiveSite", "Secondary") }
    $GroupMembersList += $deployConfig.virtualMachines | Where-Object { $_.InstallMP }
    $GroupMembersList += $deployConfig.virtualMachines | Where-Object { $_.InstallDP }
    $GroupMembersList += $deployConfig.virtualMachines | Where-Object { $_.InstallRP }
    $GroupMembersList += $deployConfig.virtualMachines | Where-Object { $_.InstallSUP }
    [System.Collections.ArrayList]$iisgroupMembers = @()
    foreach ($member in $GroupMembersList) {
        $memberName = $member.vmName + "$"
        if (-not $iisgroupMembers.Contains($memberName)) {
            $iiscount = $iisgroupMembers.Add($memberName)
            $iiscount++
        }
    }

    # Domain creds
    [System.Management.Automation.PSCredential]$DomainCreds = New-Object System.Management.Automation.PSCredential ("${DomainName}\$($Admincreds.UserName)", $Admincreds.Password)

    Node LOCALHOST
    {
        LocalConfigurationManager {
            ConfigurationMode  = 'ApplyOnly'
            RebootNodeIfNeeded = $true
        }

        RemoteDesktopAdmin RemoteDesktopSettings {
            IsSingleInstance   = 'yes'
            Ensure             = 'Present'
            UserAuthentication = 'NonSecure'
            #DependsOn          = $waitOnDependency
        }

        DnsServerConditionalForwarder 'Forwarder1'
        {
            Name             = ($deployConfig.vmOptions.domainName)
            MasterServers    = @($DCIPAddr)
            ReplicationScope = 'Forest'
            Ensure           = 'Present'
            DependsOn = "[RemoteDesktopAdmin]RemoteDesktopSettings"
        }


        WriteStatus Complete {
            DependsOn = "[DnsServerConditionalForwarder]Forwarder1"
            Status    = "Complete!"
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