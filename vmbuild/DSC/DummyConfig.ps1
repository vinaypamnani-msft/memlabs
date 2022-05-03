Configuration DummyConfig {

    # Cheat to include all modules guest VM's would need, so we have an exported copy.
    Import-DscResource -ModuleName 'PSDesiredStateConfiguration', 'NetworkingDsc', 'xDhcpServer', 'SqlServerDsc', 'DnsServerDsc', 'ComputerManagementDsc', 'xDscDiagnostics', 'ActiveDirectoryDsc', 'xFailOverCluster', 'AccessControlDsc', 'UpdateServicesDsc'

    Node LOCALHOST {

        LocalConfigurationManager {
            ConfigurationMode  = 'ApplyOnly'
            RebootNodeIfNeeded = $true
        }

        Script Initialize_Disk
        {
            DependsOn = '[xIPAddress]NewIPAddress'
            SetScript = {
                # Start logging the actions
                Start-Transcript -Path $env:windir\temp\Diskinitlog.txt -Append -Force

                # Move CD-ROM drive to Z:
                "Moving CD-ROM drive to Z:.."
                Get-WmiObject -Class Win32_volume -Filter 'DriveType=5' | Select-Object -First 1 | Set-WmiInstance -Arguments @{DriveLetter='Z:'}

                # Set the parameters
                $disks = Get-Disk | Where-Object partitionstyle -eq 'raw' | Sort-Object number
                $letters = 69..89 | ForEach-Object { [char]$_ }
                $count = 0
                $label = "Data"

                "Formatting disks.."
                foreach ($disk in $disks) {
                    $driveLetter = $letters[$count].ToString()
                    $disk | Initialize-Disk -PartitionStyle MBR -PassThru | New-Partition -UseMaximumSize -DriveLetter $driveLetter | Format-Volume -FileSystem NTFS -NewFileSystemLabel "$label.$count" -Confirm:$false -Force
                    "$label.$count"
                    $count++
                }

                Stop-Transcript
            }

            TestScript = {
                try
                {
                    Write-Verbose "Testing if any Raw disks are left"

                    # $Validate = New-Object -ComObject 'AgentConfigManager.MgmtSvcCfg' -ErrorAction SilentlyContinue
                    $Validate = Get-Disk | Where-Object partitionstyle -eq 'raw'
                }
                catch
                {
                    $ErrorMessage = $_.Exception.Message
                    $ErrorMessage
                }

                If (!($Validate -eq $null))
                {
                    Write-Verbose "Disks are not initialized"
                    return $False
                }
                Else
                {
                    Write-Verbose "Disks are initialized"
                    Return $True
                }
            }

            GetScript = { @{ Result = Get-Disk | Where-Object partitionstyle -eq 'raw' } }
        }


    }
}