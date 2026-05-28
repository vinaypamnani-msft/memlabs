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

        # Before promotion, point DNS exclusively at the PDC so
        # WaitForADDomain / WaitForDomainReady can actually resolve
        # the domain. 127.0.0.1 has no DNS server at this point and
        # Windows DNS client's tight retry loop never falls back to
        # the secondary server in time.
        # After promotion, SetDNSSelfAndPDC switches to self + PDC.
        $alias = (Get-NetAdapter).Name | Select-Object -First 1

        WriteStatus SetDNS {
            DependsOn = $nextDepend
            Status    = "Setting DNS to PDC ($PDCIPAddress)"
        }

        DnsServerAddress SetDNS {
            Address        = @($PDCIPAddress)
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
            Status    = "Waiting for AD forest to be available"
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

        WriteStatus Prereqs {
            DependsOn = $nextDepend
            Status    = "Configuring RDP, file shares, and NTFS permissions"
        }

        File ShareFolder {
            DestinationPath = $LogPath
            Type            = 'Directory'
            Ensure          = 'Present'
            DependsOn       = "[WriteStatus]Prereqs"
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

        WriteStatus Reboot {
            DependsOn = $nextDepend
            Status    = "Rebooting before DC promotion"
        }

        RebootNow RebootNow {
            FileName  = 'C:\Temp\BDCReboot.txt'
            DependsOn = "[WriteStatus]Reboot"
        }

        $nextDepend = "[RebootNow]RebootNow"

        WriteStatus PromoteDC {
            DependsOn = $nextDepend
            Status    = "Promoting to Backup Domain Controller (this takes 10-20 minutes)"
        }

        ADDomainController 'DomainControllerAllProperties' {
            DomainName                    = $DomainName
            Credential                    = $DomainCreds
            SafeModeAdministratorPassword = $DomainCreds
            DatabasePath                  = 'C:\Windows\NTDS'
            LogPath                       = 'C:\Windows\Logs'
            SysvolPath                    = 'C:\Windows\SYSVOL'
            #SiteName                      = 'Europe'
            IsGlobalCatalog               = $true
            InstallDns                    = $true
            DependsOn                     = "[WriteStatus]PromoteDC"
        }

        $nextDepend = '[ADDomainController]DomainControllerAllProperties'

        # Now that DNS server role is installed (InstallDns=$true above),
        # point DNS at self first for the local AD-integrated zones, with
        # PDC as fallback for records not yet replicated.
        # Uses a Script resource because DSC won't allow two DnsServerAddress
        # resources targeting the same InterfaceAlias with different values.
        Script SetDNSSelfAndPDC {
            DependsOn  = $nextDepend
            GetScript  = { return @{ Result = (Get-DnsClientServerAddress -InterfaceAlias $using:alias -AddressFamily IPv4).ServerAddresses -join ',' } }
            TestScript = {
                $current = (Get-DnsClientServerAddress -InterfaceAlias $using:alias -AddressFamily IPv4).ServerAddresses
                $desired = @('127.0.0.1', $using:PDCIPAddress)
                return ($null -ne $current -and ($current -join ',') -eq ($desired -join ','))
            }
            SetScript  = {
                Set-DnsClientServerAddress -InterfaceAlias $using:alias -ServerAddresses @('127.0.0.1', $using:PDCIPAddress)
            }
        }
        $nextDepend = "[Script]SetDNSSelfAndPDC"

        WriteStatus ConfigureDnsForwarders {
            DependsOn = $nextDepend
            Status    = "Configuring DNS forwarders"
        }

        # DNS forwarders (matching the PDC's configuration)
        $DNSForwarderIPs = @('1.1.1.1', '8.8.8.8', '9.9.9.9')
        if ($deployConfig.DNSForwarders) {
            $DNSForwarderIPs = $deployConfig.DNSForwarders
        }

        DnsServerForwarder DnsServerForwarder {
            DependsOn        = "[WriteStatus]ConfigureDnsForwarders"
            IsSingleInstance = 'Yes'
            IPAddresses      = $DNSForwarderIPs
            UseRootHint      = $true
            EnableReordering = $true
        }
        $nextDepend = "[DnsServerForwarder]DnsServerForwarder"

        WriteStatus ForceReplication {
            DependsOn = $nextDepend
            Status    = "Forcing AD replication from $($PDC.vmName)"
        }

        Script ForceReplication {
            DependsOn  = "[WriteStatus]ForceReplication"
            GetScript  = { return @{ Result = (Get-Date).ToString() } }
            TestScript = {
                $flag = 'C:\Temp\BDCReplicationDone.txt'
                if (Test-Path $flag) { return $true }
                return $false
            }
            SetScript  = {
                $pdcName = $using:PDC.vmName
                $domainDN = ($using:DomainName).Split('.') | ForEach-Object { "DC=$_" }
                $domainDN = $domainDN -join ','
                $adminUser = $using:Admincreds.UserName

                # Run the entire replication attempt inside a background job
                # with a hard wall-clock timeout. Get-ADDomainController,
                # repadmin, and Get-ADUser can all hang indefinitely if NTDS
                # is still initializing after promotion reboot. The previous
                # 5-minute "timeout" loop only caught exceptions; if a cmdlet
                # blocked (no throw, no return), the while condition never
                # re-evaluated and DSC hung for 35+ minutes. A job with
                # Wait-Job -Timeout is the only reliable kill switch in PS 5.1.
                $job = Start-Job -ScriptBlock {
                    param($pdcName, $domainDN, $adminUser)

                    Import-Module ActiveDirectory -ErrorAction SilentlyContinue

                    # Wait for NTDS to accept connections (up to 90s)
                    $ntdsReady = $false
                    for ($i = 0; $i -lt 18; $i++) {
                        try {
                            $null = Get-ADDomainController -ErrorAction Stop
                            $ntdsReady = $true
                            break
                        }
                        catch {
                            Start-Sleep -Seconds 5
                        }
                    }
                    if (-not $ntdsReady) { return }

                    # Force inbound replication from the PDC for all naming contexts
                    try {
                        $sourceDC = Get-ADDomainController -Identity $pdcName -ErrorAction Stop
                        $localDC = Get-ADDomainController -ErrorAction Stop

                        foreach ($nc in @($domainDN, "CN=Configuration,$domainDN", "CN=Schema,CN=Configuration,$domainDN")) {
                            repadmin /replicate $localDC.HostName $sourceDC.HostName $nc /force 2>&1 | Out-Null
                        }
                    }
                    catch {
                        # Best-effort; replication converges naturally
                    }

                    # Verify admin account is reachable
                    for ($i = 0; $i -lt 6; $i++) {
                        try {
                            $null = Get-ADUser -Identity $adminUser -ErrorAction Stop
                            break
                        }
                        catch {
                            Start-Sleep -Seconds 3
                        }
                    }
                } -ArgumentList $pdcName, $domainDN, $adminUser

                # 3-minute hard timeout. Replication will converge naturally
                # within the 15-second intra-site interval, so bailing early
                # just means the next resource waits a few extra seconds.
                $null = Wait-Job $job -Timeout 180
                if ($job.State -eq 'Running') {
                    Stop-Job $job -ErrorAction SilentlyContinue
                }
                Remove-Job $job -Force -ErrorAction SilentlyContinue

                New-Item -Path 'C:\Temp\BDCReplicationDone.txt' -ItemType File -Force | Out-Null
            }
        }

        $nextDepend = "[Script]ForceReplication"

        WriteStatus FinalizeShares {
            DependsOn = $nextDepend
            Status    = "Creating log share and finishing up"
        }

        FileReadAccessShare DomainSMBShare {
            Name      = $LogFolder
            Path      = $LogPath
            DependsOn = "[WriteStatus]FinalizeShares"
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