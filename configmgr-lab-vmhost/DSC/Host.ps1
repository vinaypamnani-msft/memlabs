Configuration Host {

    Import-DscResource -ModuleName 'PSDesiredStateConfiguration', 'xHyper-V', 'xNetworking', 'xDscDiagnostics'

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

        xVMSwitch ExternalSwitch {
            DependsOn      = '[WindowsFeature]Hyper-V-PowerShell'
            Ensure         = 'Present'
            Name           = $externalSwitchName
            Type           = 'External'
            NetAdapterName = $phsyicalInterface
        }
    }
}