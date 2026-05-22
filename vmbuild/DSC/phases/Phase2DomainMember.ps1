configuration Phase2DomainMember
{
    param
    (
        [Parameter(Mandatory)]
        [string]$DeployConfigPath,
        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$Admincreds
    )

    Set-ExecutionPolicy -ExecutionPolicy Bypass -Force
    Import-DscResource -ModuleName 'TemplateHelpDSC'
    Import-DscResource -ModuleName 'PSDesiredStateConfiguration', 'ComputerManagementDsc'

    # Read config
    $deployConfig = Get-Content -Path $DeployConfigPath | ConvertFrom-Json
    $DomainName = $deployConfig.parameters.domainName

    $DCName = $deployConfig.parameters.DCName

    $ThisMachineName = $deployConfig.parameters.ThisMachineName
    $ThisVM = $deployConfig.virtualMachines | Where-Object { $_.vmName -eq $ThisMachineName }

    if ($thisVM.Domain) {
        $DomainName = $thisVM.Domain
    }

    # Log share
    $LogFolder = "DSC"
    $LogPath = "c:\staging\$LogFolder"

    # Firewall Roles
    $firewallRoles = @("DomainMember")
    if ($ThisVM.role -in "CAS", "Primary", "PassiveSite", "Secondary") {
        $firewallRoles += @("Site Server", "Provider", "CM Console", "Management Point", "Distribution Point", "Software Update Point", "Reporting Services Point")
    }
    if ($ThisVM.role -eq "SiteSystem") {
        $firewallRoles += @("Management Point", "Distribution Point", "Software Update Point", "Reporting Services Point")
    }

    # Domain creds
    [System.Management.Automation.PSCredential]$DomainCreds = New-Object System.Management.Automation.PSCredential ("${DomainName}\$($Admincreds.UserName)", $Admincreds.Password)

    Node localhost
    {
        LocalConfigurationManager {
            ConfigurationMode  = 'ApplyOnly'
            RebootNodeIfNeeded = $true
        }

        WriteStatus Rename {
            Status = "Renaming the computer to $ThisMachineName"
        }

        Computer NewName {
            Name      = $ThisMachineName
            DependsOn = "[WriteStatus]Rename"
        }

        WriteStatus InitDisks {
            DependsOn = "[Computer]NewName"
            Status    = "Initializing disks"
        }

        InitializeDisks InitDisks {
            DependsOn = "[WriteStatus]InitDisks"
            DummyKey  = "Dummy"
            VM        = $ThisVM | ConvertTo-Json
        }

        $PageFileSize = ($thisVM.memory)/2MB
        SetCustomPagingFile PagingSettings {
            DependsOn   = "[InitializeDisks]InitDisks"
            Drive       = 'C:'
            InitialSize = $PageFileSize
            MaximumSize = $PageFileSize
        }
        
        WriteStatus DisableWU {
            DependsOn = "[SetCustomPagingFile]PagingSettings"
            Status    = "Disabling Windows Update"
        }

        # Disable Windows Update before domain join reboot so WU doesn't fire on restart
        Script DisableWindowsUpdate {
            DependsOn  = "[WriteStatus]DisableWU"
            GetScript  = { @{ Result = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -Name NoAutoUpdate -ErrorAction SilentlyContinue).NoAutoUpdate } }
            TestScript = {
                $val = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -Name NoAutoUpdate -ErrorAction SilentlyContinue
                return ($val -and $val.NoAutoUpdate -eq 1)
            }
            SetScript  = {
                New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -Force | Out-Null
                New-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -Name 'NoAutoUpdate' -PropertyType DWord -Value 1 -Force | Out-Null
                Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
            }
        }

        WriteStatus WaitDomain {
            DependsOn = "[Script]DisableWindowsUpdate"
            Status    = "Waiting for domain $DomainName to be ready (Trying to ping the DC)"
        }

        WaitForDomainReady WaitForDomain {
            DependsOn  = "[WriteStatus]WaitDomain"
            Ensure     = "Present"
            DomainName = $DomainName
            DCName     = $DCName
        }

        WriteStatus DomainJoin {
            DependsOn = "[WaitForDomainReady]WaitForDomain"
            Status    = "Joining computer to the domain"
        }

        JoinDomain JoinDomain {
            DomainName = $DomainName
            Credential = $DomainCreds
            DependsOn  = "[WriteStatus]DomainJoin"
        }

        AddNtfsPermissions AddNtfsPerms {
            Ensure    = "Present"
            DependsOn = "[JoinDomain]JoinDomain"
        }

        File ShareFolder {
            DestinationPath = $LogPath
            Type            = 'Directory'
            Ensure          = 'Present'
            DependsOn       = '[AddNtfsPermissions]AddNtfsPerms'
        }

        FileReadAccessShare DomainSMBShare {
            Name      = $LogFolder
            Path      = $LogPath
            DependsOn = "[File]ShareFolder"
        }

        OpenFirewallPortForSCCM OpenFirewall {
            DependsOn = "[FileReadAccessShare]DomainSMBShare"
            Name      = "DomainMember"
            Role      = $firewallRoles
        }

        # Pre-seed TPM protector for BitLocker VMs
        # Windows 11 24H2 on Hyper-V 512e disks cannot add a NumericalPassword as the first protector.
        # The ConfigMgr BLM handler calls ProtectKeyWithNumericalPassword first, which fails with 0x8007001f.
        # Pre-adding a TPM protector works around this by ensuring the volume already has a protector.
        if ($ThisVM.BitLocker -eq $true) {
            WriteStatus SeedTPM {
                DependsOn = "[OpenFirewallPortForSCCM]OpenFirewall"
                Status    = "Adding TPM protector for BitLocker"
            }

            # Prevent Windows 11 24H2 automatic device encryption on first login.
            # We want ConfigMgr BLM to manage encryption, not the OS auto-trigger.
            Registry PreventDeviceEncryption {
                DependsOn = "[WriteStatus]SeedTPM"
                Ensure    = "Present"
                Key       = "HKLM:\SYSTEM\CurrentControlSet\Control\BitLocker"
                ValueName = "PreventDeviceEncryption"
                ValueType = "Dword"
                ValueData = "1"
            }

            # Cancel the auto-device-encryption flow if it was already initiated before
            # PreventDeviceEncryption was set. The KeyBackupMonitor flags cause
            # UserOOBEBroker to retry encryption at every logon.
            # Note: AutoDE\HSTI is TrustedInstaller-protected and cannot be deleted even as SYSTEM.
            Script CancelAutoDeviceEncryption {
                DependsOn = "[Registry]PreventDeviceEncryption"
                GetScript  = { @{ Result = "N/A" } }
                TestScript = {
                    $monitor = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\BitLocker\KeyBackupMonitor" -ErrorAction SilentlyContinue
                    return (-not $monitor -or $monitor.IsKeyBackupMonitorStarted -eq 0)
                }
                SetScript  = {
                    # Clear the key backup monitor that retries encryption at each logon
                    $monPath = "HKLM:\SYSTEM\CurrentControlSet\Control\BitLocker\KeyBackupMonitor"
                    if (Test-Path $monPath) {
                        Set-ItemProperty $monPath -Name "IsKeyBackupMonitorStarted" -Value 0 -ErrorAction SilentlyContinue
                        Set-ItemProperty $monPath -Name "IsKeyBackupMonitorStartedLocal" -Value 0 -ErrorAction SilentlyContinue
                    }
                    # Remove BDESVC service trigger so it doesn't auto-start and launch fvenotify.exe
                    sc.exe triggerinfo BDESVC delete 2>&1 | Out-Null
                    # Stop BDESVC now (prevents fvenotify popup until ConfigMgr BLM starts it)
                    Stop-Service BDESVC -Force -ErrorAction SilentlyContinue
                    # Disable scheduled tasks as belt-and-suspenders
                    Get-ScheduledTask -TaskPath "\Microsoft\Windows\BitLocker\" -ErrorAction SilentlyContinue |
                        Where-Object { $_.State -ne "Disabled" } |
                        Disable-ScheduledTask -ErrorAction SilentlyContinue
                }
            }

            Script SeedTPMProtector {
                DependsOn  = "[Script]CancelAutoDeviceEncryption"
                GetScript  = { @{ Result = (Get-BitLockerVolume -MountPoint "C:" -ErrorAction SilentlyContinue).KeyProtector.Count } }
                TestScript = {
                    $vol = Get-BitLockerVolume -MountPoint "C:" -ErrorAction SilentlyContinue
                    if (-not $vol) { return $false }
                    # If volume is not fully decrypted, auto-encryption was triggered and must be cleaned up
                    if ($vol.VolumeStatus -ne "FullyDecrypted") { return $false }
                    # Ensure a TPM protector specifically exists (not just any protector from auto-encryption)
                    $tpmProtector = $vol.KeyProtector | Where-Object { $_.KeyProtectorType -eq "Tpm" }
                    return ($null -ne $tpmProtector)
                }
                SetScript  = {
                    $vol = Get-BitLockerVolume -MountPoint "C:" -ErrorAction SilentlyContinue

                    # If auto-device-encryption was triggered before PreventDeviceEncryption was set, cancel it
                    if ($vol -and $vol.VolumeStatus -ne "FullyDecrypted") {
                        manage-bde -off C: 2>&1 | Out-Null
                        do {
                            Start-Sleep -Seconds 2
                            $vol = Get-BitLockerVolume -MountPoint "C:"
                        } while ($vol.VolumeStatus -ne "FullyDecrypted")
                    }

                    # Remove any existing protectors from failed auto-encryption
                    if ($vol -and $vol.KeyProtector.Count -gt 0) {
                        $hasTpm = $vol.KeyProtector | Where-Object { $_.KeyProtectorType -eq "Tpm" }
                        if (-not $hasTpm) {
                            foreach ($kp in $vol.KeyProtector) {
                                Remove-BitLockerKeyProtector -MountPoint "C:" -KeyProtectorId $kp.KeyProtectorId -ErrorAction SilentlyContinue
                            }
                        }
                    }

                    # Provision TPM ownership (Hyper-V virtual TPMs are not auto-provisioned)
                    $initResult = Initialize-Tpm -ErrorAction SilentlyContinue
                    if ($initResult -and $initResult.RestartRequired) {
                        # TPM provisioning needs a reboot before the TPM can be used
                        $global:DSCMachineStatus = 1
                        return
                    }
                    $result = manage-bde -protectors -add C: -TPM 2>&1
                    if ($LASTEXITCODE -ne 0) { throw "Failed to add TPM protector: $result" }
                }
            }

            WriteStatus Complete {
                DependsOn = "[Script]SeedTPMProtector"
                Status    = "Complete!"
            }
        }
        else {
            WriteStatus Complete {
                DependsOn = "[OpenFirewallPortForSCCM]OpenFirewall"
                Status    = "Complete!"
            }
        }
    }
}