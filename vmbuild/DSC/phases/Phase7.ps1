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

        $IsRemoteDatabaseServer = $true
        if ($thisVM.SQLVersion) {
            $SqlServer = $thisVM
            $IsRemoteDatabaseServer = $false
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


        $sqlServerVM = $deployConfig.VirtualMachines | where-object { $_.vmName -eq $SqlServerInstance }
        #
        $SqlServerInstance = $SqlServerInstance + "." + $deployConfig.vmOptions.DomainName
        if ($sqlServerVM.sqlInstanceName) {
            if ($sqlServerVM.sqlInstanceName -ne "MSSQLSERVER") {
            $SqlServerInstance = $SqlServerInstance + "\" + $sqlServerVM.sqlInstanceName
            }
        }
        if ($sqlServerVM.sqlPort) {
            $sqlPort = $sqlServerVM.sqlPort
        }
        else {
            $sqlPort = 1433
        }
        if ($sqlPort-ne "1433") {
            $SqlServerInstance = $SqlServerInstance + "," + $sqlPort
        }


        WriteStatus ImportModule {
            Status    = "Importing SQLServer Module"
        }

        ModuleAdd SQLServerModule {
            Key             = 'Always'
            CheckModuleName = 'SqlServer'
        }

        WriteStatus InstallPBIRS {
            Status    = "Installing PBIRS with the DB on $($SqlServerInstance)"
            DependsOn = "[ModuleAdd]SQLServerModule"
        }

        $usePKI = $deployConfig.cmOptions.UsePKI
        if ($usePKI) {
            $templateName = 'ConfigMgr WebServer Certificate'
            $dnsName = $thisVm.vmName + "." + $DomainName
        }else {
            $templateName = $null
            $dnsName = $null
        }
        InstallPBIRS InstallPBIRS {
            InstallPath          = "C:\PBIRS"
            SQLServer            = $SqlServerInstance
            DownloadUrl          = "https://download.microsoft.com/download/7/0/A/70AD68EF-5085-4DF2-A3AB-D091244DDDBF/PowerBIReportServer.exe"
            RSInstance           = "PBIRS"
            DBcredentials          = $Admincreds
            IsRemoteDatabaseServer = $IsRemoteDatabaseServer
            TemplateName         = $templateName
            DNSName              = $dnsName
            PsDscRunAsCredential = $Admincreds
            DependsOn = "[ModuleAdd]SQLServerModule"
        }

        WriteStatus Complete {
            Status    = "Complete!"
            DependsOn = "[InstallPBIRS]InstallPBIRS"
        }
    }
}