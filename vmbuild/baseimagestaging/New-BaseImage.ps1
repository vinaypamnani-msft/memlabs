<#
.SYNOPSIS
    Builds a customized Windows base-image VHDX from local or MemLabs-hosted ISO media.

.DESCRIPTION
    Imports install.wim, applies the selected Windows image to a generation-2 VHDX,
    customizes it in a temporary Hyper-V VM, syspreps it, and publishes the verified
    VHDX to the MemLabs Azure image cache.

.EXAMPLE
    .\New-BaseImage.ps1 -IsoFileName 'iso\OS\windows11_26h2.iso' -WimFileName 'WIN11-26H2.wim' -SwitchName 'Default Switch' -DeleteVM
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $false, HelpMessage = "ISO File to extract install.wim from.")]
    [string]$IsoPath,
    [Parameter(Mandatory = $false, HelpMessage = "ISO path relative to the MemLabs Azure file store.")]
    [string]$IsoFileName,
    [Parameter(Mandatory = $false, HelpMessage = "Expected hash for the Azure ISO. Use NONE only to bootstrap a newly uploaded blob.")]
    [string]$IsoExpectedHash = "NONE",
    [Parameter(Mandatory = $false, HelpMessage = "Hash algorithm for the Azure ISO.")]
    [ValidateSet("MD5", "SHA256")]
    [string]$IsoHashAlgorithm = "MD5",
    [Parameter(Mandatory = $false, HelpMessage = "Force re-download of the Azure ISO.")]
    [switch]$ForceDownloadIso,
    [Parameter(Mandatory = $false, HelpMessage = "Use the configured CDN when downloading the Azure ISO.")]
    [switch]$UseCDN,
    [Parameter(Mandatory = $true, HelpMessage = "New Name of the WIM File.")]
    [string]$WimFileName,
    [Parameter(Mandatory = $false, HelpMessage = "Exact image name inside install.wim. WIN11-* defaults to Windows 11 Enterprise.")]
    [string]$WindowsImageName,
    [Parameter(Mandatory = $false, HelpMessage = "Unattend XML filename from baseimagestaging\unattend.")]
    [string]$UnattendFileName,
    [Parameter(Mandatory = $false, HelpMessage = "Hyper-V switch with internet access. If omitted, an external switch or Default Switch is selected.")]
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
    [Parameter(Mandatory = $false, HelpMessage = "Resume an existing VM that is already running in Audit mode after a prior customization-launch failure.")]
    [switch]$ResumeAuditVm,
    [Parameter(Mandatory = $false, HelpMessage = "Capture an existing stopped VM after final Sysprep has completed. Offline verification remains mandatory.")]
    [switch]$CaptureSyspreppedVm,
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

# Check for admin rights
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host
    Write-Host "This script must run as Administrator." -ForegroundColor Red
    Write-Host
    return
}

# Set Verbose
$enableVerbose = $PSCmdlet.MyInvocation.BoundParameters["Verbose"].IsPresent

# Dot source common
$RootPath = Split-Path -Path $PSScriptRoot -Parent
. $RootPath\Common.ps1 -VerboseEnabled:$enableVerbose -SkipMaintenanceRefresh:$WhatIf -SkipVmCacheRefresh:$WhatIf -SkipHostPreparation:$WhatIf

# Validate token exists
if ($Common.FatalError) {
    Write-Log "Critical Failure! $($Common.FatalError)" -Failure
    return
}

# Validate Hyper-V is available
try {
    $null = Get-Command Get-VM -ErrorAction Stop
}
catch {
    Write-Log "Hyper-V PowerShell module not available. Install the Hyper-V feature first." -Failure
    return
}

Write-Host

# Timer
Write-Log "### START." -Success

$timer = New-Object -TypeName System.Diagnostics.Stopwatch
$phaseTimer = New-Object -TypeName System.Diagnostics.Stopwatch
$timer.Start()

