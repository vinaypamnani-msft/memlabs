#New-BaseImage.ps1
param (
    [Parameter(Mandatory = $false, HelpMessage = "ISO File to extract install.wim from.")]
    [string]$IsoPath,
    [Parameter(Mandatory = $true, HelpMessage = "New Name of the WIM File.")]
    [string]$WimFileName,
    [Parameter(Mandatory = $true, HelpMessage = "Hyper-V Switch to use for the VM. Must have Internet access for Server OS.")]
    [string]$SwitchName,
    [Parameter(Mandatory = $false, HelpMessage = "Force reimporting WIM, if WIM already exists.")]
    [switch]$ForceNewWim,
    [Parameter(Mandatory = $false, HelpMessage = "Force recreating VHDX, if VHDX already exists.")]
    [switch]$ForceNewVhdx,
    [Parameter(Mandatory = $false, HelpMessage = "Force recreating VM, if VM already exists.")]
    [switch]$ForceNewVm,
    [Parameter(Mandatory = $false, HelpMessage = "Force recreating golden image, if it already exists.")]
    [switch]$ForceNewGoldImage,
    [Parameter(Mandatory = $false, HelpMessage = "Delete VM after importing golden image successfully.")]
    [switch]$DeleteVM,
    [Parameter(Mandatory = $false, HelpMessage = "Indicate if existing VM should be re-used. Not recommended. Use only for test/dev to save time.")]
    [switch]$UseExistingVm,
    [Parameter(Mandatory = $false, HelpMessage = "Force re-download of tools to inject in the image.")]
    [switch]$ForceTools,
    [Parameter(Mandatory = $false, HelpMessage = "Indicate if the script should continue, without bginfo in the filesToInject\staging\bginfo directory")]
    [switch]$IgnoreBginfo,
    [Parameter(Mandatory = $false, HelpMessage = "Indicate if the script should pause after customization, allowing user to make additional changes.")]
    [switch]$PauseAfterCustomization,
    [Parameter(Mandatory = $false, HelpMessage = "Dry Run.")]
    [switch]$WhatIf
)

# Check for PS Version
if ($PSVersionTable.PSVersion.Major -gt 5) {
    Write-Host
    Write-Host "This script must run using PowerShell version 5." -ForegroundColor Red
    Write-Host
    return
}

# Set Verbose
$enableVerbose = $PSCmdlet.MyInvocation.BoundParameters["Verbose"].IsPresent

# Dot source common
$RootPath = Split-Path -Path $PSScriptRoot -Parent
. $RootPath\Common.ps1 -VerboseEnabled:$enableVerbose

# Validate token exists
if ($Common.FatalError) {
    Write-Log "Critical Failure! $($Common.FatalError)" -Failure
    return
}

# Validate/Download bginfo.exe
$bgInfoPath = "$($Common.StagingInjectPath)\staging\bginfo\bginfo.exe"
if (-not (Test-Path $bgInfoPath)) {
    $worked = Get-File -Source $($Common.AzureFileList.Urls.BgInfo) -Destination $bgInfoPath -DisplayName "Downloading bginfo.exe" -Action "Downloading" -Silent
    if (-not $worked -and -not $IgnoreBginfo.IsPresent) {
        Write-Log "$bgInfoPath not found, and download failed. Use IgnoreBginfo switch if you don't care about this." -Warning
        return
    }
}

Write-Host

# Timer
Write-Log "### START." -Success

$timer = New-Object -TypeName System.Diagnostics.Stopwatch
$timer.Start()

################
### VALIDATION
################

# Validate WimFileName
if ($WimFileName -notlike "*.wim") {
    $WimFileName = $WimFileName + ".wim"
}

# Set VHDX file name
$vhdxFile = $WimFileName -replace ".wim", ".vhdx"

# Check if gold image exists
$purgeGoldImage = $false
$goldImagePath = Join-Path $Common.AzureImagePath $vhdxFile
if (-not $WhatIf -and (Test-Path $goldImagePath)) {
    Write-Log "Found $vhdxFile in $($Common.AzureImagePath)."
    if ($ForceNewGoldImage.IsPresent) {
        Write-Log "ForceNewGoldImage switch present. Will remove $goldImagePath..." -Warning
        $purgeGoldImage = $true
    }
    else {
        Write-Log "ForceNewGoldImage switch not present and gold image exists. Exiting! " -Warning
        return
    }
}

