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

        # Pre-compute values for Domain Admins membership verification.
        # After reboot the BDC is still a workgroup machine, so we use an
        # explicit LDAP bind to the PDC to confirm the admin account is in
        # Domain Admins before attempting promotion.  This avoids the race
        # where the BDC's cached Kerberos PAC pre-dates the PDC adding the
        # account to Domain Admins, which causes Install-ADDSDomainController
        # to fail with a credential-permissions warning.
        $cvDomainDN = (($DomainName).Split('.') | ForEach-Object { "DC=$_" }) -join ','
        $cvAdminUser = $Admincreds.UserName
        $cvAdminPassB64 = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($Admincreds.GetNetworkCredential().Password))

        WriteStatus VerifyCreds {
            DependsOn = $nextDepend
            Status    = "Verifying Domain Admins membership before promotion"
        }

        Script VerifyDomainAdminCreds {
            DependsOn  = "[WriteStatus]VerifyCreds"
            GetScript  = { return @{ Result = (Get-Date).ToString() } }
            TestScript = {
                if (Test-Path 'C:\Temp\VerifyDomainAdmin.txt') { return $true }
                return $false
            }
            SetScript  = [string]"
                `$pdcIP     = '$PDCIPAddress'
                `$domain    = '$DomainName'
                `$domainDN  = '$cvDomainDN'
                `$adminUser = '$cvAdminUser'
                `$adminPass = [System.Text.Encoding]::Unicode.GetString(
                                  [Convert]::FromBase64String('$cvAdminPassB64'))

                `$maxWait = 600   # 10 minutes
                `$waited  = 0
                `$verified = `$false

                while (`$waited -lt `$maxWait) {
                    try {
                        `$de = New-Object System.DirectoryServices.DirectoryEntry(
                            ""LDAP://`$pdcIP/`$domainDN"",
                            ""`$domain\`$adminUser"",
                            `$adminPass)
                        `$searcher = New-Object System.DirectoryServices.DirectorySearcher(`$de)
                        `$searcher.Filter = ""(&(objectClass=group)(cn=Domain Admins))""
                        `$searcher.PropertiesToLoad.Add(""member"") | Out-Null
                        `$result = `$searcher.FindOne()
                        if (`$result) {
                            `$found = @(`$result.Properties[""member""]) |
                                      Where-Object { `$_ -like ""CN=`$adminUser,*"" }
                            if (`$found) {
                                Write-Verbose ""User '`$adminUser' confirmed in Domain Admins via LDAP""
                                `$verified = `$true
                                break
                            }
                        }
                    }
                    catch {
                        Write-Verbose ""LDAP query to `$pdcIP failed: `$_""
                    }

                    Start-Sleep -Seconds 15
                    `$waited += 15
                    Write-Verbose ""Waiting for '`$adminUser' in Domain Admins (`$waited s / `$maxWait s)""
                }

                # Purge any cached Kerberos tickets so promotion uses a fresh TGT
                klist purge 2>&1 | Out-Null

                if (`$verified) {
                    New-Item -Path 'C:\Temp\VerifyDomainAdmin.txt' -ItemType File -Force | Out-Null
                }
                else {
                    # Not verified — request a guarded reboot to refresh credential state.
                    # Allow one reboot immediately, then at most once per hour.
                    `$rebootFile = 'C:\Temp\VerifyDomainAdmin.reboot'
                    `$shouldReboot = `$false

                    if (-not (Test-Path `$rebootFile)) {
                        `$shouldReboot = `$true
                    }
                    else {
                        try {
                            `$lastReboot = [DateTime]::Parse((Get-Content `$rebootFile -First 1))
                            if (([DateTime]::UtcNow - `$lastReboot).TotalMinutes -ge 60) {
                                `$shouldReboot = `$true
                            }
                        }
                        catch {
                            `$shouldReboot = `$true
                        }
                    }

                    if (`$shouldReboot) {
                        [DateTime]::UtcNow.ToString('o') | Out-File `$rebootFile -Force -Encoding ASCII
                        Write-Verbose ""Requesting reboot to refresh credential state""
                        `$global:DSCMachineStatus = 1
                    }
                    else {
                        Write-Warning ""Could not verify Domain Admins membership and reboot was recent. Proceeding anyway.""
                        New-Item -Path 'C:\Temp\VerifyDomainAdmin.txt' -ItemType File -Force | Out-Null
                    }
                }
            "
        }

        $nextDepend = "[Script]VerifyDomainAdminCreds"

        WriteStatus PromoteDC {
            DependsOn = $nextDepend
            Status    = "Promoting to Domain Controller (this takes 10-20 minutes)"
        }

        PromoteDomainController 'DomainControllerAllProperties' {
            DomainName                    = $DomainName
            Credential                    = $DomainCreds
            SafeModeAdministratorPassword = $DomainCreds
            DatabasePath                  = 'C:\Windows\NTDS'
            LogPath                       = 'C:\Windows\Logs'
            SysvolPath                    = 'C:\Windows\SYSVOL'
            IsGlobalCatalog               = $true
            InstallDns                    = $true
            DependsOn                     = "[WriteStatus]PromoteDC"
        }

        $nextDepend = '[PromoteDomainController]DomainControllerAllProperties'

        # Set the KDC default encryption types so all accounts get AES tickets.
        # Must be set on every DC since each runs its own KDC service.
        Registry KdcDefaultEncryptionTypes {
            Ensure    = 'Present'
            Key       = 'HKLM:\SYSTEM\CurrentControlSet\Services\KDC'
            ValueName = 'DefaultDomainSupportedEncTypes'
            ValueType = 'Dword'
            ValueData = '28'
            DependsOn = $nextDepend
        }

        # Reduce intra-site replication notification delay from 15s to 0s.
        Registry ReplNotifyPauseAfterModify {
            Ensure    = 'Present'
            Key       = 'HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters'
            ValueName = 'Replicator notify pause after modify (secs)'
            ValueType = 'Dword'
            ValueData = '0'
            DependsOn = $nextDepend
        }

        Registry ReplNotifyPauseBetweenDSAs {
            Ensure    = 'Present'
            Key       = 'HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters'
            ValueName = 'Replicator notify pause between DSAs (secs)'
            ValueType = 'Dword'
            ValueData = '0'
            DependsOn = $nextDepend
        }

        # Now that DNS server role is installed (InstallDns=$true above),
        # point DNS at self first for the local AD-integrated zones, with
        # PDC as fallback for records not yet replicated.
        # Uses custom SetDNSAddress (keyed on Name) instead of a second
        # DnsServerAddress (keyed on InterfaceAlias) to avoid the DSC
        # compile-time conflict with the pre-promotion SetDNS resource.
        SetDNSAddress SetDNSSelfAndPDC {
            Name      = 'PostPromotion'
            Address   = @('127.0.0.1', $PDCIPAddress)
            DependsOn = $nextDepend
        }
        $nextDepend = "[SetDNSAddress]SetDNSSelfAndPDC"

        WriteStatus ConfigureDnsForwarders {
            DependsOn = $nextDepend
            Status    = "Configuring DNS forwarders"
        }

        # After promotion + reboot the DNS Server WMI provider can take a
        # few minutes to become responsive.  DnsServerForwarder will hang
        # indefinitely if we call it before the provider is ready, so poll
        # with Get-DnsServerForwarder first.
        Script WaitForDnsServer {
            DependsOn  = "[WriteStatus]ConfigureDnsForwarders"
            GetScript  = { return @{ Result = (Get-Date).ToString() } }
            TestScript = {
                try {
                    $null = Get-DnsServerForwarder -ErrorAction Stop
                    return $true
                }
                catch { return $false }
            }
            SetScript  = {
                $waited = 0
                $ready  = $false
                while ($waited -lt 300) {
                    try {
                        $null = Get-DnsServerForwarder -ErrorAction Stop
                        $ready = $true
                        break
                    }
                    catch {
                        Write-Verbose "DNS Server not ready yet ($waited s)..."
                        Start-Sleep -Seconds 10
                        $waited += 10
                    }
                }
                if (-not $ready) {
                    Write-Verbose "DNS Server still not responsive after $waited s - proceeding anyway"
                }
            }
        }

        # DNS forwarders (matching the PDC's configuration)
        $DNSForwarderIPs = @('1.1.1.1', '8.8.8.8', '9.9.9.9')
        if ($deployConfig.DNSForwarders) {
            $DNSForwarderIPs = $deployConfig.DNSForwarders
        }

        DnsServerForwarder DnsServerForwarder {
            DependsOn        = "[Script]WaitForDnsServer"
            IsSingleInstance = 'Yes'
            IPAddresses      = $DNSForwarderIPs
            UseRootHint      = $true
            EnableReordering = $true
        }
        $nextDepend = "[DnsServerForwarder]DnsServerForwarder"

        # Pre-compute values for ForceReplication (avoids $using: which
        # causes Deserialize errors in PSDirect-compiled configurations)
        $frPdcName = $PDC.vmName
        $frDomainDN = (($DomainName).Split('.') | ForEach-Object { "DC=$_" }) -join ','
        $frAdminUser = $Admincreds.UserName

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
            SetScript  = [string]"
                `$pdcName = '$frPdcName'
                `$domainDN = '$frDomainDN'
                `$adminUser = '$frAdminUser'

                `$job = Start-Job -ScriptBlock {
                    param(`$pdcName, `$domainDN, `$adminUser)

                    Import-Module ActiveDirectory -ErrorAction SilentlyContinue

                    `$ntdsReady = `$false
                    for (`$i = 0; `$i -lt 18; `$i++) {
                        try {
                            `$null = Get-ADDomainController -ErrorAction Stop
                            `$ntdsReady = `$true
                            break
                        }
                        catch {
                            Start-Sleep -Seconds 5
                        }
                    }
                    if (-not `$ntdsReady) { return }

                    try {
                        `$sourceDC = Get-ADDomainController -Identity `$pdcName -ErrorAction Stop
                        `$localDC = Get-ADDomainController -ErrorAction Stop

                        foreach (`$nc in @(`$domainDN, ""CN=Configuration,`$domainDN"", ""CN=Schema,CN=Configuration,`$domainDN"")) {
                            repadmin /replicate `$localDC.HostName `$sourceDC.HostName `$nc /force 2>&1 | Out-Null
                        }
                    }
                    catch {
                    }

                    for (`$i = 0; `$i -lt 6; `$i++) {
                        try {
                            `$null = Get-ADUser -Identity `$adminUser -ErrorAction Stop
                            break
                        }
                        catch {
                            Start-Sleep -Seconds 3
                        }
                    }
                } -ArgumentList `$pdcName, `$domainDN, `$adminUser

                `$null = Wait-Job `$job -Timeout 180
                if (`$job.State -eq 'Running') {
                    Stop-Job `$job -ErrorAction SilentlyContinue
                }
                Remove-Job `$job -Force -ErrorAction SilentlyContinue

                New-Item -Path 'C:\Temp\BDCReplicationDone.txt' -ItemType File -Force | Out-Null
            "
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