################
### VALIDATION
################

Write-Log "Validating parameters and prerequisites..." -Activity
$phaseTimer.Restart()

# Validate WimFileName
if ([IO.Path]::GetFileName($WimFileName) -ne $WimFileName) {
    Write-Log "WimFileName must be a filename, not a path: '$WimFileName'." -Failure
    return
}
if ([IO.Path]::GetExtension($WimFileName) -ine ".wim") {
    $WimFileName = $WimFileName + ".wim"
}

# Set VHDX file name
$vhdxFile = [IO.Path]::ChangeExtension($WimFileName, ".vhdx")

# Validate ISO source
if ($IsoPath -and $IsoFileName) {
    Write-Log "Specify either IsoPath or IsoFileName, not both." -Failure
    return
}
if ($IsoPath -and -not (Test-Path $IsoPath)) {
    Write-Log "ISO path not found: $IsoPath" -Failure
    return
}
if ($IsoPath -and [IO.Path]::GetExtension($IsoPath) -ine ".iso") {
    Write-Log "IsoPath must point to an .iso file: '$IsoPath'." -Failure
    return
}
if ($IsoExpectedHash -ne "NONE") {
    $expectedHashLength = if ($IsoHashAlgorithm -eq "MD5") { 32 } else { 64 }
    if ($IsoExpectedHash -notmatch "^[0-9a-fA-F]{$expectedHashLength}$") {
        Write-Log "IsoExpectedHash must be a $expectedHashLength-character hexadecimal $IsoHashAlgorithm hash." -Failure
        return
    }
    if (($ResumeAuditVm.IsPresent -or $CaptureSyspreppedVm.IsPresent) -and ($ForceNewVm.IsPresent -or $UseExistingVm.IsPresent)) {
        Write-Log "ResumeAuditVm and CaptureSyspreppedVm cannot be combined with ForceNewVm or UseExistingVm." -Failure
        return
    }
    if ($ResumeAuditVm.IsPresent -and $CaptureSyspreppedVm.IsPresent) {
        Write-Log "Specify either ResumeAuditVm or CaptureSyspreppedVm, not both." -Failure
        return
    }
}

# Check disk space (need ~150GB free for VHDX creation + golden image copy)
$targetDrive = (Split-Path $Common.StagingImagePath -Qualifier)
if ($targetDrive) {
    $freeSpace = (Get-PSDrive ($targetDrive -replace ':','') -ErrorAction SilentlyContinue).Free
    if ($freeSpace -and $freeSpace -lt 150GB) {
        Write-Log "Low disk space on $targetDrive - only $([math]::Round($freeSpace / 1GB, 1)) GB free. Recommend at least 150 GB." -Warning
    }
}

# Check if gold image exists
$goldImagePath = Join-Path $Common.AzureImagePath $vhdxFile
if (-not $WhatIf -and (Test-Path $goldImagePath)) {
    Write-Log "Found $vhdxFile in $($Common.AzureImagePath)."
    if ($ForceNewGoldImage.IsPresent) {
        Write-Log "ForceNewGoldImage switch present. The existing image will be retained until its replacement is verified." -Warning
    }
    else {
        Write-Log "ForceNewGoldImage switch not present and gold image exists. Exiting!" -Warning
        return
    }
}

Write-Log "Validation complete. ($($phaseTimer.Elapsed.ToString('mm\:ss')))" -Success

################
### GET TOOLS
################
if ($Common.AzureFileList.Tools) {
    Write-Log "Obtaining Tools to inject in the image." -Activity
    $phaseTimer.Restart()
    try {
        $worked = Get-ToolsForBaseImage -ForceTools:$ForceTools -WhatIf:$WhatIf
        if (-not $worked) {
            Write-Log "One or more tools could not be staged." -Failure
            return
        }
        Write-Log "Tools obtained successfully. ($($phaseTimer.Elapsed.ToString('mm\:ss')))" -Success
    }
    catch {
        Write-Log "Failed to obtain tools: $($_.Exception.Message)" -Failure
        Write-Log "$($_.ScriptStackTrace)" -LogOnly
        return
    }
}

