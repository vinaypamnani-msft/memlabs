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