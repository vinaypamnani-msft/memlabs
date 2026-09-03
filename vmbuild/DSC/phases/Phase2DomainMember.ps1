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
    if ($ThisVM.sqlVersion -and ("SQL Server" -notin $firewallRoles)) {
        $firewallRoles += "SQL Server"
    }
    $isWindows11DP = $ThisVM.role -eq 'SiteSystem' -and $ThisVM.installDP -eq $true -and "$($ThisVM.operatingSystem)" -like 'Windows 11*'

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
                $wuPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
                $auPath = "$wuPath\AU"
                New-Item -Path $auPath -Force | Out-Null
                New-ItemProperty -Path $auPath -Name 'NoAutoUpdate' -PropertyType DWord -Value 1 -Force | Out-Null
                New-ItemProperty -Path $wuPath -Name 'DoNotConnectToWindowsUpdateInternetLocations' -PropertyType DWord -Value 1 -Force | Out-Null
                New-ItemProperty -Path $wuPath -Name 'DisableWindowsUpdateAccess' -PropertyType DWord -Value 1 -Force | Out-Null
                $service = Get-Service -Name wuauserv -ErrorAction SilentlyContinue
                if ($service -and $service.Status -ne 'Stopped') {
                    $stopWatch = [System.Diagnostics.Stopwatch]::StartNew()
                    try {
                        $service.Stop()
                        $service.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Stopped, [TimeSpan]::FromSeconds(30))
                    }
                    catch {
                        $service.Refresh()
                        Write-Warning "wuauserv did not stop within 30 seconds. Current status: $($service.Status). Error: $_"
                    }
                    finally {
                        $stopWatch.Stop()
                        Write-Verbose "wuauserv stop attempt completed in $([math]::Round($stopWatch.Elapsed.TotalSeconds, 1)) seconds."
                    }
                }
            }
        }

        # ---------------------------------------------------------------------
        # Domain-independent local OS configuration — run BEFORE the domain
        # wait/join, not after the post-join reboot.
        #
        # None of these resources need AD membership (pure local icacls/takeown,
        # a local SMB share, local firewall rules, a local registry value). On a
        # fresh deploy the member otherwise sits idle in WaitForDomainReady while
        # the DC promotes; doing this local work first overlaps it with that
        # wait. After the join reboot DSC just re-Tests these (fast no-op), so the
        # expensive Sets stay off the post-join critical path. All of them persist
        # across the domain-join reboot.
        # ---------------------------------------------------------------------
        AddNtfsPermissions AddNtfsPerms {
            Ensure    = "Present"
            DependsOn = "[Script]DisableWindowsUpdate"
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

        $remoteAdminDependency = "[OpenFirewallPortForSCCM]OpenFirewall"
        if ($isWindows11DP) {
            Script ClientDpRemoteManagementFirewall {
                GetScript  = { @{ Result = 'N/A' } }
                TestScript = {
                    $requiredRules = @(
                        'MemLabs ConfigMgr DP RPC Endpoint Mapper TCP',
                        'MemLabs ConfigMgr DP RPC Endpoint Mapper UDP',
                        'MemLabs ConfigMgr DP Dynamic RPC',
                        'MemLabs ConfigMgr DP WMI',
                        'MemLabs ConfigMgr DP SMB'
                    )
                    foreach ($ruleName in $requiredRules) {
                        $rule = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
                        if (-not $rule -or $rule.Enabled -ne 'True' -or $rule.Direction -ne 'Inbound' -or $rule.Action -ne 'Allow') {
                            return $false
                        }
                    }
                    return $true
                }
                SetScript  = {
                    foreach ($groupName in @('Windows Management Instrumentation (WMI)', 'Remote Service Management', 'File and Printer Sharing')) {
                        Enable-NetFirewallRule -DisplayGroup $groupName -ErrorAction SilentlyContinue
                    }

                    $ruleDefinitions = @(
                        @{ Name = 'MemLabs ConfigMgr DP RPC Endpoint Mapper TCP'; Protocol = 'TCP'; LocalPort = '135' },
                        @{ Name = 'MemLabs ConfigMgr DP RPC Endpoint Mapper UDP'; Protocol = 'UDP'; LocalPort = '135' },
                        @{ Name = 'MemLabs ConfigMgr DP Dynamic RPC'; Protocol = 'TCP'; LocalPort = '49152-65535' },
                        @{ Name = 'MemLabs ConfigMgr DP WMI'; Protocol = 'TCP'; LocalPort = 'RPC'; Program = "$env:SystemRoot\system32\svchost.exe"; Service = 'winmgmt' },
                        @{ Name = 'MemLabs ConfigMgr DP SMB'; Protocol = 'TCP'; LocalPort = '445' }
                    )
                    foreach ($definition in $ruleDefinitions) {
                        Get-NetFirewallRule -DisplayName $definition.Name -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
                        $parameters = @{
                            DisplayName = $definition.Name
                            Group       = 'For ConfigMgr Client DP Provisioning'
                            Profile     = 'Any'
                            Direction   = 'Inbound'
                            Action      = 'Allow'
                            Enabled     = 'True'
                            Protocol    = $definition.Protocol
                            LocalPort   = $definition.LocalPort
                            ErrorAction = 'Stop'
                        }
                        if ($definition.Program) { $parameters.Program = $definition.Program }
                        if ($definition.Service) { $parameters.Service = $definition.Service }
                        New-NetFirewallRule @parameters | Out-Null
                    }
                }
                DependsOn  = "[OpenFirewallPortForSCCM]OpenFirewall"
            }

            Service ClientDpRemoteRegistry {
                Name        = 'RemoteRegistry'
                StartupType = 'Automatic'
                State       = 'Running'
                DependsOn   = '[Script]ClientDpRemoteManagementFirewall'
            }
            $remoteAdminDependency = '[Service]ClientDpRemoteRegistry'
        }

        # Disable UAC remote restrictions so PSDirect sessions from the host
        # get a full (elevated) admin token. Without this, post-DSC host-to-VM
        # commands (Set-WindowsClientProxy, etc.) fail with "Requested registry
        # access is not allowed" on Windows client SKUs (Win10/Win11) because
        # UAC filters remote admin tokens.
        Registry DisableUACRemoteRestrictions {
            DependsOn = $remoteAdminDependency
            Ensure    = "Present"
            Key       = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
            ValueName = "LocalAccountTokenFilterPolicy"
            ValueType = "Dword"
            ValueData = "1"
        }

        # Confirm the rename actually applied to the ACTIVE computer name before
        # we join the domain. The stock 'Computer NewName' resource's Test trusts
        # the PENDING-rename registry value, so if Windows re-ran its specialize
        # pass on a reboot (observed under heavy host disk I/O, which re-randomizes
        # the computer name) the ACTIVE name can still be the random DESKTOP-* even
        # though Computer.Test reported success. Joining the domain under that
        # transient name permanently breaks the rename ("the specified computer
        # account could not be found") and strands the config. Gate here: if the
        # active name isn't the target yet, (re)stage the rename and reboot so the
        # name lands FIRST. The box is still in a workgroup at this point, so a
        # plain Rename-Computer needs no domain credential. A genuinely stuck
        # re-specialize loop now parks on this gate (a clean, detectable failure)
        # instead of silently joining under the wrong name and bricking the VM.
        Script ConfirmComputerName {
            DependsOn  = "[Registry]DisableUACRemoteRestrictions"
            GetScript  = { return @{ Result = $env:COMPUTERNAME } }
            TestScript = [string]"return (`$env:COMPUTERNAME -eq '$ThisMachineName')"
            SetScript  = [string]"
                if (`$env:COMPUTERNAME -ne '$ThisMachineName') {
                    try { Rename-Computer -NewName '$ThisMachineName' -Force -ErrorAction Stop } catch { }
                    `$global:DSCMachineStatus = 1
                }
            "
        }

        WriteStatus WaitDomain {
            DependsOn = "[Script]ConfirmComputerName"
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

        # Validate secure channel after the post-JoinDomain reboot. If the machine
        # secret drifted (e.g. JoinDomain's retry loop fired Add-Computer twice
        # against a half-promoted DC), try non-destructive password repairs before
        # any downstream resource depends on AD auth. A full rejoin remains the
        # final recovery after stable PDC readiness and repeated failure checks.
        TestDomainJoin TestDomainJoin {
            DomainName = $DomainName
            DCName     = $DCName
            Credential = $DomainCreds
            DependsOn  = "[JoinDomain]JoinDomain"
        }

        # Configure system proxy if this VM is a proxy client. Runs as SYSTEM
        # so there are no UAC/PSDirect elevation issues. Sets WinHTTP, machine
        # env vars, HKLM/HKU\.DEFAULT registry, and machine.config <defaultProxy>
        # with retry logic. By the time Phase 3 DSC starts, all proxy layers are
        # in place and downloads go through Squid.
        #
        # Chains off TestDomainJoin (not DisableUACRemoteRestrictions, which now
        # runs before the domain wait) so the proxy is configured after the box
        # is joined and its secure channel validated — keeping the join path free
        # of any proxy interference.
        $proxyDepend = '[TestDomainJoin]TestDomainJoin'
        if ($ThisVM.useProxy -eq $true) {
            $proxyVm = $deployConfig.virtualMachines | Where-Object { $_.role -eq 'Proxy' } | Select-Object -First 1
            if ($proxyVm) {
                $proxyFqdn = "$($proxyVm.vmName).$DomainName"
                $proxyServer = "${proxyFqdn}:3128"
                $bypassEntries = @('<local>', "*.$DomainName", $proxyFqdn)
                # Bypass the proxy for THIS VM's own subnet, not the domain
                # default network — a member on a secondary network must bypass
                # for its own subnet, not vmOptions.network.
                $network = if ($ThisVM.network) { $ThisVM.network } else { $deployConfig.vmOptions.network }
                if ($network) {
                    $base = ($network -replace '\.0$', '')
                    if ($base -match '^\d+\.\d+\.\d+$') { $bypassEntries += "$base.*" }
                }
                $proxyBypass = ($bypassEntries | Select-Object -Unique) -join ';'

                WriteStatus ConfigureProxy {
                    DependsOn = '[TestDomainJoin]TestDomainJoin'
                    Status    = "Configuring system proxy: $proxyServer"
                }

                SetWindowsProxy ConfigureProxy {
                    DependsOn   = '[WriteStatus]ConfigureProxy'
                    ProxyServer = $proxyServer
                    BypassList  = $proxyBypass
                }
                $proxyDepend = '[SetWindowsProxy]ConfigureProxy'
            }
        }

        # Pre-seed TPM protector for BitLocker VMs
        # Windows 11 24H2 on Hyper-V 512e disks cannot add a NumericalPassword as the first protector.
        # The ConfigMgr BLM handler calls ProtectKeyWithNumericalPassword first, which fails with 0x8007001f.
        # Pre-adding a TPM protector works around this by ensuring the volume already has a protector.
        if ($ThisVM.BitLocker -eq $true) {
            WriteStatus SeedTPM {
                DependsOn = $proxyDepend
                Status    = "Adding TPM protector for BitLocker"
            }

            # On Server OS, the BitLocker feature (and its PowerShell module) must be installed
            # before Get-BitLockerVolume and Enable-BitLocker are available. On client OS
            # (Windows 10/11) the cmdlets are always present.
            Script InstallBitLockerFeature {
                DependsOn  = "[WriteStatus]SeedTPM"
                GetScript  = { @{ Result = "N/A" } }
                TestScript = {
                    # ProductType 1 = Workstation (client OS) — BitLocker cmdlets built-in
                    $productType = (Get-CimInstance Win32_OperatingSystem).ProductType
                    if ($productType -eq 1) { return $true }
                    # Server OS — check if the BitLocker feature is installed
                    $feat = Get-WindowsFeature -Name BitLocker -ErrorAction SilentlyContinue
                    return ($feat -and $feat.Installed)
                }
                SetScript  = {
                    Install-WindowsFeature -Name BitLocker -IncludeManagementTools -ErrorAction Stop
                    if ((Get-WindowsFeature -Name BitLocker).InstallState -eq 'InstallPending') {
                        $global:DSCMachineStatus = 1
                    }
                }
            }

            # Prevent Windows 11 24H2 automatic device encryption on first login.
            # We want ConfigMgr BLM to manage encryption, not the OS auto-trigger.
            Registry PreventDeviceEncryption {
                DependsOn = "[Script]InstallBitLockerFeature"
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
                    # If a TPM protector exists, we're done (encryption may be in progress or complete)
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

                    # Start encryption with TPM protector. Using Enable-BitLocker rather than
                    # just adding the protector because MBAM's enforcement engine requires an
                    # interactive user session (0x800703f0) to start encryption on its own.
                    # -SkipHardwareTest avoids a reboot before encryption begins.
                    # BLM will later add a NumericalPassword protector and escrow it.
                    Enable-BitLocker -MountPoint "C:" -TpmProtector -EncryptionMethod XtsAes256 -SkipHardwareTest -ErrorAction Stop
                }
            }

            WriteStatus Complete {
                DependsOn = "[Script]SeedTPMProtector"
                Status    = "Complete!"
            }
        }
        else {
            WriteStatus Complete {
                DependsOn = $proxyDepend
                Status    = "Complete!"
            }
        }
    }
}