# Validate/download bginfo.exe after parameter validation and honor WhatIf.
$bgInfoPath = Join-Path $Common.StagingInjectPath "staging\bginfo\bginfo.exe"
if (-not (Test-Path $bgInfoPath -PathType Leaf)) {
    $worked = Get-File -Source $Common.AzureFileList.Urls.BgInfo -Destination $bgInfoPath -DisplayName "Downloading bginfo.exe" -Action "Downloading" -Silent -WhatIf:$WhatIf
    if (-not $worked -and -not $IgnoreBginfo.IsPresent) {
        Write-Log "'$bgInfoPath' was not found and its download failed. Use -IgnoreBginfo only if the omission is intentional." -Failure
        return
    }
}

##############
### GET WIM
##############

Write-Log "Obtaining $WimFileName." -Activity
$phaseTimer.Restart()

# Check if WIM exists
$importWim = $true
$wimPath = Join-Path $Common.StagingWimPath $WimFileName

if (Test-Path $wimPath) {
    Write-Log "Found $WimFileName in $($Common.StagingWimPath)."
    if ($ForceNewWim.IsPresent) {
        Write-Log "ForceNewWim switch present. The existing WIM will be retained until its replacement has copied successfully." -Warning
    }
    else {
        Write-Log "ForceNewWim switch not present. Re-using existing $WimFileName file..." -Warning
        $importWim = $false
    }
}

# Import WIM file
if ($importWim) {
    if ($IsoFileName) {
        try {
            $IsoPath = Get-BaseImageIsoFromStorage -FileName $IsoFileName -ExpectedHash $IsoExpectedHash -HashAlgorithm $IsoHashAlgorithm -ForceDownload:$ForceDownloadIso -UseCDN:$UseCDN -WhatIf:$WhatIf
        }
        catch {
            Write-Log "Failed to obtain Azure ISO '$IsoFileName': $($_.Exception.Message)" -Failure
            Write-Log "$($_.ScriptStackTrace)" -LogOnly
            return
        }
    }

    if ($IsoPath) {
        Write-Log "Importing WIM from '$IsoPath'."
        $wimPath = Import-WimFromIso -IsoPath $IsoPath -WimName $WimFileName -WhatIf:$WhatIf
    }
    else {
        Write-Log "$WimFileName is not reusable. Specify -IsoPath or -IsoFileName." -Failure
        return
    }
}

# Verify we have the WIM
if (-not $WhatIf -and (-not $wimPath -or -not (Test-Path $wimPath -PathType Leaf))) {
    Write-Log "$WimFileName at $($Common.StagingWimPath) was not found. Exiting!" -Failure
    return
}

Write-Log "WIM ready. ($($phaseTimer.Elapsed.ToString('mm\:ss')))" -Success

##############
### GET VHDX
##############

Write-Log "Using WIM $WimFileName to create a VHDX file." -Activity
$phaseTimer.Restart()
$vhdxPath = Join-Path $Common.StagingImagePath $vhdxFile

# Check if VHDX exists
$createVhdx = $true
if (-not $WhatIf -and (Test-Path $vhdxPath)) {
    Write-Log "Found $vhdxFile in $($Common.StagingImagePath)."
    if ($ForceNewVhdx.IsPresent) {
        Write-Log "ForceNewVhdx switch present. The existing VHDX will be retained until its replacement is ready." -Warning
    }
    else {
        Write-Log "ForceNewVhdx switch not present. Re-using existing $vhdxFile file..." -Warning
        $createVhdx = $false
    }
}

