Param($ConfigFilePath, $LogFolder)

#Param($DomainFullName,$CM,$CMUser,$DPMPName,$ClientName,$Config,$CurrentRole,$LogFolder,$CSName,$PSName)
#ScriptArgument = "$DomainName $CM $DName\admin $DPMPName $Clients $Configuration $CurrentRole $LogFolder $CSName $PSName"

function Write-DscStatusSetup {
    $StatusPrefix = "Setting up ConfigMgr. See ConfigMgrSetup.log"
    $StatusFile = "C:\staging\DSC\DSC_Status.txt"
    $StatusPrefix | Out-File $StatusFile -Force
}

function Write-DscStatus {
    param($status)
    $StatusPrefix = "Setting up ConfigMgr."
    $StatusFile = "C:\staging\DSC\DSC_Status.txt"
    "$StatusPrefix Current Status: $status" | Out-File $StatusFile -Force
}

$deployConfig = Get-Content $ConfigFilePath | ConvertFrom-Json
$Config = $deployConfig.parameters.Scenario
$CurrentRole = $deployConfig.parameters.ThisMachineRole

$ThisMachineName = $deployConfig.parameters.ThisMachineName
$ThisVM = $deployConfig.virtualMachines | Where-Object { $_.vmName -eq $ThisMachineName }

if ($ThisVM.siteCode) {
    $SiteCode = $ThisVM.siteCode
}
else {
    Write-DscStatus "SiteCode not found."
    return
}

$ProvisionToolPath = "$env:windir\temp\ProvisionScript"
if(!(Test-Path $ProvisionToolPath))
{
    New-Item $ProvisionToolPath -ItemType directory | Out-Null
}

$ConfigurationFile = Join-Path -Path $ProvisionToolPath -ChildPath "$SiteCode.json"

if (Test-Path -Path $ConfigurationFile)
{
    $Configuration = Get-Content -Path $ConfigurationFile | ConvertFrom-Json
}
else
{
    if($Config -eq "Standalone")
    {
        [hashtable]$Actions = @{
            InstallSCCM = @{
                Status = 'NotStart'
                StartTime = ''
                EndTime = ''
            }
            UpgradeSCCM = @{
                Status = 'NotStart'
                StartTime = ''
                EndTime = ''
            }
            InstallDP = @{
                Status = 'NotStart'
                StartTime = ''
                EndTime = ''
            }
            InstallMP = @{
                Status = 'NotStart'
                StartTime = ''
                EndTime = ''
            }
            InstallClient = @{
                Status = 'NotStart'
                StartTime = ''
                EndTime = ''
            }
        }
    }
    else
    {
        if($CurrentRole -eq "CS")
        {
            [hashtable]$Actions = @{
                InstallSCCM = @{
                    Status = 'NotStart'
                    StartTime = ''
                    EndTime = ''
                }
                UpgradeSCCM = @{
                    Status = 'NotStart'
                    StartTime = ''
                    EndTime = ''
                }
                PSReadytoUse = @{
                    Status = 'NotStart'
                    StartTime = ''
                    EndTime = ''
                }
            }
        }
        elseif($CurrentRole -eq "PS")
        {
            [hashtable]$Actions = @{
                WaitingForCASFinsihedInstall = @{
                    Status = 'NotStart'
                    StartTime = ''
                    EndTime = ''
                }
                InstallSCCM = @{
                    Status = 'NotStart'
                    StartTime = ''
                    EndTime = ''
                }
                InstallDP = @{
                    Status = 'NotStart'
                    StartTime = ''
                    EndTime = ''
                }
                InstallMP = @{
                    Status = 'NotStart'
                    StartTime = ''
                    EndTime = ''
                }
                InstallClient = @{
                    Status = 'NotStart'
                    StartTime = ''
                    EndTime = ''
                }
            }
        }
    }
    $Configuration = New-Object -TypeName psobject -Property $Actions
    $Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force
}

if($Config -eq "Standalone")
{
    #Install CM and Config
    $ScriptFile = Join-Path -Path $ProvisionToolPath -ChildPath "InstallAndUpdateSCCM.ps1"
    . $ScriptFile $ConfigFilePath $ProvisionToolPath

    #Install DP
    $ScriptFile = Join-Path -Path $ProvisionToolPath -ChildPath "InstallDP.ps1"
    . $ScriptFile $ConfigFilePath $ProvisionToolPath

    #Install MP
    $ScriptFile = Join-Path -Path $ProvisionToolPath -ChildPath "InstallMP.ps1"
    . $ScriptFile $ConfigFilePath $ProvisionToolPath

    #Install Client
    $ScriptFile = Join-Path -Path $ProvisionToolPath -ChildPath "InstallClient.ps1"
    . $ScriptFile $ConfigFilePath $ProvisionToolPath

}
else {
    if($CurrentRole -eq "CS")
    {
        #Install CM and Config
        $ScriptFile = Join-Path -Path $ProvisionToolPath -ChildPath "InstallCSForHierarchy.ps1"
        . $ScriptFile $DomainFullName $CM $CMUser $SiteCode $ProvisionToolPath $LogFolder $PSName $PSRole

    }
    elseif($CurrentRole -eq "PS")
    {
        #Install CM and Config
        $ScriptFile = Join-Path -Path $ProvisionToolPath -ChildPath "InstallPSForHierarchy.ps1"
        . $ScriptFile $DomainFullName $CM $CMUser $SiteCode $ProvisionToolPath $CSName $CSRole $LogFolder

        #Install DP
        $ScriptFile = Join-Path -Path $ProvisionToolPath -ChildPath "InstallDP.ps1"
        . $ScriptFile $DomainFullName $DPMPName $SiteCode $ProvisionToolPath

        #Install MP
        $ScriptFile = Join-Path -Path $ProvisionToolPath -ChildPath "InstallMP.ps1"
        . $ScriptFile $DomainFullName $DPMPName $SiteCode $ProvisionToolPath

        if ($PushClients) {
            #Install Client
            $ScriptFile = Join-Path -Path $ProvisionToolPath -ChildPath "InstallClient.ps1"
            . $ScriptFile $DomainFullName $CMUser $ClientName $DPMPName $SiteCode $ProvisionToolPath
        }
    }
}

Write-DscStatus "Finished setting up ConfigMgr."
"Finished!" | Out-File "C:\staging\DSC\ScriptWorkflow.txt" -Force