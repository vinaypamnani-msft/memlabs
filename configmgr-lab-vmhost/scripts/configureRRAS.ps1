
# Logging
$logFile = "$env:windir\temp\configureHost.log"

function Write-HostLog {
    param ($Text)
    "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] $Text" | Out-File -Append $logFile
}

Write-HostLog "START"

# Install HyperV
Write-Host "Installing Hyper-V"
Install-WindowsFeature 'Hyper-V"', 'Hyper-V-Tools', 'Hyper-V-PowerShell' -Confirm:$false -IncludeAllSubFeature -IncludeManagementTools

# Create External Switch
$phsyicalNic = Get-NetAdapter | Where-Object {$_.InterfaceDescription -like "Microsoft Hyper-V Network Adapter*" }
$phsyicalInterface = $phsyicalNic.Name
$externalSwitchName = "External"
$switch = Get-VMSwitch -Name $externalSwitchName -SwitchType External -ErrorAction SilentlyContinue

if ($null -eq $switch) {
    Write-HostLog "External swich not present. Creating..."
    New-VMSwitch -Name "External2" -NetAdapterName $phsyicalInterface -AllowManagementOS $true
    $switch = Get-VMSwitch -Name $externalSwitchName -SwitchType External -ErrorAction SilentlyContinue
    if ($switch) {
        Write-HostLog "Created External switch."
    }
    else {
        Write-HostLog "Failed to create external switch. Exiting."
        return
    }
}
else {
    Write-HostLog "External switch already exists."
}

# Change CD-ROM Drive Letter
Write-HostLog "Changing CD-ROM DriveLetter to Z:"
Get-WmiObject -Class Win32_volume -Filter 'DriveType=5' | Select-Object -First 1 | Set-WmiInstance -Arguments @{DriveLetter='Z:'}
$x = Get-WmiObject -Class Win32_volume -Filter 'DriveType=5 AND DriveLetter="Z:"'
if ($x) {
    Write-HostLog "Changed Driveletter of CD-ROM drive"
} else {
    Write-HostLog "Failed to change Driveletter of CD-ROM drive. Exiting."
    return
}

# Create Storage Pool
$poolName = "StoragePool1"
Write-HostLog "Creating Storage Pool named $poolName"
New-StoragePool -FriendlyName $poolName -StorageSubSystemFriendlyName '*storage*' -PhysicalDisks (Get-PhysicalDisk -CanPool $True)
$pool = Get-StoragePool -ErrorAction SilentlyContinue -FriendlyName $poolName
if ($pool.OperationalStatus -eq 'OK') {
    Write-HostLog "Storage Pool created."
}
else {
    Write-HostLog "Storage Pool was not created. Exiting."
    return
}

# Create Virtual Disks
$virtualdiskName = "VirtualDisk1"
Write-HostLog "Creating Virtual Disk named $virtualDiskName"
$disks = Get-StoragePool -FriendlyName $poolName -IsPrimordial $False | Get-PhysicalDisk
$diskNum = $disks.Count
New-VirtualDisk -StoragePoolFriendlyName $poolName -FriendlyName $virtualdiskName -ResiliencySettingName simple -NumberOfColumns $diskNum -UseMaximumSize
$vdisk = get-virtualdisk -ErrorAction SilentlyContinue -friendlyName $virtualdiskName
if ($vdisk.OperationalStatus -eq 'OK') {
    Write-HostLog "$diskNum Virtual Disks created."
}
else {
    Write-HostLog "Virtual Disks were not created. Exiting."
    return
}

# Format virtual disks
Write-HostLog "Formatting Virtual Disk $virtualDiskName"
Get-VirtualDisk -FriendlyName $virtualDiskName | Get-Disk | Initialize-Disk -Passthru | New-Partition -AssignDriveLetter -UseMaximumSize | Format-Volume -NewFileSystemLabel $virtualDiskName -AllocationUnitSize 64KB -FileSystem NTFS
$vol = Get-Volume -ErrorAction SilentlyContinue -filesystemlabel $virtualdiskName
if ($vol.filesystem -EQ 'NTFS') {
    Write-HostLog "$virtualDiskName disk volume created."
}
else {
    Write-HostLog "$virtualDiskName disk volume was not created. Exiting."
    return
}

# Install choco
Write-HostLog "Installing chocolatey"
Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))

# Reload PATH
Write-HostLog "Reloading PATH"
$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")

# Install git
Write-HostLog "Installing git via choco"
& choco install git -y

# Install sysinternals
Write-HostLog "Installing sysinternals via choco"
& choco install sysinternals -y

# Clone the repo
Write-HostLog "Cloning the repository"
$repoName = "memlabs"
$repoUrl = "https://github.com/vinaypamnani-msft/$repoName"

$destination = "$($vol.DriveLetter):\$repoName"
git clone $repoUrl $destination --quiet

# Install RRAS
Write-HostLog "Installing RRAS"
Install-WindowsFeature 'Routing', 'DirectAccess-VPN' -Confirm:$false -IncludeAllSubFeature -IncludeManagementTools

# External Hyper-V Switch name (created by Host DSC)
$externalInterface = "vEthernet ($externalSwitchName)"

# Configure NAT
Write-HostLog "Configuring NAT"
Install-RemoteAccess -VpnType RoutingOnly
cmd.exe /c netsh routing ip nat install
cmd.exe /c netsh routing ip nat add interface "$externalInterface"
cmd.exe /c netsh routing ip nat set interface "$externalInterface" mode=full
cmd.exe /c reg add HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\RemoteAccess\Parameters /v ModernStackEnabled /t REG_DWORD /d 0 /f

Write-HostLog "FINISH"