# Create the VHDX
if ($createVhdx) {
    $partialVhdxPath = Join-Path $Common.StagingImagePath "_partial_${PID}_$vhdxFile"
    if (-not $WhatIf) {
        Remove-Item -LiteralPath $partialVhdxPath -Force -ErrorAction SilentlyContinue
    }

    $worked = New-VhdxFile -WimName $WimFileName -VhdxPath $partialVhdxPath -ImageName $WindowsImageName -UnattendFileName $UnattendFileName -WhatIf:$WhatIf
    if (-not $worked) {
        Write-Log "VHDX creation failed for $vhdxFile. Exiting!" -Failure
        return
    }

    if (-not $WhatIf) {
        $backupVhdxPath = "$vhdxPath.backup.$PID"
        try {
            Remove-Item -LiteralPath $backupVhdxPath -Force -ErrorAction SilentlyContinue
            if (Test-Path $vhdxPath -PathType Leaf) {
                Move-Item -LiteralPath $vhdxPath -Destination $backupVhdxPath -ErrorAction Stop
            }
            try {
                Move-Item -LiteralPath $partialVhdxPath -Destination $vhdxPath -ErrorAction Stop
            }
            catch {
                if ((Test-Path $backupVhdxPath -PathType Leaf) -and -not (Test-Path $vhdxPath)) {
                    Move-Item -LiteralPath $backupVhdxPath -Destination $vhdxPath -ErrorAction Stop
                }
                throw
            }
            Remove-Item -LiteralPath $backupVhdxPath -Force -ErrorAction SilentlyContinue
        }
        catch {
            Remove-Item -LiteralPath $partialVhdxPath -Force -ErrorAction SilentlyContinue
            Write-Log "Failed to publish staged VHDX '$partialVhdxPath' as '$vhdxPath': $($_.Exception.Message)" -Failure
            return
        }
    }
}

# Validate we have the VHDX
if (-not $WhatIf -and -not (Test-Path $vhdxPath)) {
    Write-Log "$vhdxFile was not found after creation. Exiting!" -Failure
    return
}

Write-Log "VHDX ready. ($($phaseTimer.Elapsed.ToString('mm\:ss')))" -Success

if ($SwitchName) {
    $selectedSwitch = Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue
    if (-not $selectedSwitch) {
        Write-Log "Hyper-V switch '$SwitchName' was not found. Available switches: $((Get-VMSwitch | Select-Object -ExpandProperty Name) -join ', ')" -Failure
        return
    }
}
else {
    $selectedSwitch = Get-VMSwitch -SwitchType External -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $selectedSwitch) {
        $selectedSwitch = Get-VMSwitch -Name "Default Switch" -ErrorAction SilentlyContinue
    }
    if (-not $selectedSwitch) {
        Write-Log "No external Hyper-V switch or Default Switch is available. Specify -SwitchName for a switch with internet access." -Failure
        return
    }
    $SwitchName = $selectedSwitch.Name
    Write-Log "No switch specified. Using '$SwitchName'."
}

##############
### GET VM
##############

Write-Log "Using $vhdxFile for staging a VM for image customization" -Activity
$phaseTimer.Restart()

$vmName = $WimFileName -replace ".wim", ""
$vmName = "z$vmName"

