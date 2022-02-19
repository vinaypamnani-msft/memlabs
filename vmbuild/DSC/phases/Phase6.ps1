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

    # Domain Creds
    [System.Management.Automation.PSCredential]$DomainCreds = New-Object System.Management.Automation.PSCredential ("${DomainName}\$($Admincreds.UserName)", $Admincreds.Password)
    [System.Management.Automation.PSCredential]$CMAdmin = New-Object System.Management.Automation.PSCredential ("${DomainName}\$DomainAdminName", $Admincreds.Password)


    Node $AllNodes.Where{ $_.Role -eq 'DC' }.NodeName
    {
        WriteStatus Complete {
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

            WriteStatus RunScriptWorkflow {
                Status = "Setting up ConfigMgr. Waiting for workflow to begin."
            }

            $nextDepend = "[WriteStatus]RunScriptWorkflow"

            WriteFileOnce CMSvc {
                FilePath  = "$LogPath\cm_svc.txt"
                Content   = $Admincreds.GetNetworkCredential().Password
                DependsOn = $nextDepend
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