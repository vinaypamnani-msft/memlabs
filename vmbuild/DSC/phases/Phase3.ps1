configuration Phase3
{
    param
    (
        [Parameter(Mandatory)]
        [string]$DeployConfigPath,
        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$Admincreds
    )

    Set-ExecutionPolicy -ExecutionPolicy Bypass -Force
    Import-DscResource -ModuleName 'TemplateHelpDSC'
    Import-DscResource -ModuleName 'PSDesiredStateConfiguration', 'ComputerManagementDsc'

    # Read deployConfig
    $deployConfig = Get-Content -Path $DeployConfigPath | ConvertFrom-Json
    $DomainName = $deployConfig.parameters.domainName

    Node $AllNodes.NodeName
    {
        $ThisVM = $deployConfig.virtualMachines | Where-Object { $_.vmName -eq $node.NodeName }

        WriteStatus AddLocalAdmin {
            Status = "Adding required accounts to Local Administrators group"
        }

        $addUserDependancy = @('[WriteStatus]AddLocalAdmin')
        $i = 0
        foreach ($user in $ThisVM.thisParams.LocalAdminAccounts) {
            $i++
            $DscNodeName = "AddADUserToLocalAdminGroup$($i)"
            AddUserToLocalAdminGroup "$DscNodeName" {
                Name       = $user
                DomainName = $DomainName
            }
            $addUserDependancy += "[AddUserToLocalAdminGroup]$DscNodeName"
        }

        WriteStatus InstallFeature {
            DependsOn = $addUserDependancy
            Status    = "Installing required windows features"
        }

        InstallFeatureForSCCM InstallFeature {
            Name      = "DummyName"
            Role      = $ThisVM.role
            DependsOn = "[WriteStatus]InstallFeature"
        }

        WriteStatus OpenPorts {
            DependsOn = "[InstallFeatureForSCCM]InstallFeature"
            Status    = "Open required firewall ports"
        }

        OpenFirewallPortForSCCM OpenFirewall {
            DependsOn = "[WriteStatus]OpenPorts"
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

        $nextDepend = "[InstallDotNet4]DotNet"
        if ($ThisVM.installSSMS) {

            WriteStatus SSMS {
                DependsOn = $nextDepend
                Status    = "Downloading and installing SQL Management Studio"
            }

            InstallSSMS SSMS {
                DownloadUrl = "https://aka.ms/ssmsfullsetup"
                Ensure      = "Present"
                DependsOn   = "[WriteStatus]SSMS"
            }
        }

        WriteStatus Complete {
            DependsOn = $nextDepend
            Status    = "Complete!"
        }

    }
}