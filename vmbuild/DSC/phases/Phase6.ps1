Configuration Phase6
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
    $DomainName = $deployConfig.parameters.domainName
    $DomainAdminName = $deployConfig.vmOptions.adminName

    # Log share
    $LogFolder = "DSC"
    $LogPath = "c:\staging\$LogFolder"

    # CM Share Folder
    $CM = if ($deployConfig.cmOptions.version -eq "tech-preview") { "CMTP" } else { "CMCB" }

    # Domain Creds
    [System.Management.Automation.PSCredential]$DomainCreds = New-Object System.Management.Automation.PSCredential ("${DomainName}\$($Admincreds.UserName)", $Admincreds.Password)
    [System.Management.Automation.PSCredential]$CMAdmin = New-Object System.Management.Automation.PSCredential ("${DomainName}\$DomainAdminName", $Admincreds.Password)

    Node $AllNodes.Where{ $_.Role -eq 'DC' }.NodeName
    {
        $ThisVM = $deployConfig.virtualMachines | Where-Object { $_.vmName -eq $node.NodeName }
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

        WriteStatus WaitExtSchema {
            DependsOn = $waitOnDependency
            Status    = "Waiting for site to download ConfigMgr source files, before extending schema for Configuration Manager"
        }

        WaitForExtendSchemaFile WaitForExtendSchemaFile {
            MachineName = if ($CSName) { $CSName } else { $PSName }
            ExtFolder   = $CM
            Ensure      = "Present"
            DependsOn   = "[WriteStatus]WaitExtSchema"
        }

        WriteStatus Complete {
            DependsOn = "[WaitForExtendSchemaFile]WaitForExtendSchemaFile"
            Status    = "Complete!"
        }
    }


    Node $AllNodes.Where{ $_.Role -eq "Secondary" }.NodeName
    {
        #$PSName = $deployConfig.thisParams.PrimarySiteServer.vmName

        $ParentSiteCode = ($deployConfig.virtualMachines | where-object { $_.vmName -eq ($Node.NodeName) }).ParentSiteCode
        $PSName = ($deployConfig.virtualMachines | where-object { $_.Role -eq "Primary" -and $_.SiteCode -eq $ParentSiteCode }).vmName

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

        WriteStatus Complete {
            DependsOn = "[WaitForEvent]WaitPrimary"
            Status    = "Complete!"
        }

        WriteEvent WriteConfigFinished {
            LogPath   = $LogPath
            WriteNode = "ConfigurationFinished"
            Status    = "Passed"
            Ensure    = "Present"
            DependsOn = "[WriteStatus]Complete"
        }
    }

    Node $AllNodes.Where{ $_.Role -eq 'CAS' -or $_.Role -eq "Primary" }.NodeName
    {
        $ThisMachineName = $Node.NodeName
        $ThisVM = $deployConfig.virtualMachines | Where-Object { $_.vmName -eq $node.NodeName }

        WriteStatus Setup {
            Status = "Setting up Configuration Manager."
        }

        $nextDepend = "[WriteStatus]Setup"
        if (-not $ThisVM.thisParams.ParentSiteServer) {

            $CMDownloadStatus = "Downloading Configuration Manager current branch (latest baseline version)"
            if ($CM -eq "CMTP") {
                $CMDownloadStatus = "Downloading Configuration Manager technical preview"
            }

            WriteStatus DownLoadSCCM {
                DependsOn = $nextDepend
                Status    = $CMDownloadStatus
            }

            DownloadSCCM DownLoadSCCM {
                CM        = $CM
                Ensure    = "Present"
                DependsOn = "[WriteStatus]DownLoadSCCM"
            }
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
            TaskName       = "ScriptWorkFlow"
            ScriptName     = "ScriptWorkFlow.ps1"
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
}