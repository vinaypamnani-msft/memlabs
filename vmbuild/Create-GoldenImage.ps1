param (
    [Parameter(Mandatory=$false, HelpMessage="ISO File to extract install.wim from.")]
    [string]$IsoPath,
    [Parameter(Mandatory=$true, HelpMessage="New Name of the WIM File.")]
    [string]$WimFileName,
    [Parameter(Mandatory=$false, HelpMessage="Force reimporting WIM, if WIM already exists.")]
    [switch]$ForceNewWim,
    [Parameter(Mandatory=$false, HelpMessage="Force recreating VHDX, if VHDX already exists.")]
    [switch]$ForceNewVhdx,
    [Parameter(Mandatory=$false, HelpMessage="Force recreating VM, if VM already exists.")]
    [switch]$ForceNewVm,
    [Parameter(Mandatory=$false, HelpMessage="Force recreating golden image, if it already exists.")]
    [switch]$ForceNewGoldImage,
    [Parameter(Mandatory=$false, HelpMessage="Indicate if existing VM should be re-used. Not recommended. Use only for test/dev to save time.")]
    [switch]$UseExistingVm,
    [Parameter(Mandatory=$false, HelpMessage="Indicate if the script should continue, without bginfo in the filesToInject\staging\bginfo directory")]
    [switch]$IgnoreBginfo,
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

# Validate bginfo.exe is present
if (-not (Test-Path "$($Common.InjectPath)\staging\bginfo\bginfo.exe") -and -not $IgnoreBginfo.IsPresent) {
    Write-Log "Main: $($Common.InjectPath)\staging\bginfo\bginfo.exe not found. Use IgnoreBginfo switch if you don't care about this." -Warning    
    return
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
$goldImagePath = Join-Path $Common.GoldImagePath $vhdxFile
if (-not $WhatIf -and (Test-Path $goldImagePath)) {
    Write-Log "Main: Found $vhdxFile in $($Common.GoldImagePath)."
    if ($ForceNewGoldImage.IsPresent) {
        Write-Log "Main: ForceNewGoldImage switch present. Will remove $goldImagePath..." -Warning
        $purgeGoldImage = $true
    }
    else {
        Write-Log "Main: ForceNewGoldImage switch not present and gold image exists. Exiting! " -Warning
        return
    }
}

##############
### GET WIM
##############

Write-Log "Main: Obtaining $WimFileName." -Activity

# Check if WIM exists
$importWim = $true
$wimPath = Join-Path $Common.WimagePath $WimFileName

if (Test-Path $wimPath) {
    Write-Log "Main: Found $WimFileName in $($Common.WimagePath)."
    if ($ForceNewWim.IsPresent) {
        Write-Log "Main: ForceNewWim switch present. Removing existing $WimFileName..." -Warning
        if (-not $WhatIf) {
            Remove-Item -Path $wimPath -Force | Out-Null
        }
    }
    else {
        Write-Log "Main: ForceNewWim switch not present. Re-using existing $WimFileName file..." -Warning        
        $importWim = $false
    }
}

# Import WIM file
if ($importWim) {
    if ($IsoPath -and $WimFileName) {
        Write-Log "Main: Importing WIM from $IsoPath."
        $wimPath = Import-WimFromIso -IsoPath $IsoPath -WimName $WimFileName -WhatIf:$WhatIf
    }
    else {
        Write-Log "Main: $WimFileName not present. Please specify IsoPath." -Failure
        return
    }
}

# Verify we have the WIM
if ($null -eq $wimPath -and -not $WhatIf) {
    Write-Log "Main: $WimFileName was not found. Exiting!" -Failure
    return
}

##############
### GET VHDX
##############

Write-Log "Main: Using WIM $WimFileName to create a VHDX file." -Activity
$vhdxPath = Join-Path $Common.BaseImagePath $vhdxFile

# Check if VHDX exists
$createVhdx = $true
if (-not $WhatIf -and (Test-Path $vhdxPath)) {
    Write-Log "Main: Found $vhdxFile in $($Common.BaseImagePath)."
    if ($ForceNewVhdx.IsPresent) {
        Write-Log "Main: ForceNewVhdx switch present. Removing pre-existing $vhdxFile..." -Warning
        Remove-Item -Path $vhdxPath -Force | Out-Null        
    }
    else {
        Write-Log "Main: ForceNewVhdx switch not present. Re-using existing $vhdxFile file..." -Warning
        $createVhdx = $false
    }
}

# Create the VHDX
if ($createVhdx) {    
    $worked = New-VhdxFile -WimName $WimFileName -VhdxPath $vhdxPath -WhatIf:$WhatIf
    if (-not $worked) {
        Write-Log "Main: Valid $vhdxFile was not found. Exiting!" -Failure
        return
    }
}

# Validate we have the VHDX
if (-not $WhatIf -and -not (Test-Path $vhdxPath)) {
    Write-Log "Main: $vhdxFile was not found. Exiting!" -Failure
    return
}

##############
### GET VM
##############

Write-Log "Main: Using $vhdxFile for staging a VM for image customization" -Activity

$vmName = $WimFileName -replace ".wim", ""
$vmName = "z$vmName"

# Check if VM exists
$createVm = $true
$vmTest = Get-VM -Name $vmName -ErrorAction SilentlyContinue
if ($vmTest) {
    Write-Log "Main: Found $vmName in Hyper-V."
    if ($ForceNewVm.IsPresent) {
        Write-Log "Main: ForceNewVm switch present. Removing pre-existing VM..." -Warning
        if (-not $WhatIf) {
            if ($vmTest.State -ne "Off") { 
                Write-Log "Main: Turning the VM off forcefully..."
                $vmTest | Stop-VM -TurnOff -Force 
            }
            $vmTest | Remove-VM -Force
            Write-Log "Main: Purging $($vmTest.Path) folder..."
            Remove-Item -Path $($vmTest.Path) -Force -Recurse
            Write-Log "Main: Purge complete."
        }
    }
    else {
        Write-Log "Main: ForceNewVm switch not present. Re-using existing VM may have undesired effects. Check if use of existing VM is allowed..." -Warning
        if ($UseExistingVm.IsPresent) {
            Write-Log "Main: UseExistingVm switch present. Re-using existing VM..." -Warning
            $createVm = $false
        }
        else {
            Write-Log "Main: UseExistingVm switch not present. Exiting!" -Warning
            return
        }
    }
}

if ($createVm) {
    $worked = New-VirtualMachine -VmName $vmName -VmPath $Common.StagingVMPath -SourceDiskPath $vhdxPath -Memory "4GB" -Generation 2 -Processors 1 -SwitchName "InternalSwitchCB1" -WhatIf:$WhatIf
    if (-not $worked) {
        Write-Log "Main: VM not created. Exiting!" -Failure
        return
    }
}

Write-Log "Main: Wait for $vmName to be ready to start customization..."
$connected = Wait-ForVm -VmName $VmName -OobeComplete -WhatIf:$WhatIf
if (-not $connected) {
    Write-Log "Main: Could not verify if VM is ready for customization. Exiting!" -Failure
    return
}

#################
### GET CUSTOM
#################

Write-Log "Main: Preparing $vmName for customization..." -Activity

Write-Log "Main: Restarting $vmName in Audit-Mode..."

$worked = Invoke-VmCommand -VmName $vmName -ScriptBlock { Remove-Item -Path "C:\staging\Customization.txt" -Force -ErrorAction SilentlyContinue } -WhatIf:$WhatIf # Sleep for a bit to make sure VM is at login screen.
$worked = Invoke-VmCommand -VmName $vmName -ScriptBlock { & $env:windir\system32\sysprep\sysprep.exe /audit /reboot } -WhatIf:$WhatIf

if (-not $worked) {
    Write-Log "Main: Could not restart VM in Audit-mode. Exiting!" -Failure
    return
}

# Audit-Mode should automagically trigger running the customize-script (via unattend file).
# C:\staging\Customize-WindowsSettings.ps1 will create C:\staging\Customization.txt after it finishes.
Write-Log "Main: Waiting for $vmName to finish customization..."
$connected = Wait-ForVm -VmName $VmName -PathToVerify "C:\staging\Customization.txt" -WhatIf:$WhatIf

if (-not $connected) {
    Write-Log "Main: Could not verify if customization finished in allotted time. Exiting!" -Failure
    return
}

###################
# WAIT FOR GOLDEN
###################

Write-Log "Main: Customization finished. Waiting for sysprep, and VM to stop..." -Activity
$connected = Wait-ForVm -VmName $VmName -VmState "Off" -WhatIf:$WhatIf

if (-not $connected) {
    Write-Log "Main: Timed out while waiting for VM to stop. Exiting!" -Failure
    return
}

Write-Log "Main: Capturing the golden image from $vmName..." -Activity

Write-Log "Main: Obtaining OS disk path of $vmName..."
if (-not $WhatIf) {
    $f = Get-VM -Name $vmName | Get-VMFirmware
    $f_hd = $f.BootOrder | Where-Object{$_.BootType -eq "Drive" -and $_.Device -is [Microsoft.HyperV.PowerShell.HardDiskDrive]}
    $osDiskPath = $f_hd.Device.Path

    if (-not $osDiskPath) {
        Write-Log "Main: Could not obtain the disk path of the VM.. Exiting!" -Failure
        return
    }
}

#################
# GET GOLDEN
#################

if ($purgeGoldImage) {
    Write-Log "Main: Deleting existing 'golden' image $goldImagePath..."
    Remove-Item -Path $goldImagePath -Force | Out-Null
}

Write-Log "Main: Copying the 'golden' image..."

Get-File -Source $osDiskPath -Destination $goldImagePath -DisplayName "Copying the 'golden' image to $($Common.GoldImagePath)" -Action "Copying" -WhatIf:$WhatIf
Write-Host 
if (-not $WhatIf -and -not (Test-Path $osDiskPath)) {
    Write-Log "### Something went wrong copying the 'golden' image $osDiskPath to $($Common.GoldImagePath). Please copy manually." -Warning
}
else {
    Write-Log "### Success! The 'golden' image $vhdxFile was copied to $($Common.GoldImagePath)..." -Success
}

$timer.Stop()
Write-Host 
Write-Log "### COMPLETE. Elapsed Time: $($timer.Elapsed)" -Success
Write-Host 
