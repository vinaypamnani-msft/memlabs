configuration Phase2BDC
{
    param
    (
        [Parameter(Mandatory)]
        [string]$DeployConfigPath,
        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$Admincreds
    )

    Import-DscResource -ModuleName 'TemplateHelpDSC'
    Import-DscResource -ModuleName 'PSDesiredStateConfiguration', 'NetworkingDsc', 'xDhcpServer', 'DnsServerDsc', 'ComputerManagementDsc', 'ActiveDirectoryDsc'

    # Define log share
    $LogFolder = "DSC"
    $LogPath = "c:\staging\$LogFolder"

    # Read config
    $deployConfig = Get-Content -Path $DeployConfigPath | ConvertFrom-Json
    $DomainName = $deployConfig.parameters.domainName
    $DomainAdminName = $deployConfig.vmOptions.adminName

    # This VM
    $ThisMachineName = $deployConfig.parameters.ThisMachineName
    $ThisVM = $deployConfig.virtualMachines | Where-Object { $_.vmName -eq $ThisMachineName }
    $PDC = $deployConfig.virtualMachines | Where-Object { $_.role -eq "DC" }

    # PDC IP address (always .1 on the network)
    $pdcNetwork = if ($PDC.network) { $PDC.network } else { $deployConfig.vmOptions.network }
    $PDCIPAddress = $pdcNetwork.Substring(0, $pdcNetwork.LastIndexOf(".")) + ".1"

    # Domain creds
    [System.Management.Automation.PSCredential]$DomainCreds = New-Object System.Management.Automation.PSCredential ("${DomainName}\$($Admincreds.UserName)", $Admincreds.Password)

    Node LOCALHOST
    {
        LocalConfigurationManager {
            ConfigurationMode  = 'ApplyOnly'
            RebootNodeIfNeeded = $true
        }

        WriteStatus NewName {
            Status = "Renaming the computer to $ThisMachineName"
        }

        Computer NewName {
            Name = $ThisMachineName
        }

        WriteStatus InitDisks {
            DependsOn = "[Computer]NewName"
            Status    = "Initializing disks"
        }

        InitializeDisks InitDisks {
            DependsOn = "[Computer]NewName"
            DummyKey  = "Dummy"
            VM        = $ThisVM | ConvertTo-Json
        }

        $PageFileSize = ($thisVM.memory) / 2MB
        SetCustomPagingFile PagingSettings {
            DependsOn   = "[InitializeDisks]InitDisks"
            Drive       = 'C:'
            InitialSize = $PageFileSize
            MaximumSize = $PageFileSize
        }
        
        WriteStatus InstallFeature {
            DependsOn = "[SetCustomPagingFile]PagingSettings"
            Status    = "Installing required windows features"
        }

        InstallFeatureForSCCM InstallFeature {
            Name      = 'DC'
            Role      = 'DC'
            DependsOn = "[SetCustomPagingFile]PagingSettings"
        }

        $nextDepend = "[InstallFeatureForSCCM]InstallFeature"

        WriteStatus InstallDotNet {
            DependsOn = $nextDepend
            Status    = "Installing .NET 4.8"
        }

        InstallDotNet4 DotNet {
            DownloadUrl = $deployConfig.URLS.DotNet
            FileName    = "ndp48-x86-x64-allos-enu.exe"
            NetVersion  = "528040"
            Ensure      = "Present"
            DependsOn   = "[WriteStatus]InstallDotNet"
        }
        $nextDepend = "[InstallDotNet4]DotNet"

        # Explicitly set DNS to the PDC's IP so domain name resolution works
        # regardless of DHCP state (DHCP may not have the PDC as DNS yet if
        # the PDC is still creating the domain)
        $alias = (Get-NetAdapter).Name | Select-Object -First 1

        WriteStatus SetDNS {
            DependsOn = $nextDepend
            Status    = "Setting DNS to PDC ($PDCIPAddress)"
        }

        DnsServerAddress SetDNS {
            Address        = $PDCIPAddress
            InterfaceAlias = $alias
            AddressFamily  = 'IPv4'
            Validate       = $false
            DependsOn      = "[WriteStatus]SetDNS"
        }
        $nextDepend = "[DnsServerAddress]SetDNS"

        WriteStatus WaitDomain {
            DependsOn = $nextDepend
            Status    = "Waiting for domain to be ready"
        }

        WaitForDomainReady WaitForDomain {
            DependsOn  = "[WriteStatus]WaitDomain"
            Ensure     = "Present"
            DomainName = $DomainName
            DCName     = $PDC.vmName
        }

        $nextDepend = "[WaitForDomainReady]WaitForDomain"

        #ModuleAdd ActiveDirectory {
        #    Key             = 'Always'
        #    CheckModuleName = 'ActiveDirectory'
        #}

        #$nextDepend = "[ModuleAdd]ActiveDirectory"

        WriteStatus NewDS {
            DependsOn = $nextDepend
            Status    = "Configuring ADDS and setting up the domain Controller."
        }

        WaitForADDomain 'WaitForestAvailability' {
            DomainName              = $DomainName
            Credential              = $DomainCreds
            RestartCount            = 1
            WaitForValidCredentials = $true
            WaitTimeout             = 900
            DependsOn               = $nextDepend
        }
        $nextDepend = "[WaitForADDomain]WaitForestAvailability"

        OpenFirewallPortForSCCM OpenFirewall {
            DependsOn = $nextDepend
            Name      = "DC"
            Role      = "DC"
        }

        $nextDepend = "[OpenFirewallPortForSCCM]OpenFirewall"

        File ShareFolder {
            DestinationPath = $LogPath
            Type            = 'Directory'
            Ensure          = 'Present'
            DependsOn       = $nextDepend
        }
        $nextDepend = "[File]ShareFolder"

        RemoteDesktopAdmin RemoteDesktopSettings {
            IsSingleInstance   = 'yes'
            Ensure             = 'Present'
            UserAuthentication = 'NonSecure'
            DependsOn          = $nextDepend
        }

        $nextDepend = "[RemoteDesktopAdmin]RemoteDesktopSettings"

        AddNtfsPermissions AddNtfsPerms {
            Ensure    = "Present"
            DependsOn = $nextDepend
        }
        $nextDepend = "[AddNtfsPermissions]AddNtfsPerms"

        RebootNow RebootNow {
            FileName  = 'C:\Temp\BDCReboot.txt'
            DependsOn = $nextDepend
        }

        $nextDepend = "[RebootNow]RebootNow"

        ADDomainController 'DomainControllerAllProperties' {
            DomainName                    = $DomainName
            Credential                    = $DomainCreds
            SafeModeAdministratorPassword = $DomainCreds
            DatabasePath                  = 'C:\Windows\NTDS'
            LogPath                       = 'C:\Windows\Logs'
            SysvolPath                    = 'C:\Windows\SYSVOL'
            #SiteName                      = 'Europe'
            IsGlobalCatalog               = $false
            InstallDns                    = $false
            DependsOn                     = $nextDepend
        }

        $nextDepend = '[ADDomainController]DomainControllerAllProperties'

        WriteStatus ForceReplication {
            DependsOn = $nextDepend
            Status    = "Forcing AD replication from $($PDC.vmName)"
        }

        Script ForceReplication {
            DependsOn  = "[WriteStatus]ForceReplication"
            GetScript  = { return @{ Result = (Get-Date).ToString() } }
            TestScript = {
                # Always run on first pass after promotion; skip if replication already confirmed
                $flag = 'C:\Temp\BDCReplicationDone.txt'
                if (Test-Path $flag) { return $true }
                return $false
            }
            SetScript  = {
                $pdcName = $using:PDC.vmName
                $domainDN = ($using:DomainName).Split('.') | ForEach-Object { "DC=$_" }
                $domainDN = $domainDN -join ','

                # Wait for NTDS service to be ready (can take a moment after promotion reboot)
                $timeout = (Get-Date).AddMinutes(5)
                while ((Get-Date) -lt $timeout) {
                    try {
                        $null = Get-ADDomainController -ErrorAction Stop
                        break
                    }
                    catch {
                        Start-Sleep -Seconds 5
                    }
                }

                # Force inbound replication from the PDC for all naming contexts
                try {
                    $sourceDC = Get-ADDomainController -Identity $pdcName -ErrorAction Stop
                    $localDC = Get-ADDomainController -ErrorAction Stop

                    foreach ($nc in @($domainDN, "CN=Configuration,$domainDN", "CN=Schema,CN=Configuration,$domainDN")) {
                        repadmin /replicate $localDC.HostName $sourceDC.HostName $nc /force 2>&1 | Out-Null
                    }

                    # Verify the vmbuildadmin account is now reachable
                    $retries = 0
                    while ($retries -lt 12) {
                        try {
                            $null = Get-ADUser -Identity $using:Admincreds.UserName -ErrorAction Stop
                            break
                        }
                        catch {
                            $retries++
                            Start-Sleep -Seconds 5
                        }
                    }
                }
                catch {
                    # Best-effort; replication will happen naturally within 15s anyway
                    Start-Sleep -Seconds 30
                }

                New-Item -Path 'C:\Temp\BDCReplicationDone.txt' -ItemType File -Force | Out-Null
            }
        }

        $nextDepend = "[Script]ForceReplication"

        FileReadAccessShare DomainSMBShare {
            Name      = $LogFolder
            Path      = $LogPath
            DependsOn = $nextDepend
        }

        $nextDepend = "[FileReadAccessShare]DomainSMBShare"

        
        WriteStatus Complete {
            DependsOn = $nextDepend
            Status    = "Complete!"
        }

        WriteEvent WriteConfigFinished {
            LogPath   = $LogPath
            WriteNode = "ConfigurationFinished"
            Status    = "Passed"
            Ensure    = "Present"
            DependsOn = $nextDepend
        }

    }
}