# Check if VM exists
$createVm = $true
$resumeAuditMode = $false
$captureSyspreppedMode = $false
$vmTest = Get-VM2 -Fallback -Name $vmName
if ($vmTest) {
    Write-Log "Found $vmName in Hyper-V."
    if ($CaptureSyspreppedVm.IsPresent) {
        if ($vmTest.State -ne "Off") {
            Write-Log "CaptureSyspreppedVm requires '$vmName' to be Off; current state is '$($vmTest.State)'." -Failure
            return
        }
        Write-Log "CaptureSyspreppedVm switch present. The stopped VM will be verified offline before capture." -Warning
        $createVm = $false
        $captureSyspreppedMode = $true
    }
    elseif ($ResumeAuditVm.IsPresent) {
        Write-Log "ResumeAuditVm switch present. Resuming the existing Audit-mode VM..." -Warning
        if ($vmTest.State -eq "Off") {
            $startedVm = Start-VM2 -Name $vmName
            if (-not $startedVm) {
                Write-Log "Existing Audit-mode VM '$vmName' could not be started." -Failure
                return
            }
        }
        $createVm = $false
        $resumeAuditMode = $true
    }
    elseif ($ForceNewVm.IsPresent) {
        Write-Log "ForceNewVm switch present. Removing pre-existing VM..." -Warning
    }
    else {
        Write-Log "ForceNewVm switch not present. Re-using existing VM may have undesired effects. Check if use of existing VM is allowed..." -Warning
        if ($UseExistingVm.IsPresent) {
            Write-Log "UseExistingVm switch present. Re-using existing VM..." -Warning
            if ($vmTest.State -eq "Off") {
                $startedVm = Start-VM2 -Name $vmName
                if (-not $startedVm) {
                    Write-Log "Existing VM '$vmName' could not be started." -Failure
                    return
                }
            }
            $createVm = $false
        }
        else {
            Write-Log "UseExistingVm switch not present. Exiting!" -Warning
            return
        }
    }
}
elseif (($ResumeAuditVm.IsPresent -or $CaptureSyspreppedVm.IsPresent) -and -not $WhatIf) {
    Write-Log "A resume/capture switch was specified, but VM '$vmName' does not exist." -Failure
    return
}

if ($createVm) {
    $enableTpm = $WimFileName -like "WIN11-*"
    $worked = New-VirtualMachine -VmName $vmName -VmPath $Common.StagingVMPath -SourceDiskPath $vhdxPath -Memory "8GB" -Generation 2 -Processors 8 -SwitchName $SwitchName -ForceNew:$ForceNewVm -tpmEnabled:$enableTpm -DisableAutomaticCheckpoints -WhatIf:$WhatIf
    if (-not $worked) {
        Write-Log "VM not created. Exiting!" -Failure
        return
    }
}

if (-not $WhatIf -and @(Get-VMSnapshot -VMName $vmName -ErrorAction Stop).Count -gt 0) {
    Write-Log "VM '$vmName' has checkpoints. Refusing to capture a base disk that may omit differencing-disk changes." -Failure
    return
}

Write-Log "VM created. ($($phaseTimer.Elapsed.ToString('mm\:ss')))" -Success

