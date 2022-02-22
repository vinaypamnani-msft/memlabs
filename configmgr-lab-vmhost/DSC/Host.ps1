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

    }
}