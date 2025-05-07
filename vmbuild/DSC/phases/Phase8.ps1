Configuration Phase8
{
    param
    (
        [Parameter(Mandatory)]
        [string]$DeployConfigPath,
        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$Admincreds
    )

    Import-DscResource -ModuleName 'PSDesiredStateConfiguration', 'TemplateHelpDSC', 'ActiveDirectoryDsc', 'ComputerManagementDsc', 'xFailOverCluster', 'AccessControlDsc', 'SqlServerDsc'

    # Read config
    $deployConfig = Get-Content -Path $DeployConfigPath | ConvertFrom-Json


    $DomainAdminName = $deployConfig.vmOptions.adminName

    # Log share
    $LogFolder = "DSC"
    $LogPath = "c:\staging\$LogFolder"

    # CM Share Folder
    $CM = if ($deployConfig.cmOptions.version -eq "tech-preview") { "CMTP" } else { "CMCB" }

    # Domain Creds
    $DomainName = $deployConfig.parameters.domainName
    [System.Management.Automation.PSCredential]$DomainCreds = New-Object System.Management.Automation.PSCredential ("${DomainName}\$($Admincreds.UserName)", $Admincreds.Password)
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
            Dependson         = $nextDepend
        }
        $nextDepend = "[NTFSAccessEntry]PMPCApps"

        SmbShare "PMPCShare" {
            Name                  = "PMPCApps"
            Path                  = 'E:\PMPCApps'
            #Ensure                = "Present"
            Description           = "Share for PMPC Apps"
            #FolderEnumerationMode = 'Unrestricted'
            FullAccess            = "Everyone"
            #ReadAccess            = "Everyone"
            DependsOn             = $nextDepend
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
                    RetryIntervalSec = 15
                    RetryCount       = 2400
                    Dependson        = $nextDepend
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
                DependsOn = $nextDepend
                Path      = "C:\temp\pmpc.msi"
                URL       = $deployConfig.URLS.PMPC
                SiteCode  = $ThisVM.Sitecode
                SqlServer = $SqlServer
                SiteServer = $serverToWait.VmName
                FileServer = $ThisVM.PatchMyPCFileServer
                Ensure    = "Present"
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
        [System.Management.Automation.PSCredential]$DomainCreds = New-Object System.Management.Automation.PSCredential ("${DomainName}\$($Admincreds.UserName)", $Admincreds.Password)
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
                RetryIntervalSec = 15
                RetryCount       = 2400
                Dependson        = $nextDepend
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
            #Credential       = $Admincreds
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
        [System.Management.Automation.PSCredential]$DomainCreds = New-Object System.Management.Automation.PSCredential ("${DomainName}\$($Admincreds.UserName)", $Admincreds.Password)
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
            WriteStatus WaitExtSchema {
                DependsOn = $nextDepend
                Status    = "Waiting for site to download ConfigMgr source files, before extending schema for Configuration Manager"
            }

            WaitForExtendSchemaFile WaitForExtendSchemaFile {
                MachineName = if ($CSName) { $CSName } else { $PSName }
                ExtFolder   = $CM
                Ensure      = "Present"
                DependsOn   = "[WriteStatus]WaitExtSchema"
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
        [System.Management.Automation.PSCredential]$DomainCreds = New-Object System.Management.Automation.PSCredential ("${DomainName}\$($Admincreds.UserName)", $Admincreds.Password)
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

        WriteEvent WriteConfigFinished {
            LogPath   = $LogPath
            WriteNode = "ConfigurationFinished"
            Status    = "Passed"
            Ensure    = "Present"
            DependsOn = "[WaitForEvent]WaitPrimary"
        }

        WriteStatus Complete {
            DependsOn = "[InstallODBCDriver]ODBCDriverInstall"
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

            WriteStatus DownLoadSCCM {
                DependsOn = $nextDepend
                Status    = $CMDownloadStatus
            }

            DownloadSCCM DownLoadSCCM {
                CM            = $CM
                CMDownloadUrl = $ThisVM.thisParams.cmDownloadVersion.downloadUrl
                Ensure        = "Present"
                DependsOn     = "[WriteStatus]DownLoadSCCM"
            }

            FileReadAccessShare CMSourceSMBShare {
                Name      = $CM
                Path      = "c:\$CM"
                DependsOn = "[DownLoadSCCM]DownLoadSCCM"
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
                DependsOn = $nextDepend
                Path      = "C:\temp\pmpc.msi"
                URL       = $deployConfig.URLS.PMPC
                Ensure    = "Present"
                SiteCode  = $ThisVM.Sitecode
                SqlServer = $SqlServer
                SiteServer = $ThisVM.VmName
                FileServer = $ThisVM.PatchMyPCFileServer
            }
            $nextDepend = '[InstallPMPC]InstallPMPC'
            WriteStatus RebootNow {
                Status    = "Rebooting to get Finalize PMPC"
                DependsOn = $nextDepend
            }

            RebootNow RebootNow {
                FileName  = 'C:\Temp\PMPCReboot.txt'
                DependsOn = $nextDepend
            }
            $nextDepend = "[RebootNow]RebootNow"
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
        [System.Management.Automation.PSCredential]$DomainCreds = New-Object System.Management.Automation.PSCredential ("${DomainName}\$($Admincreds.UserName)", $Admincreds.Password)
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
            Dependson = '[InstallADK]ADKInstall'
        }

        WaitForAll ActiveNode {
            ResourceName     = '[WriteStatus]Complete'
            NodeName         = $ThisVM.thisParams.ActiveNode
            RetryIntervalSec = 25
            RetryCount       = 1300
            Dependson        = '[WriteStatus]WaitActive'
        }

        WriteStatus Complete {
            DependsOn = "[WaitForAll]ActiveNode"
            Status    = "Complete!"
        }

    }
}