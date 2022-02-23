# Logging
$logFile = "$env:windir\temp\configureHost.log"

function Write-HostLog {
    param ($Text)
    "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] $Text" | Out-File -Append $logFile
}

# Define vars
$poolName = "StoragePool1"
$virtualdiskName = "VirtualDisk1"
$repoName = "memlabs"
$repoUrl = "https://github.com/vinaypamnani-msft/$repoName"

# # Check if repository has already been cloned, if so, script has run before and there's no need to re-run
# $vol = Get-Volume -ErrorAction SilentlyContinue -filesystemlabel $virtualdiskName
# if ($vol) {
#     $repoDestination = "$($vol.DriveLetter):\$repoName"
#     if (Test-Path $repoDestination) {
#         Write-HostLog "SKIPPED. Running at startup, but repo already cloned at $repoDestination."
#         return
#     }
# }

Write-HostLog "START"

# Change CD-ROM Drive Letter
$cd = Get-WmiObject -Class Win32_volume -Filter 'DriveType=5'
if ($cd) {
    Write-HostLog "Changing CD-ROM DriveLetter to Z:"
    $x = Get-WmiObject -Class Win32_volume -Filter 'DriveType=5 AND DriveLetter="Z:"'
    if (-not $x) {
        Get-WmiObject -Class Win32_volume -Filter 'DriveType=5' | Select-Object -First 1 | Set-WmiInstance -Arguments @{DriveLetter = 'Z:' }
        $x = Get-WmiObject -Class Win32_volume -Filter 'DriveType=5 AND DriveLetter="Z:"'
        if ($x) {
            Write-HostLog "Changed Driveletter of CD-ROM drive"
        }
        else {
            Write-HostLog "Failed to change Driveletter of CD-ROM drive. Exiting."
            return
        }
    }
    else {
        Write-HostLog "CD-ROM already changed to Z:"
    }
}

# Create Storage Pool
Write-HostLog "Creating Storage Pool named $poolName"
$pool = Get-StoragePool -ErrorAction SilentlyContinue -FriendlyName $poolName
if (-not $pool) {
    New-StoragePool -FriendlyName $poolName -StorageSubSystemFriendlyName '*storage*' -PhysicalDisks (Get-PhysicalDisk -CanPool $True)
    $pool = Get-StoragePool -ErrorAction SilentlyContinue -FriendlyName $poolName
    if ($pool.OperationalStatus -eq 'OK') {
        Write-HostLog "Storage Pool created."
    }
    else {
        Write-HostLog "Storage Pool was not created. Exiting."
        return
    }
}
else {
    Write-HostLog "Storage Pool already exists."
}


# Create Virtual Disks
Write-HostLog "Creating Virtual Disk named $virtualDiskName"
$vdisk = Get-VirtualDisk -ErrorAction SilentlyContinue -friendlyName $virtualdiskName
if (-not $vdisk) {
    $disks = Get-StoragePool -FriendlyName $poolName -IsPrimordial $False | Get-PhysicalDisk
    $diskNum = $disks.Count
    New-VirtualDisk -StoragePoolFriendlyName $poolName -FriendlyName $virtualdiskName -ResiliencySettingName simple -NumberOfColumns $diskNum -UseMaximumSize
    $vdisk = Get-VirtualDisk -ErrorAction SilentlyContinue -friendlyName $virtualdiskName
    if ($vdisk.OperationalStatus -eq 'OK') {
        Write-HostLog "Virtual Disk created with $diskNum disks."
    }
    else {
        Write-HostLog "Virtual Disk was not created. Exiting."
        return
    }
}
else {
    Write-HostLog "Virtual Disk already exists."
}

# Format virtual disks
Write-HostLog "Formatting Virtual Disk $virtualDiskName"
$vol = Get-Volume -ErrorAction SilentlyContinue -filesystemlabel $virtualdiskName
if (-not $vol) {
    Get-VirtualDisk -FriendlyName $virtualDiskName | Get-Disk | Initialize-Disk -Passthru | New-Partition -AssignDriveLetter -UseMaximumSize | Format-Volume -NewFileSystemLabel $virtualDiskName -AllocationUnitSize 4KB -FileSystem NTFS
    $vol = Get-Volume -ErrorAction SilentlyContinue -filesystemlabel $virtualdiskName
    if ($vol.filesystem -EQ 'NTFS') {
        Write-HostLog "$virtualDiskName disk volume created."
    }
    else {
        Write-HostLog "$virtualDiskName disk volume was not created. Exiting."
        return
    }
}
else {
    Write-HostLog "$virtualDiskName disk volume already exists"
}

