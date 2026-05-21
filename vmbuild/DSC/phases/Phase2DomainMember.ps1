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
        
        WriteStatus WaitDomain {
            DependsOn = "[SetCustomPagingFile]PagingSettings"
            Status    = "Waiting for domain to be ready (Trying to ping the DC)"
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

            Script SeedTPMProtector {
                DependsOn  = "[WriteStatus]SeedTPM"
                GetScript  = { @{ Result = (Get-BitLockerVolume -MountPoint "C:" -ErrorAction SilentlyContinue).KeyProtector.Count } }
                TestScript = {
                    $vol = Get-BitLockerVolume -MountPoint "C:" -ErrorAction SilentlyContinue
                    return ($vol -and $vol.KeyProtector.Count -gt 0)
                }
                SetScript  = {
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