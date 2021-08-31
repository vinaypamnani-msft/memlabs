param (    
    [Parameter(Mandatory=$true, HelpMessage="Lab Configuration: Standalone, Hierarchy, SingleMachine.")]
    [string]$Configuration,
    [Parameter(Mandatory=$false, HelpMessage="Dry Run.")]
    [switch]$WhatIf
)

# Dot source common
. $PSScriptRoot\Common.ps1

# Validate token exists
if ($Common.FatalError) {
    Write-Log "Main: Critical Failure! $($Common.FatalError)" -Failure
    return
}

function Write-JobProgress
{
    param($Job)
 
    #Make sure the first child job exists
    if($null -ne $Job.ChildJobs[0].Progress)
    {
        #Extracts the latest progress of the job and writes the progress
        $jobProgressHistory = $Job.ChildJobs[0].Progress;
        $latestProgress = $jobProgressHistory[$jobProgressHistory.Count - 1];
        $latestPercentComplete = $latestProgress | Select-Object -expand PercentComplete;
        $latestActivity = $latestProgress | Select-Object -expand Activity;
        $latestStatus = $latestProgress | Select-Object -expand StatusDescription;
        $jobName = $job.Name

        if ($latestActivity -and $latestStatus) {
            #When adding multiple progress bars, a unique ID must be provided. Here I am providing the JobID as this
            Write-Progress -Id $Job.Id -Activity "$jobName`: $latestActivity" -Status $latestStatus -PercentComplete $latestPercentComplete;
        }
    }
}

#Clear-Host
Write-Host
Write-Host 
Write-Host 
Write-Host 
Write-Host 
Write-Host 
Write-Host 

# Timer
Write-Log "### START." -Success
Write-Host 
Write-Log "Main: Creating virtual machines for specified configuration: $Configuration" -Activity

$timer = New-Object -TypeName System.Diagnostics.Stopwatch
$timer.Start()

$configPath = Join-Path $Common.ConfigPath "$Configuration.json"

if (-not (Test-Path $configPath)) {
    Write-Log "Main: $configPath not found for specified configuration. Please create the config, and try again."
    return
}
else {
    Write-Log "Main: $configPath will be used for creating the lab environment."    
}

$jsonConfig = Get-Content -Path $configPath | ConvertFrom-Json

$jobs = @()

$createVms = {
    Param(
        [string]$cmVersion,
        [string]$roleName,
        [System.Management.Automation.PSCredential] $adminCreds
    )

    # Dot source common
    . $using:PSScriptRoot\Common.ps1

    # Get required variables from parent scope
    $cmVersion = $using:cmVersion
    $currentItem = $using:currentItem
    $jsonConfig = $using:jsonConfig    

    # TODO: Add Validation here
    if ($cmVersion -eq "current-branch") {$SwitchName = "InternalSwitchCB1"} else { $SwitchName = "InternalSwitchTP1"}
    $imageFile = $Common.ImageList.Files | Where-Object {$_.id -eq $currentItem.operatingSystem }
    $vhdxPath = Join-Path $Common.GoldImagePath $imageFile.filename
    $virtualMachinePath = "E:\VirtualMachines"

    # Create VM
    New-VirtualMachine -VmName $currentItem.vmName -VmPath $virtualMachinePath -SourceDiskPath $vhdxPath -Memory $currentItem.hardware.memory -Generation $currentItem.hardware.generation -Processors $currentItem.hardware.virtualProcs -SwitchName $SwitchName -WhatIf:$using:WhatIf
    
    # Wait for VM to finish OOBE
    $connected = Wait-ForVm -VmName $currentItem.vmName -OobeComplete -WhatIf:$using:WhatIf
    if (-not $connected) {
        Write-Log "Main: Could not verify if $($currentItem.vmName) completed OOBE." -Failure
        return
    }

    # Copy DSC files    
    $ps = New-PSSession -VMName $currentItem.vmName -Credential $Common.LocalAdmin -ErrorVariable Err1 -ErrorAction SilentlyContinue
    Copy-Item -ToSession $ps -Path "$using:PSScriptRoot\DSC" -Destination "C:\staging" -Recurse -Container -Force

    # Extract DSC modules
    Invoke-VmCommand -VmName $currentItem.vmName -ScriptBlock { Expand-Archive -Path "C:\staging\DSC\$using:cmVersion\DSC.zip" -DestinationPath "C:\staging\DSC\$using:cmVersion\modules" } -WhatIf:$WhatIf

    # Define DSC ScriptBlock
    $DSC = {       

        # Get required variables from parent scope
        $cmVersion = $using:cmVersion
        $currentItem = $using:currentItem
        $jsonConfig = $using:jsonConfig
        $adminCreds = $using:Common.LocalAdmin

        # Install modules
        $modules = Get-ChildItem -Path "C:\staging\DSC\$cmVersion\modules" -Directory
        foreach ($folder in $modules) {
            Copy-Item $folder.FullName "C:\Program Files\WindowsPowerShell\Modules" -Recurse -Container -Force
            Import-Module $folder.Name -Force; 
        }
    
        # Apply DSC
        $dscName = "C:\staging\DSC\$cmVersion\$($currentItem.role)Configuration.ps1"
        . "$dscName"

        $dscName2 = $dscName -replace ".ps1", ""

        $cd = @{
            AllNodes = @(
                @{
                    NodeName = 'LOCALHOST'
                    PSDscAllowPlainTextPassword = $true
                }
            )
        }
    
        & "$($currentItem.role)Configuration" -DomainName contoso.com `
        -DCName CM-DC1 -DPMPName CM-MP1 -CSName CM-CS1 -PSName CM-SITE1 -ClientName CM-CL1 `
        -Configuration "Standalone" -DNSIPAddress 192.168.1.1 -AdminCreds $adminCreds `
        -ConfigurationData $cd -OutputPath $dscName2
    
        Set-DscLocalConfigurationManager -Path $dscName2 -Verbose    
        
        Start-DscConfiguration -Force -Path $dscName2 -Verbose
    }

    # Start DSC
    Invoke-VmCommand -VmName $currentItem.vmName -ScriptBlock $DSC -WhatIf:$WhatIf
}

$cmVersion = "current-branch"

foreach ($currentItem in $jsonConfig) {    

    $job = Start-Job -ScriptBlock $createVms -Name $currentItem.vmName -ErrorAction Stop -ErrorVariable Err

    if ($Err.Count -ne 0) {
        Write-Log "Main: Failed to start job to create VM $($currentItem.vmName). $Err"
    }
    else {
        Write-Log "Main: Created job $($job.Id) to create VM $($currentItem.vmName)"
        $jobs += $job
    }   
}

$runningJobs = $jobs | Where-Object { $_.State -ne "Completed" }

do {
    $runningJobs = $jobs | Where-Object { $_.State -ne "Completed" }

    foreach($job in $runningJobs) {
        Write-JobProgress($job)
    }
} until ($runningJobs.Count -eq 0)

# Write-Progress -Activity "Waiting for virtual machines to be created" -Completed


$timer.Stop()
Write-Host 
Write-Log "### COMPLETE. Elapsed Time: $($timer.Elapsed)" -Success
Write-Host 