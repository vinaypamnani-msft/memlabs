Configuration Host {

    Import-DscResource -ModuleName 'PSDesiredStateConfiguration', 'xHyper-V', 'xDhcpServer', 'xDscDiagnostics'

    $phsyicalNic = Get-NetAdapter | Where-Object { $_.InterfaceDescription -like "Microsoft Hyper-V Network Adapter*" }
    $phsyicalInterface = $phsyicalNic.Name
    $externalSwitchName = "External"

    Node LOCALHOST {

        LocalConfigurationManager {
            ConfigurationMode  = 'ApplyOnly'
            RebootNodeIfNeeded = $true
        }

        WindowsFeature Hyper-V {
            Ensure               = 'Present'
            Name                 = "Hyper-V"
            IncludeAllSubFeature = $true
        }

        WindowsFeature Hyper-V-Tools {
            Ensure               = 'Present'
            Name                 = 'Hyper-V-Tools'
            IncludeAllSubFeature = $true
        }

        WindowsFeature Hyper-V-PowerShell {
            Ensure               = 'Present'
            Name                 = 'Hyper-V-PowerShell'
            IncludeAllSubFeature = $true
        }

        WindowsFeature DHCP {
            DependsOn            = "[WindowsFeature]Hyper-V-PowerShell"
            Name                 = 'DHCP'
            Ensure               = 'Present'
            IncludeAllSubFeature = $true
        }

        WindowsFeature RSAT-DHCP {
            DependsOn            = "[WindowsFeature]DHCP"
            Name                 = 'RSAT-DHCP'
            Ensure               = 'Present'
            IncludeAllSubFeature = $true
        }

        xVMSwitch ExternalSwitch {
            DependsOn      = '[WindowsFeature]RSAT-DHCP'
            Ensure         = 'Present'
            Name           = $externalSwitchName
            Type           = 'External'
            NetAdapterName = $phsyicalInterface
        }

        xDhcpServerAuthorization LocalServerActivation {
            DependsOn        = "[xVMSwitch]ExternalSwitch"
            IsSingleInstance = 'Yes'
            Ensure           = 'Present'
        }
    }
}