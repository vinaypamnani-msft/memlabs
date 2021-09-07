Configuration Host {
    
    Import-DscResource -ModuleName 'PSDesiredStateConfiguration', 'xHyper-V', 'xNetworking', 'xDscDiagnostics'
    
    $externalSwitchName = "External"
    
    $phsyicalNic = Get-NetAdapter | Where-Object {$_.InterfaceDescription -like "Microsoft Hyper-V Network Adapter*" }
    
    $phsyicalInterface = $phsyicalNic.Name
    $externalInterface = "vEthernet ($externalSwitchName)"

    $repoName = "memlabs"
    $repoUrl = "https://github.com/vinaypamnani-msft/$repoName"
    
    Node LOCALHOST {
    
        LocalConfigurationManager {            
            ConfigurationMode  = 'ApplyOnly'
            RebootNodeIfNeeded = $true                       
        }

        # Windows Features

        WindowsFeature Routing {
            Ensure               = 'Present'
            Name                 = 'Routing'
            IncludeAllSubFeature = $true            
        }

        WindowsFeature Hyper-V {
            Ensure               = 'Present'
            Name                 = "Hyper-V"
            IncludeAllSubFeature = $true
        }

        WindowsFeature Hyper-V-Tools {
            Ensure               = 'Present'
            Name                 = 'Hyper-V-Tools'
            IncludeAllSubFeature = $true
        }
    
        WindowsFeature Hyper-V-PowerShell {
            Ensure               = 'Present'
            Name                 = 'Hyper-V-PowerShell'
            IncludeAllSubFeature = $true
        }

        WindowsFeature Routing {
            Ensure               = 'Present'
            Name                 = 'Routing'
            IncludeAllSubFeature = $true            
        }
        
        WindowsFeature DirectAccess-VPN {
            Ensure               = 'Present'
            Name                 = 'DirectAccess-VPN'
            IncludeAllSubFeature = $true            
        }

        WindowsFeature RSAT-RemoteAccess {
            Ensure               = 'Present'
            Name                 = 'RSAT-RemoteAccess'
            IncludeAllSubFeature = $true
        }
    
        # Hyper-V Host Network Settings

        xVMSwitch ExternalSwitch
        {
            DependsOn      = '[WindowsFeature]Hyper-V'
            Ensure         = 'Present'
            Name           = $externalSwitchName
            Type           = 'External'
            NetAdapterName = $phsyicalInterface
        }
    
        # RRAS Settings

        Script ConfigureNAT
        {
            DependsOn = '[xVMSwitch]ExternalSwitch'
            SetScript = {
                
                Install-RemoteAccess -VpnType RoutingOnly                
                
                cmd.exe /c netsh routing ip nat install
                cmd.exe /c netsh routing ip nat add interface "$using:externalInterface"
                cmd.exe /c netsh routing ip nat set interface "$using:externalInterface" mode=full                
                cmd.exe /c reg add HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\RemoteAccess\Parameters /v ModernStackEnabled /t REG_DWORD /d 0 /f

            }
            TestScript = {
                $text = & netsh routing ip nat show interface
                if ($text -like "*$using:externalInterface*") { return $true } else { return $false }
            }
            GetScript = {
                # Do Nothing
            }
        }

        Script MoveCDDrive
        {
            DependsOn = '[Script]ConfigureNAT'
            SetScript = {
                # Start logging the actions 
                Start-Transcript -Path $env:windir\temp\CDMovelog.txt -Append -Force
    
                # Move CD-ROM drive to Z:
                "Moving CD-ROM drive to Z:.."
                Get-WmiObject -Class Win32_volume -Filter 'DriveType=5' | Select-Object -First 1 | Set-WmiInstance -Arguments @{DriveLetter='Z:'}
    
                Stop-Transcript
            }
            
            TestScript = {
                $x = Get-WmiObject -Class Win32_volume -Filter 'DriveType=5 AND DriveLetter="Z:"'
                if ($x) {return $true } else { return $false }
            }    
    
            GetScript = { 
                # Do nothing
            }
        }        

        Script StoragePool {
            DependsOn = "[Script]MoveCDDrive"
            SetScript = {
                New-StoragePool -FriendlyName StoragePool1 -StorageSubSystemFriendlyName '*storage*' -PhysicalDisks (Get-PhysicalDisk -CanPool $True)
            }
            TestScript = {
                (Get-StoragePool -ErrorAction SilentlyContinue -FriendlyName StoragePool1).OperationalStatus -eq 'OK'
            }
            GetScript = {
                @{Ensure = if ((Get-StoragePool -FriendlyName StoragePool1).OperationalStatus -eq 'OK') {'Present'} Else {'Absent'}}
            }
        }

        Script VirtualDisk {
            DependsOn = "[Script]StoragePool"
            SetScript = {
              $disks = Get-StoragePool -FriendlyName StoragePool1 -IsPrimordial $False | Get-PhysicalDisk
              $diskNum = $disks.Count
              New-VirtualDisk -StoragePoolFriendlyName StoragePool1 -FriendlyName VirtualDisk1 -ResiliencySettingName simple -NumberOfColumns $diskNum -UseMaximumSize 
            }
            TestScript = {
              (get-virtualdisk -ErrorAction SilentlyContinue -friendlyName VirtualDisk1).OperationalStatus -eq 'OK'
            }
            GetScript = {
              @{Ensure = if ((Get-VirtualDisk -FriendlyName VirtualDisk1).OperationalStatus -eq 'OK') {'Present'} Else {'Absent'}}
            }            
        }

        Script FormatDisk {
            DependsOn = "[Script]VirtualDisk"
            SetScript = {
                Get-VirtualDisk -FriendlyName VirtualDisk1 | Get-Disk | Initialize-Disk -Passthru | New-Partition -AssignDriveLetter -UseMaximumSize | Format-Volume -NewFileSystemLabel VirtualDisk1 -AllocationUnitSize 64KB -FileSystem NTFS
            }
            TestScript = {
                (get-volume -ErrorAction SilentlyContinue -filesystemlabel VirtualDisk1).filesystem -EQ 'NTFS'
            }
            GetScript = {
                @{Ensure = if ((get-volume -filesystemlabel VirtualDisk1).filesystem -EQ 'NTFS') {'Present'} Else {'Absent'}}
            }            
        }

        Script DownloadFiles {
            DependsOn = "[Script]FormatDisk"
            SetScript = {
                Start-Transcript -Path $env:windir\temp\RepoClone.txt -Append -Force

                "Downloading and installing chocolatey"
                Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))

                "Installing git via choco"
                & choco install git -y

                "Cloning the repository"
                $destination = "E:\$using:repoName"
                git clone $using:repoUrl $destination

                Stop-Transcript
            }
            TestScript = {
                return (Test-Path "E:\$using:repoName")
            }
            GetScript = {
                # Do nothing
            }
        }
    }
}