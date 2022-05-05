configuration Phase7
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

    Node $AllNodes.Where{ $_.Role -eq 'DC' }.NodeName
    {
        WriteStatus Complete {
            Status = "Complete!"
        }
    }


    Node $AllNodes.Where{ $_.Role -eq 'PBIRS' }.NodeName
    {
        $thisVM = $deployConfig.VirtualMachines | where-object { $_.vmName -eq $node.NodeName }
        if ($thisVM.SQLVersion) {
            $SqlServer = $thisVM
        }

        if ($thisVM.RemoteSQLVM) {
            $SqlServer = $deployConfig.VirtualMachines | where-object { $_.vmName -eq $thisVM.RemoteSQLVM }
        }

        if (-not $SqlServer) {
            #Find the Primary or CAS
            $SiteServer = $deployConfig.VirtualMachines | where-object { $_.siteCode -eq $thisVM.siteCode -and $_.Role -in "CAS", "Primary" }

            if ($SiteServer.SqlVersion) {
                $SqlServer = $SiteServer
            }

            if ($SiteServer.RemoteSQLVM) {
                $SqlServer = $deployConfig.VirtualMachines | where-object { $_.vmName -eq $SiteServer.RemoteSQLVM }
            }
        }

        $SqlServerInstance = $SqlServer.vmName
        if ($SqlServer.SqlInstanceName -and $SqlServer.SqlInstanceName -ne "MSSQLSERVER") {
            $SqlServerInstance = $SqlServerInstance + "\" + $SqlServer.SqlInstanceName
        }

        WriteStatus InstallPBIRS {
            Status    = "Installing PBIRS with the DB on $($SqlServerInstance)"
        }

        InstallPBIRS InstallPBIRS {
            InstallPath          = "C:\PBIRS"
            SQLServer            = $SqlServerInstance
            DownloadUrl          = "https://download.microsoft.com/download/7/0/A/70AD68EF-5085-4DF2-A3AB-D091244DDDBF/PowerBIReportServer.exe"
            RSInstance           = "PBIRS"
            PsDscRunAsCredential = $Admincreds
        }

        WriteStatus Complete {
            Status    = "Complete!"
            DependsOn = "[InstallPBIRS]InstallPBIRS"
        }
    }
}