# ScriptWorkflow.ps1
param(
    [string]$ConfigFilePath,
    [string]$LogPath
)

# dot source functions
. $PSScriptRoot\ScriptFunctions.ps1


Write-DscStatus "ScriptWorkflow.ps1 called with $ConfigFilePath and $LogPath)"

# Read required items from config json
$deployConfig = Get-Content $ConfigFilePath | ConvertFrom-Json
$ThisVM = $deployConfig.virtualMachines | where-object { $_.vmName -eq $deployconfig.Parameters.ThisMachineName }
$CurrentRole = $ThisVM.role

$scenario = "Standalone"
if ($ThisVM.role -eq "CAS" -or $ThisVM.parentSiteCode) { $scenario = "Hierarchy" }

$TopLevelSiteServer = $true
if ($ThisVM.parentSiteCode) {
    $TopLevelSiteServer = $false
}
# contains passive?
$containsPassive = $false
$containsSecondary = $false

if ($CurrentRole -eq "Primary" -and $ThisVM.hidden -and ($ThisVM.domain) -and ($ThisVm.domain -ne $deployConfig.vmOptions.DomainName)) {
    $scenario = "MultiDomain"
    Write-DscStatus "Multi Domain Scenerio"
}
else {
    # contains passive?
    $containsPassive = $deployConfig.virtualMachines | Where-Object { $_.role -eq "PassiveSite" -and $_.siteCode -eq $ThisVM.siteCode }
    $containsSecondary = $deployConfig.virtualMachines | Where-Object { $_.role -eq "Secondary" -and $_.parentSiteCode -eq $ThisVM.siteCode }
}


# Script Workflow json file
$ConfigurationFile = Join-Path -Path $LogPath -ChildPath "ScriptWorkflow.json"
$firstRun = $true

