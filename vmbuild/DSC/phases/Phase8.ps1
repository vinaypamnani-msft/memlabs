Configuration Phase8
{
    param
    (
        [Parameter(Mandatory)]
        [string]$DeployConfigPath,
        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$Admincreds
    )

    Import-DscResource -ModuleName 'PSDesiredStateConfiguration', 'TemplateHelpDSC', 'ActiveDirectoryDsc', 'ComputerManagementDsc', 'FailoverClusterDsc', 'AccessControlDsc', 'SqlServerDsc'

    # Read config
    $deployConfig = Get-Content -Path $DeployConfigPath | ConvertFrom-Json


    $DomainAdminName = $deployConfig.vmOptions.adminName

    # Log share
    $LogFolder = "DSC"
    $LogPath = "c:\staging\$LogFolder"

    # $CM (CMTP vs CMCB source folder) is resolved per-Node from the owning
    # VM's cmOptions so multi-hierarchy deploys with mixed CM versions stamp
    # the correct folder on each node. See CAS/Primary and DC Node blocks.

    # Strip domain prefix from credential username if present (the multi-node
    # DSC compilation path pre-prefixes with NetBIOS name, which would create
    # an invalid double-prefix like "FQDN\NetBIOS\user")
    $AdminUserName = $Admincreds.UserName
    if ($AdminUserName -match '\\') { $AdminUserName = ($AdminUserName -split '\\', 2)[1] }

    # Domain Creds
    $DomainName = $deployConfig.parameters.domainName
    [System.Management.Automation.PSCredential]$DomainCreds = New-Object System.Management.Automation.PSCredential ("${DomainName}\$AdminUserName", $Admincreds.Password)
    [System.Management.Automation.PSCredential]$CMAdmin = New-Object System.Management.Automation.PSCredential ("${DomainName}\$DomainAdminName", $Admincreds.Password)


    Node $AllNodes.Where{ $_.Role -eq 'FileServer' }.NodeName
    {

        $ThisVM = $deployConfig.virtualMachines | Where-Object { $_.vmName -eq $node.NodeName.split(".")[0] }

        WriteStatus Start {
            DependsOn = $nextDepend
            Status    = "Creating PMPCApps share in E:\PMPCApps"
        }

        File "PMPCApps" {
            DestinationPath = 'E:\PMPCApps'
            Type            = 'Directory'
            Ensure          = "Present"
            DependsOn       = $nextDepend
        }
        $nextDepend = "[File]PMPCApps"

        NTFSAccessEntry PMPCApps {
            Path              = 'E:\PMPCApps'
            AccessControlList = @(
                NTFSAccessControlList {
                    Principal          = "Everyone"
                    ForcePrincipal     = $false
                    AccessControlEntry = @(
                        NTFSAccessControlEntry {
                            AccessControlType = 'Allow'
                            FileSystemRights  = 'FullControl'
                            Inheritance       = 'This folder subfolders and files'
                            Ensure            = 'Present'
                        }
                    )
                }
                            
                NTFSAccessControlList {
                    Principal          = "$netbiosName\$DomainAdminName"
                    ForcePrincipal     = $false
                    AccessControlEntry = @(
                        NTFSAccessControlEntry {
                            AccessControlType = 'Allow'
                            FileSystemRights  = 'FullControl'
                            Inheritance       = 'This folder subfolders and files'
                            Ensure            = 'Present'
                        }
                    )
                }
            )
            DependsOn         = $nextDepend
        }
        $nextDepend = "[NTFSAccessEntry]PMPCApps"

        SmbShare "PMPCShare" {
            Name        = "PMPCApps"
            Path        = 'E:\PMPCApps'
            #Ensure                = "Present"
            Description = "Share for PMPC Apps"
            #FolderEnumerationMode = 'Unrestricted'
            FullAccess  = "Everyone"
            #ReadAccess            = "Everyone"
            DependsOn   = $nextDepend
        }
        $nextDepend = "[SmbShare]PMPCShare"


        WriteStatus Complete {
            DependsOn = $nextDepend
            Status    = "Complete!"
        }
    }

    Node $AllNodes.Where{ $_.Role -eq 'SiteSystem' }.NodeName
    {
        $ThisVM = $deployConfig.virtualMachines | Where-Object { $_.vmName -eq $node.NodeName.split(".")[0] }

        # WSUS categories baseline cab import for a REMOTE SUP site system.
        # When the SUP/WSUS role lives on a dedicated site system (this box)
        # rather than co-located on the site server, nobody else imports the
        # categories cab onto THIS WSUS host: InstallRoles (Primary/CAS) and
        # the Secondary Phase 8 path both run the import against their OWN
        # localhost WSUS, which a remote SUP is not. Without this block the
        # SUP's taxonomy stays at the ~17-row postinstall default until a slow
        # upstream categories sync lands (observed on a remote SUP: Phase 11
        # "WSUS initial sync (taxonomy) not populated [TaxonomyCats=17]").
        # The cab was already staged to C:\staging\wsus\ in Phase <=7, and
        # WSUS + its postinstall (SUSDB) are guaranteed present once the owning
        # site server's ScriptWorkflow (which adds the SUP role) has completed.
        # Idempotent: Start-WsusBaselineImportBackground short-circuits with
        # 'already-imported' / 'no-cab' / 'no-wsusutil' as appropriate.
        if ($ThisVM.installSUP -eq $true) {
            $supSiteServer = $deployConfig.virtualMachines | Where-Object { $_.role -in ("CAS", "Primary") -and $_.Sitecode -eq $ThisVM.Sitecode } | Select-Object -First 1
            if ($supSiteServer) {
                WriteStatus WaitSupSiteServer {
                    Status = "Waiting for site server $($supSiteServer.vmName) before importing the WSUS categories baseline."
                }

                WaitForEvent WaitSupSiteServer {
                    MachineName   = $supSiteServer.vmName
                    LogFolder     = $LogFolder
                    FileName      = "ScriptWorkflow"
                    ReadNode      = "ScriptWorkflow"
                    ReadNodeValue = "Completed"
                    Ensure        = "Present"
                    DependsOn     = "[WriteStatus]WaitSupSiteServer"
                }

                Script ImportWsusBaseline {
                    GetScript  = { @{ Result = '' } }
                    TestScript = {
                        if (-not (Test-Path 'C:\staging\wsus\WsusCategoriesBaseline.cab')) { return $true }
                        try {
                            [void][System.Reflection.Assembly]::LoadWithPartialName('Microsoft.UpdateServices.Administration')
                            $srv = [Microsoft.UpdateServices.Administration.AdminProxy]::GetUpdateServer()
                            return ($srv.GetUpdateCategories().Count -ge 100)
                        }
                        catch { return $false }
                    }
                    SetScript  = {
                        try {
                            . C:\staging\DSC\phases\ScriptFunctions.ps1
                            Start-WsusBaselineImportBackground -Tag '[Phase8-SiteSystem]' | Out-Null
                            Wait-WsusBaselineImport -Tag '[Phase8-SiteSystem]'
                        }
                        catch {
                            # Non-fatal: an upstream categories sync will eventually
                            # populate the taxonomy, just slower. Don't break DSC.
                        }
                    }
                    DependsOn  = "[WaitForEvent]WaitSupSiteServer"
                }
                $nextDepend = '[Script]ImportWsusBaseline'
            }
        }

        if ($ThisVM.InstallPatchMyPC) {
            $WaitFor = @()

            $serverToWait = $deployConfig.virtualMachines | Where-Object { $_.role -in ("CAS", "Primary") -and $_.Sitecode -eq $ThisVM.Sitecode }
            if ($serverToWait) {
                $WaitFor += $serverToWait.vmName        
            }
       
            $WaitFor = $WaitFor | Where-Object { $_ } | select-object -Unique
            if ($WaitFor) {
                WriteStatus WaitSCCM {
                    DependsOn = $nextDepend
                    Status    = "Waiting on $($WaitFor -join ",") to Complete"
                }

                WaitForAll WaitSCCM {
                    ResourceName     = '[WaitForEvent]WorkflowComplete'
                    NodeName         = $WaitFor
                    RetryIntervalSec = 5
                    RetryCount       = 7200
                    DependsOn        = $nextDepend
                }
                $nextDepend = '[WaitForAll]WaitSCCM'
            }
            InstallConsole InstallConsole {
                SiteServerFQDN = $serverToWait.VmName + "." + $DomainName
                CMInstallDir   = $serverToWait.CMInstallDir
                DependsOn      = $nextDepend                
            }
            $nextDepend = '[InstallConsole]InstallConsole'

            if ($serverToWait.RemoteSQLVM) {
                $SqlServer = $serverToWait.RemoteSQLVM
            }
            else {
                $SqlServer = $serverToWait.VmName
            }
            InstallPMPC InstallPMPC {
                DependsOn  = $nextDepend
                Path       = "C:\temp\pmpc.msi"
                URL        = $deployConfig.URLS.PMPC
                SiteCode   = $ThisVM.Sitecode
                SqlServer  = $SqlServer
                SiteServer = $serverToWait.VmName
                FileServer = $ThisVM.PatchMyPCFileServer
                Ensure     = "Present"
            }
            $nextDepend = '[InstallPMPC]InstallPMPC'


        }

        WriteStatus Complete {
            DependsOn = $nextDepend
            Status    = "Complete!"
        }
    }

    Node $AllNodes.Where{ $_.Role -eq 'WSUS' }.NodeName
    {
        WriteStatus Complete {
            DependsOn = $nextDepend
            Status    = "Complete!"
        }
    }

    Node $AllNodes.Where{ $_.Role -eq 'SqlServer' }.NodeName
    {
        $ThisVM = $deployConfig.virtualMachines | Where-Object { $_.vmName -eq $node.NodeName.split(".")[0] }
        # Domain Creds
        $DomainName = $deployConfig.parameters.domainName
        if ($ThisVM.Domain) {
            $DomainName = $ThisVM.Domain
        }
        [System.Management.Automation.PSCredential]$DomainCreds = New-Object System.Management.Automation.PSCredential ("${DomainName}\$AdminUserName", $Admincreds.Password)
        [System.Management.Automation.PSCredential]$CMAdmin = New-Object System.Management.Automation.PSCredential ("${DomainName}\$DomainAdminName", $Admincreds.Password)

        $AgentJobSet = "C:\staging\DSC\SQLScripts\Disable-AgentJob-Set.sql"
        $AgentJobTest = "C:\staging\DSC\SQLScripts\AgentJob-Test.sql"
        $AgentJobGet = "C:\staging\DSC\SQLScripts\AgentJob-Get.sql"


        WriteStatus DisableAgentJob {
            Status = "Disabling Agent Jobs"
        }

        SqlScript 'DisableAgentJob' {
            Id                   = 'DisableAgentJob'
            ServerName           = $thisvm.VmName
            InstanceName         = $thisVM.sqlInstanceName
            #Credential       = $Admincreds
            SetFilePath          = $AgentJobSet
            TestFilePath         = $AgentJobTest
            GetFilePath          = $AgentJobGet
            DisableVariables     = $true
            Variable             = @('FilePath=C:\temp\')
            PsDscRunAsCredential = $Admincreds
            Encrypt              = "Optional"
        }
        $nextDepend = '[SqlScript]DisableAgentJob'


        $WaitFor = @()
        $serverToWait = $deployConfig.virtualMachines | Where-Object { $_.RemoteSQLVM -eq $node.NodeName -and $_.role -in "CAS", "Primary" }
        if ($serverToWait) {
            $WaitFor += $serverToWait.vmName
        }
        if ($ThisVm.role -eq "SQLAO" -and (-not $ThisVM.OtherNode)) {
            $primaryNode = $serverToWait = $deployConfig.virtualMachines | Where-Object { $_.OtherNode -eq $node.NodeName }
            $serverToWait = $deployConfig.virtualMachines | Where-Object { $_.RemoteSQLVM -eq $primaryNode.vmName -and $_.role -in "CAS", "Primary" }
            if ($serverToWait) {
                $WaitFor += $serverToWait.vmName
            }
        }
        $WaitFor = $WaitFor | Where-Object { $_ } | select-object -Unique
        if ($WaitFor) {
            WriteStatus WaitSCCM {
                DependsOn = $nextDepend
                Status    = "Waiting on $($WaitFor -join ",") to Complete"
            }

            WaitForAll WaitSCCM {
                ResourceName     = '[WaitForEvent]WorkflowComplete'
                NodeName         = $WaitFor
                RetryIntervalSec = 5
                RetryCount       = 7200
                DependsOn        = $nextDepend
            }
            $nextDepend = '[WaitForAll]WaitSCCM'
        }

        $AgentJobSet = "C:\staging\DSC\SQLScripts\Enable-AgentJob-Set.sql"

        WriteStatus EnableAgentJob {
            Status = "Enabling Agent Jobs"
        }

        SqlScript 'EnableAgentJob' {
            Id                   = 'EnableAgentJob'
            ServerName           = $thisvm.VmName
            InstanceName         = $thisVM.sqlInstanceName
            #Credential       = $Admincreds
            SetFilePath          = $AgentJobSet
            TestFilePath         = $AgentJobTest
            GetFilePath          = $AgentJobGet
            DisableVariables     = $true
            DependsOn            = $nextDepend
            Variable             = @('FilePath=C:\temp\')
            PsDscRunAsCredential = $Admincreds
            Encrypt              = "Optional"
        }
        $nextDepend = '[SqlScript]EnableAgentJob'

        $CustomJobSet = "C:\staging\DSC\SQLScripts\MemLabsCustomization-Set.sql"
        $CustomJobTest = "C:\staging\DSC\SQLScripts\MemLabsCustomization-Test.sql"
        $CustomJobGet = "C:\staging\DSC\SQLScripts\MemLabsCustomization-Get.sql"

        SqlScript 'MemLabsCustomization' {
            Id                   = 'MemLabsCustomization'
            ServerName           = $thisvm.VmName
            InstanceName         = $thisVM.sqlInstanceName
            SetFilePath          = $CustomJobSet
            TestFilePath         = $CustomJobTest
            GetFilePath          = $CustomJobGet
            DisableVariables     = $true
            DependsOn            = $nextDepend
            Variable             = @('FilePath=C:\temp\')
            PsDscRunAsCredential = $Admincreds
            Encrypt              = "Optional"
        }
        $nextDepend = '[SqlScript]MemLabsCustomization'
        
        WriteStatus Complete {
            DependsOn = $nextDepend
            Status    = "Complete!"
        }
    }

    Node $AllNodes.Where{ $_.Role -eq 'DC' }.NodeName
    {
        $ThisVM = $deployConfig.virtualMachines | Where-Object { $_.vmName -eq $node.NodeName.split(".")[0] }
        # Domain Creds
        $DomainName = $deployConfig.parameters.domainName
        if ($ThisVM.Domain) {
            $DomainName = $ThisVM.Domain
        }
        [System.Management.Automation.PSCredential]$DomainCreds = New-Object System.Management.Automation.PSCredential ("${DomainName}\$AdminUserName", $Admincreds.Password)
        [System.Management.Automation.PSCredential]$CMAdmin = New-Object System.Management.Automation.PSCredential ("${DomainName}\$DomainAdminName", $Admincreds.Password)
        $PSName = $ThisVM.thisParams.PSName
        $CSName = $ThisVM.thisParams.CSName

        WriteStatus DelegateControl {
            Status = "Assigning permissions to Systems Management container"
        }

        $nextDepend = "[WriteStatus]DelegateControl"
        $waitOnDependency = @($nextDepend)
        foreach ($server in $ThisVM.thisParams.ServersToWaitOn) {

            VerifyComputerJoinDomain "WaitFor$server" {
                ComputerName = $server
                Ensure       = "Present"
                DependsOn    = $nextDepend
            }

            DelegateControl "Add$server" {
                Machine        = $server
                DomainFullName = $DomainName
                Ensure         = "Present"
                DependsOn      = "[VerifyComputerJoinDomain]WaitFor$server"
            }

            $waitOnDependency += "[DelegateControl]Add$server"
        }

        $nextDepend = $waitOnDependency

        if ($CSName -or $PSName) {
            # AD schema extensions are cumulative -- a single extension by the
            # highest-version top-level site server in this domain covers every
            # hierarchy. Prefer tech-preview (newer schema) over current-branch.
            # Falls back to legacy $CSName/$PSName if no top-levels are visible
            # in this deployConfig snapshot.
            $dcDomain = if ($ThisVM.Domain) { $ThisVM.Domain } else { $deployConfig.parameters.domainName }
            $domainTops = @($deployConfig.virtualMachines | Where-Object {
                    $_.Role -in 'CAS', 'Primary' -and -not $_.parentSiteCode -and
                    (-not $_.Domain -or $_.Domain -eq $dcDomain)
                })
            $schemaServer = $domainTops | Where-Object {
                $vmCmo = if ($_.cmOptions) { $_.cmOptions } else { $deployConfig.cmOptions }
                $vmCmo.version -eq 'tech-preview'
            } | Select-Object -First 1
            if (-not $schemaServer) { $schemaServer = $domainTops | Select-Object -First 1 }

            if ($schemaServer) {
                $parentName = $schemaServer.vmName
                $parentCmo = if ($schemaServer.cmOptions) { $schemaServer.cmOptions } else { $deployConfig.cmOptions }
            }
            else {
                $parentName = if ($CSName) { $CSName } else { $PSName }
                $parentVM = $deployConfig.virtualMachines | Where-Object { $_.vmName -eq $parentName } | Select-Object -First 1
                $parentCmo = if ($parentVM.cmOptions) { $parentVM.cmOptions } else { $deployConfig.cmOptions }
            }
            $CM = if ($parentCmo.version -eq "tech-preview") { "CMTP" } else { "CMCB" }

            WriteStatus WaitExtSchema {
                DependsOn = $nextDepend
                Status    = "Waiting for site to download ConfigMgr source files, before extending schema for Configuration Manager"
            }

            WaitForExtendSchemaFile WaitForExtendSchemaFile {
                MachineName          = $parentName
                ExtFolder            = $CM
                Ensure               = "Present"
                DependsOn            = "[WriteStatus]WaitExtSchema"
                PsDscRunAsCredential = $DomainCreds
            }
        }

        WriteStatus Complete {
            DependsOn = $nextDepend
            Status    = "Complete!"
        }
    }


    Node $AllNodes.Where{ $_.Role -eq "Secondary" }.NodeName
    {

        $ThisVM = $deployConfig.virtualMachines | Where-Object { $_.vmName -eq $node.NodeName.split(".")[0] }
        # Domain Creds
        $DomainName = $deployConfig.parameters.domainName
        if ($ThisVM.Domain) {
            $DomainName = $ThisVM.Domain
        }
        [System.Management.Automation.PSCredential]$DomainCreds = New-Object System.Management.Automation.PSCredential ("${DomainName}\$AdminUserName", $Admincreds.Password)
        [System.Management.Automation.PSCredential]$CMAdmin = New-Object System.Management.Automation.PSCredential ("${DomainName}\$DomainAdminName", $Admincreds.Password)
        $PSName = $ThisVM.thisParams.ParentSiteServer

        #$ParentSiteCode = ($deployConfig.virtualMachines | where-object { $_.vmName -eq ($Node.NodeName) }).ParentSiteCode
        #$PSName = ($deployConfig.virtualMachines | where-object { $_.Role -eq "Primary" -and $_.SiteCode -eq $ParentSiteCode }).vmName

        WriteStatus ODBCDriverInstall {            
            Status = "Downloading and installing ODBC driver version 18"
        }

        InstallODBCDriver ODBCDriverInstall {
            ODBCPath  = "C:\temp\msodbcsql.msi"
            URL       = $deployConfig.URLS.ODBC
            Ensure    = "Present"
            DependsOn = "[WriteStatus]ODBCDriverInstall"
        }
        $nextDepend = "[InstallODBCDriver]ODBCDriverInstall"

        WriteStatus ReportBuilderInstall {            
            Status    = "Downloading and installing ODBC driver version 18"
            DependsOn = $nextDepend
        }

        InstallReportBuilder InstallReportBuilder {
            Path      = "C:\temp\ReportBuilder.msi"
            URL       = $deployConfig.URLS.ReportBuilder
            Ensure    = "Present"
            DependsOn = $nextDepend
        }
        $nextDepend = "[InstallReportBuilder]InstallReportBuilder"

        WriteStatus WaitPrimary {
            Status    = "Waiting for Site Server $PSName to finish configuration."
            DependsOn = $nextDepend
        }

        WaitForEvent WaitPrimary {
            MachineName   = $PSName
            LogFolder     = $LogFolder
            FileName      = "ScriptWorkflow"
            ReadNode      = "ScriptWorkflow"
            ReadNodeValue = "Completed"
            Ensure        = "Present"
            DependsOn     = $nextDepend
        }

        # WSUS categories baseline cab import for this Secondary's SUP.
        # By the time WaitPrimary returns the Primary's InstallRoles has
        # added the SUP role to this Secondary, which installs WSUS +
        # runs wsusutil postinstall via CM's site component manager. The
        # cab was already staged to C:\staging\wsus\ during Phase <=7
        # by the host orchestrator. Fire the import locally now -- CM's
        # ScriptWorkflow on the Primary never runs on a Secondary, so
        # this is the only point where the import can be triggered with
        # WSUS guaranteed-installed and the cab guaranteed-present.
        # Start-WsusBaselineImportBackground + Wait-WsusBaselineImport
        # are defined in C:\staging\DSC\phases\ScriptFunctions.ps1 and
        # are idempotent (short-circuit with 'no-cab' / 'already-imported'
        # / 'no-wsusutil' as appropriate), so this is safe on re-runs and
        # on Secondaries that for any reason don't have a SUP role.
        Script ImportWsusBaseline {
            GetScript  = { @{ Result = '' } }
            TestScript = {
                if (-not (Test-Path 'C:\staging\wsus\WsusCategoriesBaseline.cab')) { return $true }
                try {
                    [void][System.Reflection.Assembly]::LoadWithPartialName('Microsoft.UpdateServices.Administration')
                    $srv = [Microsoft.UpdateServices.Administration.AdminProxy]::GetUpdateServer()
                    return ($srv.GetUpdateCategories().Count -ge 100)
                }
                catch { return $false }
            }
            SetScript  = {
                try {
                    . C:\staging\DSC\phases\ScriptFunctions.ps1
                    Start-WsusBaselineImportBackground -Tag '[Phase8-Secondary]' | Out-Null
                    Wait-WsusBaselineImport -Tag '[Phase8-Secondary]'
                }
                catch {
                    # Non-fatal: downstream sync from upstream SUP will eventually populate
                    # the taxonomy, just slower. Don't break the Secondary's DSC over this.
                }
            }
            DependsOn  = "[WaitForEvent]WaitPrimary"
        }

        WriteEvent WriteConfigFinished {
            LogPath   = $LogPath
            WriteNode = "ConfigurationFinished"
            Status    = "Passed"
            Ensure    = "Present"
            DependsOn = "[Script]ImportWsusBaseline"
        }

        WriteStatus Complete {
            DependsOn = "[Script]ImportWsusBaseline"
            Status    = "Complete!"
        }
    }

    Node $AllNodes.Where{ $_.Role -eq 'CAS' -or $_.Role -eq "Primary" }.NodeName
    {
        $ThisMachineName = $Node.NodeName
        $ThisVM = $deployConfig.virtualMachines | Where-Object { $_.vmName -eq $node.NodeName.split(".")[0] }
        # Domain Creds
        $DomainName = $deployConfig.parameters.domainName
        if ($ThisVM.Domain) {
            $DomainName = $ThisVM.Domain
        }
        #[System.Management.Automation.PSCredential]$DomainCreds = New-Object System.Management.Automation.PSCredential ("${DomainName}\$($Admincreds.UserName)", $Admincreds.Password)
        [System.Management.Automation.PSCredential]$CMAdmin = New-Object System.Management.Automation.PSCredential ("${DomainName}\$DomainAdminName", $Admincreds.Password)

        # Resolve per-VM CM version so each hierarchy uses its own source
        # folder when multiple top-level site servers are deployed together.
        $cmo = if ($ThisVM.cmOptions) { $ThisVM.cmOptions } else { $deployConfig.cmOptions }
        $CM = if ($cmo.version -eq "tech-preview") { "CMTP" } else { "CMCB" }

        WriteStatus ADKInstall {
            Status = "Downloading and installing ADK"
        }

        InstallADK ADKInstall {
            ADKPath              = "C:\temp\adksetup.exe"
            ADKWinPEPath         = "c:\temp\adksetupwinpe.exe"
            ADKDownloadPath      = $deployConfig.URLS.ADK
            ADKWinPEDownloadPath = $deployConfig.URLS.ADKPE         
            Ensure               = "Present"
            DependsOn            = "[WriteStatus]ADKInstall"
        }

        $nextDepend = "[InstallADK]ADKInstall"

        InstallReportBuilder InstallReportBuilder {
            Path      = "C:\temp\ReportBuilder.msi"
            URL       = $deployConfig.URLS.ReportBuilder
            Ensure    = "Present"
            DependsOn = $nextDepend
        }
        $nextDepend = "[InstallReportBuilder]InstallReportBuilder"

        WriteStatus ODBCDriverInstall {
            DependsOn = $nextDepend
            Status    = "Downloading and installing ODBC driver version 18"
        }

        InstallODBCDriver ODBCDriverInstall {
            ODBCPath  = "C:\temp\msodbcsql.msi"
            URL       = $deployConfig.URLS.ODBC
            Ensure    = "Present"
            DependsOn = "[WriteStatus]ODBCDriverInstall"
        }

        $nextDepend = "[InstallODBCDriver]ODBCDriverInstall"

        if (-not $ThisVM.thisParams.ParentSiteServer -and (-not $($ThisVM.hidden))) {

            $CMDownloadStatus = "Downloading Configuration Manager current branch (required baseline version)"
            if ($CM -eq "CMTP") {
                $CMDownloadStatus = "Downloading Configuration Manager technical preview"
            }

            if ($ThisVM.thisParams.cmDownloadVersion.downloadUrl) {

                WriteStatus DownLoadSCCM {
                    DependsOn = $nextDepend
                    Status    = $CMDownloadStatus
                }
                $nextDepend = "[WriteStatus]DownLoadSCCM"

                DownloadSCCM DownLoadSCCM {
                    CM            = $CM
                    CMDownloadUrl = $ThisVM.thisParams.cmDownloadVersion.downloadUrl
                    Ensure        = "Present"
                    DependsOn     = $nextDepend
                }
                $nextDepend = "[DownLoadSCCM]DownLoadSCCM"
            }

            FileReadAccessShare CMSourceSMBShare {
                Name      = $CM
                Path      = "c:\$CM"
                DependsOn = $nextDepend
            }

            $nextDepend = "[FileReadAccessShare]CMSourceSMBShare"
        }

        WriteStatus RunScriptWorkflow {
            DependsOn = $nextDepend
            Status    = "Setting up ConfigMgr. Waiting for workflow to begin."
        }

        WriteFileOnce CMSvc {
            FilePath  = "$LogPath\cm_svc.txt"
            Content   = $Admincreds.GetNetworkCredential().Password
            DependsOn = "[WriteStatus]RunScriptWorkflow"
        }

        RegisterTaskScheduler RunScriptWorkflow {
            TaskName       = "ScriptWorkflow"
            ScriptName     = "ScriptWorkflow.ps1"
            ScriptPath     = $PSScriptRoot
            ScriptArgument = "$DeployConfigPath $LogPath"
            AdminCreds     = $CMAdmin
            Ensure         = "Present"
            DependsOn      = "[WriteFileOnce]CMSvc"
        }

        WaitForEvent WorkflowComplete {
            MachineName   = $ThisMachineName
            LogFolder     = $LogFolder
            FileName      = "ScriptWorkflow"
            ReadNode      = "ScriptWorkflow"
            ReadNodeValue = "Completed"
            Ensure        = "Present"
            DependsOn     = "[RegisterTaskScheduler]RunScriptWorkflow"
        }

        $nextDepend = "[WaitForEvent]WorkflowComplete"

        if ($thisVM.InstallPatchMyPC) {

            if ($ThisVM.RemoteSQLVM) {
                $SqlServer = $ThisVM.RemoteSQLVM
            }
            else {
                $SqlServer = $ThisVM.VmName
            }

            InstallPMPC InstallPMPC {
                DependsOn  = $nextDepend
                Path       = "C:\temp\pmpc.msi"
                URL        = $deployConfig.URLS.PMPC
                Ensure     = "Present"
                SiteCode   = $ThisVM.Sitecode
                SqlServer  = $SqlServer
                SiteServer = $ThisVM.VmName
                FileServer = $ThisVM.PatchMyPCFileServer
            }
            $nextDepend = '[InstallPMPC]InstallPMPC'
            # No RebootNow here: pmpc.msi was installed with /norestart and the
            # forced reboot would kill the in-flight WSUS sync that perfloading
            # kicked off after AddProduct (sync runs async on WsusService.exe
            # and is not waited on by ScriptWorkflow). Any reboot PMPC actually
            # needs is picked up at the next natural restart.
        }

        WriteStatus Complete {
            DependsOn = $nextDepend 
            Status    = "Complete!"
        }
    }

    Node $AllNodes.Where{ $_.Role -eq 'PassiveSite' }.NodeName
    {
        $ThisMachineName = $Node.NodeName
        $ThisVM = $deployConfig.virtualMachines | Where-Object { $_.vmName -eq $node.NodeName.split(".")[0] }
        # Domain Creds
        $DomainName = $deployConfig.parameters.domainName
        if ($ThisVM.Domain) {
            $DomainName = $ThisVM.Domain
        }
        [System.Management.Automation.PSCredential]$DomainCreds = New-Object System.Management.Automation.PSCredential ("${DomainName}\$AdminUserName", $Admincreds.Password)
        [System.Management.Automation.PSCredential]$CMAdmin = New-Object System.Management.Automation.PSCredential ("${DomainName}\$DomainAdminName", $Admincreds.Password)

        WriteStatus ADKInstall {
            Status = "Downloading and installing ADK"
        }

        InstallADK ADKInstall {
            ADKPath              = "C:\temp\adksetup.exe"
            ADKWinPEPath         = "c:\temp\adksetupwinpe.exe"
            ADKDownloadPath      = $deployConfig.URLS.ADK
            ADKWinPEDownloadPath = $deployConfig.URLS.ADKPE           
            Ensure               = "Present"
            DependsOn            = "[WriteStatus]ADKInstall"
        }
        $nextDepend = "[InstallADK]ADKInstall"

        InstallReportBuilder InstallReportBuilder {
            Path      = "C:\temp\ReportBuilder.msi"
            URL       = $deployConfig.URLS.ReportBuilder
            Ensure    = "Present"
            DependsOn = $nextDepend
        }
        $nextDepend = "[InstallReportBuilder]InstallReportBuilder"

        WriteStatus WaitActive {
            Status    = "Waiting for $($ThisVM.thisParams.ActiveNode) to finish adding passive site server role"
            DependsOn = '[InstallADK]ADKInstall'
        }

        WaitForAll ActiveNode {
            ResourceName     = '[WriteStatus]Complete'
            NodeName         = $ThisVM.thisParams.ActiveNode
            RetryIntervalSec = 5
            RetryCount       = 6500
            DependsOn        = '[WriteStatus]WaitActive'
        }

        WriteStatus Complete {
            DependsOn = "[WaitForAll]ActiveNode"
            Status    = "Complete!"
        }

    }
}