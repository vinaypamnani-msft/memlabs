configuration Phase6
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
    Import-DscResource -ModuleName 'PSDesiredStateConfiguration', 'ComputerManagementDsc', 'UpdateServicesDsc'

    # Read deployConfig
    $deployConfig = Get-Content -Path $DeployConfigPath | ConvertFrom-Json
    $DomainName = $deployConfig.parameters.domainName

    Node $AllNodes.Where{ $_.Role -eq 'DC' }.NodeName
    {
        WriteStatus Complete {
            Status = "Complete!"
        }
    }


    Node $AllNodes.Where{ $_.Role -eq 'WSUS' }.NodeName
    {
        $thisVM = $deployConfig.VirtualMachines | where-object { $_.vmName -eq $node.NodeName }
        $wsusFeatures = @("UpdateServices-Services", "UpdateServices-RSAT", "UpdateServices-API", "UpdateServices-UI")
        $sqlServer = "WID"
        if ($thisVM.sqlVersion -or $thisVM.remoteSQLVM) {
            $wsusFeatures += "UpdateServices-DB"
            if ($thisVM.remoteSQLVM) {
                $sqlServer = $thisVM.remoteSQLVM
            }
            else {
                $sqlServer = $thisVM.vmName
            }

            $sqlServerVM = $deployConfig.VirtualMachines | where-object { $_.vmName -eq $sqlServer }
            #
            if ($sqlServerVM.sqlInstanceName) {
                $sqlServer = $sqlServer + "\" + $sqlServerVM.sqlInstanceName
            }

            if ($sqlServerVM.sqlPort) {
                $sqlPort = $sqlServerVM.sqlPort
            }
            else {
                $sqlPort = 1433
            }
            if ($sqlPort -ne 1433) {
                $sqlServer = $sqlServer + "," + $sqlServerVM.sqlPort
            }

        }
        else {
            $wsusFeatures += "UpdateServices-WidDB"
        }

        WriteStatus UpdateServices {
            Status = "Adding WSUS Features: $($wsusFeatures -join ',')"
        }

        WindowsFeatureSet UpdateServices
        {
            Name                 = $wsusFeatures
            Ensure               = 'Present'
            IncludeAllSubFeature = $false
            DependsOn            = "[WriteStatus]UpdateServices"
        }

        $contentDir = $thisVM.wsusContentDir
        if (-not $contentDir) {
            $contentDir = "C:\WSUS"
            if ($thisVM.AdditionalDisks.E) {
                $contentDir = "E:\WSUS"
            }
        }

        WriteStatus ConfigureWSUS {
            Status = "Configuring WSUS to use ContentDir [$($contentDir)] and DB [$sqlServer]"
        }

        if ($thisVM.sqlVersion -or $thisVM.remoteSQLVM) {
            ConfigureWSUS UpdateServices {
                DependsOn            = @('[WindowsFeatureSet]UpdateServices')
                ContentPath          = $contentDir
                SqlServer            = $sqlServer
                PsDscRunAsCredential = $Admincreds
            }
        }
        else {
            ConfigureWSUS UpdateServices {
                DependsOn   = @('[WindowsFeatureSet]UpdateServices')
                ContentPath = $contentDir
            }
        }

        WriteStatus Complete {
            Status    = "Complete!"
            DependsOn = "[ConfigureWSUS]UpdateServices"
        }
    }

}