if (Test-Path -Path $ConfigurationFile) {
    $Configuration = Get-Content -Path $ConfigurationFile | ConvertFrom-Json
    $firstRun = $false
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
                ScriptWorkflow = @{
                    Status    = 'NotStart'
                    StartTime = ''
                    EndTime   = ''
                }
            }
            $psvms = $deployConfig.VirtualMachines | Where-Object { $_.Role -eq "Primary" -and ($_.ParentSiteCode -eq $thisVM.SiteCode) }
            foreach ($psvm in $psvms) {
                $PSReadytoUse = @{
                    Status    = 'NotStart'
                    StartTime = ''
                    EndTime   = ''
                }
                $propName = propName = "PSReadyToUse" + $psvm.VmName
                $Actions.Add($propName, $PSReadytoUse)
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

    if ($containsSecondary) {
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

if (-not $Configuration.InstallSUP) {
    $item = [PSCustomObject]@{
        Status    = 'NotStart'
        StartTime = ''
        EndTime   = ''
    }
    $Configuration | Add-Member -MemberType NoteProperty -Name "InstallSUP" -Value $item
}

$Configuration.ScriptWorkflow.Status = "Running"
$Configuration.ScriptWorkflow.StartTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
$Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force

# Force AD Replication
$domainControllers = Get-ADDomainController -Filter *
if ($domainControllers.Count -gt 1) {
    Write-DscStatus "Forcing AD Replication on $($domainControllers.Name -join ', ')"
    $domainControllers.Name | Foreach-Object { repadmin /syncall $_ (Get-ADDomain).DistinguishedName /AdeP }
    Start-Sleep -Seconds 3
}

if ($scenario -eq "MultiDomain") {
    Write-DscStatus "$scenario Running InstallMultiDomainPKI.ps1"
    $ScriptFile = Join-Path -Path $PSScriptRoot -ChildPath "InstallMultiDomainPKI.ps1"
    Set-Location $LogPath
    . $ScriptFile $ConfigFilePath $LogPath

    $Configuration = Get-Content -Path $ConfigurationFile | ConvertFrom-Json
    $Configuration.ScriptWorkflow.Status = "Completed"
    $Configuration.ScriptWorkflow.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
    $Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force
    Write-DscStatus "Complete!"
    return
}

if ($scenario -eq "Standalone") {

    #Install CM and Config
    Write-DscStatus "$scenario Running InstallAndUpdateSCCM.ps1"
    $ScriptFile = Join-Path -Path $PSScriptRoot -ChildPath "InstallAndUpdateSCCM.ps1"
    Set-Location $LogPath
    . $ScriptFile $ConfigFilePath $LogPath

    #Install DP/MP/Client - Run before secondary so MP can be installed on sitesytems
    Write-DscStatus "$scenario Running InstallDPMPClient.ps1"
    $ScriptFile = Join-Path -Path $PSScriptRoot -ChildPath "InstallDPMPClient.ps1"
    Set-Location $LogPath
    . $ScriptFile $ConfigFilePath $LogPath

    if ($containsSecondary) {
        # Install Secondary Site Server. Run before InstallBoundaryGroups.ps1, so it can create proper BGs
        Write-DscStatus "$scenario Running InstallSecondarySiteServer.ps1"
        $ScriptFile = Join-Path -Path $PSScriptRoot -ChildPath "InstallSecondarySiteServer.ps1"
        Set-Location $LogPath
        . $ScriptFile $ConfigFilePath $LogPath
    }

    #Install BGs
    Write-DscStatus "$scenario Running InstallBoundaryGroups.ps1"
    $ScriptFile = Join-Path -Path $PSScriptRoot -ChildPath "InstallBoundaryGroups.ps1"
    Set-Location $LogPath
    . $ScriptFile $ConfigFilePath $LogPath
   

    Write-DscStatus "$scenario Running InstallRoles.ps1"
    $ScriptFile = Join-Path -Path $PSScriptRoot -ChildPath "InstallRoles.ps1"
    Set-Location $LogPath
    . $ScriptFile $ConfigFilePath $LogPath

}

if ($scenario -eq "Hierarchy") {

    if ($CurrentRole -eq "CAS") {

        #Install CM and Config
        Write-DscStatus "$scenario Running InstallAndUpdateSCCM.ps1"
        $ScriptFile = Join-Path -Path $PSScriptRoot -ChildPath "InstallAndUpdateSCCM.ps1"
        Set-Location $LogPath
        . $ScriptFile $ConfigFilePath $LogPath

        Write-DscStatus "$scenario Running InstallRoles.ps1"
        $ScriptFile = Join-Path -Path $PSScriptRoot -ChildPath "InstallRoles.ps1"
        Set-Location $LogPath
        . $ScriptFile $ConfigFilePath $LogPath

    }
    elseif ($CurrentRole -eq "Primary") {

        #Install CM and Config
        if (-not [string]::IsNullOrWhiteSpace($($ThisVM.thisParams.ParentSiteServer))) {
            Write-DscStatus "$scenario Running InstallPSForHierarchy.ps1"
            $ScriptFile = Join-Path -Path $PSScriptRoot -ChildPath "InstallPSForHierarchy.ps1"
            Set-Location $LogPath
            . $ScriptFile $ConfigFilePath $LogPath
        }

        #Install DP/MP/Client - Run before secondary so MP can be installed on sitesytems
        Write-DscStatus "$scenario Running InstallDPMPClient.ps1"
        $ScriptFile = Join-Path -Path $PSScriptRoot -ChildPath "InstallDPMPClient.ps1"
        Set-Location $LogPath
        . $ScriptFile $ConfigFilePath $LogPath
               
        if ($containsSecondary) {
            # Install Secondary Site Server. Run before InstallBoundaryGroups.ps1, so it can create proper BGs
            Write-DscStatus "$scenario Running InstallSecondarySiteServer.ps1"
            $ScriptFile = Join-Path -Path $PSScriptRoot -ChildPath "InstallSecondarySiteServer.ps1"
            Set-Location $LogPath
            . $ScriptFile $ConfigFilePath $LogPath
        }

        #Install DP/MP/Client
        Write-DscStatus "$scenario Running InstallBoundaryGroups.ps1"
        $ScriptFile = Join-Path -Path $PSScriptRoot -ChildPath "InstallBoundaryGroups.ps1"
        Set-Location $LogPath
        . $ScriptFile $ConfigFilePath $LogPath

        Write-DscStatus "$scenario Running InstallRoles.ps1"
        $ScriptFile = Join-Path -Path $PSScriptRoot -ChildPath "InstallRoles.ps1"
        Set-Location $LogPath
        . $ScriptFile $ConfigFilePath $LogPath


    }
}

if ($containsPassive) {
    # Install Passive Site Server
    Write-DscStatus "ContainsPassive Running InstallPassiveSiteServer.ps1"
    $ScriptFile = Join-Path -Path $PSScriptRoot -ChildPath "InstallPassiveSiteServer.ps1"
    Set-Location $LogPath
    . $ScriptFile $ConfigFilePath $LogPath
}


Write-DscStatus "Finished setting up ConfigMgr. Running Additional Tasks"
if ($CurrentRole -eq "CAS") {
    #If we are on the CAS, we can mark this early, to allow the primary to start while we run other tasks.
# Mark ScriptWorkflow completed for DSC to move on.
$Configuration = Get-Content -Path $ConfigurationFile | ConvertFrom-Json
$Configuration.ScriptWorkflow.Status = "Completed"
$Configuration.ScriptWorkflow.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
$Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force

}


if (-not $deployConfig.cmOptions.UsePKI) {
    # Enable E-HTTP. This takes time on new install because SSLState flips, so start the script but don't monitor.
    Write-DscStatus "Not UsePKI Running EnableEHTTP.ps1"
    $ScriptFile = Join-Path -Path $PSScriptRoot -ChildPath "EnableEHTTP.ps1"
    . $ScriptFile $ConfigFilePath $LogPath $firstRun
}
else {
    Write-DscStatus "UsePKI Running EnableHTTPS.ps1"
    $ScriptFile = Join-Path -Path $PSScriptRoot -ChildPath "EnableHTTPS.ps1"
    . $ScriptFile $ConfigFilePath $LogPath $firstRun
}

if ($TopLevelSiteServer) {
    Write-DScStatus "Loading object pre-population for MEMLABS"
    $ScriptFile = Join-Path -Path $PSScriptRoot -ChildPath "Perfloading.ps1"
    Set-Location $LogPath
    . $ScriptFile $ConfigFilePath $LogPath

}

# Mark ScriptWorkflow completed for DSC to move on.
$Configuration = Get-Content -Path $ConfigurationFile | ConvertFrom-Json
$Configuration.ScriptWorkflow.Status = "Completed"
$Configuration.ScriptWorkflow.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"
$Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force
Write-DscStatus "Complete!"

if ($ThisVM.role -ne "CAS") {
    Write-DscStatus "Always Running PushClients.ps1"
    $ScriptFile = Join-Path -Path $PSScriptRoot -ChildPath "PushClients.ps1"
    Set-Location $LogPath
    . $ScriptFile $ConfigFilePath $LogPath
    Write-DscStatus "Complete!"
}


