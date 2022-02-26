param(
    [string]$ConfigFilePath,
    [string]$LogPath
)

# dot source functions
. $PSScriptRoot\ScriptFunctions.ps1

# Read required items from config json
$deployConfig = Get-Content $ConfigFilePath | ConvertFrom-Json
$scenario = $deployConfig.parameters.Scenario

$ThisVM = $deployConfig.virtualMachines | where-object { $_.vmName -eq $deployconfig.Parameters.ThisMachineName }
$CurrentRole = $ThisVM.role

# contains passive?
$containsPassive = $deployConfig.virtualMachines | Where-Object { $_.role -eq "PassiveSite" -and $_.siteCode -eq $ThisVM.siteCode }
$containsSecondary = $deployConfig.virtualMachines | Where-Object { $_.role -eq "Secondary" -and $_.parentSiteCode -eq $ThisVM.siteCode }

# Script Workflow json file
$ConfigurationFile = Join-Path -Path $LogPath -ChildPath "ScriptWorkflow.json"

if (Test-Path -Path $ConfigurationFile) {
    $Configuration = Get-Content -Path $ConfigurationFile | ConvertFrom-Json
}
if (-not ($configuration.ScriptWorkflow)) {
    $Configuration = $null
}
if (-not $Configuration) {
    if ($scenario -eq "Standalone") {
        [hashtable]$Actions = @{
            InstallSCCM    = @{
                Status    = 'NotStart'
                StartTime = ''
                EndTime   = ''
            }
            UpgradeSCCM    = @{
                Status    = 'NotStart'
                StartTime = ''
                EndTime   = ''
            }
            InstallDP      = @{
                Status    = 'NotStart'
                StartTime = ''
                EndTime   = ''
            }
            InstallMP      = @{
                Status    = 'NotStart'
                StartTime = ''
                EndTime   = ''
            }
            InstallClient  = @{
                Status    = 'NotStart'
                StartTime = ''
                EndTime   = ''
            }
            ScriptWorkflow = @{
                Status    = 'NotStart'
                StartTime = ''
                EndTime   = ''
            }
        }
    }

    if ($scenario -eq "Hierarchy") {
        if ($CurrentRole -eq "CAS") {
            [hashtable]$Actions = @{
                InstallSCCM    = @{
                    Status    = 'NotStart'
                    StartTime = ''
                    EndTime   = ''
                }
                UpgradeSCCM    = @{
                    Status    = 'NotStart'
                    StartTime = ''
                    EndTime   = ''
                }
                PSReadytoUse   = @{
                    Status    = 'NotStart'
                    StartTime = ''
                    EndTime   = ''
                }
                ScriptWorkflow = @{
                    Status    = 'NotStart'
                    StartTime = ''
                    EndTime   = ''
                }
            }
        }
        elseif ($CurrentRole -eq "Primary") {
            [hashtable]$Actions = @{
                WaitingForCASFinsihedInstall = @{
                    Status    = 'NotStart'
                    StartTime = ''
                    EndTime   = ''
                }
                InstallSCCM                  = @{
                    Status    = 'NotStart'
                    StartTime = ''
                    EndTime   = ''
                }
                InstallDP                    = @{
                    Status    = 'NotStart'
                    StartTime = ''
                    EndTime   = ''
                }
                InstallMP                    = @{
                    Status    = 'NotStart'
                    StartTime = ''
                    EndTime   = ''
                }
                InstallClient                = @{
                    Status    = 'NotStart'
                    StartTime = ''
                    EndTime   = ''
                }
                ScriptWorkflow               = @{
                    Status    = 'NotStart'
                    StartTime = ''
                    EndTime   = ''
                }
            }
        }
    }

    if ($containsPassive) {
        $Actions += @{
            InstallPassive = @{
                Status    = 'NotStart'
                StartTime = ''
                EndTime   = ''
            }
        }
    }

    if ($containsPassive) {
        $Actions += @{
            InstallSecondary = @{
                Status    = 'NotStart'
                StartTime = ''
                EndTime   = ''
            }
        }
    }

    $Configuration = New-Object -TypeName psobject -Property $Actions
}

$Configuration.ScriptWorkflow.Status = "Running"
$Configuration.ScriptWorkflow.StartTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
$Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force

if ($scenario -eq "Standalone") {

    #Install CM and Config
    $ScriptFile = Join-Path -Path $PSScriptRoot -ChildPath "InstallAndUpdateSCCM.ps1"
    . $ScriptFile $ConfigFilePath $LogPath

    if ($containsSecondary) {
        # Install Secondary Site Server. Run before InstallDPMPClient.ps1, so it can create proper BGs
        $ScriptFile = Join-Path -Path $PSScriptRoot -ChildPath "InstallSecondarySiteServer.ps1"
        . $ScriptFile $ConfigFilePath $LogPath
    }

    #Install DP/MP/Client
    $ScriptFile = Join-Path -Path $PSScriptRoot -ChildPath "InstallDPMPClient.ps1"
    . $ScriptFile $ConfigFilePath $LogPath

}

if ($scenario -eq "Hierarchy") {

    if ($CurrentRole -eq "CAS") {

        #Install CM and Config
        $ScriptFile = Join-Path -Path $PSScriptRoot -ChildPath "InstallAndUpdateSCCM.ps1"
        . $ScriptFile $ConfigFilePath $LogPath

    }
    elseif ($CurrentRole -eq "Primary") {

        #Install CM and Config
        $ScriptFile = Join-Path -Path $PSScriptRoot -ChildPath "InstallPSForHierarchy.ps1"
        . $ScriptFile $ConfigFilePath $LogPath

        if ($containsSecondary) {
            # Install Secondary Site Server. Run before InstallDPMPClient.ps1, so it can create proper BGs
            $ScriptFile = Join-Path -Path $PSScriptRoot -ChildPath "InstallSecondarySiteServer.ps1"
            . $ScriptFile $ConfigFilePath $LogPath
        }

        #Install DP/MP/Client
        $ScriptFile = Join-Path -Path $PSScriptRoot -ChildPath "InstallDPMPClient.ps1"
        . $ScriptFile $ConfigFilePath $LogPath
    }
}

if ($containsPassive) {
    # Install Passive Site Server
    $ScriptFile = Join-Path -Path $PSScriptRoot -ChildPath "InstallPassiveSiteServer.ps1"
    . $ScriptFile $ConfigFilePath $LogPath
}

Write-DscStatus "Finished setting up ConfigMgr."

# Mark ScriptWorkflow completed for DSC to move on.
$Configuration = Get-Content -Path $ConfigurationFile | ConvertFrom-Json
$Configuration.ScriptWorkflow.Status = "Completed"
$Configuration.ScriptWorkflow.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
$Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force

# Enable E-HTTP. This takes time on new install because SSLState flips, so start the script but don't monitor.
$ScriptFile = Join-Path -Path $PSScriptRoot -ChildPath "EnableEHTTP.ps1"
. $ScriptFile $ConfigFilePath $LogPath