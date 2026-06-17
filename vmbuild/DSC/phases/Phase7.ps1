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

        # Per-VM cmOptions (multi-hierarchy safe).
        $cmo = if ($thisVM.cmOptions) { $thisVM.cmOptions } else { $deployConfig.cmOptions }
        $usePKI = $cmo.UsePKI
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
            DownloadUrl          = $deployConfig.URLS.PBIRS
            RSInstance           = "PBIRS"
            DBcredentials          = $Admincreds
            IsRemoteDatabaseServer = $IsRemoteDatabaseServer
            TemplateName         = $templateName
            DNSName              = $dnsName
            PsDscRunAsCredential = $Admincreds
            DependsOn = "[ModuleAdd]SQLServerModule"
        }

        $nextDepend = "[InstallPBIRS]InstallPBIRS"

        # Dual-role VM (installSUP + installRP): fire the early WSUS catalog
        # sync AFTER PBIRS install completes so a PBIRS-triggered reboot can't
        # interrupt the in-flight sync. Only the top-of-hierarchy SUP syncs
        # from MU (CAS, or standalone Primary). Child Primaries / Secondaries
        # sync from upstream and don't need an early kick.
        $hasCAS = ($deployConfig.VirtualMachines | Where-Object { $_.role -eq 'CAS' }).Count -gt 0
        $syncsFromMU = ($thisVM.installSUP -eq $true) -and (
            ($thisVM.role -eq 'CAS') -or
            ($thisVM.role -eq 'Primary' -and -not $hasCAS)
        )
        if ($syncsFromMU) {
            WSUSSync WSUSSync {
                DependsOn  = $nextDepend
                ServerName = $thisVM.vmName + "." + $DomainName
            }
            $nextDepend = "[WSUSSync]WSUSSync"
        }

        WriteStatus Complete {
            Status    = "Complete!"
            DependsOn = $nextDepend
        }
    }

    Node $AllNodes.Where{ $_.Role -eq 'WSUS' }.NodeName
    {
        # WSUS-only nodes in Phase 7: VMs with installSUP=true (or role=WSUS)
        # that do NOT have installRP. Phase 6 already installed/configured WSUS;
        # here we just kick the early catalog sync, mirroring the original
        # Phase 6 behavior but timed to happen after any PBIRS-induced reboots
        # elsewhere in the hierarchy have settled.

        $thisVM = $deployConfig.VirtualMachines | where-object { $_.vmName -eq $node.NodeName }

        # Only the top-of-hierarchy SUP (or a standalone WSUS) syncs from MU.
        $hasCAS = ($deployConfig.VirtualMachines | Where-Object { $_.role -eq 'CAS' }).Count -gt 0
        $standalone = ($thisVM.role -eq 'WSUS')
        $syncsFromMU = $standalone -or (
            ($thisVM.installSUP -eq $true) -and (
                ($thisVM.role -eq 'CAS') -or
                ($thisVM.role -eq 'Primary' -and -not $hasCAS)
            )
        )

        if ($syncsFromMU) {
            WriteStatus StartWSUSSync {
                Status = "Starting early WSUS catalog sync (background)"
            }
            WSUSSync WSUSSync {
                DependsOn  = "[WriteStatus]StartWSUSSync"
                ServerName = $thisVM.vmName + "." + $DomainName
            }
            WriteStatus Complete {
                Status    = "Complete!"
                DependsOn = "[WSUSSync]WSUSSync"
            }
        }
        else {
            # Downstream WSUS — syncs from upstream when upstream is ready.
            WriteStatus Complete {
                Status = "Complete!"
            }
        }
    }
}