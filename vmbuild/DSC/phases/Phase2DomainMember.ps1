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

            Script SeedTPMProtector {
                DependsOn  = "[Registry]PreventDeviceEncryption"
                GetScript  = { @{ Result = (Get-BitLockerVolume -MountPoint "C:" -ErrorAction SilentlyContinue).KeyProtector.Count } }
                TestScript = {
                    $vol = Get-BitLockerVolume -MountPoint "C:" -ErrorAction SilentlyContinue
                    return ($vol -and $vol.KeyProtector.Count -gt 0)
                }
                SetScript  = {
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