# Install choco
Write-HostLog "Installing chocolatey"
Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))

# Install git
Write-HostLog "Installing git via choco"
& choco install git -y

# Install sysinternals
Write-HostLog "Installing sysinternals via choco"
& choco install sysinternals -y

# Install sysinternals
Write-HostLog "Installing curl via choco"
& choco install curl -y

# Reload PATH
Write-HostLog "Reloading PATH"
$env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")

# Clone the repo
if ($vol) {
    $repoDestination = "$($vol.DriveLetter):\$repoName"
    Write-HostLog "Cloning the repository"
    if (-not (Test-Path $repoDestination)) {
        git clone $repoUrl $repoDestination --quiet
    }
    else {
        Write-HostLog "$repoName already cloned to $repoDestination. Run git pull instead of trying to clone again."
    }
}
else {
    Write-HostLog "SKIPPED cloning the repository, volume not found."
}

# Run Customize-WindowsSettings.ps1 on host VM
# $scriptPath = Join-Path $repoDestination "vmbuild\baseimagestaging\filesToInject\staging\Customize-WindowsSettings.ps1"
# if (Test-Path $scriptPath) {
#     if (Test-Path "C:\staging\Customization.txt") {
#         Write-HostLog "SKIPPED executing $scriptPath since it's been executed before. See C:\staging\Customization.txt"
#     }
#     else {
#         Write-HostLog "Executing $scriptPath. See C:\staging\Customization.txt"
#         & $scriptPath
#     }
# }
# else {
#     Write-HostLog "SKIPPED executing $scriptPath since it was not found."
# }

# Create External Hyper-V Switch
$Network = "External"
$phsyicalNic = Get-NetAdapter | Where-Object { $_.InterfaceDescription -like "Microsoft Hyper-V Network Adapter*" }
$phsyicalInterface = $phsyicalNic.Name
$exists = Get-VMSwitch -SwitchType External | Where-Object { $_.Name -eq $Network }
if (-not $exists) {
    Write-HostLog "HyperV Network switch for '$Network' not found. Creating a new one."
    New-VMSwitch -Name $Network  -NetAdapterName $phsyicalInterface -AllowManagementOS $true -Notes $Network | Out-Null
    Start-Sleep -Seconds 10 # Sleep to make sure network adapter is present
}
else {
    Write-HostLog "SKIPPED creating HyperV Network switch for '$Network' since it already exist."
}

# Install RRAS
Write-HostLog "Installing RRAS"
Install-WindowsFeature 'Routing', 'DirectAccess-VPN' -Confirm:$false -IncludeAllSubFeature -IncludeManagementTools

# Configure NAT
Write-HostLog "Configuring NAT"
Install-RemoteAccess -VpnType RoutingOnly
cmd.exe /c netsh routing ip nat install

# External Hyper-V Switch NIC
$shouldReboot = $false
$externalInterface = "vEthernet ($Network)"
Write-HostLog "Adding $externalInterface interface to NAT"
$text = & netsh routing ip nat show interface
if ($text -like "*$externalInterface*") {
    Write-HostLog "'$externalInterface' interface is already present in NAT."
}
else {
    cmd.exe /c netsh routing ip nat add interface "$externalInterface"
    cmd.exe /c netsh routing ip nat set interface "$externalInterface" mode=full
    $shouldReboot = $true
}

# Disable Modern Stack to allow use of RRAS GUI again
cmd.exe /c reg add HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\RemoteAccess\Parameters /v ModernStackEnabled /t REG_DWORD /d 0 /f

Write-HostLog "FINISH"

if ($shouldReboot) {
    Write-HostLog "Restarting the machine."
    & shutdown /r /t 30 /c "MEMLABS needs to restart the Azure Host VM. The machine will restart in less than a minute."
}