################
### GET TOOLS
################
if ($Common.AzureFileList.Tools) {
    Write-Log "Obtaining Tools to inject in the image." -Activity
    Get-ToolsForBaseImage -ForceTools:$ForceTools
}

##############
### GET WIM
##############

Write-Log "Obtaining $WimFileName." -Activity

# Check if WIM exists
$importWim = $true
$wimPath = Join-Path $Common.StagingWimPath $WimFileName

if (Test-Path $wimPath) {
    Write-Log "Found $WimFileName in $($Common.StagingWimPath)."
    if ($ForceNewWim.IsPresent) {
        Write-Log "ForceNewWim switch present. Removing existing $WimFileName..." -Warning
        if (-not $WhatIf) {
            Remove-Item -Path $wimPath -Force | Out-Null
        }
    }
    else {
        Write-Log "ForceNewWim switch not present. Re-using existing $WimFileName file..." -Warning
        $importWim = $false
    }
}

# Import WIM file
if ($importWim) {
    if ($IsoPath -and $WimFileName) {
        Write-Log "Importing WIM from $IsoPath."
        $wimPath = Import-WimFromIso -IsoPath $IsoPath -WimName $WimFileName -WhatIf:$WhatIf
    }
    else {
        Write-Log "$WimFileName not present. Please specify IsoPath." -Failure
        return
    }
}

# Verify we have the WIM
if ($null -eq $wimPath -and -not $WhatIf) {
    Write-Log "$WimFileName at $($Common.StagingWimPath) was not found. Exiting!" -Failure
    return
}

##############
### GET VHDX
##############

Write-Log "Using WIM $WimFileName to create a VHDX file." -Activity
$vhdxPath = Join-Path $Common.StagingImagePath $vhdxFile

# Check if VHDX exists
$createVhdx = $true
if (-not $WhatIf -and (Test-Path $vhdxPath)) {
    Write-Log "Found $vhdxFile in $($Common.StagingImagePath)."
    if ($ForceNewVhdx.IsPresent) {
        Write-Log "ForceNewVhdx switch present. Removing pre-existing $vhdxFile..." -Warning
        Remove-Item -Path $vhdxPath -Force | Out-Null
    }
    else {
        Write-Log "ForceNewVhdx switch not present. Re-using existing $vhdxFile file..." -Warning
        $createVhdx = $false
    }
}

# Create the VHDX
if ($createVhdx) {
    $worked = New-VhdxFile -WimName $WimFileName -VhdxPath $vhdxPath -WhatIf:$WhatIf
    if (-not $worked) {
        Write-Log "Valid $vhdxFile was not found. Exiting!" -Failure
        return
    }
}

# Validate we have the VHDX
if (-not $WhatIf -and -not (Test-Path $vhdxPath)) {
    Write-Log "$vhdxFile was not found. Exiting!" -Failure
    return
}

##############
### GET VM
##############

Write-Log "Using $vhdxFile for staging a VM for image customization" -Activity

$vmName = $WimFileName -replace ".wim", ""
$vmName = "z$vmName"

# Check if VM exists
$createVm = $true
$vmTest = Get-VM2 -Name $vmName
if ($vmTest) {
    Write-Log "Found $vmName in Hyper-V."
    if ($ForceNewVm.IsPresent) {
        Write-Log "ForceNewVm switch present. Removing pre-existing VM..." -Warning
    }
    else {
        Write-Log "ForceNewVm switch not present. Re-using existing VM may have undesired effects. Check if use of existing VM is allowed..." -Warning
        if ($UseExistingVm.IsPresent) {
            Write-Log "UseExistingVm switch present. Re-using existing VM..." -Warning
            $createVm = $false
        }
        else {
            Write-Log "UseExistingVm switch not present. Exiting!" -Warning
            return
        }
    }
}

if ($createVm) {
    # $response = Read-Host -Prompt "For Server OS, please make sure the switch used for creating VM has Internet. Continue? [y/N]"
    # if ($response -ne 'Y' -or $response -ne 'y') { return }
    $worked = New-VirtualMachine -VmName $vmName -VmPath $Common.StagingVMPath -SourceDiskPath $vhdxPath -Memory "8GB" -Generation 2 -Processors 8 -SwitchName $SwitchName -ForceNew:$ForceNewVm -WhatIf:$WhatIf
    if (-not $worked) {
        Write-Log "VM not created. Exiting!" -Failure
        return
    }
}

Write-Log "Wait for $vmName to be ready to start customization..."
$connected = Wait-ForVm -VmName $VmName -OobeComplete -WhatIf:$WhatIf
if (-not $connected) {
    Write-Log "Could not verify if VM is ready for customization. Exiting!" -Failure
    return
}

