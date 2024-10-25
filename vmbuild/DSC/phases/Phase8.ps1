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
        WriteStatus Complete {
            DependsOn = $nextDepend
            Status    = "Complete!"
        }
    }

    Node $AllNodes.Where{ $_.Role -eq 'SiteSystem' }.NodeName
    {
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
            ServerName           = $thisvm.VmName
            InstanceName         = $thisVM.sqlInstanceName
            #Credential       = $Admincreds
            SetFilePath          = $AgentJobSet
            TestFilePath         = $AgentJobTest
            GetFilePath          = $AgentJobGet
            DisableVariables     = $true
            Variable             = @('FilePath=C:\temp\')
            PsDscRunAsCredential =  $Admincreds
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
                RetryIntervalSec = 60
                RetryCount       = 300
                Dependson        = $nextDepend
            }
            $nextDepend = '[WaitForAll]WaitSCCM'
        }

        $AgentJobSet = "C:\staging\DSC\SQLScripts\Enable-AgentJob-Set.sql"

        WriteStatus EnableAgentJob {
            Status = "Enabling Agent Jobs"
        }

        SqlScript 'EnableAgentJob' {
            ServerName           = $thisvm.VmName
            InstanceName         = $thisVM.sqlInstanceName
            #Credential       = $Admincreds
            SetFilePath          = $AgentJobSet
            TestFilePath         = $AgentJobTest
            GetFilePath          = $AgentJobGet
            DisableVariables     = $true
            DependsOn            = $nextDepend
            Variable             = @('FilePath=C:\temp\')
            PsDscRunAsCredential =  $Admincreds
            Encrypt              = "Optional"
        }
        $nextDepend = '[SqlScript]EnableAgentJob'

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
                ExtFolder = $CM
                Ensure    = "Present"
                DependsOn = "[WriteStatus]WaitExtSchema"
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

        WriteStatus WaitPrimary {
            Status = "Waiting for Site Server $PSName to finish configuration."
        }

        WaitForEvent WaitPrimary {
            MachineName   = $PSName
            LogFolder     = $LogFolder
            FileName      = "ScriptWorkflow"
            ReadNode      = "ScriptWorkflow"
            ReadNodeValue = "Completed"
            Ensure        = "Present"
            DependsOn     = "[WriteStatus]WaitPrimary"
        }

        WriteEvent WriteConfigFinished {
            LogPath   = $LogPath
            WriteNode = "ConfigurationFinished"
            Status    = "Passed"
            Ensure    = "Present"
            DependsOn = "[WaitForEvent]WaitPrimary"
        }

        WriteStatus ODBCDriverInstall {
            DependsOn = "[WriteEvent]WriteConfigFinished"
            Status = "Downloading and installing ODBC driver version 18"
        }

        InstallODBCDriver ODBCDriverInstall {
            ODBCPath  = "C:\temp\msodbcsql.msi"
            Ensure    = "Present"
            DependsOn = "[WriteStatus]ODBCDriverInstall"
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
    [System.Management.Automation.PSCredential]$DomainCreds = New-Object System.Management.Automation.PSCredential ("${DomainName}\$($Admincreds.UserName)", $Admincreds.Password)
    [System.Management.Automation.PSCredential]$CMAdmin = New-Object System.Management.Automation.PSCredential ("${DomainName}\$DomainAdminName", $Admincreds.Password)

        WriteStatus ADKInstall {
            Status = "Downloading and installing ADK"
        }

        InstallADK ADKInstall {
            ADKPath      = "C:\temp\adksetup.exe"
            ADKWinPEPath = "c:\temp\adksetupwinpe.exe"
            ADKDownloadPath = "https://go.microsoft.com/fwlink/?linkid=2271337"
            ADKWinPEDownloadPath = "https://go.microsoft.com/fwlink/?linkid=2271338"   
            Ensure       = "Present"
            DependsOn    = "[WriteStatus]ADKInstall"
        }

        $nextDepend = "[InstallADK]ADKInstall"

        WriteStatus ODBCDriverInstall {
            DependsOn = $nextDepend
            Status = "Downloading and installing ODBC driver version 18"
        }

        InstallODBCDriver ODBCDriverInstall {
            ODBCPath  = "C:\temp\msodbcsql.msi"
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

        WriteStatus Complete {
            DependsOn = "[WaitForEvent]WorkflowComplete"
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
            ADKPath      = "C:\temp\adksetup.exe"
            ADKWinPEPath = "c:\temp\adksetupwinpe.exe"
            Ensure       = "Present"
            DependsOn    = "[WriteStatus]ADKInstall"
        }

        WriteStatus WaitActive {
            Status    = "Waiting for $($ThisVM.thisParams.ActiveNode) to finish adding passive site server role"
            Dependson = '[InstallADK]ADKInstall'
        }

        WaitForAll ActiveNode {
            ResourceName     = '[WriteStatus]Complete'
            NodeName         = $ThisVM.thisParams.ActiveNode
            RetryIntervalSec = 15
            RetryCount       = 1200
            Dependson        = '[WriteStatus]WaitActive'
        }

        WriteStatus Complete {
            DependsOn = "[WaitForAll]ActiveNode"
            Status    = "Complete!"
        }

    }
}