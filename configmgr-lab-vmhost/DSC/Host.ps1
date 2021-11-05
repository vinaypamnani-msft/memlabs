Configuration Host {

    Import-DscResource -ModuleName 'PSDesiredStateConfiguration', 'xDscDiagnostics'

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
            DependsOn            = "[WindowsFeature]Hyper-V"
            Ensure               = 'Present'
            Name                 = 'Hyper-V-Tools'
            IncludeAllSubFeature = $true
        }

        WindowsFeature Hyper-V-PowerShell {
            DependsOn            = "[WindowsFeature]Hyper-V-Tools"
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

    }
}