#################
### GET CUSTOM
#################

Write-Log "Sleep for 45 seconds before preparing $vmName for customization..." -Activity
if (-not $WhatIf.IsPresent) {
    Start-Sleep -Seconds 45
}
Write-Log "Restarting $vmName in Audit-Mode..."

$worked = Invoke-VmCommand -VmName $vmName -VmDomainName "WORKGROUP" -ScriptBlock { Remove-Item -Path "C:\staging\Customization.txt" -Force -ErrorAction SilentlyContinue } -WhatIf:$WhatIf # Sleep for a bit to make sure VM is at login screen.
$worked = Invoke-VmCommand -VmName $vmName -VmDomainName "WORKGROUP" -ScriptBlock { & $env:windir\system32\sysprep\sysprep.exe /audit /reboot } -WhatIf:$WhatIf

if (-not $worked) {
    Write-Log "Could not restart VM in Audit-mode. Exiting!" -Failure
    return
}

# Audit-Mode should automagically trigger running the customize-script (via unattend file).
# C:\staging\Customize-WindowsSettings.ps1 will create C:\staging\Customization.txt after it finishes.
Write-Log "Waiting for $vmName to finish customization..."
$connected = Wait-ForVm -VmName $VmName -PathToVerify "C:\staging\Customization.txt" -WhatIf:$WhatIf

if (-not $connected) {
    Write-Log "Could not verify if customization finished in allotted time. Exiting!" -Failure
    return
}

###################
# PAUSE IF NEEDED
###################
if ($PauseAfterCustomization.IsPresent) {
    $ready = $false
    do {
        $response = Read-Host -Prompt "Pausing for post-customization changes. Press [y] to confinue"
        if ($response.ToLowerInvariant() -eq "y" -or $response.ToLowerInvariant() -eq "yes") {
            $ready = $true
        }
    } until ($ready)
}

###################
# WAIT FOR GOLDEN
###################

Write-Log "Customization finished. Waiting for sysprep, and VM to stop..." -Activity
$connected = Wait-ForVm -VmName $VmName -VmState "Off" -WhatIf:$WhatIf

if (-not $connected) {
    Write-Log "Timed out while waiting for VM to stop. Exiting!" -Failure
    return
}

Write-Log "Capturing the golden image from $vmName..." -Activity

Write-Log "Obtaining OS disk path of $vmName..."
if (-not $WhatIf) {
    $f = Get-VM2 -Name $vmName | Get-VMFirmware
    $f_hd = $f.BootOrder | Where-Object { $_.BootType -eq "Drive" -and $_.Device -is [Microsoft.HyperV.PowerShell.HardDiskDrive] }
    $osDiskPath = $f_hd.Device.Path

    if (-not $osDiskPath) {
        Write-Log "Could not obtain the disk path of the VM.. Exiting!" -Failure
        return
    }
}

#################
# GET GOLDEN
#################

if ($purgeGoldImage) {
    Write-Log "Deleting existing 'golden' image $goldImagePath..."
    Remove-Item -Path $goldImagePath -Force | Out-Null
}

Write-Log "Copying the 'golden' image..."

$worked = Get-File -Source $osDiskPath -Destination $goldImagePath -DisplayName "Copying the 'golden' image to $($Common.AzureImagePath)" -Action "Copying" -WhatIf:$WhatIf
if (-not $WhatIf -and -not $worked) {
    Write-Log "### Something went wrong copying the 'golden' image $osDiskPath to $($Common.AzureImagePath). Please copy manually." -Warning
}
else {
    Write-Log "The 'golden' image $vhdxFile was copied to $($Common.AzureImagePath)..." -Success

    # Delete VM
    $vmTest = Get-VM2 -Name $VmName -ErrorAction SilentlyContinue
    if ($vmTest -and $DeleteVM.IsPresent) {
        if ($vmTest.State -ne "Off") {
            Write-Log "$VmName`: Turning the VM off forcefully..."
            $vmTest | Stop-VM -TurnOff -Force
        }
        $vmTest | Remove-VM -Force
        Write-Log "$VmName`: Purging $($vmTest.Path) folder..."
        Remove-Item -Path $($vmTest.Path) -Force -Recurse
    }
}

$timer.Stop()
Write-Host
Write-Log "### COMPLETE. Elapsed Time: $($timer.Elapsed.ToString("hh\:mm\:ss"))" -Success
Write-Host
