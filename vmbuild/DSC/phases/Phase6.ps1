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
                $sqlServer = $thisVM.remoteSQLVM + "." + $DomainName
            }
            else {
                $sqlServer = $thisVM.vmName + "." + $DomainName
            }

            if ($thisVM.sqlInstanceName -and $thisVM.sqlInstanceName -ne "MSSQLSERVER") {
                $sqlServer = $sqlServer + "\" + $thisVM.sqlInstanceName
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
            IncludeAllSubFeature = $true
            DependsOn            = "[WriteStatus]UpdateServices"
        }

        WriteStatus ConfigureWSUS {
            Status = "Configuring WSUS to use ContentDir [$($thisVM.ContentDir)] and DB [$sqlServer]"
        }

        if ($thisVM.sqlVersion -or $thisVM.remoteSQLVM) {
            UpdateServicesServer UpdateServices
            {
                DependsOn  = @('[WindowsFeatureSet]UpdateServices')
                Ensure     = 'Present'
                ContentDir = $thisVM.ContentDir
                SqlServer  = $sqlServer
            }
        }
        else {
            UpdateServicesServer UpdateServices
            {
                DependsOn  = @('[WindowsFeatureSet]UpdateServices')
                Ensure     = 'Present'
                ContentDir = $thisVM.ContentDir
            }
        }

        WriteStatus Complete {
            Status    = "Complete!"
            DependsOn = "[UpdateServicesServer]UpdateServices"
        }
    }

}