if ($captureSyspreppedMode) {
    Write-Log "Skipping customization because CaptureSyspreppedVm was specified. Offline Sysprep verification is still required." -Warning
}
else {
#################
### GET CUSTOM
#################

Write-Log "Preparing $vmName for audit-mode customization..." -Activity
$phaseTimer.Restart()

if (-not $resumeAuditMode) {
    Write-Log "Wait for $vmName to be ready to start customization... Auth errors are expected while OOBE runs."
    $connected = Wait-ForVm -VmName $VmName -OobeComplete -WhatIf:$WhatIf
    if (-not $connected) {
        Write-Log "Could not verify if VM is ready for customization. Exiting!" -Failure
        return
    }
    Write-Log "VM is ready. ($($phaseTimer.Elapsed.ToString('mm\:ss')))" -Success

    if (-not $WhatIf.IsPresent) {
        Write-Log "Waiting 15 seconds for VM to stabilize..."
        Start-Sleep -Seconds 15
    }
    Write-Log "Transitioning $vmName to Audit mode..."

    $worked = Invoke-VmCommand -VmName $vmName -VmDomainName "WORKGROUP" -ScriptBlock {
        Remove-Item -Path "C:\staging\Customization.txt", "C:\staging\SysprepComplete.txt", "C:\staging\SysprepFailed.txt" -Force -ErrorAction SilentlyContinue
    } -WhatIf:$WhatIf
    if (-not $worked) {
        Write-Log "Could not connect to VM to clear customization markers. Exiting!" -Failure
        return
    }

    $worked = Invoke-VmCommand -VmName $vmName -VmDomainName "WORKGROUP" -ScriptBlock { & $env:windir\system32\sysprep\sysprep.exe /audit /shutdown } -WhatIf:$WhatIf
    if (-not $worked) {
        Write-Log "Could not transition VM to Audit mode. Exiting!" -Failure
        return
    }

    Write-Log "Waiting for $vmName to shut down for the Audit-mode transition..."
    $auditShutdown = Wait-ForVm -VmName $VmName -VmState "Off" -TimeoutMinutes 30 -NoForceStateOnTimeout -WhatIf:$WhatIf
    if (-not $auditShutdown) {
        Write-Log "Timed out waiting for the Audit-mode shutdown. The VM was left running for diagnostics." -Failure
        return
    }

    if (-not $WhatIf) {
        $startedVm = Start-VM2 -Name $vmName
        if (-not $startedVm) {
            Write-Log "Could not start '$vmName' in Audit mode." -Failure
            return
        }
    }
}
else {
    Write-Log "Skipping OOBE and Audit-mode transition for resumed VM '$vmName'."
}

Write-Log "Waiting for $vmName to accept PowerShell Direct in Audit mode..."
$auditReady = Wait-ForVm -VmName $VmName -PathToVerify "C:\staging\Customize-WindowsSettings.ps1" -TimeoutMinutes 15 -SkipDiskTest -WhatIf:$WhatIf
if (-not $auditReady) {
    Write-Log "Could not connect to '$vmName' after its Audit-mode boot." -Failure
    return
}

$worked = Invoke-VmCommand -VmName $vmName -VmDomainName "WORKGROUP" -ScriptBlock {
    Remove-Item -Path "C:\staging\Customization.txt", "C:\staging\SysprepComplete.txt", "C:\staging\SysprepFailed.txt" -Force -ErrorAction SilentlyContinue
} -WhatIf:$WhatIf
if (-not $worked) {
    Write-Log "Could not clear customization markers in '$vmName'." -Failure
    return
}

$worked = Invoke-VmCommand -VmName $vmName -VmDomainName "WORKGROUP" -ScriptBlock {
    $customizationScript = "C:\staging\Customize-WindowsSettings.ps1"
    $existingProcess = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*$customizationScript*" } |
        Select-Object -First 1
    if (-not $existingProcess) {
        $powerShellPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
        $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$customizationScript`" -RunSysprep -DisableFirewall -RunOptional"
        $process = Start-Process -FilePath $powerShellPath -ArgumentList $arguments -PassThru
        if (-not $process) {
            throw "Failed to launch '$customizationScript'."
        }
    }
} -WhatIf:$WhatIf
if (-not $worked) {
    Write-Log "Could not launch base-image customization in '$vmName'." -Failure
    return
}

Write-Log "Waiting for $vmName to finish customization..."
$connected = Wait-ForVm -VmName $VmName -PathToVerify "C:\staging\Customization.txt" -WhatIf:$WhatIf

if (-not $connected) {
    Write-Log "Could not verify if customization finished in allotted time. Exiting!" -Failure
    return
}

Write-Log "Customization complete. ($($phaseTimer.Elapsed.ToString('mm\:ss')))" -Success

###################
# PAUSE IF NEEDED
###################
if ($PauseAfterCustomization.IsPresent) {
    $ready = $false
    do {
        $response = Read-Host -Prompt "Pausing for post-customization changes. Press [y] to continue"
        if ($response.ToLowerInvariant() -eq "y" -or $response.ToLowerInvariant() -eq "yes") {
            $ready = $true
        }
    } until ($ready)
}

###################
# WAIT FOR GOLDEN
###################

Write-Log "Waiting for sysprep to complete and VM to stop..." -Activity
$phaseTimer.Restart()
$connected = Wait-ForVm -VmName $VmName -VmState "Off" -TimeoutMinutes 60 -NoForceStateOnTimeout -WhatIf:$WhatIf
if (-not $connected) {
    Write-Log "Timed out while waiting for successful Sysprep shutdown. The VM was left running for diagnostics." -Failure
    return
}

Write-Log "VM stopped. ($($phaseTimer.Elapsed.ToString('mm\:ss')))" -Success
}

Write-Log "Capturing the golden image from $vmName..." -Activity
$phaseTimer.Restart()

if ($WhatIf) {
    Write-Log "WhatIf: Will copy the stopped VM OS disk to '$goldImagePath', validate it, and create an MD5 marker."
}
else {
    Write-Log "Obtaining OS disk path of $vmName..."
    try {
        $captureVm = Get-VM2 -Fallback -Name $vmName -ErrorAction Stop
        if ($captureVm.State -ne "Off") {
            throw "VM state is '$($captureVm.State)', not Off."
        }
        if (@(Get-VMSnapshot -VMName $vmName -ErrorAction Stop).Count -gt 0) {
            throw "VM has one or more checkpoints; its active changes may be in a differencing disk."
        }

        $osDisk = Get-VMHardDiskDrive -VMName $vmName -ErrorAction Stop |
            Sort-Object ControllerNumber, ControllerLocation |
            Select-Object -First 1
        $osDiskPath = $osDisk.Path
        if (-not $osDiskPath -or -not (Test-Path $osDiskPath -PathType Leaf)) {
            throw "The VM OS disk path '$osDiskPath' does not exist."
        }

        $sourceVhd = Get-VHD -Path $osDiskPath -ErrorAction Stop
        if ($sourceVhd.VhdFormat -ne "VHDX") {
            throw "The VM OS disk is '$($sourceVhd.VhdFormat)', not VHDX."
        }

        $sysprepValidation = Test-BaseImageSysprepComplete -VhdxPath $osDiskPath
        if (-not $sysprepValidation.Success) {
            throw "Offline Sysprep verification failed: $($sysprepValidation.Message)"
        }
        foreach ($sysprepWarning in @($sysprepValidation.Warnings)) {
            Write-Log "Offline Sysprep provider warning: $sysprepWarning" -Warning
        }
        Write-Log $sysprepValidation.Message -Success
    }
    catch {
        Write-Log "Could not resolve a safe OS disk for '$vmName': $($_.Exception.Message)" -Failure
        Write-Log "$($_.ScriptStackTrace)" -LogOnly
        return
    }

    Write-Log "OS disk: $osDiskPath (Size: $([math]::Round((Get-Item $osDiskPath).Length / 1GB, 2)) GB)"

    $partialGoldImagePath = Join-Path $Common.AzureImagePath "_partial_${PID}_$vhdxFile"
    $backupGoldImagePath = "$goldImagePath.backup.$PID"
    $goldHashPath = "$goldImagePath.MD5"
    $backupGoldHashPath = "$goldHashPath.backup.$PID"
    Remove-Item -LiteralPath $partialGoldImagePath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $backupGoldImagePath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $backupGoldHashPath -Force -ErrorAction SilentlyContinue

    Write-Log "Copying the 'golden' image to a staging path..."
    $worked = Get-File -Source $osDiskPath -Destination $partialGoldImagePath -DisplayName "Copying the 'golden' image to $($Common.AzureImagePath)" -Action "Copying"
    if (-not $worked -or -not (Test-Path $partialGoldImagePath -PathType Leaf)) {
        Remove-Item -LiteralPath $partialGoldImagePath -Force -ErrorAction SilentlyContinue
        Write-Log "Failed to copy the golden image from '$osDiskPath' to '$partialGoldImagePath'." -Failure
        return
    }

    try {
        $goldSize = (Get-Item -LiteralPath $partialGoldImagePath -ErrorAction Stop).Length
        $sourceSize = (Get-Item -LiteralPath $osDiskPath -ErrorAction Stop).Length
        if ($goldSize -ne $sourceSize) {
            throw "Golden image size mismatch. Source=$sourceSize bytes, copy=$goldSize bytes."
        }

        $goldVhd = Get-VHD -Path $partialGoldImagePath -ErrorAction Stop
        if ($goldVhd.VhdFormat -ne "VHDX") {
            throw "Copied disk is '$($goldVhd.VhdFormat)', not VHDX."
        }

        Write-Log "Calculating MD5 for the verified golden image..."
        $goldHash = (Get-FileHash -LiteralPath $partialGoldImagePath -Algorithm MD5 -ErrorAction Stop).Hash

        $existingGoldMoved = $false
        $existingGoldHashMoved = $false
        $newGoldMoved = $false
        try {
            if (Test-Path $goldImagePath -PathType Leaf) {
                Move-Item -LiteralPath $goldImagePath -Destination $backupGoldImagePath -ErrorAction Stop
                $existingGoldMoved = $true
            }
            if (Test-Path $goldHashPath -PathType Leaf) {
                Move-Item -LiteralPath $goldHashPath -Destination $backupGoldHashPath -ErrorAction Stop
                $existingGoldHashMoved = $true
            }
            Move-Item -LiteralPath $partialGoldImagePath -Destination $goldImagePath -ErrorAction Stop
            $newGoldMoved = $true
            Set-Content -LiteralPath $goldHashPath -Value $goldHash -Encoding ASCII -Force -ErrorAction Stop
        }
        catch {
            if ($newGoldMoved) {
                Remove-Item -LiteralPath $goldImagePath -Force -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $goldHashPath -Force -ErrorAction SilentlyContinue
            }
            if ($existingGoldMoved -and (Test-Path $backupGoldImagePath -PathType Leaf)) {
                Move-Item -LiteralPath $backupGoldImagePath -Destination $goldImagePath -ErrorAction Stop
            }
            if ($existingGoldHashMoved -and (Test-Path $backupGoldHashPath -PathType Leaf)) {
                Move-Item -LiteralPath $backupGoldHashPath -Destination $goldHashPath -ErrorAction Stop
            }
            throw
        }

        Remove-Item -LiteralPath $backupGoldImagePath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $backupGoldHashPath -Force -ErrorAction SilentlyContinue
        Write-Log "Golden image verified: $([math]::Round($goldSize / 1GB, 2)) GB, MD5 $goldHash"
    }
    catch {
        Remove-Item -LiteralPath $partialGoldImagePath -Force -ErrorAction SilentlyContinue
        Write-Log "Golden image validation or publication failed: $($_.Exception.Message)" -Failure
        Write-Log "$($_.ScriptStackTrace)" -LogOnly
        return
    }
}

Write-Log "The 'golden' image $vhdxFile was copied to $($Common.AzureImagePath)." -Success
Write-Log "Golden image capture complete. ($($phaseTimer.Elapsed.ToString('mm\:ss')))" -Success

# Delete VM
$vmTest = Get-VM2 -Fallback -Name $VmName -ErrorAction SilentlyContinue
if ($vmTest -and $DeleteVM.IsPresent) {
    Write-Log "Cleaning up VM '$VmName'..."
    try {
        if ($vmTest.State -ne "Off") {
            Write-Log "$VmName`: Turning the VM off forcefully..."
            $vmTest | Stop-VM -TurnOff -Force
        }
        $vmTest | Remove-VM -Force
        Write-Log "$VmName`: Purging $($vmTest.Path) folder..."
        Remove-Item -Path $($vmTest.Path) -Force -Recurse
        Write-Log "$VmName`: VM cleaned up successfully."
    }
    catch {
        Write-Log "$VmName`: Warning - VM cleanup failed: $($_.Exception.Message)" -Warning
    }
}

$timer.Stop()
Write-Host
Write-Log "### COMPLETE. Elapsed Time: $($timer.Elapsed.ToString("hh\:mm\:ss"))" -Success
Write-Host
