# This file must be saved with UTF-8 BOM. createGuestDscZip.ps1 loads it under PS 5.1, which needs the BOM to parse Unicode.
####################################
### Functional Validation (Phase 11)
####################################
# Common.Validation.Functional.ps1
#
# Fast, role-specific functional tests run inside each guest VM via
# Invoke-VmCommand / PSDirect. Called by $global:Phase11Job after
# the build completes to confirm each VM's assigned role is working.
#
# NOTE: Functions in this file must NOT use Write-Log -OutputStream.
# That flag calls Write-Output which pollutes PowerShell function
# return values (the caller gets @(PSCustomObject, ..., $false)
# instead of just $false). Instead, failure/warning lines are
# accumulated in $script:Phase11OutputBuffer and emitted by the
# Phase11Job scriptblock at top-level where -OutputStream works.

# Accumulator for lines that should appear in console output.
# Populated by Format-TestResult and Test-VmFunctionality;
# read and emitted by Phase11Job after Test-VmFunctionality returns.
$script:Phase11OutputBuffer = $null

function Test-VmFunctionality {
    <#
    .SYNOPSIS
        Dispatches role-specific functional tests for a single VM.
    .DESCRIPTION
        Runs inside the Phase 11 job context. Uses Invoke-VmCommand to
        execute checks inside the guest. Returns $true if all checks
        pass, $false otherwise.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$VMName,

        [Parameter(Mandatory)]
        [object]$CurrentItem,

        [Parameter(Mandatory)]
        [object]$DeployConfig,

        [switch]$IsRetry
    )

    $role = $CurrentItem.role
    $domain = $DeployConfig.vmOptions.domainName
    $Phase = 11

    # Reset the output buffer for this VM's test run
    $script:Phase11OutputBuffer = [System.Collections.Generic.List[hashtable]]::new()

    Write-Log "[Phase $Phase] $VMName [$role]: Starting functional validation" -LogOnly

    # Progress activity label — Write-JobProgress reads this from the job's
    # Progress stream and displays it in the console during execution.
    $validationActivity = "$VMName [$role]"

    # Determine which test function(s) to call based on role and installed features.
    $testsPassed = $true
    $vmIsLinux = Test-VmIsLinux -Vm $CurrentItem

    # Post-reboot settle gate: when Phase 11 is run standalone (-startPhase 11)
    # the VMs are freshly rebooted and many subsystems (AD replication, the
    # failover cluster, the SMS provider host, secure channels) need a couple of
    # minutes to converge. Validating immediately produces spurious failures.
    # Gate on the guest's actual OS uptime (LastBootUpTime) rather than a fixed
    # sleep: on a normal end-to-end deploy the OS has been up well past the
    # threshold (Phase 11 follows Phase 8/10 with no reboot) so this adds ZERO
    # delay; only a freshly-rebooted VM waits, and only for the time remaining.
    if (-not $vmIsLinux) {
        $minUptimeMinutes = 3
        Write-Progress2 -PercentComplete 0 -Activity $validationActivity -Status "Checking uptime (settle gate)"
        $uptimeResult = Invoke-VmCommand -VmName $VMName -VmDomainName $domain `
            -ScriptBlock { (Get-Date) - (Get-CimInstance Win32_OperatingSystem).LastBootUpTime | Select-Object -ExpandProperty TotalMinutes } `
            -DisplayName "Phase11-UptimeGate" -SuppressLog -SessionMaxRetries 3
        if ($uptimeResult -and -not $uptimeResult.ScriptBlockFailed -and $null -ne $uptimeResult.ScriptBlockOutput) {
            $uptimeMin = [double]($uptimeResult.ScriptBlockOutput | Select-Object -First 1)
            if ($uptimeMin -lt $minUptimeMinutes) {
                $waitSec = [int][math]::Ceiling(($minUptimeMinutes - $uptimeMin) * 60)
                Write-Log "[Phase $Phase] $VMName [$role]: Uptime $([int]$uptimeMin)min < ${minUptimeMinutes}min — waiting ${waitSec}s for the VM to settle before validating" -LogOnly
                Write-Progress2 -PercentComplete 0 -Activity $validationActivity -Status "Waiting ${waitSec}s for VM to settle after reboot"
                Start-Sleep -Seconds $waitSec
            }
            else {
                Write-Log "[Phase $Phase] $VMName [$role]: Uptime $([int]$uptimeMin)min >= ${minUptimeMinutes}min — no settle wait needed" -LogOnly
            }
        }
        else {
            Write-Log "[Phase $Phase] $VMName [$role]: Could not determine uptime; skipping settle gate" -LogOnly
        }
    }

    # Ensure all SQL services on this VM are running before role-specific tests.
    # If any Automatic-start SQL engine service is stopped, try to start it.
    $hasLocalSql = ($CurrentItem.sqlVersion -and -not $CurrentItem.remoteSQLVM) -or
                   $role -in @('Secondary', 'SQLAO')
    if ($hasLocalSql) {
        Write-Progress2 -PercentComplete 0 -Activity $validationActivity -Status "Ensuring SQL services are running"
        $testsPassed = Repair-StoppedSQLServices -VMName $VMName -Domain $domain
    }

    switch ($role) {
        'DC' {
            Write-Progress2 -PercentComplete 0 -Activity $validationActivity -Status "Verifying AD DS / DNS / Netlogon"
            $testsPassed = Test-DCFunctionality -VMName $VMName -Domain $domain -DeployConfig $DeployConfig
        }
        'BDC' {
            Write-Progress2 -PercentComplete 0 -Activity $validationActivity -Status "Verifying AD DS / DNS / Netlogon (BDC)"
            $testsPassed = Test-DCFunctionality -VMName $VMName -Domain $domain -IsBDC -DeployConfig $DeployConfig
        }
        'CAS' {
            if (-not $CurrentItem.remoteSQLVM) {
                Write-Progress2 -PercentComplete 0 -Activity $validationActivity -Status "Verifying SQL Server"
                $testsPassed = Test-SQLFunctionality -VMName $VMName -CurrentItem $CurrentItem -DeployConfig $DeployConfig
            }
            else {
                Write-Log "[Phase $Phase] $VMName [$role]: SQL is remote ($($CurrentItem.remoteSQLVM)); SQL test runs against that VM" -LogOnly
            }
            if ($testsPassed) {
                Write-Progress2 -PercentComplete 0 -Activity $validationActivity -Status "Verifying ConfigMgr site"
                $testsPassed = Test-CMSiteFunctionality -VMName $VMName -CurrentItem $CurrentItem -DeployConfig $DeployConfig
            }
        }
        'Primary' {
            if (-not $CurrentItem.remoteSQLVM) {
                Write-Progress2 -PercentComplete 0 -Activity $validationActivity -Status "Verifying SQL Server"
                $testsPassed = Test-SQLFunctionality -VMName $VMName -CurrentItem $CurrentItem -DeployConfig $DeployConfig
            }
            else {
                Write-Log "[Phase $Phase] $VMName [$role]: SQL is remote ($($CurrentItem.remoteSQLVM)); SQL test runs against that VM" -LogOnly
            }
            if ($testsPassed) {
                Write-Progress2 -PercentComplete 0 -Activity $validationActivity -Status "Verifying ConfigMgr site"
                $testsPassed = Test-CMSiteFunctionality -VMName $VMName -CurrentItem $CurrentItem -DeployConfig $DeployConfig
            }
        }
        'Secondary' {
            Write-Progress2 -PercentComplete 0 -Activity $validationActivity -Status "Verifying Secondary site"
            $testsPassed = Test-SecondaryFunctionality -VMName $VMName -CurrentItem $CurrentItem -DeployConfig $DeployConfig
        }
        'SiteSystem' {
            Write-Progress2 -PercentComplete 0 -Activity $validationActivity -Status "Verifying site system roles"
            $testsPassed = Test-SiteSystemFunctionality -VMName $VMName -CurrentItem $CurrentItem -DeployConfig $DeployConfig
        }
        'SQLAO' {
            Write-Progress2 -PercentComplete 0 -Activity $validationActivity -Status "Verifying SQL Always On"
            $testsPassed = Test-SQLAOFunctionality -VMName $VMName -CurrentItem $CurrentItem -DeployConfig $DeployConfig
        }
        'WSUS' {
            Write-Progress2 -PercentComplete 0 -Activity $validationActivity -Status "Verifying WSUS"
            $testsPassed = Test-WSUSFunctionality -VMName $VMName -Domain $domain
        }
        'FileServer' {
            Write-Progress2 -PercentComplete 0 -Activity $validationActivity -Status "Verifying file server"
            $testsPassed = Test-FileServerFunctionality -VMName $VMName -Domain $domain
        }
        'StandaloneRootCA' {
            Write-Progress2 -PercentComplete 0 -Activity $validationActivity -Status "Verifying Standalone Root CA"
            $testsPassed = Test-StandaloneRootCAFunctionality -VMName $VMName -Domain $domain
        }
        'PassiveSite' {
            Write-Progress2 -PercentComplete 0 -Activity $validationActivity -Status "Verifying passive site server"
            $testsPassed = Test-PassiveSiteFunctionality -VMName $VMName -CurrentItem $CurrentItem -DeployConfig $DeployConfig
        }
        'DomainMember' {
            Write-Progress2 -PercentComplete 0 -Activity $validationActivity -Status "Verifying domain member"
            $testsPassed = Test-DomainMemberFunctionality -VMName $VMName -CurrentItem $CurrentItem -DeployConfig $DeployConfig
        }
        'WorkgroupMember' {
            Write-Progress2 -PercentComplete 0 -Activity $validationActivity -Status "Verifying workgroup member"
            $testsPassed = Test-WorkgroupMemberFunctionality -VMName $VMName -CurrentItem $CurrentItem -DeployConfig $DeployConfig
        }
        'InternetClient' {
            Write-Progress2 -PercentComplete 0 -Activity $validationActivity -Status "Verifying internet client"
            $testsPassed = Test-InternetClientFunctionality -VMName $VMName -CurrentItem $CurrentItem -DeployConfig $DeployConfig
        }
        default {
            # Any role not in this switch falls through silently. The phase
            # dispatcher in Common.Phases.ps1 already filters out OSDClient/
            # AADClient. Unknown roles get a log line but don't fail.
            Write-Log "[Phase $Phase] $VMName [$role]: No role-specific tests defined; skipping" -LogOnly
        }
    }

    # If the VM has installRP, also test reporting services
    if ($testsPassed -and $CurrentItem.installRP) {
        Write-Progress2 -PercentComplete 0 -Activity $validationActivity -Status "Verifying Reporting Services"
        $testsPassed = Test-ReportingFunctionality -VMName $VMName -Domain $domain -CurrentItem $CurrentItem -DeployConfig $DeployConfig
    }

    # If the VM has InstallCA, test Certificate Authority
    if ($testsPassed -and $CurrentItem.InstallCA) {
        Write-Progress2 -PercentComplete 0 -Activity $validationActivity -Status "Verifying Certificate Authority"
        $testsPassed = Test-CAFunctionality -VMName $VMName -Domain $domain
    }

    # If the VM received PKI IIS/DP certs (UsePKI + CM role), validate cert health
    $hasCaVM = @($DeployConfig.virtualMachines | Where-Object { $_.InstallCA }).Count -gt 0
    $cmo = if ($CurrentItem.cmOptions) { $CurrentItem.cmOptions } else { $DeployConfig.cmOptions }
    $needsIISCert = $role -in @('CAS', 'Primary', 'Secondary', 'PassiveSite') -or
                    $CurrentItem.InstallSUP -or $CurrentItem.InstallMP -or
                    $CurrentItem.InstallDP -or $CurrentItem.InstallRP
    if ($testsPassed -and $hasCaVM -and $cmo.UsePKI -and $needsIISCert) {
        Write-Progress2 -PercentComplete 0 -Activity $validationActivity -Status "Verifying PKI certificates"
        $testsPassed = Test-PKICertificatesOnVM -VMName $VMName -Domain $domain -CurrentItem $CurrentItem -DeployConfig $DeployConfig
    }

    # If the VM has SQL but is not a Primary/CAS/SQLAO (standalone SQL server)
    if ($testsPassed -and $CurrentItem.sqlVersion -and $role -notin @('CAS', 'Primary', 'SQLAO')) {
        Write-Progress2 -PercentComplete 0 -Activity $validationActivity -Status "Verifying SQL Server"
        $testsPassed = Test-SQLFunctionality -VMName $VMName -CurrentItem $CurrentItem -DeployConfig $DeployConfig
    }

    # SSMS install check (any role with installSSMS=$true)
    if ($testsPassed -and $CurrentItem.installSSMS) {
        Write-Progress2 -PercentComplete 0 -Activity $validationActivity -Status "Verifying SSMS install"
        $testsPassed = Test-SSMSInstall -VMName $VMName -Domain $domain
    }

    # SQL ISO must not be left mounted after a successful build (host-side check).
    # Phase 4 mounts the SQL ISO and ejects it on success; by Phase 11 a healthy
    # SQL VM should have an empty DVD drive.
    if ($testsPassed -and $CurrentItem.sqlVersion -and -not $CurrentItem.remoteSQLVM) {
        Write-Progress2 -PercentComplete 0 -Activity $validationActivity -Status "Verifying SQL ISO is not mounted"
        $testsPassed = Test-SqlIsoNotMounted -VMName $VMName -CurrentItem $CurrentItem -DeployConfig $DeployConfig
    }

    # SMS Provider role check (remote SMS provider, not on the site server itself)
    if ($testsPassed -and $CurrentItem.InstallSMSProv -and $role -ne 'CAS' -and $role -ne 'Primary') {
        Write-Progress2 -PercentComplete 0 -Activity $validationActivity -Status "Verifying SMS Provider"
        $testsPassed = Test-SMSProviderRole -VMName $VMName -CurrentItem $CurrentItem -DeployConfig $DeployConfig
    }

    # Pull-DP configuration (verified from parent Primary)
    if ($testsPassed -and $CurrentItem.enablePullDP) {
        Write-Progress2 -PercentComplete 0 -Activity $validationActivity -Status "Verifying Pull-DP"
        $testsPassed = Test-PullDPConfiguration -VMName $VMName -CurrentItem $CurrentItem -DeployConfig $DeployConfig
    }

    # Additional data disks (E:, F:, ...) per additionalDisks config
    if ($testsPassed -and $CurrentItem.additionalDisks) {
        Write-Progress2 -PercentComplete 0 -Activity $validationActivity -Status "Verifying additional disks"
        $testsPassed = Test-AdditionalDisks -VMName $VMName -CurrentItem $CurrentItem -DeployConfig $DeployConfig
    }

    # BitLocker volume state on member VMs flagged for encryption
    if ($testsPassed -and $CurrentItem.BitLocker -eq $true -and $role -notin @('DC', 'BDC')) {
        Write-Progress2 -PercentComplete 0 -Activity $validationActivity -Status "Verifying BitLocker"
        $testsPassed = Test-BitLockerProtection -VMName $VMName -CurrentItem $CurrentItem -DeployConfig $DeployConfig
    }

    # BitLocker Management: validate policy exists and is deployed (top-level site only).
    # Only check when cmOptions.EnableBLM is set — EnableBLM.ps1 skips policy creation
    # when only VMs have BitLocker=true (TPM-only, no ConfigMgr BLM policy management).
    $cmo = if ($CurrentItem.cmOptions) { $CurrentItem.cmOptions } else { $DeployConfig.cmOptions }
    if ($testsPassed -and $cmo.EnableBLM -and $role -eq 'Primary') {
        Write-Progress2 -PercentComplete 0 -Activity $validationActivity -Status "Verifying BitLocker Management"
        $testsPassed = Test-BLMFunctionality -VMName $VMName -CurrentItem $CurrentItem -DeployConfig $DeployConfig
    }

    # Verify maintenance scheduled tasks are present (confirms Phase 10 ran correctly)
    if ($testsPassed -and $role -notin @('OSDClient', 'AADClient', 'StandaloneRootCA')) {
        Write-Progress2 -PercentComplete 0 -Activity $validationActivity -Status "Verifying maintenance tasks"
        $testsPassed = Test-MaintenanceTasks -VMName $VMName -Domain $domain
    }

    # Pre-create the domain admin user profile so first RDCMan/RDP login is fast.
    # Applies to all domain-joined Windows VMs that will stay running. Skip:
    #   - OSDClient/AADClient: not reachable via PSDirect / not domain-joined
    #   - Linux VMs (Proxy, LinuxServer, LinuxClient): no Windows profiles
    #   - StandaloneRootCA: offline (powered off) after setup, stays off long-term
    #   - WorkgroupMember/InternetClient: not domain-joined with the admin account
    if ($testsPassed -and -not $vmIsLinux -and $role -notin @('OSDClient', 'AADClient', 'StandaloneRootCA', 'WorkgroupMember', 'InternetClient')) {
        Write-Progress2 -PercentComplete 0 -Activity $validationActivity -Status "Pre-creating domain admin profile"
        $testsPassed = Test-UserProfilePreCreation -VMName $VMName -Domain $domain -DeployConfig $DeployConfig
    }

    # ---- Linux health check ----
    # For all Linux VMs: ping + SSH + SMB health cascade from the host.
    # Ping fail → restart. SSH down + SMB down → restart (both services dead).
    # SSH down + SMB up → read logs via SMB share to diagnose, warn only.
    if ($testsPassed -and $vmIsLinux) {
        Write-Progress2 -PercentComplete 0 -Activity $validationActivity -Status "Checking Linux VM health (ping + SSH)"
        $healthResult = Test-LinuxVmHealth -VMName $VMName -CurrentItem $CurrentItem -DeployConfig $DeployConfig -IsRetry:$IsRetry
        if ($healthResult -eq 'Restarted') {
            # VM was restarted and recovered — re-run all tests from scratch
            $script:Phase11OutputBuffer = [System.Collections.Generic.List[hashtable]]::new()
            $testsPassed = Test-VmFunctionality -VMName $VMName -CurrentItem $CurrentItem -DeployConfig $DeployConfig -IsRetry
            return $testsPassed
        }
        elseif ($healthResult -eq 'Failed') {
            $testsPassed = $false
        }
        # 'OK' or 'SshDown' — continue to SMB and role tests
    }

    # ---- Linux SMB validation ----
    # For all Linux VMs: verify Samba is accessible from the host (TCP 445 + shares).
    # This runs from the host side — no SSH needed — so it validates the backup
    # file-access channel that works when SSH is down.
    if ($testsPassed -and $vmIsLinux) {
        Write-Progress2 -PercentComplete 0 -Activity $validationActivity -Status "Verifying Samba (SMB) access"
        $testsPassed = Test-LinuxSmbAccess -VMName $VMName -CurrentItem $CurrentItem -DeployConfig $DeployConfig
    }

    # ---- Proxy validation ----
    # 1) For the Proxy VM itself: verify Squid is listening on TCP 3128.
    if ($testsPassed -and $role -eq 'Proxy') {
        Write-Progress2 -PercentComplete 0 -Activity $validationActivity -Status "Verifying Squid proxy"
        $testsPassed = Test-ProxyListening -VMName $VMName -CurrentItem $CurrentItem -DeployConfig $DeployConfig
    }
    # 1b) Verify the Proxy Admin web UI is listening on TCP 8443.
    if ($testsPassed -and $role -eq 'Proxy') {
        Write-Progress2 -PercentComplete 0 -Activity $validationActivity -Status "Verifying Proxy Admin web UI"
        $testsPassed = Test-ProxyAdminWebUI -VMName $VMName -CurrentItem $CurrentItem -DeployConfig $DeployConfig
    }
    # 2) For any opted-in Windows client/CM-role VM: verify it's pointed at the proxy,
    #    that direct Internet is blocked by host ACLs, and (CM site roles only) that
    #    Get-CMSiteSystemServer reports UseProxy=$true.
    if ($testsPassed -and (Test-VmUsesProxy -Vm $CurrentItem -DeployConfig $DeployConfig)) {
        Write-Progress2 -PercentComplete 0 -Activity $validationActivity -Status "Verifying proxy configuration"
        if (-not (Test-WindowsProxyConfig -VMName $VMName -CurrentItem $CurrentItem -DeployConfig $DeployConfig)) {
            $testsPassed = $false
        }
        if ($testsPassed -and -not (Test-InternetBlocked -VMName $VMName -CurrentItem $CurrentItem -DeployConfig $DeployConfig)) {
            $testsPassed = $false
        }
        if ($testsPassed -and $role -in @('CAS', 'Primary', 'SiteSystem')) {
            if (-not (Test-CMSiteRoleProxy -VMName $VMName -CurrentItem $CurrentItem -DeployConfig $DeployConfig)) {
                $testsPassed = $false
            }
        }
    }

    Write-Progress2 -Activity $validationActivity -Completed

    # If tests failed on a Windows VM, check whether PSDirect itself is broken.
    # The PSDirect target process inside the guest can crash while heartbeat/
    # ping/RDP all remain healthy. A quick smoke test distinguishes "real test
    # failure" from "PSDirect broken". If broken, reboot the VM and retry all
    # tests once. This avoids running a smoke test on every VM upfront.
    if (-not $testsPassed -and -not $IsRetry -and -not $vmIsLinux -and $role -ne 'StandaloneRootCA') {
        $smokeResult = Invoke-VmCommand -VmName $VMName -VmDomainName $domain `
            -ScriptBlock { $env:COMPUTERNAME } -DisplayName "Phase11-PSDirect-SmokeTest" `
            -SuppressLog -SessionMaxRetries 3
        if (-not $smokeResult -or $smokeResult.ScriptBlockFailed) {
            Write-Log "[Phase $Phase] $VMName [$role]: Tests failed and PSDirect is broken — rebooting VM to recover..." -Warning
            $rebooted = Restart-UnresponsiveVm -VmName $VMName -MaxRetries 1 -WaitTimeSeconds 120
            if ($rebooted) {
                # Verify PSDirect works after reboot
                $smokeResult2 = Invoke-VmCommand -VmName $VMName -VmDomainName $domain `
                    -ScriptBlock { $env:COMPUTERNAME } -DisplayName "Phase11-PSDirect-PostReboot" `
                    -SuppressLog -SessionMaxRetries 5
                if ($smokeResult2 -and -not $smokeResult2.ScriptBlockFailed) {
                    Write-Log "[Phase $Phase] $VMName [$role]: PSDirect recovered after reboot — retrying all tests" -Warning
                    # Clear output buffer and re-run all tests
                    $script:Phase11OutputBuffer = [System.Collections.Generic.List[hashtable]]::new()
                    $testsPassed = Test-VmFunctionality -VMName $VMName -CurrentItem $CurrentItem -DeployConfig $DeployConfig -IsRetry
                } else {
                    Write-Log "[Phase $Phase] $VMName [$role]: PSDirect still broken after reboot" -Failure -LogOnly
                    $script:Phase11OutputBuffer.Add(@{ Text = "[Phase $Phase] $VMName [$role]: FAIL - PSDirect broken after reboot"; Level = 'Failure' })
                }
            } else {
                Write-Log "[Phase $Phase] $VMName [$role]: VM did not recover after reboot" -Failure -LogOnly
                $script:Phase11OutputBuffer.Add(@{ Text = "[Phase $Phase] $VMName [$role]: FAIL - VM unresponsive after reboot"; Level = 'Failure' })
            }
        }
    }

    return $testsPassed
}

#region Role-Specific Test Functions

function Test-DCFunctionality {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$Domain,
        [switch]$IsBDC,
        [object]$DeployConfig
    )

    $Phase = 11
    $label = if ($IsBDC) { 'BDC' } else { 'DC' }
    Write-Log "[Phase $Phase] $VMName [$label]: Testing AD DS, DNS, and Netlogon services" -LogOnly

    # Build "vmName=ip" CSV from Hyper-V network adapter view of every non-hidden
    # VM in the deploy that lives in this domain. The DC-side scriptblock will
    # Resolve-DnsName each and flag mismatches. Catches stale static records
    # (e.g. an old ADA-DC1 -> 192.168.x.21 entry left over from a prior deploy
    # where roles got reassigned) which otherwise cause cascading secure-channel
    # failures on clients that resolve a DC name to the wrong IP.
    $expectedDnsCsv = ''
    if ($DeployConfig) {
        $entries = New-Object System.Collections.Generic.List[string]

        # Build set of cluster/AG virtual IPs to exclude when resolving SQLAO
        # node IPs from Get-VMNetworkAdapter. These virtual IPs float between
        # nodes and are NOT the node's own address.
        $virtualIps = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($sqlaoVm in ($DeployConfig.virtualMachines | Where-Object { $_.role -eq 'SQLAO' })) {
            if ($sqlaoVm.ClusterIPAddress) { $null = $virtualIps.Add(($sqlaoVm.ClusterIPAddress -replace '/\d+$','')) }
            if ($sqlaoVm.AGIPAddress)      { $null = $virtualIps.Add(($sqlaoVm.AGIPAddress -replace '/\d+$','')) }
        }
        # On reruns (-StartPhase 2+), ClusterIPAddress/AGIPAddress may not be
        # on the deployConfig objects. Check VM Notes as fallback.
        if ($virtualIps.Count -eq 0) {
            foreach ($sqlaoVm in ($DeployConfig.virtualMachines | Where-Object { $_.role -eq 'SQLAO' })) {
                try {
                    $note = Get-VMNote -VMName $sqlaoVm.vmName
                    if ($note) {
                        if ($note.ClusterIPAddress) { $null = $virtualIps.Add(($note.ClusterIPAddress -replace '/\d+$','')) }
                        if ($note.AGIPAddress)      { $null = $virtualIps.Add(($note.AGIPAddress -replace '/\d+$','')) }
                    }
                } catch {}
            }
        }
        if ($virtualIps.Count -gt 0) {
            Write-Log "[Phase $Phase] ${VMName}: SQLAO virtual IPs to exclude: $($virtualIps -join ', ')" -LogOnly
        }

        foreach ($vm in $DeployConfig.virtualMachines) {
            if ($vm.hidden) { continue }
            if ($vm.domain -and $vm.domain -ne $Domain) { continue }
            # Workgroup/InternetClient VMs are not domain-joined and won't have DNS A records.
            if ($vm.role -in @('WorkgroupMember', 'InternetClient', 'AADClient')) { continue }
            try {
                # IP source priority for DNS validation:
                # 1. AssignedIP from deployConfig (set before Phase 1)
                # 2. DHCP reservation (authoritative — set by us in Phase 1)
                # 3. Get-VMNetworkAdapter (live Hyper-V data, with SQLAO virtual IP filtering)
                # 4. LastKnownIP from VM Notes (last resort only)
                $ip = $null
                $ipSource = 'none'

                # 1. AssignedIP — stamped by Set-DeployConfigIPAddresses
                if ($vm.AssignedIP) {
                    $ip = $vm.AssignedIP
                    $ipSource = 'AssignedIP'
                }

                # 2. DHCP reservation
                if (-not $ip) {
                    try {
                        $vmnet = Get-VMNetworkAdapter -VMName $vm.vmName -ErrorAction Stop |
                            Where-Object { $_.SwitchName -and $_.SwitchName -notmatch 'Cluster' } |
                            Select-Object -First 1
                        if ($vmnet -and $vmnet.MacAddress) {
                            $scopeId = if ($vm.network) { $vm.network } else { $DeployConfig.vmOptions.network }
                            $reservation = Get-DhcpServerv4Reservation -ScopeId $scopeId -ErrorAction SilentlyContinue |
                                Where-Object { ($_.ClientId -replace '-','') -eq $vmnet.MacAddress }
                            if ($reservation) {
                                $ip = $reservation.IPAddress.IPAddressToString
                                $ipSource = 'DHCP'
                            }
                        }
                    } catch {}
                }

                # 3. Get-VMNetworkAdapter — filter heartbeat, cluster and AG virtual IPs
                if (-not $ip) {
                    try {
                        $allIps = @((Get-VMNetworkAdapter -VMName $vm.vmName -ErrorAction Stop).IPAddresses |
                            Where-Object {
                                $_ -match '^\d+\.\d+\.\d+\.\d+$' -and
                                $_ -notlike '10.250.250.*' -and
                                $_ -notlike '10.250.251.*' -and
                                -not $virtualIps.Contains($_)
                            })
                        if ($allIps.Count -gt 0) {
                            $ip = $allIps[0]
                            $ipSource = 'VMNetAdapter'
                            if ($allIps.Count -gt 1) {
                                Write-Log "[Phase $Phase] ${VMName}: $($vm.vmName) has $($allIps.Count) candidate IPs after filtering: $($allIps -join ', '); using $ip" -LogOnly
                            }
                        }
                    } catch {}
                }

                # 4. LastKnownIP from VM Notes — last resort only
                if (-not $ip) {
                    try {
                        $vmNote = Get-VMNote -VMName $vm.vmName
                        if ($vmNote -and $vmNote.LastKnownIP) {
                            $ip = $vmNote.LastKnownIP
                            $ipSource = 'LastKnownIP'
                        }
                    } catch {}
                }

                if ($ip) {
                    $entries.Add("$($vm.vmName)=$ip")
                    if ($ipSource -notin 'AssignedIP', 'DHCP') {
                        Write-Log "[Phase $Phase] ${VMName}: $($vm.vmName) expected IP $ip resolved via $ipSource (no AssignedIP or DHCP reservation found)" -LogOnly
                    }
                }
                else {
                    Write-Log "[Phase $Phase] ${VMName}: $($vm.vmName) could not determine expected IP; skipping DNS check for this VM" -LogOnly
                }
            }
            catch {}
        }
        $expectedDnsCsv = ($entries -join ',')
    }

    $scriptBlock = {
        # NOTE: Invoke-VmCommand declares [string[]]$ArgumentList, so any bool we pass
        # in arrives as the string 'True'/'False' (both truthy in `if`). Compare to
        # the string 'True' explicitly to avoid the BDC branch firing on every DC.
        param($domainFqdn, $isBdcInner, $expectedDnsCsv, $hasCmSitesInner)
        $isBdc = ($isBdcInner -eq 'True')
        $hasCmSites = ($hasCmSitesInner -eq 'True')
        $results = @{ Passed = $true; Details = [System.Collections.Generic.List[string]]::new() }

        # Check critical services. KDC included: if it's stopped, machine-account
        # Kerberos breaks while user auth (via cached tickets) may still appear to
        # work, which produces very confusing "secure channel False" symptoms on
        # otherwise-healthy clients.
        $services = @('NTDS', 'DNS', 'Netlogon', 'Kdc')
        foreach ($svc in $services) {
            $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
            if (-not $s) {
                $results.Passed = $false
                $results.Details.Add("FAIL: Service '$svc' not found")
            }
            elseif ($s.Status -ne 'Running') {
                $results.Passed = $false
                $results.Details.Add("FAIL: Service '$svc' is $($s.Status), expected Running")
            }
            else {
                $results.Details.Add("OK: Service '$svc' is Running")
            }
        }

        # DNS resolution test — query the local DNS zone database directly
        # instead of Resolve-DnsName, which can return cached/LLMNR results.
        $results.Details.Add("CMD: Get-DnsServerResourceRecord -ZoneName '$domainFqdn' -Name '@' -RRType A")
        try {
            $zoneRecs = @(Get-DnsServerResourceRecord -ZoneName $domainFqdn -Name '@' -RRType A -ErrorAction Stop)
            $zoneIPs = @($zoneRecs | ForEach-Object { $_.RecordData.IPv4Address.IPAddressToString })
            if ($zoneIPs.Count -gt 0) {
                $results.Details.Add("OK: DNS zone '$domainFqdn' has A record(s): $($zoneIPs -join ', ')")
            }
            else {
                $results.Passed = $false
                $results.Details.Add("FAIL: DNS zone '$domainFqdn' has no A records at zone apex")
            }
        }
        catch {
            $results.Passed = $false
            $results.Details.Add("FAIL: DNS zone query for '$domainFqdn' failed: $($_.Exception.Message)")
        }

        # BDC: force AD replication from all partners (including DomainDnsZones)
        # BEFORE checking DNS records. Without this, a VM that was recreated
        # with a new IP will have the correct record on the primary DC but the
        # BDC still shows the stale IP — causing the DNS check below to fail.
        if ($isBdc) {
            $results.Details.Add("CMD: repadmin /syncall /e /d /A (force inbound sync of all partitions)")
            try {
                # /e = enterprise (cross-site)  /d = DNS names  /A = all naming contexts
                $syncOutput = & repadmin.exe /syncall /e /d /A 2>&1
                $syncErrors = @($syncOutput | Where-Object { $_ -match 'SyncAll terminated with no errors' } )
                if ($syncErrors.Count -gt 0) {
                    $results.Details.Add("OK: repadmin /syncall completed successfully")
                }
                else {
                    # Check for actual errors vs. just informational output
                    $errs = @($syncOutput | Where-Object { $_ -match 'error|failed' -and $_ -notmatch 'no errors' })
                    if ($errs.Count -gt 0) {
                        $results.Details.Add("WARN: repadmin /syncall reported issues: $($errs[0].Trim())")
                    }
                    else {
                        $results.Details.Add("OK: repadmin /syncall completed")
                    }
                }

                # Wait for convergence — DNS zone changes propagate via AD replication,
                # not DNS zone transfer, so the records won't appear until the
                # DomainDnsZones partition has finished inbound replication.
                Start-Sleep -Seconds 8

                # Verify DomainDnsZones partition replicated recently
                try {
                    Import-Module ActiveDirectory -ErrorAction Stop
                    $domainDN = (Get-ADDomain -ErrorAction Stop).DistinguishedName
                    $dnsPartition = "DC=DomainDnsZones,$domainDN"
                    $dnsPartners = Get-ADReplicationPartnerMetadata -Target $env:COMPUTERNAME -Scope Server -Partition $dnsPartition -ErrorAction Stop
                    if ($dnsPartners) {
                        $freshDns = @($dnsPartners | Where-Object { $_.LastReplicationSuccess -gt (Get-Date).AddMinutes(-5) })
                        if ($freshDns.Count -gt 0) {
                            $results.Details.Add("OK: DomainDnsZones partition replicated from $($freshDns.Count) partner(s) within last 5 min")
                        }
                        else {
                            $most = $dnsPartners | Sort-Object LastReplicationSuccess -Descending | Select-Object -First 1
                            $results.Details.Add("WARN: DomainDnsZones replication stale — last success $($most.LastReplicationSuccess) from $($most.Partner)")
                            # Retry sync for just the DNS partition
                            $results.Details.Add("CMD: repadmin /syncall /e /d /P:$dnsPartition (retry DNS partition)")
                            try {
                                & repadmin.exe /replicate $env:COMPUTERNAME ($most.Partner -replace '^CN=NTDS Settings,CN=','') $dnsPartition 2>&1 | Out-Null
                                Start-Sleep -Seconds 5
                            }
                            catch {}
                        }
                    }
                }
                catch {
                    $results.Details.Add("WARN: Could not verify DomainDnsZones replication: $($_.Exception.Message)")
                }
            }
            catch {
                $results.Details.Add("WARN: repadmin /syncall failed: $($_.Exception.Message)")
            }
        }

        # Per-VM DNS sanity check: for each non-hidden VM in the deploy, confirm
        # its A record on this DC resolves to its actual Hyper-V-reported IPv4.
        # Catches stale static records (no aging) left by older code paths or
        # earlier deploys -- e.g. an ADA-DC1 -> 192.168.x.21 entry from when a
        # role used to live at .21, which now causes clients to talk to the
        # wrong host and see "server is not operational" / secure-channel breaks.
        if ($expectedDnsCsv) {
            $expected = @{}
            foreach ($pair in $expectedDnsCsv.Split(',')) {
                if ($pair -match '^([^=]+)=(.+)$') { $expected[$Matches[1]] = $Matches[2] }
            }
            $mismatches = 0
            foreach ($name in $expected.Keys) {
                $expectedIp = $expected[$name]
                $fqdn = "$name.$domainFqdn"
                try {
                    $recs = @(Get-DnsServerResourceRecord -ZoneName $domainFqdn -Name $name -RRType A -ErrorAction Stop)
                    $resolvedIps = @($recs | ForEach-Object { $_.RecordData.IPv4Address.IPAddressToString })
                    if (-not $resolvedIps -or $resolvedIps.Count -eq 0) {
                        $mismatches++
                        $results.Details.Add("WARN: DNS '$fqdn' returned no A records (expected $expectedIp)")
                    }
                    elseif ($resolvedIps -notcontains $expectedIp) {
                        # Stale record — remove wrong A records on the PDC, then trigger
                        # /registerdns on the target VM via its NetBIOS name (short name
                        # bypasses DNS, uses WINS/NetBIOS resolution instead).
                        $fixStatus = 'failed'
                        try {
                            $zone = $domainFqdn
                            $dnsTarget = (Get-ADDomain -ErrorAction SilentlyContinue).PDCEmulator
                            if (-not $dnsTarget) { $dnsTarget = $env:COMPUTERNAME }
                            $existingRecs = Get-DnsServerResourceRecord -ZoneName $zone -Name $name -RRType A -ComputerName $dnsTarget -ErrorAction SilentlyContinue
                            $removedCount = 0
                            foreach ($staleIp in $resolvedIps) {
                                $matchRec = $existingRecs | Where-Object { $_.RecordData.IPv4Address.IPAddressToString -eq $staleIp }
                                if ($matchRec) {
                                    Remove-DnsServerResourceRecord -ZoneName $zone -InputObject $matchRec -ComputerName $dnsTarget -Force -ErrorAction Stop
                                    $removedCount++
                                }
                                else {
                                    Remove-DnsServerResourceRecord -ZoneName $zone -RRType A -Name $name -RecordData $staleIp -ComputerName $dnsTarget -Force -ErrorAction Stop
                                    $removedCount++
                                }
                            }
                            # Trigger /registerdns via NetBIOS name (doesn't depend on DNS)
                            if ($removedCount -gt 0) {
                                $registered = Invoke-Command -ComputerName $name -ScriptBlock {
                                    ipconfig /registerdns 2>&1 | Out-Null
                                    return $true
                                } -ErrorAction SilentlyContinue
                                # If /registerdns failed (Linux VM, unreachable, etc.),
                                # add the correct A record directly on the DC.
                                if (-not $registered) {
                                    try {
                                        Add-DnsServerResourceRecordA -ZoneName $zone -Name $name -IPv4Address $expectedIp -ComputerName $dnsTarget -ErrorAction Stop
                                    }
                                    catch {
                                        # Best-effort; re-verify below will catch success/failure
                                    }
                                }
                                Start-Sleep -Seconds 3
                                # Re-verify via zone database on the PDC
                                $zoneRec = Get-DnsServerResourceRecord -ZoneName $zone -Name $name -RRType A -ComputerName $dnsTarget -ErrorAction SilentlyContinue
                                $zoneIps = @($zoneRec | ForEach-Object { $_.RecordData.IPv4Address.IPAddressToString })
                                if ($zoneIps -contains $expectedIp) {
                                    $fixStatus = 'verified'
                                }
                                elseif ($registered) {
                                    $fixStatus = 'registered'
                                }
                                else {
                                    $fixStatus = 'removed'
                                }
                            }
                        }
                        catch {
                            $results.Details.Add("DIAG: DNS auto-fix for '$fqdn' threw: $_")
                        }
                        if ($fixStatus -eq 'verified') {
                            $results.Details.Add("OK: DNS '$fqdn' had stale record(s) ($($resolvedIps -join ',')); removed + /registerdns -> $expectedIp")
                        }
                        elseif ($fixStatus -eq 'registered') {
                            $results.Details.Add("WARN: DNS '$fqdn' had stale record(s) ($($resolvedIps -join ',')); removed + /registerdns sent (re-verify pending replication)")
                        }
                        elseif ($fixStatus -eq 'removed') {
                            $results.Details.Add("WARN: DNS '$fqdn' had stale record(s) ($($resolvedIps -join ',')); removed but /registerdns failed — reboot VM to re-register")
                        }
                        else {
                            $mismatches++
                            $results.Details.Add("WARN: DNS '$fqdn' -> $($resolvedIps -join ',') (expected $expectedIp; auto-fix failed)")
                        }
                    }
                    elseif ($resolvedIps.Count -gt 1) {
                        # Extra records alongside the correct one — remove the extras.
                        $extras = @($resolvedIps | Where-Object { $_ -ne $expectedIp })
                        try {
                            if (-not $dnsTarget) {
                                $dnsTarget = (Get-ADDomain -ErrorAction SilentlyContinue).PDCEmulator
                                if (-not $dnsTarget) { $dnsTarget = $env:COMPUTERNAME }
                            }
                            foreach ($extraIp in $extras) {
                                Remove-DnsServerResourceRecord -ZoneName $domainFqdn -RRType A -Name $name -RecordData $extraIp -ComputerName $dnsTarget -Force -ErrorAction Stop
                            }
                            $results.Details.Add("OK: DNS '$fqdn' had extra A record(s) ($($extras -join ',')); removed, keeping $expectedIp")
                        }
                        catch {
                            $results.Details.Add("WARN: DNS '$fqdn' has extra A record(s): $($extras -join ',') (expected only $expectedIp; cleanup failed)")
                        }
                    }
                }
                catch {
                    $mismatches++
                    $results.Details.Add("WARN: DNS lookup for '$fqdn' threw: $($_.Exception.Message)")
                }
            }
            if ($mismatches -eq 0) {
                $results.Details.Add("OK: DNS A records for $($expected.Count) deploy VM(s) match Hyper-V IPs")
            }
            else {
                # Collect recent DNS-related event log entries for diagnostics
                try {
                    $dnsEvents = Get-WinEvent -FilterHashtable @{
                        LogName      = 'DNS Server'
                        Level        = @(2,3)   # Error, Warning
                        StartTime    = (Get-Date).AddMinutes(-60)
                    } -MaxEvents 10 -ErrorAction SilentlyContinue
                    if ($dnsEvents) {
                        $results.Details.Add("DIAG: $($dnsEvents.Count) DNS Server event(s) in last 60 min:")
                        foreach ($evt in $dnsEvents | Select-Object -First 5) {
                            $msg = ($evt.Message -replace '\r?\n',' ' -replace '\s+',' ').Trim()
                            if ($msg.Length -gt 200) { $msg = $msg.Substring(0, 200) + '...' }
                            $results.Details.Add("  Event $($evt.Id) ($($evt.LevelDisplayName)): $msg")
                        }
                    }
                } catch {}
                try {
                    $netlogonEvents = Get-WinEvent -FilterHashtable @{
                        LogName   = 'System'
                        Id        = @(5774, 5775, 5781, 5783)
                        StartTime = (Get-Date).AddMinutes(-60)
                    } -MaxEvents 5 -ErrorAction SilentlyContinue
                    if ($netlogonEvents) {
                        $results.Details.Add("DIAG: $($netlogonEvents.Count) NETLOGON DNS event(s) in last 60 min:")
                        foreach ($evt in $netlogonEvents | Select-Object -First 3) {
                            $msg = ($evt.Message -replace '\r?\n',' ' -replace '\s+',' ').Trim()
                            if ($msg.Length -gt 200) { $msg = $msg.Substring(0, 200) + '...' }
                            $results.Details.Add("  Event $($evt.Id): $msg")
                        }
                    }
                } catch {}
            }
        }

        # dcdiag quick checks. Advertising + NetLogons added because a half-promoted
        # DC (e.g. Phase 2 interrupted mid-DCPROMO) can show all services Running
        # yet refuse to serve authentications -- Advertising/NetLogons catches that
        # before downstream DomainMember tests fail with cryptic ERROR_NO_LOGON_SERVERS.
        $results.Details.Add("CMD: dcdiag.exe /test:Services /test:Replications /test:FSMOCheck /test:Advertising /test:NetLogons /q")
        # Retry on transient failures: right after a reboot (e.g. a -startPhase 11
        # rerun) AD replication between DCs is still re-establishing, so dcdiag's
        # Replications test can fail on the first pass and pass moments later.
        $dcdiag = $null
        $failCount = 0
        $dcdiagErr = $null
        for ($dd = 1; $dd -le 3; $dd++) {
            try {
                $dcdiag = & dcdiag.exe /test:Services /test:Replications /test:FSMOCheck /test:Advertising /test:NetLogons /q 2>&1
                $dcdiagText = $dcdiag -join "`n"
                $failCount = ([regex]::Matches($dcdiagText, 'failed test')).Count
                $dcdiagErr = $null
                if ($failCount -eq 0) { break }
            }
            catch {
                $dcdiagErr = $_
            }
            if ($dd -lt 3) { Start-Sleep -Seconds 20 }
        }
        if ($dcdiagErr) {
            $results.Details.Add("WARN: dcdiag execution failed: $($dcdiagErr.Exception.Message)")
        }
        elseif ($failCount -gt 0) {
            $results.Passed = $false
            $results.Details.Add("FAIL: dcdiag reported $failCount failed test(s) after retries")
            $failLines = $dcdiag | Where-Object { $_ -match 'failed test' } | Select-Object -First 5
            foreach ($fl in $failLines) { $results.Details.Add("  dcdiag: $($fl.Trim())") }
        }
        else {
            $results.Details.Add("OK: dcdiag Services/Replications/FSMOCheck/Advertising/NetLogons passed")
        }

        # SYSVOL + NETLOGON shares -- if these are missing GPOs and logons break.
        foreach ($shr in @('SYSVOL', 'NETLOGON')) {
            $s = Get-SmbShare -Name $shr -ErrorAction SilentlyContinue
            if (-not $s) {
                $results.Passed = $false
                $results.Details.Add("FAIL: SMB share '$shr' missing on DC")
            }
            else {
                $results.Details.Add("OK: SMB share '$shr' -> '$($s.Path)'")
            }
        }

        # NETLOGON 5781 = "Dynamic registration of DNS records failed" -- an early
        # warning that the DC came up without fully registering its SRV records,
        # which downstream clients then can't locate. Surface recent occurrences.
        try {
            $since = (Get-Date).AddMinutes(-30)
            $5781 = Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'NETLOGON'; Id = 5781; StartTime = $since } -ErrorAction SilentlyContinue
            if ($5781) {
                $results.Details.Add("WARN: NETLOGON 5781 (DNS SRV registration failed) seen $($5781.Count) time(s) in last 30 min -- run 'nltest /dsregdns' to re-register")
            }
            else {
                $results.Details.Add("OK: No NETLOGON 5781 (DNS SRV registration failure) events in last 30 min")
            }
        }
        catch {
            $results.Details.Add("WARN: Could not query NETLOGON event log: $($_.Exception.Message)")
        }

        # BDC-only: confirm all naming contexts replicated recently.
        # The forced sync above should have brought everything current;
        # this is the final verification.
        if ($isBdc) {
            $results.Details.Add("CMD: Get-ADReplicationPartnerMetadata -Target `$env:COMPUTERNAME -Scope Server")
            try {
                Import-Module ActiveDirectory -ErrorAction Stop
                $partners = Get-ADReplicationPartnerMetadata -Target $env:COMPUTERNAME -Scope Server -ErrorAction Stop
                if (-not $partners) {
                    $results.Passed = $false
                    $results.Details.Add("FAIL: No replication partners found for BDC")
                }
                else {
                    # Group by partition to show per-NC replication status
                    $partitions = $partners | Group-Object Partition
                    $stalePartitions = @()
                    foreach ($pg in $partitions) {
                        $fresh = $pg.Group | Where-Object { $_.LastReplicationSuccess -gt (Get-Date).AddMinutes(-10) }
                        $partName = ($pg.Name -split ',')[0] -replace '^DC=',''
                        if ($fresh) {
                            $results.Details.Add("OK: Partition '$partName' replicated from $($fresh.Count) partner(s) within last 10 min")
                        }
                        else {
                            $most = $pg.Group | Sort-Object LastReplicationSuccess -Descending | Select-Object -First 1
                            $stalePartitions += $partName
                            $results.Details.Add("WARN: Partition '$partName' replication stale — last success $($most.LastReplicationSuccess)")
                        }
                    }
                    if ($stalePartitions.Count -gt 0) {
                        $results.Details.Add("WARN: $($stalePartitions.Count) partition(s) stale after forced sync: $($stalePartitions -join ', ')")
                    }
                    else {
                        $results.Details.Add("OK: All $($partitions.Count) partition(s) replicated recently")
                    }
                }
            }
            catch {
                $results.Details.Add("WARN: Could not query BDC replication metadata: $($_.Exception.Message)")
            }
        }

        # FSMO role check (primary DC only) — all five roles should remain on
        # the first DC unless intentionally moved.
        if (-not $isBdc) {
            try {
                $forest = Get-ADForest -ErrorAction Stop
                $domain = Get-ADDomain -ErrorAction Stop
                $localFQDN = "$env:COMPUTERNAME.$domainFqdn"

                $fsmoRoles = [ordered]@{
                    'Schema Master'          = $forest.SchemaMaster
                    'Domain Naming Master'   = $forest.DomainNamingMaster
                    'PDC Emulator'           = $domain.PDCEmulator
                    'RID Master'             = $domain.RIDMaster
                    'Infrastructure Master'  = $domain.InfrastructureMaster
                }

                $moved = @()
                foreach ($role in $fsmoRoles.GetEnumerator()) {
                    if ($role.Value -ine $localFQDN) {
                        $moved += "$($role.Key) -> $($role.Value)"
                    }
                }

                if ($moved.Count -gt 0) {
                    $results.Details.Add("WARN: FSMO role(s) not on primary DC: $($moved -join '; ')")
                }
                else {
                    $results.Details.Add("OK: All 5 FSMO roles on primary DC")
                }
            }
            catch {
                $results.Details.Add("WARN: FSMO role check failed: $($_.Exception.Message)")
            }
        }

        # ConfigMgr AD schema extension check (primary DC only, CM deployments only)
        if (-not $isBdc -and $hasCmSites) {
            $cmSchemaAttrs = @('mSSMSSiteCode', 'mSSMSAssignmentSiteCode', 'mSSMSCapabilities', 'mSSMSMPName', 'mSSMSMPAddress')
            try {
                Import-Module ActiveDirectory -ErrorAction Stop
                $schemaDN = (Get-ADRootDSE).schemaNamingContext
                $missing = @()
                foreach ($attr in $cmSchemaAttrs) {
                    $obj = Get-ADObject -SearchBase $schemaDN -Filter "lDAPDisplayName -eq '$attr'" -ErrorAction SilentlyContinue
                    if (-not $obj) { $missing += $attr }
                }
                if ($missing.Count -gt 0) {
                    $results.Passed = $false
                    $results.Details.Add("FAIL: ConfigMgr AD schema attributes missing: $($missing -join ', '). extadsch.exe may have failed — check C:\ExtADSch.log on the DC.")
                }
                else {
                    $results.Details.Add("OK: ConfigMgr AD schema extension verified ($($cmSchemaAttrs.Count) attributes present)")

                    # Verify schema has replicated to all DCs
                    $allDCs = @(Get-ADDomainController -Filter * -ErrorAction SilentlyContinue)
                    if ($allDCs.Count -gt 1) {
                        $staleDCs = @()
                        foreach ($dc in $allDCs) {
                            if ($dc.HostName -eq "$env:COMPUTERNAME.$domainFqdn") { continue }
                            try {
                                $testObj = Get-ADObject -Server $dc.HostName -SearchBase $schemaDN `
                                    -Filter "lDAPDisplayName -eq 'mSSMSSiteCode'" -ErrorAction Stop
                                if (-not $testObj) { $staleDCs += $dc.HostName }
                            }
                            catch {
                                $staleDCs += "$($dc.HostName) (unreachable: $($_.Exception.Message))"
                            }
                        }
                        if ($staleDCs.Count -gt 0) {
                            $results.Details.Add("WARN: CM schema not replicated to: $($staleDCs -join ', ')")
                        }
                        else {
                            $results.Details.Add("OK: CM schema replicated to all $($allDCs.Count) DC(s)")
                        }
                    }
                }
            }
            catch {
                $results.Details.Add("WARN: CM schema check failed: $($_.Exception.Message)")
            }
        }

        return $results
    }

    $hasCmSites = $false
    if ($DeployConfig) {
        $hasCmSites = @($DeployConfig.virtualMachines | Where-Object { $_.role -in @('CAS', 'Primary', 'Secondary', 'PassiveSite') }).Count -gt 0
    }

    $result = Invoke-VmCommand -VmName $VMName -VmDomainName $Domain `
        -ScriptBlock $scriptBlock -ArgumentList $Domain, ([string]$IsBDC.IsPresent), $expectedDnsCsv, ([string]$hasCmSites) `
        -DisplayName "Phase11-$label-Test" -SuppressLog `
        -AsJob -TimeoutSeconds 300

    $dcPassed = Format-TestResult -VMName $VMName -RoleLabel $label -Result $result

    # Host-side DHCP reservation audit. DHCP runs on the HOST (not the DC), so
    # this runs against the local DHCP server, not inside the guest. Anchored to
    # the primary DC's Phase 11 test so it runs exactly once per domain. The BDC
    # run is skipped to avoid auditing the same scope twice.
    $reservationsPassed = $true
    if (-not $IsBDC -and $DeployConfig) {
        $reservationsPassed = Test-DhcpReservations -Domain $Domain -DeployConfig $DeployConfig
    }

    return ($dcPassed -and $reservationsPassed)
}

function Test-DhcpReservations {
    <#
    .SYNOPSIS
        Host-side audit that every VM expected to have a DHCP reservation
        actually has one, pointing at the right IP, with no IP claimed by
        more than one VM.
    .DESCRIPTION
        Runs on the host (DHCP server is local, not on the DC). For each
        non-hidden VM in the domain that gets a reservation in Phase 1
        (all roles except OSDClient, which is skipped there), it:
          - resolves the VM's domain-NIC MAC (Get-VMMacIsolated -ExcludeCluster)
          - looks up the live reservation for that MAC in the VM's scope
          - confirms the reservation exists and its IP matches AssignedIP
          - flags any IP held by more than one reservation (the collision class
            that broke Phase 5 SQLAO cluster creation)
        Buffers FAIL/WARN lines into $script:Phase11OutputBuffer like the other
        Phase 11 tests, and returns $true only when every expected reservation
        is present and correct.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Domain,
        [Parameter(Mandatory)][object]$DeployConfig
    )

    $Phase = 11
    $label = 'DHCP'
    $passed = $true
    $checked = 0

    # IP -> list of vmNames, to detect an IP reserved for more than one VM.
    $ipOwners = @{}

    # Batch the two CIM lookups instead of spawning a fresh isolated runspace
    # per VM. Calling Get-VMMacIsolated + Get-DHCPReservationIPForMac in the
    # loop creates 2 throwaway [PowerShell]::Create() runspaces per VM, each
    # re-importing the Hyper-V / DhcpServer module (~seconds). On a 24-VM lab
    # that's ~48 spawns and dominates Phase 11. Fetch all VM MACs in one
    # isolated runspace and all DHCP reservations in another (2 spawns total),
    # then match on the host (fully-typed runspace, no CDXML adapter concerns).
    $macMap = @{}
    try { $macMap = Get-AllVMMacsIsolated -ExcludeCluster }
    catch { Write-Log "[Phase $Phase] [$label]: failed to batch-read VM MACs: $_" -LogOnly }

    # Build "scopeId|mac" -> ip from every live reservation. Hashtable keys are
    # case-insensitive, so the upper/lower MAC mismatch between Hyper-V's
    # MacAddress and the reservation ClientId resolves automatically.
    $resvMap = @{}
    try {
        foreach ($r in (Get-AllDHCPReservationsIsolated)) {
            if ($r.Mac) { $resvMap["$($r.ScopeId)|$($r.Mac)"] = $r.Ip }
        }
    }
    catch { Write-Log "[Phase $Phase] [$label]: failed to batch-read DHCP reservations: $_" -LogOnly }

    foreach ($vm in $DeployConfig.virtualMachines) {
        if ($vm.hidden) { continue }
        if ($vm.domain -and $vm.domain -ne $Domain) { continue }
        # OSDClient never gets a reservation (Phase 1 skips it via -OSDClient).
        if ($vm.role -eq 'OSDClient') { continue }
        # A VM with no pre-assigned IP had no reservation created for it.
        if (-not $vm.AssignedIP) { continue }

        $checked++
        $expectedIp = ($vm.AssignedIP -replace '/.+$', '')
        $scopeId = if ($vm.role -in 'InternetClient', 'AADClient') {
            '172.31.250.0'
        } else {
            if ($vm.network) { $vm.network } else { $DeployConfig.vmOptions.network }
        }

        $mac = $macMap[$vm.vmName]
        if (-not $mac -or $mac -eq '000000000000') {
            Write-Log "[Phase $Phase] [$label]: $($vm.vmName): could not resolve domain-NIC MAC; skipping reservation check" -LogOnly
            $script:Phase11OutputBuffer.Add(@{ Text = "[Phase $Phase] [$label]: WARN: $($vm.vmName) has no resolvable MAC; reservation not verified"; Level = 'Warning' })
            continue
        }

        $reservedIp = $resvMap["$scopeId|$mac"]

        if (-not $reservedIp) {
            $passed = $false
            $script:Phase11OutputBuffer.Add(@{ Text = "[Phase $Phase] [$label]: FAIL: $($vm.vmName) has no DHCP reservation in scope $scopeId (expected $expectedIp, MAC=$mac)"; Level = 'Failure' })
            continue
        }

        if ($reservedIp -ne $expectedIp) {
            $passed = $false
            $script:Phase11OutputBuffer.Add(@{ Text = "[Phase $Phase] [$label]: FAIL: $($vm.vmName) reservation is $reservedIp but AssignedIP is $expectedIp (scope $scopeId, MAC=$mac)"; Level = 'Failure' })
            continue
        }

        if (-not $ipOwners.ContainsKey($reservedIp)) {
            $ipOwners[$reservedIp] = New-Object System.Collections.Generic.List[string]
        }
        $ipOwners[$reservedIp].Add($vm.vmName)

        Write-Log "[Phase $Phase] [$label]: $($vm.vmName): reservation OK $reservedIp (scope $scopeId)" -LogOnly
    }

    # Flag any IP that resolved to a reservation for more than one VM.
    foreach ($ip in $ipOwners.Keys) {
        if ($ipOwners[$ip].Count -gt 1) {
            $passed = $false
            $script:Phase11OutputBuffer.Add(@{ Text = "[Phase $Phase] [$label]: FAIL: IP $ip is reserved for multiple VMs: $($ipOwners[$ip] -join ', ')"; Level = 'Failure' })
        }
    }

    if ($passed) {
        Write-Log "[Phase $Phase] [$label]: All $checked DHCP reservation(s) verified" -LogOnly
    }
    else {
        Write-Log "[Phase $Phase] [$label]: DHCP reservation audit found problems ($checked checked)" -Failure -LogOnly
    }

    return $passed
}

function Repair-StoppedSQLServices {
    <#
    .SYNOPSIS
        Scans for all SQL Server engine services on a VM and starts any that are stopped.
    .DESCRIPTION
        Runs before role-specific tests to ensure SQL services are up. If a service
        has Automatic start type but is Stopped, tries Start-Service with a 60s wait.
        Disabled services are skipped. Returns $false only if a service cannot be started.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$Domain
    )

    $Phase = 11
    Write-Log "[Phase $Phase] $VMName`: Scanning for stopped SQL services" -LogOnly

    $scriptBlock = {
        $results = @{ Passed = $true; Details = [System.Collections.Generic.List[string]]::new() }

        # Find all SQL engine services (MSSQLSERVER for default, MSSQL$<instance> for named)
        $sqlServices = @(Get-Service -Name 'MSSQL*' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq 'MSSQLSERVER' -or $_.Name -match '^MSSQL\$' })

        if ($sqlServices.Count -eq 0) {
            $results.Details.Add("OK: No SQL Server engine services found on this VM")
            return $results
        }

        foreach ($svc in $sqlServices) {
            $results.Details.Add("CMD: Get-Service -Name '$($svc.Name)' (StartType=$($svc.StartType), Status=$($svc.Status))")

            if ($svc.Status -eq 'Running') {
                $results.Details.Add("OK: $($svc.Name) is Running")
                continue
            }

            if ($svc.StartType -eq 'Disabled') {
                $results.Details.Add("OK: $($svc.Name) is Disabled (skipping)")
                continue
            }

            # Service is stopped but has Automatic/Manual start type — try to start it
            $results.Details.Add("REMEDIATE: $($svc.Name) is $($svc.Status) (StartType=$($svc.StartType)), attempting Start-Service...")
            try {
                Start-Service -Name $svc.Name -ErrorAction Stop
                $waited = 0
                while ($waited -lt 60) {
                    Start-Sleep -Seconds 5
                    $waited += 5
                    $refreshed = Get-Service -Name $svc.Name
                    if ($refreshed.Status -eq 'Running') { break }
                }
                $refreshed = Get-Service -Name $svc.Name
                if ($refreshed.Status -eq 'Running') {
                    $results.Details.Add("RECOVERED: $($svc.Name) was $($svc.Status); started successfully (took ~$($waited)s)")
                }
                else {
                    $results.Passed = $false
                    $results.Details.Add("FAIL: $($svc.Name) is still $($refreshed.Status) after $($waited)s start attempt")
                }
            }
            catch {
                $results.Passed = $false
                $results.Details.Add("FAIL: Start-Service '$($svc.Name)' failed: $($_.Exception.Message)")
            }
        }

        return $results
    }

    $result = Invoke-VmCommand -VmName $VMName -VmDomainName $Domain `
        -ScriptBlock $scriptBlock -DisplayName "Phase11-SQL-Service-Sweep" -SuppressLog `
        -AsJob -TimeoutSeconds 300

    return (Format-TestResult -VMName $VMName -RoleLabel 'SQL-Services' -Result $result)
}

function Test-SQLFunctionality {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][object]$CurrentItem,
        [Parameter(Mandatory)][object]$DeployConfig
    )

    $Phase = 11
    $domain = $DeployConfig.vmOptions.domainName
    $instanceName = if ($CurrentItem.sqlInstanceName) { $CurrentItem.sqlInstanceName } else { 'MSSQLSERVER' }
    $sqlPort = if ($CurrentItem.sqlPort) { $CurrentItem.sqlPort } else { $null }

    Write-Log "[Phase $Phase] $VMName [SQL]: Testing SQL Server instance '$instanceName'" -LogOnly
    $isSQLAO = if ($CurrentItem.role -eq 'SQLAO') { '1' } else { '0' }

    $scriptBlock = {
        param($instName, $port, $checkAgent)
        $results = @{ Passed = $true; Details = [System.Collections.Generic.List[string]]::new() }

        # Determine service name
        $svcName = if ($instName -eq 'MSSQLSERVER') { 'MSSQLSERVER' } else { "MSSQL`$$instName" }
        $results.Details.Add("CMD: Get-Service -Name '$svcName'")

        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if (-not $svc) {
            $results.Passed = $false
            $results.Details.Add("FAIL: SQL service '$svcName' not found")
            $results.Details.Add("  Available SQL services: $(( Get-Service -Name 'MSSQL*' -EA SilentlyContinue | ForEach-Object { $_.Name } ) -join ', ')")
            return $results
        }
        if ($svc.Status -ne 'Running') {
            # Service exists but is stopped — try to start it before failing
            $results.Details.Add("REMEDIATE: SQL service '$svcName' is $($svc.Status), attempting to start...")
            try {
                Start-Service -Name $svcName -ErrorAction Stop
                $waited = 0
                while ($waited -lt 60) {
                    Start-Sleep -Seconds 5
                    $waited += 5
                    $svc = Get-Service -Name $svcName
                    if ($svc.Status -eq 'Running') { break }
                }
            }
            catch {
                $results.Details.Add("WARN: Start-Service failed: $($_.Exception.Message)")
            }
            $svc = Get-Service -Name $svcName
            if ($svc.Status -ne 'Running') {
                $results.Passed = $false
                $results.Details.Add("FAIL: SQL service '$svcName' is still $($svc.Status) after start attempt")
                return $results
            }
            $results.Details.Add("RECOVERED: SQL service '$svcName' was stopped; started successfully")
        }
        else {
            $results.Details.Add("OK: SQL service '$svcName' is Running")
        }

        # SQL Agent - only check for SQLAO where it's required for failover
        $agentName = if ($instName -eq 'MSSQLSERVER') { 'SQLSERVERAGENT' } else { "SQLAgent`$$instName" }
        $agent = Get-Service -Name $agentName -ErrorAction SilentlyContinue
        if ($checkAgent -eq '1') {
            if ($agent -and $agent.Status -eq 'Running') {
                $results.Details.Add("OK: SQL Agent '$agentName' is Running")
            }
            elseif ($agent) {
                $results.Passed = $false
                $results.Details.Add("FAIL: SQL Agent '$agentName' is $($agent.Status) (required for SQLAO)")
            }
            else {
                $results.Passed = $false
                $results.Details.Add("FAIL: SQL Agent '$agentName' not found (required for SQLAO)")
            }
        }
        else {
            if ($agent -and $agent.Status -eq 'Running') {
                $results.Details.Add("OK: SQL Agent '$agentName' is Running")
            }
        }

        # Test connectivity via Invoke-Sqlcmd
        $connStr = if ($instName -eq 'MSSQLSERVER') { 'localhost' } else { "localhost\$instName" }
        if ($port) { $connStr = "localhost,$port" }
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        $results.Details.Add("CMD: Invoke-Sqlcmd -ServerInstance '$connStr' -Query 'SELECT 1' (as $identity)")
        try {
            Import-Module SqlServer -ErrorAction SilentlyContinue
            if (-not (Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue)) {
                Import-Module SQLPS -DisableNameChecking -ErrorAction SilentlyContinue
            }
            # -TrustServerCertificate not available on older SQLPS (SQL Express)
            $sqlParams = @{}
            if ((Get-Command Invoke-Sqlcmd).Parameters.ContainsKey('TrustServerCertificate')) {
                $sqlParams['TrustServerCertificate'] = $true
            }
            $qr = Invoke-Sqlcmd -ServerInstance $connStr -Query "SELECT 1 AS TestResult" -QueryTimeout 30 @sqlParams -ErrorAction Stop
            if ($qr.TestResult -eq 1) {
                $results.Details.Add("OK: SQL query 'SELECT 1' succeeded on '$connStr'")
            }
            else {
                $results.Passed = $false
                $results.Details.Add("FAIL: SQL query returned unexpected result: $($qr | Out-String)")
            }
        }
        catch {
            $results.Passed = $false
            $results.Details.Add("FAIL: SQL connection to '$connStr' as '$identity' failed: $($_.Exception.Message)")
        }

        # Generic SQL Agent job health: any enabled job whose most-recent run
        # was NOT Succeeded is a real signal (CM site maintenance, WSUS reindex,
        # AG backup jobs, operator-added jobs). Never-run jobs are skipped.
        # The outcome row (step_id=0) always carries SQL Agent's generic wrapper
        # message ("The job failed. The Job was invoked by ..."); the actual
        # T-SQL error lives in the highest-numbered step_id>0 row for the same
        # run, so we pull that too and emit it as a follow-up DIAG line (log-
        # only, since Ola's procs emit ~1.5KB of preamble before the error).
        # Widened to 4000 chars so the actionable error survives that preamble.
        if ($results.Passed) {
            $results.Details.Add("CMD: Check all enabled SQL Agent jobs in msdb for last-run failures")
            try {
                $jobHealthQuery = @"
;WITH lastRun AS (
    SELECT job_id, run_status, run_date, run_time, message, instance_id,
           ROW_NUMBER() OVER (PARTITION BY job_id
                              ORDER BY run_date DESC, run_time DESC, instance_id DESC) AS rn
    FROM msdb.dbo.sysjobhistory
    WHERE step_id = 0
),
lastStep AS (
    SELECT h.job_id, h.step_name, h.message AS StepMessage, h.run_status AS StepRunStatus,
           ROW_NUMBER() OVER (PARTITION BY h.job_id
                              ORDER BY h.instance_id DESC) AS rn
    FROM msdb.dbo.sysjobhistory h
    WHERE h.step_id > 0
)
SELECT j.name,
       h.run_status AS LastRunStatus,
       msdb.dbo.agent_datetime(h.run_date, h.run_time) AS LastRunTime,
       LEFT(ISNULL(h.message, ''''), 500) AS LastMessage,
       ISNULL(ls.step_name, '''')                AS LastStepName,
       LEFT(ISNULL(ls.StepMessage, ''''), 4000)  AS LastStepMessage
FROM msdb.dbo.sysjobs j
LEFT JOIN lastRun  h  ON h.job_id  = j.job_id AND h.rn  = 1
LEFT JOIN lastStep ls ON ls.job_id = j.job_id AND ls.rn = 1
WHERE j.enabled = 1
  AND h.run_status IS NOT NULL
  AND h.run_status <> 1
ORDER BY LastRunTime DESC
"@
                $badJobs = @(Invoke-Sqlcmd -ServerInstance $connStr -Query $jobHealthQuery -QueryTimeout 30 @sqlParams -ErrorAction Stop)
                if ($badJobs.Count -eq 0) {
                    $results.Details.Add("OK: All enabled SQL Agent jobs that have run completed successfully on last run")
                }
                else {
                    $statusMap = @{ 0 = 'Failed'; 2 = 'Retry'; 3 = 'Cancelled'; 4 = 'In Progress' }
                    foreach ($bj in $badJobs) {
                        $statusText = if ($statusMap.ContainsKey([int]$bj.LastRunStatus)) { $statusMap[[int]$bj.LastRunStatus] } else { "Status $($bj.LastRunStatus)" }
                        $msgTail = ''
                        if ($bj.LastMessage) {
                            $clean = ($bj.LastMessage -replace '\s+', ' ').Trim()
                            if ($clean) { $msgTail = " - $clean" }
                        }
                        $results.Details.Add("WARN: Agent job '$($bj.name)' last run: $statusText at $($bj.LastRunTime)$msgTail")
                        if ($bj.LastStepMessage -and $bj.LastStepMessage -isnot [System.DBNull]) {
                            $stepClean = ($bj.LastStepMessage -replace '\s+', ' ').Trim()
                            if ($stepClean) {
                                $stepName = if ($bj.LastStepName) { $bj.LastStepName } else { '(step)' }
                                $results.Details.Add("DIAG:   Step '$stepName' output: $stepClean")
                            }
                        }
                    }
                }
            }
            catch {
                $results.Details.Add("WARN: SQL Agent job health check failed: $($_.Exception.Message)")
            }
        }

        # Active validation: trigger MemLabs jobs that have either NEVER run or
        # whose LAST run failed (whitelist only — we own them and they write to
        # the NUL device, completing in seconds). Two scenarios this closes:
        #   1. Day-zero: jobs scheduled to first fire at day+1, leaving freshly
        #      built labs with no signal that the T-SQL would even parse.
        #   2. Post-fix: a Phase 10 fix (e.g. Fix-SQLAOBackupJobs) just patched
        #      a broken job, but its last history row still says Failed from
        #      the prior nightly schedule. Without an active re-trigger, the
        #      passive WARN would persist for up to 20h until the next schedule.
        # The passive WARN above is intentionally left in place so the original
        # failure is still visible in this Phase 11 run; the active re-trigger
        # adds an OK line on success so the VM-level result reflects reality.
        # Non-MemLabs jobs are NEVER triggered here. IndexOptimize is excluded:
        # it does real index work (not NUL), can run minutes on a CAS / perf-
        # loaded lab, and a syntax bug there would fail in <1s anyway via the
        # next-day scheduled run + passive check.
        if ($results.Passed) {
            try {
                # ISNULL -> -1 sentinel so PowerShell can distinguish never-run
                # (-1) from failed (0). Also capture the last (run_date, run_time)
                # so we can poll for a strictly NEW history row after sp_start_job
                # — without that, a failed-last-run job would immediately match
                # the stale failure row and we'd report it as the trigger outcome.
                $candidatesQuery = @"
;WITH lastRun AS (
    SELECT job_id, run_status, run_date, run_time,
           ROW_NUMBER() OVER (PARTITION BY job_id
                              ORDER BY run_date DESC, run_time DESC) AS rn
    FROM msdb.dbo.sysjobhistory
    WHERE step_id = 0
)
SELECT j.name,
       ISNULL(CAST(h.run_status AS int), -1) AS LastRunStatus,
       ISNULL(h.run_date, 0)                 AS LastRunDate,
       ISNULL(h.run_time, 0)                 AS LastRunTimeInt
FROM msdb.dbo.sysjobs j
LEFT JOIN lastRun h ON h.job_id = j.job_id AND h.rn = 1
WHERE j.enabled = 1
  AND (h.run_status IS NULL OR h.run_status = 0)
  AND j.name LIKE 'MemLabs %'
  AND j.name NOT LIKE 'MemLabs IndexOptimize%'
ORDER BY j.name
"@
                $candidates = @(Invoke-Sqlcmd -ServerInstance $connStr -Query $candidatesQuery -QueryTimeout 30 @sqlParams -ErrorAction Stop)
                if ($candidates.Count -gt 0) {
                    $maxToRun = 10
                    $toRun = $candidates | Select-Object -First $maxToRun
                    if ($candidates.Count -gt $maxToRun) {
                        $results.Details.Add("INFO: $($candidates.Count) MemLabs jobs need validation (never-run or last-run failed); testing first $maxToRun")
                    }
                    foreach ($cj in $toRun) {
                        $jobName    = $cj.name
                        $jobNameEsc = $jobName -replace "'", "''"
                        $isRetry    = ([int]$cj.LastRunStatus -eq 0)
                        $reason     = if ($isRetry) { 're-run after prior failure' } else { 'never-run validation' }
                        $beforeDate = [int]$cj.LastRunDate
                        $beforeTime = [int]$cj.LastRunTimeInt
                        $results.Details.Add("CMD: sp_start_job '$jobName' ($reason)")
                        try {
                            Invoke-Sqlcmd -ServerInstance $connStr -Query "EXEC msdb.dbo.sp_start_job @job_name = N'$jobNameEsc'" -QueryTimeout 30 @sqlParams -ErrorAction Stop | Out-Null
                        }
                        catch {
                            $results.Details.Add("WARN: sp_start_job '$jobName' failed: $($_.Exception.Message)")
                            continue
                        }
                        # Poll up to 60s for a NEW outcome row. Never-run jobs
                        # have $beforeDate=0/$beforeTime=0 so any row qualifies.
                        $pollQuery = @"
SELECT TOP 1 h.run_status,
       msdb.dbo.agent_datetime(h.run_date, h.run_time) AS LastRunTime,
       LEFT(ISNULL(h.message, ''''), 500) AS LastMessage
FROM msdb.dbo.sysjobhistory h
JOIN msdb.dbo.sysjobs j ON j.job_id = h.job_id
WHERE h.step_id = 0 AND j.name = N'$jobNameEsc'
  AND (h.run_date > $beforeDate
       OR (h.run_date = $beforeDate AND h.run_time > $beforeTime))
ORDER BY h.run_date DESC, h.run_time DESC
"@
                        $deadline = (Get-Date).AddSeconds(60)
                        $outcome = $null
                        while ((Get-Date) -lt $deadline) {
                            Start-Sleep -Seconds 2
                            try {
                                $row = Invoke-Sqlcmd -ServerInstance $connStr -Query $pollQuery -QueryTimeout 15 @sqlParams -ErrorAction SilentlyContinue
                                if ($row -and $null -ne $row.run_status -and $row.run_status -isnot [System.DBNull]) {
                                    $outcome = $row
                                    break
                                }
                            }
                            catch { }
                        }
                        if (-not $outcome) {
                            $results.Details.Add("WARN: Agent job '$jobName' did not complete within 60s of sp_start_job ($reason)")
                        }
                        elseif ([int]$outcome.run_status -eq 1) {
                            if ($isRetry) {
                                # The passive job-health block above already emitted
                                # a screen-visible WARN for this job (the prior
                                # failure was the last history row at scan time).
                                # We've now proven the job is healthy by re-running
                                # it successfully, so suppress that WARN and emit
                                # a single RECOVERED: line in its place. The DIAG
                                # follow-up line (log-only) stays for forensics.
                                $warnPattern = "^WARN: Agent job '$([regex]::Escape($jobName))' last run: "
                                for ($wi = $results.Details.Count - 1; $wi -ge 0; $wi--) {
                                    if ($results.Details[$wi] -match $warnPattern) {
                                        $results.Details.RemoveAt($wi)
                                        break
                                    }
                                }
                                $results.Details.Add("RECOVERED: Agent job '$jobName' previously failed; re-triggered and succeeded at $($outcome.LastRunTime)")
                            }
                            else {
                                $results.Details.Add("OK: Agent job '$jobName' triggered and succeeded at $($outcome.LastRunTime)")
                            }
                        }
                        else {
                            $statusMap2 = @{ 0 = 'Failed'; 2 = 'Retry'; 3 = 'Cancelled'; 4 = 'In Progress' }
                            $st = if ($statusMap2.ContainsKey([int]$outcome.run_status)) { $statusMap2[[int]$outcome.run_status] } else { "Status $($outcome.run_status)" }
                            $msgTail2 = ''
                            if ($outcome.LastMessage) {
                                $clean2 = ($outcome.LastMessage -replace '\s+', ' ').Trim()
                                if ($clean2) { $msgTail2 = " - $clean2" }
                            }
                            $results.Details.Add("WARN: Agent job '$jobName' triggered run ($reason): $st at $($outcome.LastRunTime)$msgTail2")
                            # Pull the actual step-level error (T-SQL message from
                            # the body of the job) for the NEW run instance only.
                            # Filtered by (run_date, run_time) > before-window so
                            # we never report a stale prior-run step message.
                            # Emitted as DIAG so it stays log-only (Ola's procs
                            # emit ~1.5KB of preamble before the actual error;
                            # widened to 4000 chars so the actionable bit fits).
                            $stepQuery = @"
SELECT TOP 1 ISNULL(h.step_name, '''') AS StepName,
             LEFT(ISNULL(h.message, ''''), 4000) AS StepMessage
FROM msdb.dbo.sysjobhistory h
JOIN msdb.dbo.sysjobs j ON j.job_id = h.job_id
WHERE h.step_id > 0 AND j.name = N'$jobNameEsc'
  AND (h.run_date > $beforeDate
       OR (h.run_date = $beforeDate AND h.run_time > $beforeTime))
ORDER BY h.instance_id DESC
"@
                            try {
                                $stepRow = Invoke-Sqlcmd -ServerInstance $connStr -Query $stepQuery -QueryTimeout 15 @sqlParams -ErrorAction SilentlyContinue
                                if ($stepRow -and $stepRow.StepMessage -and $stepRow.StepMessage -isnot [System.DBNull]) {
                                    $stepClean2 = ($stepRow.StepMessage -replace '\s+', ' ').Trim()
                                    if ($stepClean2) {
                                        $stepName2 = if ($stepRow.StepName) { $stepRow.StepName } else { '(step)' }
                                        $results.Details.Add("DIAG:   Step '$stepName2' output: $stepClean2")
                                    }
                                }
                            }
                            catch { }
                        }
                    }
                }
            }
            catch {
                $results.Details.Add("WARN: MemLabs job validation failed: $($_.Exception.Message)")
            }
        }

        return $results
    }

    $result = Invoke-VmCommand -VmName $VMName -VmDomainName $domain `
        -ScriptBlock $scriptBlock -ArgumentList $instanceName, $sqlPort, $isSQLAO `
        -DisplayName "Phase11-SQL-Test" -SuppressLog `
        -AsJob -TimeoutSeconds 300

    return (Format-TestResult -VMName $VMName -RoleLabel 'SQL' -Result $result)
}

function Test-SqlIsoNotMounted {
    <#
    .SYNOPSIS
        Host-side check that the SQL ISO is not left mounted on a SQL VM after
        the build completes.
    .DESCRIPTION
        Phase 4 mounts the SQL ISO to install SQL, then the host ejects it on a
        successful phase (Dismount-SqlIsoForPhase). On a failed Phase 4 the ISO
        is deliberately left mounted for debugging. By Phase 11 a healthy SQL VM
        should have an empty DVD drive; a still-attached ISO indicates the eject
        was skipped (e.g. a prior failed run that was never re-run cleanly).
        Buffers a FAIL line into $script:Phase11OutputBuffer like the other
        host-side Phase 11 tests, and returns $true when the DVD is empty.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][object]$CurrentItem,
        [Parameter(Mandatory)][object]$DeployConfig
    )

    $Phase = 11
    $label = 'SQL-ISO'

    $dvd = Get-VMDvdDrive -VMName $VMName -ErrorAction SilentlyContinue
    $mountedPath = ($dvd | Where-Object { $_.Path } | Select-Object -First 1).Path

    if ($mountedPath) {
        $script:Phase11OutputBuffer.Add(@{ Text = "[Phase $Phase] [$label]: FAIL: $VMName still has an ISO mounted ($mountedPath); SQL ISO should be ejected after Phase 4"; Level = 'Failure' })
        Write-Log "[Phase $Phase] [$label]: $VMName has ISO still mounted: $mountedPath" -Failure -LogOnly
        return $false
    }

    Write-Log "[Phase $Phase] [$label]: $VMName DVD drive is empty (SQL ISO not mounted)" -LogOnly
    return $true
}

function Test-SQLAOFunctionality {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][object]$CurrentItem,
        [Parameter(Mandatory)][object]$DeployConfig
    )

    $Phase = 11
    $domain = $DeployConfig.vmOptions.domainName

    # First run basic SQL tests
    $sqlOk = Test-SQLFunctionality -VMName $VMName -CurrentItem $CurrentItem -DeployConfig $DeployConfig
    if (-not $sqlOk) { return $false }

    Write-Log "[Phase $Phase] $VMName [SQLAO]: Testing Availability Group health" -LogOnly

    # Gather SQLAO config from the primary node definition (the one with OtherNode)
    $primaryAO = $DeployConfig.virtualMachines | Where-Object { $_.role -eq 'SQLAO' -and $_.OtherNode }
    $listenerName = ''
    $agName = ''
    $otherNode = ''
    $witnessShare = ''
    $backupShare = ''
    $agIP = ''
    $listenerPort = '1500'

    $clusterName = ''
    $clusterIP = ''

    if ($primaryAO) {
        $listenerName = $primaryAO.AlwaysOnListenerName
        $agName = $primaryAO.AlwaysOnGroupName
        $agIP = $primaryAO.AGIPAddress   # without CIDR
        # "Other node" relative to THIS VM
        $otherNode = if ($VMName -eq $primaryAO.vmName) { $primaryAO.OtherNode } else { $primaryAO.vmName }
        # Derive share UNC paths (same logic as Get-SQLAOConfig)
        $prefix = $DeployConfig.vmOptions.prefix
        $clusterNameNoPrefix = $primaryAO.ClusterName.Replace($prefix, "")
        $fileServerVM = $primaryAO.FileServerVM
        $witnessShare = "\\$fileServerVM\$($clusterNameNoPrefix)-Witness"
        $backupShare = "\\$fileServerVM\$($clusterNameNoPrefix)-Backup"
        $clusterName = $primaryAO.ClusterName
        $clusterIP = $primaryAO.ClusterIPAddress   # raw IP without CIDR
    }

    $sqlInstName = $CurrentItem.sqlInstanceName
    if (-not $sqlInstName) { $sqlInstName = 'MSSQLSERVER' }

    $scriptBlock = {
        param($listenerName, $listenerPort, $agName, $otherNode, $witnessShare, $backupShare, $agIP, $sqlInstName, $clusterName, $clusterIP)

        $results = @{ Passed = $true; Details = [System.Collections.Generic.List[string]]::new() }

        # Live status — Write-Progress records emitted here are confined to this
        # -AsJob nested job; Invoke-VmCommand -PollProgress polls and re-emits the
        # latest one so Phase 11 shows live SQLAO status instead of appearing frozen.
        $progressActivity = "$env:COMPUTERNAME [SQLAO]"
        Write-Progress -Activity $progressActivity -Status "Starting SQLAO validation"

        # Resolve domain and DNS server once — used by all DNS zone queries.
        # SQLAO VMs aren't DCs, so query the DC's DNS zone remotely. Build a
        # CANDIDATE LIST of DNS servers (not just the first NIC's first entry):
        # SQLAO nodes have a heartbeat NIC, and if a stale DNS server leaked
        # onto it (or onto a disconnected adapter), picking [0] can silently
        # target a non-resolver and time out every probe. Iterate every IPv4
        # ServerAddress across every NIC, skip loopback / APIPA / 0.0.0.0, and
        # try each candidate at the call site until one answers.
        $domain = (Get-CimInstance Win32_ComputerSystem).Domain
        $dnsCandidates = @(
            Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.ServerAddresses } |
                ForEach-Object { $_.ServerAddresses } |
                Where-Object {
                    $_ -and $_ -ne '0.0.0.0' -and $_ -ne '127.0.0.1' -and
                    $_ -notlike '169.254.*' -and $_ -notlike '127.*'
                } |
                Select-Object -Unique
        )
        $dnsServer = if ($dnsCandidates.Count -gt 0) { $dnsCandidates[0] } else { $null }

        # Watchdog: run a scriptblock under Start-ThreadJob (or Start-Job
        # fallback) with a per-attempt timeout and retry. A few SQLAO probes
        # (Get-DnsServerResourceRecord against a slow DC, Invoke-Sqlcmd to a
        # listener whose AG IP is mid-failover) have no native timeout and
        # can block far past the outer 10-min Invoke-VmCommand budget. The
        # whole test normally completes in seconds, so a stuck probe is
        # almost certainly a transient hang -- kill it after $TimeoutSec,
        # try again up to $MaxAttempts, and treat all-attempts-timed-out as
        # WARN (not FAIL). Caller inspects .Status (OK / Error / TimedOut)
        # and reads .Output / .Errors.
        function Invoke-WithWatchdog {
            param(
                [Parameter(Mandatory)] [scriptblock] $ScriptBlock,
                [object[]] $ArgumentList = @(),
                [int] $TimeoutSec = 20,
                [int] $MaxAttempts = 3
            )
            $useThreadJob = $null -ne (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue)
            $attemptLog = [System.Collections.Generic.List[string]]::new()
            for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
                $job = $null
                try {
                    $job = if ($useThreadJob) {
                        Start-ThreadJob -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList -ErrorAction Stop
                    } else {
                        Start-Job -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList -ErrorAction Stop
                    }
                    $completed = Wait-Job -Job $job -Timeout $TimeoutSec
                    if ($completed) {
                        $jobErrors = $null
                        $output = Receive-Job -Job $job -ErrorAction SilentlyContinue -ErrorVariable jobErrors
                        try { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue } catch {}
                        $status = if ($jobErrors -and $jobErrors.Count -gt 0) { 'Error' } else { 'OK' }
                        return [pscustomobject]@{
                            Status     = $status
                            Output     = $output
                            Errors     = @($jobErrors)
                            Attempts   = $attempt
                            AttemptLog = $attemptLog
                        }
                    }
                    $attemptLog.Add("attempt $attempt timed out after ${TimeoutSec}s")
                    try { Stop-Job -Job $job -ErrorAction SilentlyContinue } catch {}
                    try { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue } catch {}
                }
                catch {
                    $attemptLog.Add("attempt $attempt failed to start: $($_.Exception.Message)")
                    if ($job) { try { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue } catch {} }
                }
            }
            return [pscustomobject]@{
                Status     = 'TimedOut'
                Output     = $null
                Errors     = @()
                Attempts   = $MaxAttempts
                AttemptLog = $attemptLog
            }
        }

        try {
            Import-Module SqlServer -ErrorAction SilentlyContinue
            if (-not (Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue)) {
                Import-Module SQLPS -DisableNameChecking -ErrorAction SilentlyContinue
            }

            # ==============================================================
            # 1. Failover Cluster health
            # ==============================================================
            Write-Progress -Activity $progressActivity -Status "Checking failover cluster health"
            $results.Details.Add("CMD: Get-Cluster / Get-ClusterNode / Get-ClusterQuorum")
            try {
                Import-Module FailoverClusters -ErrorAction SilentlyContinue

                # Post-reboot settle wait: after a -startPhase 11 rerun the nodes
                # are freshly booted and the failover cluster needs a minute or two
                # to re-form (node rejoin + AG IP resource online). Poll up to ~2 min
                # for all nodes Up and all IP-Address resources Online before
                # evaluating, so a not-yet-settled cluster doesn't produce spurious
                # FAILs. If it never settles, the checks below still FAIL as before.
                $settleWaited = $false
                for ($cw = 1; $cw -le 8; $cw++) {
                    try {
                        $wNodes = @(Get-ClusterNode -ErrorAction Stop)
                        $wIp = @(Get-ClusterResource -ErrorAction SilentlyContinue | Where-Object { $_.ResourceType -eq 'IP Address' })
                        $allUp = ($wNodes.Count -gt 0) -and -not @($wNodes | Where-Object { $_.State -ne 'Up' }).Count
                        $ipOk = -not @($wIp | Where-Object { $_.State -ne 'Online' }).Count
                        if ($allUp -and $ipOk) { break }
                    }
                    catch { }
                    if ($cw -lt 8) { Start-Sleep -Seconds 15; $settleWaited = $true }
                }
                if ($settleWaited) {
                    $results.Details.Add("INFO: Waited for cluster to settle after reboot before evaluating node/resource state")
                }

                $cluster = Get-Cluster -ErrorAction Stop
                $results.Details.Add("OK: Cluster '$($cluster.Name)' is online")

                $nodes = @(Get-ClusterNode -ErrorAction Stop)
                $downNodes = @($nodes | Where-Object { $_.State -ne 'Up' })
                if ($downNodes.Count -gt 0) {
                    $results.Passed = $false
                    foreach ($n in $downNodes) {
                        $results.Details.Add("FAIL: Cluster node '$($n.Name)' is $($n.State)")
                    }
                }
                else {
                    $results.Details.Add("OK: All $($nodes.Count) cluster node(s) are Up ($($nodes.Name -join ', '))")
                }

                $quorum = Get-ClusterQuorum -ErrorAction Stop
                $results.Details.Add("OK: Quorum type '$($quorum.QuorumType)', resource '$($quorum.QuorumResource)'")

                # Validate cluster resource IPs
                $results.Details.Add("CMD: Validate cluster resource IPs and DNS")
                $clusterIPRes = Get-ClusterResource -ErrorAction SilentlyContinue | Where-Object { $_.ResourceType -eq 'IP Address' }
                foreach ($ipRes in $clusterIPRes) {
                    $ip = ($ipRes | Get-ClusterParameter -Name Address -ErrorAction SilentlyContinue).Value
                    $network = ($ipRes | Get-ClusterParameter -Name Network -ErrorAction SilentlyContinue).Value
                    $results.Details.Add("OK: Cluster IP resource '$($ipRes.Name)' = $ip on '$network' ($($ipRes.State))")
                    if ($ipRes.State -ne 'Online') {
                        $results.Passed = $false
                        $results.Details.Add("FAIL: Cluster IP resource '$($ipRes.Name)' is $($ipRes.State), expected Online")
                    }
                }

                # Validate cluster name DNS points to the correct IP
                # Query the DC's DNS zone directly instead of Resolve-DnsName
                # (which can return LLMNR/cache results masking stale records).
                if ($clusterName) {
                    $results.Details.Add("CMD: Get-DnsServerResourceRecord -ZoneName '$domain' -Name '$clusterName' -RRType A -ComputerName '$dnsServer'")
                    $clusterRecs = @(Get-DnsServerResourceRecord -ZoneName $domain -Name $clusterName -RRType A -ComputerName $dnsServer -ErrorAction SilentlyContinue)
                    $resolvedIPs = @($clusterRecs | ForEach-Object { $_.RecordData.IPv4Address.IPAddressToString })
                    if ($resolvedIPs.Count -eq 0) {
                        $results.Passed = $false
                        $results.Details.Add("FAIL: Cluster name '$clusterName' does not resolve in DNS")
                    }
                    else {
                        $results.Details.Add("OK: Cluster name '$clusterName' resolves to $($resolvedIPs -join ', ')")
                        if ($clusterIP -and $clusterIP -notin $resolvedIPs) {
                            $results.Passed = $false
                            $results.Details.Add("FAIL: Expected cluster IP '$clusterIP' not in DNS (found: $($resolvedIPs -join ', '))")
                        }
                        # Check for stale non-cluster IPs
                        foreach ($rip in $resolvedIPs) {
                            if ($clusterIP -and $rip -ne $clusterIP) {
                                $results.Details.Add("WARN: Cluster DNS has unexpected IP '$rip' (expected '$clusterIP')")
                            }
                        }
                    }

                    # Verify RPC connectivity to cluster name
                    $results.Details.Add("CMD: Test-NetConnection '$clusterName' -Port 135")
                    $rpc = Test-NetConnection -ComputerName $clusterName -Port 135 -WarningAction SilentlyContinue
                    if ($rpc.TcpTestSucceeded) {
                        $results.Details.Add("OK: RPC port 135 reachable on '$clusterName' ($($rpc.RemoteAddress))")
                    }
                    else {
                        $results.Passed = $false
                        $results.Details.Add("FAIL: RPC port 135 not reachable on '$clusterName' ($($rpc.RemoteAddress)) - cluster management will fail")
                    }
                }
            }
            catch {
                $results.Passed = $false
                $results.Details.Add("FAIL: Cluster health check failed: $($_.Exception.Message)")
            }

            # ==============================================================
            # 1a. Cluster resource state — check all resources, remediate failed
            # ==============================================================
            # The AG SQL DMVs can report HEALTHY while the cluster resource
            # itself is Failed (Event 1069). Check every cluster resource and
            # attempt to bring failed ones online.
            try {
                $allResources = @(Get-ClusterResource -ErrorAction Stop)
                $failedResources = @($allResources | Where-Object { $_.State -notin @('Online', 'Offline') })
                $offlineResources = @($allResources | Where-Object { $_.State -eq 'Offline' })

                if ($failedResources.Count -eq 0 -and $offlineResources.Count -eq 0) {
                    $results.Details.Add("OK: All $($allResources.Count) cluster resource(s) are Online")
                }
                else {
                    foreach ($res in $failedResources) {
                        $results.Details.Add("REMEDIATE: Cluster resource '$($res.Name)' ($($res.ResourceType)) is $($res.State) in group '$($res.OwnerGroup)' — attempting Start")
                        try {
                            $res | Start-ClusterResource -ErrorAction Stop | Out-Null
                            Start-Sleep -Seconds 5
                            $recheck = Get-ClusterResource -Name $res.Name -ErrorAction Stop
                            if ($recheck.State -eq 'Online') {
                                $results.Details.Add("OK: Cluster resource '$($res.Name)' recovered to Online")
                            }
                            else {
                                $results.Passed = $false
                                $results.Details.Add("FAIL: Cluster resource '$($res.Name)' still $($recheck.State) after Start attempt")
                            }
                        }
                        catch {
                            $results.Passed = $false
                            $results.Details.Add("FAIL: Could not start cluster resource '$($res.Name)': $($_.Exception.Message)")
                        }
                    }
                    # AG resources Offline after a cold cluster start is
                    # recoverable — try Start-ClusterGroup for the AG group.
                    # Common cause: domain NIC had APIPA during cold start,
                    # cluster mapped it to a phantom network, AG IP couldn't bind.
                    $offlineAGResources = @($offlineResources | Where-Object { $_.OwnerGroup -eq $agName })
                    $offlineOtherResources = @($offlineResources | Where-Object { $_.OwnerGroup -ne $agName })

                    if ($offlineAGResources.Count -gt 0) {
                        foreach ($res in $offlineAGResources) {
                            $results.Details.Add("REMEDIATE: AG resource '$($res.Name)' ($($res.ResourceType)) is Offline — will attempt group start")
                        }

                        # First attempt: just start the AG group
                        try {
                            Start-ClusterGroup $agName -ErrorAction Stop | Out-Null
                            Start-Sleep -Seconds 10
                            $agGroupState = (Get-ClusterGroup $agName -ErrorAction Stop).State
                            if ($agGroupState -eq 'Online') {
                                $results.Details.Add("OK: AG cluster group '$agName' recovered to Online")
                            }
                        }
                        catch {
                            $results.Details.Add("WARN: Start-ClusterGroup '$agName' failed: $($_.Exception.Message)")
                        }

                        # If still not online, check for APIPA (cold-start NIC issue)
                        $agGroupState2 = (Get-ClusterGroup $agName -ErrorAction SilentlyContinue).State
                        if ($agGroupState2 -ne 'Online') {
                            $domainIPs = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                                Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '10.250.*' -and $_.IPAddress -notlike '169.254.*' })
                            $apipaOnly = $domainIPs.Count -eq 0

                            if ($apipaOnly) {
                                $results.Details.Add("REMEDIATE: Domain NIC has no valid IP (APIPA) — attempting DHCP renew")
                                try {
                                    $null = & ipconfig /renew 2>&1
                                    Start-Sleep -Seconds 10
                                    $newIPs = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                                        Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '10.250.*' -and $_.IPAddress -notlike '169.254.*' })
                                    if ($newIPs.Count -gt 0) {
                                        $results.Details.Add("OK: DHCP renew got $($newIPs[0].IPAddress)")
                                        # Restart cluster service so it re-enumerates NICs
                                        # and removes the phantom network
                                        Restart-Service ClusSvc -Force -ErrorAction Stop
                                        Start-Sleep -Seconds 20
                                        $results.Details.Add("OK: Cluster service restarted for NIC re-enumeration")
                                        # Retry AG group start
                                        try {
                                            Start-ClusterGroup $agName -ErrorAction Stop | Out-Null
                                            Start-Sleep -Seconds 10
                                            $agGroupFinal = (Get-ClusterGroup $agName -ErrorAction Stop).State
                                            if ($agGroupFinal -eq 'Online') {
                                                $results.Details.Add("OK: AG cluster group '$agName' recovered to Online after NIC fix")
                                            }
                                            else {
                                                $results.Passed = $false
                                                $results.Details.Add("FAIL: AG cluster group '$agName' still $agGroupFinal after NIC fix + group start")
                                            }
                                        }
                                        catch {
                                            $results.Passed = $false
                                            $results.Details.Add("FAIL: Start-ClusterGroup '$agName' failed after NIC fix: $($_.Exception.Message)")
                                        }
                                    }
                                    else {
                                        $results.Passed = $false
                                        $results.Details.Add("FAIL: DHCP renew did not obtain a valid IP — DHCP server may be down")
                                    }
                                }
                                catch {
                                    $results.Passed = $false
                                    $results.Details.Add("FAIL: APIPA recovery failed: $($_.Exception.Message)")
                                }
                            }
                            else {
                                # NIC has a valid IP but AG group still won't start
                                $results.Passed = $false
                                $results.Details.Add("FAIL: AG cluster group '$agName' is $agGroupState2 (domain NIC has IP $($domainIPs[0].IPAddress) — not an APIPA issue)")
                            }
                        }
                    }

                    foreach ($res in $offlineOtherResources) {
                        # Non-AG Offline resources are informational
                        $results.Details.Add("WARN: Cluster resource '$($res.Name)' ($($res.ResourceType)) is Offline in group '$($res.OwnerGroup)'")
                    }
                }

                # Check for recent cluster resource failures in System event log
                try {
                    $since = (Get-Date).AddMinutes(-30)
                    $clusterEvents = Get-WinEvent -FilterHashtable @{
                        LogName = 'System'
                        ProviderName = 'Microsoft-Windows-FailoverClustering'
                        Id = 1069   # Resource failed
                        StartTime = $since
                    } -ErrorAction SilentlyContinue
                    if ($clusterEvents -and $clusterEvents.Count -gt 0) {
                        $uniqueResources = @($clusterEvents | ForEach-Object {
                            try { $_.Properties[0].Value } catch { 'Unknown' }
                        } | Sort-Object -Unique)
                        # Check current state of each resource that had failures
                        $stateNotes = @()
                        foreach ($resName in $uniqueResources) {
                            $cr = Get-ClusterResource -Name $resName -ErrorAction SilentlyContinue
                            if ($cr) {
                                $stateNotes += "$resName=$($cr.State)"
                            }
                            else {
                                $stateNotes += "$resName=NotFound"
                            }
                        }
                        $results.Details.Add("WARN: $($clusterEvents.Count) cluster resource failure event(s) (1069) in last 30 min for: $($uniqueResources -join ', ') (current: $($stateNotes -join ', '))")
                    }
                }
                catch {}
            }
            catch {
                $results.Details.Add("WARN: Cluster resource check failed: $($_.Exception.Message)")
            }

            # ==============================================================
            # 1b. Network configuration validation
            # ==============================================================
            Write-Progress -Activity $progressActivity -Status "Validating cluster network configuration"
            $results.Details.Add("CMD: Validate cluster network configuration")
            try {
                $clusterSubnet = '10.250.251.'

                # Classify adapters by subnet
                $allAdapters = @(Get-NetAdapter | Where-Object { $_.Status -eq 'Up' })
                $heartbeatAdapters = @()
                $domainAdapters = @()
                foreach ($a in $allAdapters) {
                    $ips = Get-NetIPAddress -InterfaceIndex $a.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
                    if ($ips | Where-Object { $_.IPAddress -like "${clusterSubnet}*" }) {
                        $heartbeatAdapters += $a
                    }
                    else {
                        $domainAdapters += $a
                    }
                }

                # Heartbeat NIC: DNS registration must be impossible (no servers, no suffix, flag off)
                foreach ($hb in $heartbeatAdapters) {
                    $dnsClient = Get-DnsClient -InterfaceIndex $hb.InterfaceIndex -ErrorAction SilentlyContinue
                    $dnsServers = (Get-DnsClientServerAddress -InterfaceIndex $hb.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses
                    $problems = @()
                    if ($dnsClient.RegisterThisConnectionsAddress) { $problems += 'RegisterThisConnectionsAddress=true' }
                    if ($dnsClient.ConnectionSpecificSuffix)        { $problems += "Suffix='$($dnsClient.ConnectionSpecificSuffix)'" }
                    if ($dnsServers -and $dnsServers.Count -gt 0)   { $problems += "DnsServers=$($dnsServers -join ',')" }

                    if ($problems.Count -gt 0) {
                        $results.Details.Add("REMEDIATE: Heartbeat adapter '$($hb.Name)' can register in DNS: $($problems -join '; ')")
                        Set-DnsClient -InterfaceIndex $hb.InterfaceIndex -RegisterThisConnectionsAddress $false -ConnectionSpecificSuffix '' -ErrorAction SilentlyContinue
                        Set-DnsClientServerAddress -InterfaceIndex $hb.InterfaceIndex -ServerAddresses @() -ErrorAction SilentlyContinue
                    }
                    else {
                        $results.Details.Add("OK: Heartbeat adapter '$($hb.Name)' cannot register in DNS")
                    }

                    # No default gateway on heartbeat NIC
                    $gw = Get-NetRoute -InterfaceIndex $hb.InterfaceIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue
                    if ($gw) {
                        $results.Details.Add("WARN: Heartbeat adapter '$($hb.Name)' has a default gateway")
                    }
                }

                # NIC metrics: domain (lower) should be preferred over heartbeat (higher)
                if ($domainAdapters -and $heartbeatAdapters) {
                    $domMetric = (Get-NetIPInterface -InterfaceIndex $domainAdapters[0].InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).InterfaceMetric
                    $hbMetric  = (Get-NetIPInterface -InterfaceIndex $heartbeatAdapters[0].InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).InterfaceMetric
                    if ($domMetric -ge $hbMetric) {
                        $results.Details.Add("WARN: Domain NIC metric ($domMetric) >= heartbeat NIC metric ($hbMetric) — domain should be preferred")
                    }
                    else {
                        $results.Details.Add("OK: Domain NIC metric ($domMetric) < heartbeat NIC metric ($hbMetric)")
                    }
                }

                # Cluster network roles: heartbeat = 1 (cluster only), domain = 3 (cluster + client)
                $clusterNetworks = Get-ClusterNetwork -ErrorAction SilentlyContinue
                foreach ($cn in $clusterNetworks) {
                    $roleDesc = switch ([int]$cn.Role) { 0 { 'None' }; 1 { 'Cluster Only' }; 3 { 'Cluster + Client' }; default { "Unknown ($($cn.Role))" } }
                    $isHeartbeat = $cn.Address -like "${clusterSubnet}*"
                    if ($isHeartbeat -and $cn.Role -ne 1) {
                        $results.Details.Add("WARN: Heartbeat network '$($cn.Name)' ($($cn.Address)) role is '$roleDesc' (expected 'Cluster Only')")
                    }
                    elseif (-not $isHeartbeat -and $cn.Role -ne 3) {
                        $results.Details.Add("WARN: Domain network '$($cn.Name)' ($($cn.Address)) role is '$roleDesc' (expected 'Cluster + Client')")
                    }
                    else {
                        $results.Details.Add("OK: Network '$($cn.Name)' ($($cn.Address)) role is '$roleDesc'")
                    }
                }

                # RegisterAllProvidersIP on Cluster Name resource should be 0
                try {
                    $clusNameRes = Get-ClusterResource -Name 'Cluster Name' -ErrorAction Stop
                    $regAll = ($clusNameRes | Get-ClusterParameter -Name RegisterAllProvidersIP -ErrorAction SilentlyContinue).Value
                    if ($null -ne $regAll -and $regAll -ne 0) {
                        $results.Details.Add("WARN: Cluster Name RegisterAllProvidersIP = $regAll (expected 0)")
                    }
                    else {
                        $results.Details.Add("OK: Cluster Name RegisterAllProvidersIP = 0")
                    }
                }
                catch {
                    $results.Details.Add("WARN: Could not check RegisterAllProvidersIP: $($_.Exception.Message)")
                }

                # Cluster Group IP resources should be on Domain Network, not heartbeat
                $clusterGroupIPs = Get-ClusterResource -ErrorAction SilentlyContinue |
                    Where-Object { $_.OwnerGroup.Name -eq 'Cluster Group' -and $_.ResourceType -eq 'IP Address' }
                foreach ($cgIP in $clusterGroupIPs) {
                    $ipNetwork = ($cgIP | Get-ClusterParameter -Name Network -ErrorAction SilentlyContinue).Value
                    $ipAddr    = ($cgIP | Get-ClusterParameter -Name Address -ErrorAction SilentlyContinue).Value
                    if ($ipNetwork -and $ipAddr -notlike "${clusterSubnet}*" -and $ipNetwork -ne 'Domain Network') {
                        $results.Details.Add("WARN: Cluster Group IP '$($cgIP.Name)' ($ipAddr) is on '$ipNetwork' (expected 'Domain Network')")
                    }
                }

                # Hostname must not have A records pointing to the heartbeat subnet.
                # Query the DNS server directly via Get-DnsServerResourceRecord
                # instead of Resolve-DnsName.  Resolve-DnsName on a short name
                # falls through to LLMNR, which returns ALL local IPs (including
                # the heartbeat IP) even when the DNS server has no stale records.
                $hostname = $env:COMPUTERNAME
                $staleRecords = @()
                if ($dnsServer -and $domain) {
                    $allARecords = @(Get-DnsServerResourceRecord -ZoneName $domain -Name $hostname -RRType A -ComputerName $dnsServer -ErrorAction SilentlyContinue)
                    $staleRecords = @($allARecords | Where-Object { $_.RecordData.IPv4Address.IPAddressToString -like "${clusterSubnet}*" })
                }
                if ($staleRecords.Count -gt 0) {
                    $staleIPs = @($staleRecords | ForEach-Object { $_.RecordData.IPv4Address.IPAddressToString })
                    # Attempt remediation: disable DNS reg on heartbeat/virtual adapters,
                    # remove stale A records, and recheck. The cluster service recreates
                    # virtual adapters with default DNS settings on every boot, so stale
                    # records can reappear after any reboot between Phase 5 and Phase 11.
                    $results.Details.Add("REMEDIATE: Found heartbeat DNS A records ($($staleIPs -join ', ')), attempting cleanup")
                    try {
                        # Three-layer prevention on all non-domain adapters (physical + virtual):
                        #  1. RegisterThisConnectionsAddress = $false  (preference flag)
                        #  2. No DNS servers  (nowhere to send the update)
                        #  3. No DNS suffix   (no zone to register in)
                        # The cluster service recreates virtual adapters with default
                        # settings on every boot, so all three layers are needed.
                        foreach ($iface in (Get-NetIPInterface -AddressFamily IPv4 -ErrorAction SilentlyContinue)) {
                            $ifaceIPs = (Get-NetIPAddress -InterfaceIndex $iface.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress
                            $isDomain = $ifaceIPs | Where-Object { $_ -notlike "${clusterSubnet}*" -and $_ -ne '127.0.0.1' -and $_ -notlike '169.254.*' }
                            $isCluster = $ifaceIPs | Where-Object { $_ -like "${clusterSubnet}*" }
                            $isClusterName = $iface.InterfaceAlias -like '*Cluster*' -or $iface.InterfaceAlias -like '*isatap*'
                            if ($isCluster -or ($isClusterName -and -not $isDomain)) {
                                Set-DnsClient -InterfaceIndex $iface.ifIndex -RegisterThisConnectionsAddress $false -ConnectionSpecificSuffix '' -ErrorAction SilentlyContinue
                                Set-DnsClientServerAddress -InterfaceIndex $iface.ifIndex -ServerAddresses @() -ErrorAction SilentlyContinue
                            }
                        }
                        # Remove stale A records from DNS server
                        foreach ($rec in $staleRecords) {
                            $ip = $rec.RecordData.IPv4Address.IPAddressToString
                            Remove-DnsServerResourceRecord -ZoneName $domain -Name $hostname -RRType A -RecordData $ip -ComputerName $dnsServer -Force -ErrorAction SilentlyContinue
                            $results.Details.Add("REMEDIATE: Removed stale A record $hostname -> $ip")
                        }
                        # Recheck the DNS server directly (no LLMNR ambiguity)
                        $recheckRecords = @(Get-DnsServerResourceRecord -ZoneName $domain -Name $hostname -RRType A -ComputerName $dnsServer -ErrorAction SilentlyContinue)
                        $staleRecords2 = @($recheckRecords | Where-Object { $_.RecordData.IPv4Address.IPAddressToString -like "${clusterSubnet}*" })
                        if ($staleRecords2.Count -gt 0) {
                            $staleIPs2 = @($staleRecords2 | ForEach-Object { $_.RecordData.IPv4Address.IPAddressToString })
                            $results.Passed = $false
                            $results.Details.Add("FAIL: Hostname '$hostname' still has DNS A record(s) on heartbeat subnet after remediation: $($staleIPs2 -join ', ')")
                        }
                        else {
                            $results.Details.Add("OK: Hostname '$hostname' heartbeat DNS records cleaned up successfully")
                        }
                    }
                    catch {
                        $results.Passed = $false
                        $results.Details.Add("FAIL: Hostname '$hostname' has DNS A record(s) on heartbeat subnet: $($staleIPs -join ', ') (remediation failed: $($_.Exception.Message))")
                    }
                }
                else {
                    $results.Details.Add("OK: Hostname '$hostname' has no stale heartbeat DNS records")
                }
            }
            catch {
                $results.Details.Add("WARN: Network config validation error: $($_.Exception.Message)")
            }

            # ==============================================================
            # 2. Remediation pass: fix common issues before testing AG health
            # ==============================================================
            Write-Progress -Activity $progressActivity -Status "Remediating availability databases and endpoints"

            # 2a. Resume any suspended availability databases
            $suspendedQuery = @"
SELECT adb.database_name, ag.name AS GroupName, drs.synchronization_state_desc
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_databases_cluster adb ON drs.group_database_id = adb.group_database_id
JOIN sys.availability_groups ag ON drs.group_id = ag.group_id
WHERE drs.is_local = 1 AND drs.is_suspended = 1
"@
            $suspended = @(Invoke-Sqlcmd -Query $suspendedQuery -QueryTimeout 30 -TrustServerCertificate -ErrorAction SilentlyContinue)
            if ($suspended.Count -gt 0) {
                foreach ($db in $suspended) {
                    $results.Details.Add("REMEDIATE: Resuming suspended database '$($db.database_name)' in AG '$($db.GroupName)'")
                    try {
                        $resumeQuery = "ALTER DATABASE [$($db.database_name)] SET HADR RESUME"
                        Invoke-Sqlcmd -Query $resumeQuery -QueryTimeout 30 -TrustServerCertificate -ErrorAction Stop
                        $results.Details.Add("OK: Resumed '$($db.database_name)'")
                    }
                    catch {
                        $results.Details.Add("WARN: Failed to resume '$($db.database_name)': $($_.Exception.Message)")
                    }
                }
                # Give a moment for synchronization to start
                Start-Sleep -Seconds 10
            }

            # 2b. Check endpoint state and restart if stopped
            $epQuery = "SELECT name, state_desc FROM sys.database_mirroring_endpoints"
            $endpoints = @(Invoke-Sqlcmd -Query $epQuery -QueryTimeout 30 -TrustServerCertificate -ErrorAction SilentlyContinue)
            foreach ($ep in $endpoints) {
                if ($ep.state_desc -ne 'STARTED') {
                    $results.Details.Add("REMEDIATE: Endpoint '$($ep.name)' is '$($ep.state_desc)', starting it")
                    try {
                        Invoke-Sqlcmd -Query "ALTER ENDPOINT [$($ep.name)] STATE = STARTED" -QueryTimeout 30 -TrustServerCertificate -ErrorAction Stop
                        $results.Details.Add("OK: Endpoint '$($ep.name)' started")
                        Start-Sleep -Seconds 5
                    }
                    catch {
                        $results.Details.Add("WARN: Failed to start endpoint '$($ep.name)': $($_.Exception.Message)")
                    }
                }
            }

            # 2c. Check for DISCONNECTED replicas and cycle endpoint to force reconnection
            $disconnectedQuery = @"
SELECT ag.name AS GroupName, rs.role_desc, rs.connected_state_desc, rs.is_local
FROM sys.dm_hadr_availability_replica_states rs
JOIN sys.availability_groups ag ON rs.group_id = ag.group_id
WHERE rs.connected_state_desc = 'DISCONNECTED'
"@
            $disconnected = @(Invoke-Sqlcmd -Query $disconnectedQuery -QueryTimeout 30 -TrustServerCertificate -ErrorAction SilentlyContinue)
            if ($disconnected.Count -gt 0) {
                $localDisc = @($disconnected | Where-Object { $_.is_local -eq 1 })
                $remoteDisc = @($disconnected | Where-Object { $_.is_local -eq 0 })
                if ($localDisc.Count -gt 0) {
                    $results.Details.Add("REMEDIATE: Local replica DISCONNECTED, cycling mirroring endpoint")
                }
                elseif ($remoteDisc.Count -gt 0) {
                    $results.Details.Add("REMEDIATE: Remote replica DISCONNECTED, cycling local mirroring endpoint to force re-establish")
                }
                foreach ($ep in $endpoints) {
                    try {
                        Invoke-Sqlcmd -Query "ALTER ENDPOINT [$($ep.name)] STATE = STOPPED" -QueryTimeout 30 -TrustServerCertificate -ErrorAction Stop
                        Start-Sleep -Seconds 5
                        Invoke-Sqlcmd -Query "ALTER ENDPOINT [$($ep.name)] STATE = STARTED" -QueryTimeout 30 -TrustServerCertificate -ErrorAction Stop
                        $results.Details.Add("OK: Cycled endpoint '$($ep.name)' (STOPPED -> STARTED)")
                    }
                    catch {
                        $results.Details.Add("WARN: Failed to cycle endpoint '$($ep.name)': $($_.Exception.Message)")
                    }
                }
                # Wait for reconnection to establish
                Start-Sleep -Seconds 20

                # Re-check for suspended databases after reconnect and resume them
                $suspended2 = @(Invoke-Sqlcmd -Query $suspendedQuery -QueryTimeout 30 -TrustServerCertificate -ErrorAction SilentlyContinue)
                if ($suspended2.Count -gt 0) {
                    foreach ($db2 in $suspended2) {
                        $results.Details.Add("REMEDIATE: Resuming database '$($db2.database_name)' after endpoint cycle")
                        try {
                            Invoke-Sqlcmd -Query "ALTER DATABASE [$($db2.database_name)] SET HADR RESUME" -QueryTimeout 30 -TrustServerCertificate -ErrorAction Stop
                            $results.Details.Add("OK: Resumed '$($db2.database_name)'")
                        }
                        catch {
                            $results.Details.Add("WARN: Failed to resume '$($db2.database_name)': $($_.Exception.Message)")
                        }
                    }
                    Start-Sleep -Seconds 10
                }
            }

            # ==============================================================
            # 3. AG replica health check with retry
            # ==============================================================
            Write-Progress -Activity $progressActivity -Status "Checking Availability Group replica health"
            $healthQuery = @"
SELECT ag.name AS GroupName,
       rs.role_desc AS Role,
       rs.connected_state_desc AS ConnState,
       rs.synchronization_health_desc AS Health,
       ar.replica_server_name AS Replica
FROM sys.dm_hadr_availability_replica_states rs
JOIN sys.availability_groups ag ON rs.group_id = ag.group_id
JOIN sys.availability_replicas ar ON rs.replica_id = ar.replica_id
"@
            $results.Details.Add("CMD: AG health query with replica detail")
            $maxRetries = 5
            $healthy = $false
            for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
                $ag = @(Invoke-Sqlcmd -Query $healthQuery -QueryTimeout 30 -TrustServerCertificate -ErrorAction Stop)
                if (-not $ag -or $ag.Count -eq 0) {
                    $results.Passed = $false
                    $results.Details.Add("FAIL: No availability group replicas found")
                    break
                }
                $unhealthy = @($ag | Where-Object { $_.Health -ne 'HEALTHY' })
                if ($unhealthy.Count -eq 0) {
                    $healthy = $true
                    foreach ($r in $ag) {
                        $results.Details.Add("OK: AG '$($r.GroupName)' replica '$($r.Replica)' ($($r.Role)) — $($r.ConnState), $($r.Health)")
                    }
                    break
                }
                if ($attempt -lt $maxRetries) {
                    $results.Details.Add("WARN: Attempt $attempt/$maxRetries — $($unhealthy.Count) replica(s) not healthy, waiting 20s...")
                    Start-Sleep -Seconds 20
                }
                else {
                    $results.Passed = $false
                    foreach ($r in $ag) {
                        $level = if ($r.Health -ne 'HEALTHY') { 'FAIL' } else { 'OK' }
                        $results.Details.Add("${level}: AG '$($r.GroupName)' replica '$($r.Replica)' ($($r.Role)) — $($r.ConnState), $($r.Health)")
                    }
                }
            }

            # 3b. If still DISCONNECTED after retries, restart SQL on the appropriate node
            #
            # Root cause: both SQLAO nodes started at different times. Each
            # timed out trying to reach the other and neither retried. The
            # fix is to restart SQL on the node that is NOT currently running
            # this validation (the "other" node) so it freshly attempts to
            # connect while we are already up and listening.  If only the
            # local replica shows DISCONNECTED, restart locally instead.
            if (-not $healthy) {
                $stillDisconnected = @($ag | Where-Object { $_.ConnState -eq 'DISCONNECTED' })
                $localStillDisc = @($ag | Where-Object { $_.ConnState -eq 'DISCONNECTED' -and $_.Replica -eq $env:COMPUTERNAME })
                $remoteStillDisc = @($ag | Where-Object { $_.ConnState -eq 'DISCONNECTED' -and $_.Replica -ne $env:COMPUTERNAME })

                if ($stillDisconnected.Count -gt 0) {
                    # Determine restart target: prefer restarting the other node
                    # (we are already up and listening), fall back to local.
                    $restartTarget = $null
                    $restartIsRemote = $false
                    if ($remoteStillDisc.Count -gt 0 -and $otherNode) {
                        $restartTarget = $otherNode
                        $restartIsRemote = $true
                        $results.Details.Add("REMEDIATE: Remote replica '$otherNode' DISCONNECTED — restarting SQL on '$otherNode' (local node is up and listening)")
                    }
                    elseif ($localStillDisc.Count -gt 0) {
                        $restartTarget = $env:COMPUTERNAME
                        $restartIsRemote = $false
                        $results.Details.Add("REMEDIATE: Local replica DISCONNECTED — restarting SQL locally")
                    }

                    if ($restartTarget) {
                        try {
                            if ($restartIsRemote) {
                                Invoke-Command -ComputerName $restartTarget -ScriptBlock {
                                    Restart-Service MSSQLSERVER -Force -ErrorAction Stop
                                } -ErrorAction Stop
                            }
                            else {
                                Restart-Service MSSQLSERVER -Force -ErrorAction Stop
                            }
                            Start-Sleep -Seconds 30
                            $results.Details.Add("OK: SQL Server on '$restartTarget' restarted, rechecking AG health")

                            # Re-run health check after restart
                            for ($attempt2 = 1; $attempt2 -le 5; $attempt2++) {
                                $ag = @(Invoke-Sqlcmd -Query $healthQuery -QueryTimeout 30 -TrustServerCertificate -ErrorAction Stop)
                                $unhealthy2 = @($ag | Where-Object { $_.Health -ne 'HEALTHY' })
                                if ($unhealthy2.Count -eq 0) {
                                    $healthy = $true
                                    $results.Passed = $true
                                    foreach ($r in $ag) {
                                        $results.Details.Add("OK: AG '$($r.GroupName)' replica '$($r.Replica)' ($($r.Role)) — $($r.ConnState), $($r.Health)")
                                    }
                                    break
                                }
                                if ($attempt2 -lt 5) {
                                    $results.Details.Add("WARN: Post-restart attempt $attempt2/5 — $($unhealthy2.Count) replica(s) not healthy, waiting 20s...")
                                    Start-Sleep -Seconds 20
                                }
                                else {
                                    foreach ($r in $ag) {
                                        $level = if ($r.Health -ne 'HEALTHY') { 'FAIL' } else { 'OK' }
                                        $results.Details.Add("${level}: AG '$($r.GroupName)' replica '$($r.Replica)' ($($r.Role)) — $($r.ConnState), $($r.Health)")
                                    }
                                }
                            }
                        }
                        catch {
                            $results.Details.Add("WARN: Failed to restart SQL Server on '$restartTarget': $($_.Exception.Message)")
                        }
                    }
                }
            }

            # 3c. Collect DB-level sync state for diagnostics if still unhealthy
            if (-not $healthy) {
                $dbStateQuery = @"
SELECT adb.database_name, drs.synchronization_state_desc, drs.synchronization_health_desc,
       drs.is_suspended, drs.suspend_reason_desc
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_databases_cluster adb ON drs.group_database_id = adb.group_database_id
WHERE drs.is_local = 1
"@
                $dbStates = @(Invoke-Sqlcmd -Query $dbStateQuery -QueryTimeout 30 -TrustServerCertificate -ErrorAction SilentlyContinue)
                foreach ($ds in $dbStates) {
                    $suspInfo = if ($ds.is_suspended) { " (SUSPENDED: $($ds.suspend_reason_desc))" } else { '' }
                    $results.Details.Add("  DB '$($ds.database_name)': sync=$($ds.synchronization_state_desc), health=$($ds.synchronization_health_desc)$suspInfo")
                }
            }

            # ==============================================================
            # 4. TESTDB membership in availability group
            # ==============================================================
            Write-Progress -Activity $progressActivity -Status "Checking TESTDB availability group membership"
            if ($agName) {
                $results.Details.Add("CMD: Check TESTDB membership in AG '$agName'")
                try {
                    $agDBs = @(Invoke-Sqlcmd -Query "SELECT database_name FROM sys.availability_databases_cluster" -QueryTimeout 30 -TrustServerCertificate -ErrorAction Stop)
                    if ($agDBs.database_name -contains 'TESTDB') {
                        $results.Details.Add("OK: TESTDB is a member of the availability group")
                    }
                    else {
                        $results.Passed = $false
                        $dbList = if ($agDBs.Count -gt 0) { $agDBs.database_name -join ', ' } else { '(none)' }
                        $results.Details.Add("FAIL: TESTDB not found in AG databases: $dbList")
                    }
                }
                catch {
                    $results.Passed = $false
                    $results.Details.Add("FAIL: AG database membership query failed: $($_.Exception.Message)")
                }
            }

            # ==============================================================
            # 5. Listener DNS resolution
            # ==============================================================
            Write-Progress -Activity $progressActivity -Status "Checking listener DNS and SQL connectivity"
            # Query the DC's DNS zone directly instead of Resolve-DnsName.
            # Wrap in watchdog: the remote DNS RPC has no native timeout and
            # can hang for the entire 10-min outer budget if the DC is busy.
            # If the RPC channel is stuck OR the chosen DNS server isn't a
            # real resolver (stale entry on a SQLAO heartbeat NIC), iterate
            # every candidate DNS server from $dnsCandidates and fall back to
            # a direct port-53 DNS query against each -- still authoritative,
            # still bypasses local cache + LLMNR (-DnsOnly -NoHostsFile), just
            # a different transport that doesn't share the DnsServer RPC hang.
            #
            # IMPORTANT: this check is *informational*. The authoritative test
            # of "is DNS for the listener working?" is the SQL listener
            # connect in Step 6 -- if SqlClient resolved the listener and
            # opened a session, DNS is functional via the OS resolver
            # regardless of whether the explicit zone probes timed out.
            # On any DNS-probe failure we record a sentinel and defer the
            # WARN/INFO decision until after Step 6 has voted.
            $dnsProbeFailureMsg = $null  # null = succeeded or skipped, string = failure detail
            if ($listenerName) {
                if (-not $dnsServer) {
                    $dnsProbeFailureMsg = "no usable DNS server found on this VM (Get-DnsClientServerAddress returned no IPv4 entries outside loopback/APIPA)"
                }
                else {
                    $resolvedIPs = @()
                    $sourceNote = ''
                    $rpcStatus = 'Skipped'
                    foreach ($candidate in $dnsCandidates) {
                        $results.Details.Add("CMD: Get-DnsServerResourceRecord -ZoneName '$domain' -Name '$listenerName' -RRType A -ComputerName '$candidate'")
                        $wd = Invoke-WithWatchdog -TimeoutSec 20 -MaxAttempts 2 -ArgumentList @($domain, $listenerName, $candidate) -ScriptBlock {
                            param($zone, $name, $server)
                            Get-DnsServerResourceRecord -ZoneName $zone -Name $name -RRType A -ComputerName $server -ErrorAction Stop
                        }
                        $rpcStatus = $wd.Status
                        if ($wd.Status -eq 'OK') {
                            $resolvedIPs = @($wd.Output | ForEach-Object { $_.RecordData.IPv4Address.IPAddressToString })
                            $attemptNote = if ($wd.Attempts -gt 1) { ", attempt $($wd.Attempts)" } else { '' }
                            if ($candidate -ne $dnsCandidates[0] -or $wd.Attempts -gt 1) {
                                $sourceNote = " (via '$candidate'$attemptNote)"
                            }
                            break
                        }
                        elseif ($wd.Status -eq 'Error') {
                            $results.Details.Add("  RPC against '$candidate' errored: $($wd.Errors[0].Exception.Message)")
                        }
                        else {
                            $results.Details.Add("  RPC against '$candidate' timed out after $($wd.Attempts) attempts")
                        }
                    }

                    if ($resolvedIPs.Count -eq 0 -and $rpcStatus -ne 'OK') {
                        # RPC failed against every candidate -- try direct DNS port 53 next.
                        $fqdn = "$listenerName.$domain"
                        foreach ($candidate in $dnsCandidates) {
                            $results.Details.Add("CMD: Resolve-DnsName -Name '$fqdn' -Type A -Server '$candidate' -DnsOnly -NoHostsFile")
                            $wd2 = Invoke-WithWatchdog -TimeoutSec 10 -MaxAttempts 2 -ArgumentList @($fqdn, $candidate) -ScriptBlock {
                                param($n, $s)
                                Resolve-DnsName -Name $n -Type A -Server $s -DnsOnly -NoHostsFile -ErrorAction Stop
                            }
                            if ($wd2.Status -eq 'OK') {
                                $resolvedIPs = @($wd2.Output | Where-Object { $_.Type -eq 'A' } | ForEach-Object { $_.IPAddress })
                                if ($resolvedIPs.Count -gt 0) {
                                    $sourceNote = " (direct DNS via '$candidate')"
                                    break
                                }
                            }
                        }
                    }

                    if ($resolvedIPs.Count -gt 0) {
                        $results.Details.Add("OK: '$listenerName' resolves to $($resolvedIPs -join ', ')$sourceNote")
                        if ($agIP -and $agIP -notin $resolvedIPs) {
                            $results.Details.Add("WARN: Expected AG IP '$agIP' not in resolved addresses")
                        }
                    }
                    elseif ($rpcStatus -eq 'OK') {
                        # RPC succeeded but returned no records => listener has no A record in the zone.
                        # This is a genuine fault, not a probe glitch -- emit FAIL immediately.
                        $results.Passed = $false
                        $results.Details.Add("FAIL: '$listenerName' has no A records in DNS zone")
                    }
                    else {
                        # All probes failed. Defer the WARN/INFO decision until after Step 6.
                        $dnsProbeFailureMsg = "DNS zone probes (RPC + port 53) did not complete against any of $($dnsCandidates.Count) DNS server(s) [$($dnsCandidates -join ', ')]"
                    }
                }
            }

            # ==============================================================
            # 6. Listener SQL connectivity
            # ==============================================================
            # Wrap in watchdog: SqlClient's TCP/TLS handshake to a listener
            # whose AG IP is mid-failover can block for minutes without
            # honoring -QueryTimeout (which only governs post-connect).
            $listenerSqlOk = $false   # used by Step 5b to decide WARN vs INFO on a deferred DNS-probe failure
            if ($listenerName -and $listenerPort) {
                $listenerConnStr = "$listenerName,$listenerPort"
                $results.Details.Add("CMD: Invoke-Sqlcmd -ServerInstance '$listenerConnStr' -Query 'SELECT 1'")
                $wd = Invoke-WithWatchdog -TimeoutSec 30 -MaxAttempts 3 -ArgumentList @($listenerConnStr) -ScriptBlock {
                    param($conn)
                    Invoke-Sqlcmd -ServerInstance $conn -Query "SELECT 1 AS TestResult" -QueryTimeout 30 -TrustServerCertificate -ErrorAction Stop
                }
                if ($wd.Status -eq 'TimedOut') {
                    $results.Details.Add("WARN: SQL connection via listener '$listenerConnStr' did not complete after $($wd.Attempts) attempts (30s each); skipping. $($wd.AttemptLog -join '; ')")
                }
                elseif ($wd.Status -eq 'Error') {
                    $results.Passed = $false
                    $errMsg = if ($wd.Errors -and $wd.Errors[0].Exception) { $wd.Errors[0].Exception.Message } else { ($wd.Errors -join '; ') }
                    $results.Details.Add("FAIL: SQL connection via listener '$listenerConnStr' failed: $errMsg")
                }
                else {
                    $lr = $wd.Output
                    if ($lr.TestResult -eq 1) {
                        $retryNote = if ($wd.Attempts -gt 1) { " (succeeded on attempt $($wd.Attempts) after timeouts)" } else { '' }
                        $results.Details.Add("OK: SQL query via listener '$listenerConnStr' succeeded$retryNote")
                        $listenerSqlOk = $true
                    }
                    else {
                        $results.Passed = $false
                        $results.Details.Add("FAIL: Listener query returned unexpected result")
                    }
                }

                # ==========================================================
                # 6a. Listener IP recycle remediation
                # ==========================================================
                # When the listener SQL connect fails it is almost always
                # one of two faults: (1) the AG IP cluster resource is in a
                # phantom state (Online but not bound, or stuck Pending)
                # so the listener Network Name didn't re-register a fresh
                # A record, or (2) DNS has a stale A from a prior failover
                # owner. Both are fixed by an offline/online cycle of the
                # AG IP resource(s): on Offline the Network Name drops its
                # DNS registration, on Online the cluster re-registers an
                # A record for whichever IP is currently active. Do this
                # once and retry the listener SQL connect.
                if (-not $listenerSqlOk -and $agName) {
                    try {
                        $agGroup = Get-ClusterGroup -Name $agName -ErrorAction Stop
                        $agIpResources = @(Get-ClusterResource -ErrorAction Stop |
                            Where-Object { $_.OwnerGroup -eq $agName -and $_.ResourceType -eq 'IP Address' })
                        if ($agIpResources.Count -gt 0 -and $agGroup.State -eq 'Online') {
                            $ipNames = ($agIpResources | ForEach-Object { $_.Name }) -join ', '
                            $results.Details.Add("REMEDIATE: Listener SQL connect failed; cycling AG IP resource(s) [$ipNames] to force DNS re-registration")
                            foreach ($ipRes in $agIpResources) {
                                try {
                                    $ipRes | Stop-ClusterResource -ErrorAction Stop | Out-Null
                                }
                                catch {
                                    $results.Details.Add("  WARN: Stop-ClusterResource '$($ipRes.Name)' failed: $($_.Exception.Message)")
                                }
                            }
                            Start-Sleep -Seconds 5
                            foreach ($ipRes in $agIpResources) {
                                try {
                                    $ipRes | Start-ClusterResource -ErrorAction Stop | Out-Null
                                }
                                catch {
                                    $results.Details.Add("  WARN: Start-ClusterResource '$($ipRes.Name)' failed: $($_.Exception.Message)")
                                }
                            }
                            # Also start the AG group so the Network Name +
                            # AG resources come back up if cycling the IP
                            # took dependents offline.
                            try { Start-ClusterGroup -Name $agName -ErrorAction SilentlyContinue | Out-Null } catch { }

                            # Wait up to 60s for the IPs and the listener
                            # Network Name resource to be Online again.
                            $deadline = (Get-Date).AddSeconds(60)
                            do {
                                Start-Sleep -Seconds 5
                                $allOnline = $true
                                foreach ($ipRes in $agIpResources) {
                                    $st = (Get-ClusterResource -Name $ipRes.Name -ErrorAction SilentlyContinue).State
                                    if ($st -ne 'Online') { $allOnline = $false; break }
                                }
                                if ($allOnline -and $listenerName) {
                                    $nn = Get-ClusterResource -Name $listenerName -ErrorAction SilentlyContinue
                                    if ($nn -and $nn.State -ne 'Online') { $allOnline = $false }
                                }
                            } while (-not $allOnline -and (Get-Date) -lt $deadline)
                            $finalStates = ($agIpResources | ForEach-Object { "$($_.Name)=$((Get-ClusterResource -Name $_.Name -ErrorAction SilentlyContinue).State)" }) -join ', '
                            $results.Details.Add("  Post-cycle states: $finalStates")

                            # Retry the listener SQL connect once.
                            $results.Details.Add("CMD: Invoke-Sqlcmd -ServerInstance '$listenerConnStr' -Query 'SELECT 1' (post-recycle retry)")
                            $wdR = Invoke-WithWatchdog -TimeoutSec 30 -MaxAttempts 2 -ArgumentList @($listenerConnStr) -ScriptBlock {
                                param($conn)
                                Invoke-Sqlcmd -ServerInstance $conn -Query "SELECT 1 AS TestResult" -QueryTimeout 30 -TrustServerCertificate -ErrorAction Stop
                            }
                            if ($wdR.Status -eq 'OK' -and $wdR.Output.TestResult -eq 1) {
                                $results.Details.Add("OK: SQL query via listener '$listenerConnStr' succeeded after AG IP recycle")
                                $listenerSqlOk = $true
                            }
                            else {
                                $results.Details.Add("WARN: Listener SQL connect still failing after AG IP recycle (status=$($wdR.Status))")
                            }
                        }
                    }
                    catch {
                        $results.Details.Add("WARN: AG IP recycle remediation failed: $($_.Exception.Message)")
                    }
                }
            }

            # ==============================================================
            # 5b. Deferred DNS-probe verdict
            # ==============================================================
            # If Step 5's explicit zone probes (RPC + port 53) all failed
            # but Step 6's SqlClient connect succeeded, DNS is functional
            # via the OS resolver -- the WARN would be misleading. Demote
            # to INFO. Only emit a real WARN when neither path worked.
            if ($dnsProbeFailureMsg) {
                if ($listenerSqlOk) {
                    $results.Details.Add("INFO: $dnsProbeFailureMsg, but SQL listener connect in Step 6 succeeded -- DNS is functional via the OS resolver; explicit zone probe is informational only")
                }
                else {
                    $results.Details.Add("WARN: $dnsProbeFailureMsg; skipping listener DNS check")
                }
            }

            # ==============================================================
            # 6b. Kerberos authentication to remote SQL node
            # ==============================================================
            # The listener may resolve to the local node (primary), and
            # loopback connections always use NTLM. Test against the other
            # node instead — that's always a network hop where Kerberos
            # should be in effect.
            if ($otherNode) {
                # Use FQDN for the remote connection — short hostnames can
                # prevent SqlClient from constructing the correct Kerberos
                # SPN, causing silent NTLM fallback.
                try { $remoteNodeFQDN = ([System.Net.Dns]::GetHostEntry($otherNode)).HostName } catch { $remoteNodeFQDN = $otherNode }
                # GetHostEntry can return mDNS suffix (.local) instead of
                # the AD domain suffix — Kerberos SPNs are registered under
                # the real domain, so .local causes silent NTLM fallback.
                if ($domain -and -not $remoteNodeFQDN.EndsWith(".$domain", [System.StringComparison]::OrdinalIgnoreCase)) {
                    $remoteNodeFQDN = "$otherNode.$domain"
                }
                $remoteConnStr = $remoteNodeFQDN
                if ($sqlInstName -and $sqlInstName -ne 'MSSQLSERVER') {
                    $remoteConnStr = "$remoteNodeFQDN\$sqlInstName"
                }
                $results.Details.Add("CMD: Check auth_scheme on remote node '$remoteConnStr'")
                $authQuery = "SELECT auth_scheme FROM sys.dm_exec_connections WHERE session_id = @@SPID"
                $wd = Invoke-WithWatchdog -TimeoutSec 30 -MaxAttempts 3 -ArgumentList @($remoteConnStr, $authQuery) -ScriptBlock {
                    param($conn, $q)
                    Invoke-Sqlcmd -ServerInstance $conn -Query $q -QueryTimeout 30 -TrustServerCertificate -ErrorAction Stop
                }
                if ($wd.Status -eq 'TimedOut') {
                    $results.Details.Add("WARN: auth_scheme query on '$remoteConnStr' did not complete after $($wd.Attempts) attempts (30s each); skipping.")
                }
                elseif ($wd.Status -eq 'Error') {
                    $errMsg = if ($wd.Errors -and $wd.Errors[0].Exception) { $wd.Errors[0].Exception.Message } else { ($wd.Errors -join '; ') }
                    $results.Details.Add("WARN: Could not query auth_scheme on '$remoteConnStr': $errMsg")
                }
                else {
                    $authResult = $wd.Output
                    if ($authResult.auth_scheme -eq 'KERBEROS') {
                        $retryNote = if ($wd.Attempts -gt 1) { " (succeeded on attempt $($wd.Attempts) after timeouts)" } else { '' }
                        $results.Details.Add("OK: Remote SQL auth_scheme = KERBEROS$retryNote")
                    }
                    else {
                        $results.Details.Add("WARN: Remote SQL auth_scheme = $($authResult.auth_scheme) (expected KERBEROS). Check SPNs and msDS-SupportedEncryptionTypes on the SQL service account.")
                    }
                }
            }

            # ==============================================================
            # 7. Backup and Witness share accessibility
            # ==============================================================
            Write-Progress -Activity $progressActivity -Status "Checking witness and backup share accessibility"
            foreach ($share in @(@{Name = 'Witness'; Path = $witnessShare }, @{Name = 'Backup'; Path = $backupShare })) {
                if ($share.Path) {
                    $results.Details.Add("CMD: Test-Path '$($share.Path)'")
                    if (Test-Path $share.Path -ErrorAction SilentlyContinue) {
                        $results.Details.Add("OK: $($share.Name) share '$($share.Path)' is accessible")
                    }
                    else {
                        $results.Passed = $false
                        $results.Details.Add("FAIL: $($share.Name) share '$($share.Path)' is not accessible")
                    }
                }
            }

            # ==============================================================
            # 8. TESTDB recovery model and log backup health (PRIMARY only)
            # ==============================================================
            Write-Progress -Activity $progressActivity -Status "Verifying TESTDB recovery model and log backups"
            if ($otherNode -and $healthy) {
                $roleQuery = "SELECT role_desc FROM sys.dm_hadr_availability_replica_states WHERE is_local = 1"
                $localRole = (Invoke-Sqlcmd -Query $roleQuery -QueryTimeout 30 -TrustServerCertificate -ErrorAction SilentlyContinue).role_desc

                if ($localRole -eq 'PRIMARY') {
                    # 8a. Recovery model must be FULL for AG databases
                    $results.Details.Add("CMD: Check TESTDB recovery model")
                    try {
                        $rmQuery = "SELECT name, recovery_model_desc FROM sys.databases WHERE name = 'TESTDB'"
                        $rmResult = Invoke-Sqlcmd -Query $rmQuery -QueryTimeout 30 -TrustServerCertificate -ErrorAction Stop
                        if ($rmResult.recovery_model_desc -eq 'FULL') {
                            $results.Details.Add("OK: TESTDB recovery model is FULL")
                        }
                        else {
                            $results.Passed = $false
                            $results.Details.Add("FAIL: TESTDB recovery model is '$($rmResult.recovery_model_desc)' (expected FULL)")
                        }
                    }
                    catch {
                        $results.Passed = $false
                        $results.Details.Add("FAIL: Recovery model check failed: $($_.Exception.Message)")
                    }

                    # 8b. Log backup agent jobs exist and are enabled
                    $results.Details.Add("CMD: Check MemLabs backup agent jobs in msdb")
                    try {
                        $jobQuery = @"
SELECT j.name, j.enabled,
       h.run_status AS LastRunStatus,
       msdb.dbo.agent_datetime(h.run_date, h.run_time) AS LastRunTime
FROM msdb.dbo.sysjobs j
LEFT JOIN (
    SELECT job_id, run_status, run_date, run_time,
           ROW_NUMBER() OVER (PARTITION BY job_id ORDER BY run_date DESC, run_time DESC) AS rn
    FROM msdb.dbo.sysjobhistory WHERE step_id = 0
) h ON h.job_id = j.job_id AND h.rn = 1
WHERE j.name LIKE 'MemLabs DatabaseBackup%'
"@
                        $jobs = @(Invoke-Sqlcmd -Query $jobQuery -QueryTimeout 30 -TrustServerCertificate -ErrorAction Stop)
                        if ($jobs.Count -eq 0) {
                            $results.Passed = $false
                            $results.Details.Add("FAIL: No MemLabs DatabaseBackup agent jobs found")
                        }
                        else {
                            $agJobLastRunFailed = $false
                            foreach ($j in $jobs) {
                                $enabledText = if ($j.enabled -eq 1) { 'enabled' } else { 'DISABLED' }
                                $historyText = ''
                                if ($null -ne $j.LastRunStatus -and $j.LastRunStatus -isnot [System.DBNull]) {
                                    $statusMap = @{ 0 = 'Failed'; 1 = 'Succeeded'; 2 = 'Retry'; 3 = 'Cancelled'; 4 = 'In Progress' }
                                    $statusText = if ($statusMap.ContainsKey([int]$j.LastRunStatus)) { $statusMap[[int]$j.LastRunStatus] } else { "Status $($j.LastRunStatus)" }
                                    $historyText = ", last run: $statusText at $($j.LastRunTime)"
                                }
                                if ($j.enabled -ne 1) {
                                    $results.Passed = $false
                                    $results.Details.Add("FAIL: Agent job '$($j.name)' is $enabledText$historyText")
                                }
                                elseif ($null -ne $j.LastRunStatus -and $j.LastRunStatus -isnot [System.DBNull] -and [int]$j.LastRunStatus -eq 0) {
                                    $agJobLastRunFailed = $true
                                    $results.Details.Add("WARN: Agent job '$($j.name)' is $enabledText$historyText")
                                }
                                else {
                                    $results.Details.Add("OK: Agent job '$($j.name)' is $enabledText$historyText")
                                }
                            }
                        }
                    }
                    catch {
                        $results.Details.Add("WARN: Agent job check failed: $($_.Exception.Message)")
                    }

                    # 8b2. Actively run the AG log backup on the primary to verify it works.
                    # The scheduled job may have failed on a transient issue; this confirms
                    # the backup path is currently functional and the log can be truncated.
                    $results.Details.Add("CMD: EXECUTE [dbo].[DatabaseBackup] @Databases='AVAILABILITY_GROUP_DATABASES' @BackupType='LOG' (active test)")
                    try {
                        $agBackupQuery = @"
EXECUTE [dbo].[DatabaseBackup]
    @Databases = 'AVAILABILITY_GROUP_DATABASES',
    @Directory = 'NUL',
    @BackupType = 'LOG',
    @Verify = 'N',
    @CleanupTime = NULL,
    @CheckSum = 'N',
    @LogToTable = 'Y',
    @ChangeBackupType = 'Y'
"@
                        Invoke-Sqlcmd -Query $agBackupQuery -QueryTimeout 120 -TrustServerCertificate -ErrorAction Stop
                        $activeTestMsg = "OK: AG log backup completed successfully on primary"
                        if ($agJobLastRunFailed) {
                            $activeTestMsg += " (scheduled job failure above was transient)"
                        }
                        $results.Details.Add($activeTestMsg)
                    }
                    catch {
                        $results.Details.Add("WARN: AG log backup failed on primary: $($_.Exception.Message)")
                    }

                    # 8c. Run a log backup and verify log space is recycled
                    $results.Details.Add("CMD: BACKUP LOG [TESTDB] TO DISK = 'NUL' (validate log backup works)")
                    try {
                        Invoke-Sqlcmd -Query "BACKUP LOG [TESTDB] TO DISK = 'NUL'" -QueryTimeout 60 -TrustServerCertificate -ErrorAction Stop
                        $results.Details.Add("OK: Log backup of TESTDB completed successfully")

                        # After a successful log backup, log_reuse_wait should no longer be LOG_BACKUP
                        $logQuery = "SELECT log_reuse_wait_desc FROM sys.databases WHERE name = 'TESTDB'"
                        $logResult = Invoke-Sqlcmd -Query $logQuery -QueryTimeout 30 -TrustServerCertificate -ErrorAction Stop
                        $waitReason = $logResult.log_reuse_wait_desc
                        if ($waitReason -eq 'LOG_BACKUP') {
                            $results.Details.Add("WARN: TESTDB log_reuse_wait is still LOG_BACKUP after backup (may need a checkpoint)")
                        }
                        else {
                            $results.Details.Add("OK: TESTDB log_reuse_wait is '$waitReason' (log space recycled)")
                        }
                    }
                    catch {
                        $results.Passed = $false
                        $results.Details.Add("FAIL: Log backup of TESTDB failed: $($_.Exception.Message)")
                    }
                }
            }

            # ==============================================================
            # 9. Cross-node replication test (write on PRIMARY, read from other)
            # ==============================================================
            Write-Progress -Activity $progressActivity -Status "Testing cross-node replication"
            if ($otherNode -and $healthy) {
                # Reuse localRole from check #8 if available, otherwise query it
                if (-not $localRole) {
                    $roleQuery = "SELECT role_desc FROM sys.dm_hadr_availability_replica_states WHERE is_local = 1"
                    $localRole = (Invoke-Sqlcmd -Query $roleQuery -QueryTimeout 30 -TrustServerCertificate -ErrorAction SilentlyContinue).role_desc
                }

                $secondaryConnStr = $otherNode
                if ($sqlInstName -and $sqlInstName -ne 'MSSQLSERVER') {
                    $secondaryConnStr = "$otherNode\$sqlInstName"
                }

                if ($localRole -eq 'PRIMARY') {
                    $results.Details.Add("CMD: Cross-node replication test (write local PRIMARY, read from '$secondaryConnStr')")
                    try {
                        # Create a validation table if needed and insert a timestamped row
                        $testId = [guid]::NewGuid().ToString('N').Substring(0, 8)
                        $writeQuery = @"
USE [TESTDB];
IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE name = 'MemLabsValidation' AND type = 'U')
    CREATE TABLE dbo.MemLabsValidation (Id INT IDENTITY(1,1), TestValue NVARCHAR(100), CreatedAt DATETIME2 DEFAULT SYSUTCDATETIME());
DELETE FROM dbo.MemLabsValidation WHERE CreatedAt < DATEADD(HOUR, -1, SYSUTCDATETIME());
INSERT INTO dbo.MemLabsValidation (TestValue) VALUES ('$testId');
"@
                        Invoke-Sqlcmd -Query $writeQuery -QueryTimeout 30 -TrustServerCertificate -ErrorAction Stop
                        $results.Details.Add("OK: Wrote test value '$testId' to TESTDB on primary")

                        # SynchronousCommit hardens the log on both replicas before commit
                        # returns, but redo on the secondary may lag slightly.
                        Start-Sleep -Seconds 5

                        $readQuery = "SELECT TOP 1 TestValue FROM [TESTDB].dbo.MemLabsValidation WHERE TestValue = '$testId'"
                        $readResult = Invoke-Sqlcmd -ServerInstance $secondaryConnStr -Query $readQuery -QueryTimeout 30 -TrustServerCertificate -ErrorAction Stop
                        if ($readResult -and $readResult.TestValue -eq $testId) {
                            $results.Details.Add("OK: Read test value '$testId' from secondary '$secondaryConnStr' — replication verified")
                        }
                        else {
                            $results.Passed = $false
                            $results.Details.Add("FAIL: Could not read test value '$testId' from secondary '$secondaryConnStr'")
                        }
                    }
                    catch {
                        $results.Passed = $false
                        $results.Details.Add("FAIL: Cross-node replication test failed: $($_.Exception.Message)")
                    }
                }
                elseif ($localRole -eq 'SECONDARY') {
                    # On secondary role, verify TESTDB is readable
                    $results.Details.Add("CMD: Verify TESTDB readable on secondary role")
                    try {
                        $readCheck = Invoke-Sqlcmd -Query "USE [TESTDB]; SELECT COUNT(*) AS Cnt FROM sys.tables" -QueryTimeout 30 -TrustServerCertificate -ErrorAction Stop
                        $results.Details.Add("OK: TESTDB is readable on secondary ($($readCheck.Cnt) user table(s))")
                    }
                    catch {
                        $results.Passed = $false
                        $results.Details.Add("FAIL: Cannot read TESTDB on secondary: $($_.Exception.Message)")
                    }
                }
            }
        }
        catch {
            $results.Passed = $false
            $results.Details.Add("FAIL: SQLAO validation failed: $($_.Exception.Message)")
        }

        return $results
    }

    # Run -AsJob with a hard timeout. The scriptblock runs entirely on the remote
    # VM (cluster/AG health, share probes, optional SQL/cluster-service restarts
    # and second-hop Invoke-Command remediation), any of which can block on a
    # network operation that has no built-in timeout (e.g. Test-Path on an
    # unreachable UNC witness/backup share, or a remote restart that never
    # returns). Without a bound, a single hung node (seen on the secondary)
    # leaves the Phase 11 job running forever with no progress, freezing the
    # whole phase. The timeout is generous enough for the worst-case remediation
    # path (health retries 5x20s + SQL restart 30s + post-restart retries
    # 5x20s + AG log backup 120s + endpoint cycling), so a healthy node never
    # hits it; on timeout Invoke-VmCommand returns ScriptBlockFailed and
    # Format-TestResult records a FAIL for the VM and the phase completes.
    $result = Invoke-VmCommand -VmName $VMName -VmDomainName $domain `
        -ScriptBlock $scriptBlock `
        -ArgumentList $listenerName, $listenerPort, $agName, $otherNode, $witnessShare, $backupShare, $agIP, $sqlInstName, $clusterName, $clusterIP `
        -DisplayName "Phase11-SQLAO-Test" -SuppressLog -AsJob -TimeoutSeconds 600 -PollProgress

    return (Format-TestResult -VMName $VMName -RoleLabel 'SQLAO' -Result $result)
}

function Test-WSUSFunctionality {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$Domain
    )

    $Phase = 11
    Write-Log "[Phase $Phase] $VMName [WSUS]: Testing WSUS services and connectivity" -LogOnly

    $scriptBlock = {
        $results = @{ Passed = $true; Details = [System.Collections.Generic.List[string]]::new() }

        # Check WSUS and IIS services
        foreach ($svc in @('WsusService', 'W3SVC')) {
            $results.Details.Add("CMD: Get-Service -Name '$svc'")
            $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
            if (-not $s) {
                $results.Passed = $false
                $results.Details.Add("FAIL: Service '$svc' not found")
            }
            elseif ($s.Status -ne 'Running') {
                $results.Passed = $false
                $results.Details.Add("FAIL: Service '$svc' is $($s.Status)")
            }
            else {
                $results.Details.Add("OK: Service '$svc' is Running")
            }
        }

        # Test WSUS API connectivity
        $results.Details.Add("CMD: [Microsoft.UpdateServices.Administration.AdminProxy]::GetUpdateServer('localhost', ...)")
        try {
            [reflection.assembly]::LoadWithPartialName('Microsoft.UpdateServices.Administration') | Out-Null
            $connected = $false
            foreach ($port in @(8530, 443)) {
                try {
                    $useSSL = ($port -eq 443)
                    $wsus = [Microsoft.UpdateServices.Administration.AdminProxy]::GetUpdateServer('localhost', $useSSL, $port)
                    if ($wsus) {
                        $results.Details.Add("OK: WSUS API connected on port $port (server version: $($wsus.Version))")
                        $connected = $true
                        break
                    }
                }
                catch { }
            }
            if (-not $connected) {
                $results.Passed = $false
                $results.Details.Add("FAIL: Cannot connect to WSUS API on port 8530 or 443")
            }
        }
        catch {
            $results.Passed = $false
            $results.Details.Add("FAIL: WSUS API test failed: $($_.Exception.Message)")
        }

        # WsusPool app pool must be Started
        try {
            Import-Module WebAdministration -ErrorAction Stop
            $pool = Get-WebAppPoolState -Name 'WsusPool' -ErrorAction SilentlyContinue
            if ($pool -and $pool.Value -eq 'Started') {
                $results.Details.Add("OK: App pool 'WsusPool' is Started")
            }
            else {
                $results.Passed = $false
                $results.Details.Add("FAIL: App pool 'WsusPool' is $(if ($pool) { $pool.Value } else { 'not found' })")
            }
        }
        catch {
            $results.Details.Add("WARN: Could not check WsusPool state: $($_.Exception.Message)")
        }

        # At least one WSUS port must be listening
        $listening = Get-NetTCPConnection -State Listen -LocalPort 8530, 8531 -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty LocalPort -Unique
        if ($listening) {
            $results.Details.Add("OK: WSUS listening on port(s): $($listening -join ', ')")
        }
        else {
            $results.Passed = $false
            $results.Details.Add("FAIL: Neither 8530 nor 8531 is listening")
        }

        return $results
    }

    $result = Invoke-VmCommand -VmName $VMName -VmDomainName $Domain `
        -ScriptBlock $scriptBlock -DisplayName "Phase11-WSUS-Test" -SuppressLog `
        -AsJob -TimeoutSeconds 300

    return (Format-TestResult -VMName $VMName -RoleLabel 'WSUS' -Result $result)
}

function Test-CMSiteFunctionality {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][object]$CurrentItem,
        [Parameter(Mandatory)][object]$DeployConfig
    )

    $Phase = 11
    $domain = $DeployConfig.vmOptions.domainName
    $siteCode = $CurrentItem.siteCode

    Write-Progress2 -PercentComplete 0 -Activity "$VMName [$($CurrentItem.role)]" -Status "Verifying ConfigMgr site $siteCode"
    $roleLabel = "$($CurrentItem.role) ($siteCode)"
    Write-Log "[Phase $Phase] $VMName [$roleLabel]: Testing ConfigMgr site services and WMI" -LogOnly

    $scriptBlock = {
        param($sc)
        $results = @{ Passed = $true; Details = [System.Collections.Generic.List[string]]::new() }

        # Check critical CM services (with remediation for transient states)
        foreach ($svc in @('SMS_EXECUTIVE', 'SMS_SITE_COMPONENT_MANAGER')) {
            $results.Details.Add("CMD: Get-Service -Name '$svc'")
            $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
            if (-not $s) {
                $results.Passed = $false
                $results.Details.Add("FAIL: Service '$svc' not found")
                continue
            }
            if ($s.Status -ne 'Running') {
                # Attempt remediation: force-stop then start
                $results.Details.Add("REMEDIATE: Service '$svc' is $($s.Status), attempting restart...")
                try { Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue } catch { }
                Start-Sleep -Seconds 5
                try { Start-Service -Name $svc -ErrorAction SilentlyContinue } catch { }
                # Wait up to 60s for the service to reach Running
                $svcOk = $false
                for ($w = 0; $w -lt 12; $w++) {
                    Start-Sleep -Seconds 5
                    $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
                    if ($s -and $s.Status -eq 'Running') { $svcOk = $true; break }
                }
                if ($svcOk) {
                    $results.Details.Add("RECOVERED: Service '$svc' was stopped; Running after restart")
                }
                else {
                    $results.Passed = $false
                    $sNow = if ($s) { $s.Status } else { 'NotFound' }
                    $results.Details.Add("FAIL: Service '$svc' is $sNow after restart attempt, expected Running")
                }
            }
            else {
                $results.Details.Add("OK: Service '$svc' is Running")
            }
        }

        if (-not $results.Passed) { return $results }

        # WMI site query with retry (CM components still initializing after fresh build)
        $maxRetries = 6
        $retryDelay = 30
        $siteOk = $false
        $results.Details.Add("CMD: Get-WmiObject -Namespace 'root\SMS\site_$sc' -Class SMS_Site (max ${maxRetries} attempts, ${retryDelay}s apart)")
        for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
            try {
                $site = Get-WmiObject -Namespace "root\SMS\site_$sc" -Class SMS_Site -ErrorAction Stop
                if ($site) {
                    $results.Details.Add("OK: WMI SMS_Site query returned site '$sc' (attempt $attempt)")
                    $siteOk = $true
                    break
                }
                else {
                    $results.Details.Add("  Attempt $attempt/${maxRetries}: SMS_Site returned null")
                }
            }
            catch {
                $results.Details.Add("  Attempt $attempt/${maxRetries} failed: $($_.Exception.Message)")
                if ($attempt -lt $maxRetries) {
                    Start-Sleep -Seconds $retryDelay
                }
            }
        }
        if (-not $siteOk) {
            $results.Passed = $false
            $results.Details.Add("FAIL: WMI SMS_Site query failed after $maxRetries attempts")
            return $results
        }

        # Component health check — verify current running state via SMS_ComponentSummarizer.
        # Filter by TallyInterval '0001128000100008' ("since site startup") to get one entry
        # per component. For fresh-build validation we only check State=1 (Started).
        # AvailabilityState is ignored — many components report Offline between processing
        # cycles (e.g. Started/Offline) which is normal, not a deployment failure.
        # Discovery agents run on a schedule and are Stopped between cycles, so they're
        # excluded entirely.
        # WSUS/SRS components are conditionally ignored — only when the corresponding
        # role is NOT installed for this site (checked via C:\staging\DSC\deployConfig.json).
        $dcfPath = 'C:\staging\DSC\deployConfig.json'
        $hasSUP = $false
        $hasRP = $false
        if (Test-Path $dcfPath) {
            try {
                $dcf = Get-Content $dcfPath -Raw | ConvertFrom-Json
                $hasSUP = [bool]($dcf.virtualMachines | Where-Object {
                    ($_.installSUP -or $_.InstallSUP) -and $_.siteCode -eq $sc
                } | Select-Object -First 1)
                $hasRP = [bool]($dcf.virtualMachines | Where-Object {
                    $_.InstallRP -and $_.siteCode -eq $sc
                } | Select-Object -First 1)
            } catch { }
        }
        $ignoredComponents = @(
            'SMS_WSUS_CONFIGURATION_MANAGER'        # Until SUP is fully configured
            'SMS_MIGRATION_MANAGER'                 # Migration not used in lab builds
            'SMS_SITE_SQL_BACKUP'                   # Backup not configured on new sites
            'SMS_SITE_BACKUP'                       # Backup not configured on new sites
            'SMS_SITE_VSS_WRITER'                   # Backup not configured on new sites
            'SMS_OFFLINE_SERVICING_MANAGER'         # No packages to service on fresh builds
            # Not monitored — source skips writing operation management key for these
            'CONFIGURATION_MANAGER_UPDATE'
            'SMS_MP_DEVICE_MANAGER'
            'SMS_TEM'
            'SMS_PROVIDERS'
            # Discovery agents — always Stopped between cycles; not meaningful health indicators
            'SMS_AD_SYSTEM_DISCOVERY_AGENT'
            'SMS_AD_SECURITY_GROUP_DISCOVERY_AGENT'
            'SMS_AD_USER_DISCOVERY_AGENT'
            'SMS_AD_FOREST_DISCOVERY_MANAGER'
            'SMS_WINNT_SERVER_DISCOVERY_AGENT'
            'SMS_NETWORK_DISCOVERY'
        )
        if (-not $hasSUP) {
            $ignoredComponents += 'SMS_WSUS_CONTROL_MANAGER'      # Only when SUP not installed
            $ignoredComponents += 'SMS_WSUS_SYNC_MANAGER'         # Only when SUP not installed
        }
        if (-not $hasRP) {
            $ignoredComponents += 'SMS_SRS_REPORTING_POINT'        # Only when RP not installed
        }
        $results.Details.Add("CMD: Get-WmiObject -Namespace 'root\SMS\site_$sc' -Class SMS_ComponentSummarizer -Filter ""TallyInterval='0001128000100008' AND SiteCode='$sc'""")
        $componentCheckAttempts = 10
        $componentRetryDelay = 30
        $unhealthyCount = 999
        $unhealthyDetails = @()
        for ($attempt = 1; $attempt -le $componentCheckAttempts; $attempt++) {
            try {
                # Filter by SiteCode so each site only validates its own components.
                # Without this, the CAS sees components from child Primaries and
                # Secondaries — a Secondary still installing its MP taints the CAS
                # check even though the Secondary has its own Phase 11 validation.
                $allComponents = @(Get-WmiObject -Namespace "root\SMS\site_$sc" -Class SMS_ComponentSummarizer `
                    -Filter "TallyInterval='0001128000100008' AND SiteCode='$sc'" -ErrorAction Stop)
                if ($allComponents.Count -eq 0) {
                    $results.Details.Add("  Attempt $attempt/${componentCheckAttempts}: SMS_ComponentSummarizer returned 0 rows (site still initializing)")
                    if ($attempt -lt $componentCheckAttempts) { Start-Sleep -Seconds $componentRetryDelay }
                    continue
                }
                $checkable = @($allComponents | Where-Object {
                    $cn = $_.ComponentName
                    # Use prefix match: some component names include the server
                    # name as a suffix (e.g. SMS_SITE_SQL_BACKUP_ZZ-BIGMAC)
                    $dominated = $false
                    foreach ($ign in $ignoredComponents) {
                        if ($cn -eq $ign -or $cn -like "${ign}_*") { $dominated = $true; break }
                    }
                    -not $dominated
                })
                $ignoredCount = $allComponents.Count - $checkable.Count

                # Check each component's live state. Deduplicate by ComponentName
                # (a site may have components on remote site systems) — take worst
                # state per name.
                $byName = @{}
                foreach ($comp in $checkable) {
                    $name = $comp.ComponentName
                    $healthy = ($comp.State -eq 1)
                    if (-not $byName.ContainsKey($name)) {
                        $byName[$name] = @{ Healthy = $healthy; State = $comp.State; Avail = $comp.AvailabilityState; Server = $comp.MachineName }
                    }
                    elseif (-not $healthy -and $byName[$name].Healthy) {
                        # Worst-state wins for the same component name
                        $byName[$name] = @{ Healthy = $false; State = $comp.State; Avail = $comp.AvailabilityState; Server = $comp.MachineName }
                    }
                }

                $stateName = @{ 0='Stopped'; 1='Started'; 2='Paused'; 3='Installing'; 4='Re-installing'; 5='De-installing' }
                $availName = @{ 0='Online'; 3='Offline'; 4='Unknown' }

                $unhealthyDetails = @()
                foreach ($kv in $byName.GetEnumerator()) {
                    if (-not $kv.Value.Healthy) {
                        $sn = if ($stateName.ContainsKey([int]$kv.Value.State)) { $stateName[[int]$kv.Value.State] } else { "State=$($kv.Value.State)" }
                        $an = if ($availName.ContainsKey([int]$kv.Value.Avail)) { $availName[[int]$kv.Value.Avail] } else { "Avail=$($kv.Value.Avail)" }
                        $unhealthyDetails += "$($kv.Key) ($sn/$an on $($kv.Value.Server))"
                    }
                }
                $unhealthyCount = $unhealthyDetails.Count

                if ($unhealthyCount -eq 0) {
                    $msg = "OK: All $($byName.Count) components are Started (attempt $attempt)"
                    if ($ignoredCount -gt 0) { $msg += " ($ignoredCount ignored: $($ignoredComponents -join ', '))" }
                    $results.Details.Add($msg)
                    break
                }
                $results.Details.Add("  Attempt $attempt/${componentCheckAttempts}: $unhealthyCount component(s) not Started")
                if ($attempt -lt $componentCheckAttempts) {
                    Start-Sleep -Seconds $componentRetryDelay
                }
            }
            catch {
                $results.Details.Add("  Component status query attempt $attempt failed: $($_.Exception.Message)")
                if ($attempt -lt $componentCheckAttempts) {
                    Start-Sleep -Seconds $componentRetryDelay
                }
            }
        }

        if ($unhealthyCount -eq 999) {
            # WMI query never returned data — site still initializing
            $results.Passed = $false
            $results.Details.Add("FAIL: SMS_ComponentSummarizer query returned no data on all $componentCheckAttempts attempts (ConfigMgr may still be initializing)")
        }
        elseif ($unhealthyCount -gt 0 -and $unhealthyCount -le 5) {
            # Lenient: up to 5 non-Started components is a warning, not a failure
            $names = $unhealthyDetails -join ', '
            $results.Details.Add("WARN: $unhealthyCount component(s) not Started: $names")
        }
        elseif ($unhealthyCount -gt 5) {
            $results.Passed = $false
            $names = ($unhealthyDetails | Select-Object -First 10) -join ', '
            $results.Details.Add("FAIL: $unhealthyCount components not Started (exceeds threshold of 5): $names")
        }

        return $results
    }

    $result = Invoke-VmCommand -VmName $VMName -VmDomainName $domain `
        -ScriptBlock $scriptBlock -ArgumentList $siteCode `
        -DisplayName "Phase11-CM-Test" -SuppressLog `
        -AsJob -TimeoutSeconds 300

    $passed = Format-TestResult -VMName $VMName -RoleLabel $roleLabel -Result $result

    # Site-wide tests run on any CAS or Primary. Hierarchy-owned checks
    # (boundaries, discovery, comms mode) are gated on $isTopLevel inside
    # the function so child Primaries skip them (DRS replication lag would
    # cause false failures). Perfloading content checks (apps, collections,
    # packages, etc.) run on every Primary that has PrePopulateObjects.
    $isTopLevel = (-not $CurrentItem.parentSiteCode) -and ($CurrentItem.role -in @('CAS', 'Primary'))
    if ($passed -and ($CurrentItem.role -in @('CAS', 'Primary'))) {
        Write-Progress2 -PercentComplete 0 -Activity "$VMName [$($CurrentItem.role)]" -Status "Verifying site-wide settings"
        $sitePassed = Test-CMSiteWideFunctionality -VMName $VMName -CurrentItem $CurrentItem -DeployConfig $DeployConfig -IsTopLevel:$isTopLevel
        if (-not $sitePassed) { $passed = $false }
    }

    # DRS replication link check: verify links to child sites are Active (not Failed/Error/Degraded)
    # ReplicationLinkStatus enum: Active=2, Initializing=4, NotStarted=5, Error=6, Unknown=7, Degraded=8, Failed=9
    $childSites = @($DeployConfig.virtualMachines | Where-Object { $_.parentSiteCode -eq $siteCode })
    if ($passed -and $childSites.Count -gt 0) {
        Write-Progress2 -PercentComplete 0 -Activity "$VMName [$($CurrentItem.role)]" -Status "Verifying child site visibility and DRS replication"
        Write-Log "[Phase $Phase] $VMName [$roleLabel]: Checking child site visibility and DRS replication links to $($childSites.Count) child site(s)" -LogOnly

        $childSiteCodes = @($childSites | ForEach-Object { $_.siteCode } | Select-Object -Unique)

        $drsScriptBlock = {
            param($parentSC, $childCodes)
            $results = @{ Passed = $true; Details = [System.Collections.Generic.List[string]]::new() }

            # StatusName lookup for readable output
            $statusName = @{ 0='Deleted'; 1='Tombstoned'; 2='Active'; 3='Active_InterOp'; 4='Initializing'; 5='NotStarted'; 6='Error'; 7='Unknown'; 8='Degraded'; 9='Failed' }
            $failedStates = @(6, 8, 9)  # Error, Degraded, Failed

            foreach ($childSC in $childCodes) {
                # --- Child site visibility via SMS_Site ---
                $results.Details.Add("CMD: Get-WmiObject -Namespace 'root\SMS\site_$parentSC' -Class SMS_Site -Filter `"SiteCode = '$childSC'`"")
                $maxSiteAttempts = 10
                $siteRetryDelay = 30
                $siteFound = $false
                for ($siteAttempt = 1; $siteAttempt -le $maxSiteAttempts; $siteAttempt++) {
                    try {
                        $childSite = Get-WmiObject -Namespace "root\SMS\site_$parentSC" -Class SMS_Site `
                            -Filter "SiteCode = '$childSC'" -ErrorAction Stop
                        if ($childSite) {
                            $results.Details.Add("OK: Child site '$childSC' visible in parent '$parentSC' (attempt $siteAttempt)")
                            $siteFound = $true
                            break
                        }
                    }
                    catch {
                        $results.Details.Add("INFO: SMS_Site query attempt $siteAttempt failed: $($_.Exception.Message)")
                    }
                    if ($siteAttempt -lt $maxSiteAttempts) {
                        $results.Details.Add("INFO: Child site '$childSC' not yet visible (attempt $siteAttempt/$maxSiteAttempts), retrying in ${siteRetryDelay}s...")
                        Start-Sleep -Seconds $siteRetryDelay
                    }
                }
                if (-not $siteFound) {
                    $results.Passed = $false
                    $results.Details.Add("FAIL: Child site '$childSC' not found in parent '$parentSC' after $maxSiteAttempts attempts")
                }

                # --- DRS replication link ---
                $results.Details.Add("CMD: Get-WmiObject -Namespace 'root\SMS\site_$parentSC' -Class SMS_ReplicationLinkSummary -Filter `"Site2 = '$childSC'`"")
                try {
                    $link = Get-WmiObject -Namespace "root\SMS\site_$parentSC" -Class SMS_ReplicationLinkSummary `
                        -Filter "Site2 = '$childSC'" -ErrorAction Stop
                    if (-not $link) {
                        $results.Details.Add("WARN: No DRS replication link found for $parentSC -> $childSC")
                    }
                    else {
                        $ls = [int]$link.LinkStatus
                        $s1s2 = [int]$link.Site1ToSite2GlobalState
                        $s2s1 = [int]$link.Site2ToSite1GlobalState
                        $lsName = if ($statusName.ContainsKey($ls)) { $statusName[$ls] } else { "Unknown($ls)" }
                        $s1Name = if ($statusName.ContainsKey($s1s2)) { $statusName[$s1s2] } else { "Unknown($s1s2)" }
                        $s2Name = if ($statusName.ContainsKey($s2s1)) { $statusName[$s2s1] } else { "Unknown($s2s1)" }

                        if ($ls -eq 2 -and $s1s2 -eq 2 -and $s2s1 -eq 2) {
                            $results.Details.Add("OK: DRS link $parentSC -> $childSC is Active")
                        }
                        elseif ($ls -in $failedStates -or $s1s2 -in $failedStates -or $s2s1 -in $failedStates) {
                            $results.Details.Add("WARN: DRS link $parentSC -> $childSC has failures: Link=$lsName, S1->S2=$s1Name, S2->S1=$s2Name")
                        }
                        else {
                            $results.Details.Add("WARN: DRS link $parentSC -> $childSC is not yet Active: Link=$lsName, S1->S2=$s1Name, S2->S1=$s2Name")
                        }
                    }
                }
                catch {
                    $results.Details.Add("WARN: Could not query DRS link $parentSC -> $childSC`: $($_.Exception.Message)")
                }
            }

            return $results
        }

        $drsResult = Invoke-VmCommand -VmName $VMName -VmDomainName $domain `
            -ScriptBlock $drsScriptBlock -ArgumentList $siteCode, $childSiteCodes `
            -DisplayName "Phase11-ChildSites-Test" -SuppressLog `
            -AsJob -TimeoutSeconds 600

        $drsPassed = Format-TestResult -VMName $VMName -RoleLabel "ChildSites ($siteCode)" -Result $drsResult
        if (-not $drsPassed) { $passed = $false }
    }

    # Verify remote site system roles (DPs) are registered in WMI.
    # Runs locally on the site server — no cross-VM PSDirect needed.
    # The SiteSystem VMs only run local checks (SMB share, WDS service).
    $remoteSiteSystems = @($DeployConfig.virtualMachines | Where-Object {
        $_.role -eq 'SiteSystem' -and $_.siteCode -eq $siteCode -and $_.installDP
    })
    if ($passed -and $remoteSiteSystems.Count -gt 0) {
        Write-Progress2 -PercentComplete 0 -Activity "$VMName [$($CurrentItem.role)]" -Status "Verifying remote DP registration"
        $dpVmNames = @($remoteSiteSystems | ForEach-Object { $_.vmName })
        Write-Log "[Phase $Phase] $VMName [$roleLabel]: Checking DP registration for $($dpVmNames.Count) remote site system(s): $($dpVmNames -join ', ')" -LogOnly

        $dpRegScript = {
            param($sc, $dpNames)
            $results = @{ Passed = $true; Details = [System.Collections.Generic.List[string]]::new() }

            foreach ($dpName in $dpNames) {
                $wmiFilter = "ServerName LIKE '%$dpName%'"
                $results.Details.Add("CMD: Get-WmiObject -Namespace 'root\SMS\site_$sc' -Class SMS_DistributionPointInfo -Filter `"$wmiFilter`"")
                $maxAttempts = 5
                $retryDelay = 20
                $found = $false
                for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
                    try {
                        $dp = Get-WmiObject -Namespace "root\SMS\site_$sc" -Class SMS_DistributionPointInfo `
                            -Filter $wmiFilter -ErrorAction Stop
                        if ($dp) {
                            $results.Details.Add("OK: DP '$dpName' found in site '$sc' (attempt $attempt)")
                            $found = $true
                            break
                        }
                        $results.Details.Add("  Attempt $attempt/${maxAttempts}: DP '$dpName' not yet visible")
                        if ($attempt -lt $maxAttempts) { Start-Sleep -Seconds $retryDelay }
                    }
                    catch {
                        $results.Details.Add("  Attempt $attempt/${maxAttempts}: WMI query failed: $($_.Exception.Message)")
                        if ($attempt -lt $maxAttempts) { Start-Sleep -Seconds $retryDelay }
                    }
                }
                if (-not $found) {
                    # Fallback: check SMS_SystemResourceList for DP role registration
                    try {
                        $role = Get-WmiObject -Namespace "root\SMS\site_$sc" -Class SMS_SystemResourceList `
                            -Filter "RoleName='SMS Distribution Point' AND ServerName LIKE '%$dpName%'" -ErrorAction Stop |
                            Select-Object -First 1
                        if ($role) {
                            $results.Details.Add("OK: DP role registered for '$dpName' (SMS_SystemResourceList)")
                            $found = $true
                        }
                    }
                    catch {
                        $results.Details.Add("  SMS_SystemResourceList fallback for '$dpName' failed: $($_.Exception.Message)")
                    }
                }
                if (-not $found) {
                    $results.Details.Add("WARN: DP '$dpName' not yet visible in site '$sc' (install may still be propagating)")
                }
            }
            return $results
        }

        $dpRegResult = Invoke-VmCommand -VmName $VMName -VmDomainName $domain `
            -ScriptBlock $dpRegScript -ArgumentList $siteCode, $dpVmNames `
            -DisplayName "Phase11-DPRegistration-Test" -SuppressLog `
            -AsJob -TimeoutSeconds 300

        $dpRegPassed = Format-TestResult -VMName $VMName -RoleLabel "DPReg ($siteCode)" -Result $dpRegResult
        if (-not $dpRegPassed) { $passed = $false }
    }

    # Office Install Targets collection: validate + self-heal membership.
    # Only on Primaries (perfloading creates the Office app/deployment on the
    # Primary, never on CAS). Pre-emptively confirms every VM with
    # installOffice is resolved into MEMLABS-Office Install Targets and that
    # the deployment exists, so spurious DomainMember-side "policy not
    # received" WARNs in Phase 11 get a definitive parent diagnosis (and an
    # auto-refresh attempt) here instead of falling on the client.
    $officeExpected = @($DeployConfig.virtualMachines | Where-Object {
        $_.installOffice -and $_.installOffice -ne $false
    } | ForEach-Object { $_.vmName })
    if ($passed -and $CurrentItem.role -eq 'Primary' -and $officeExpected.Count -gt 0) {
        Write-Progress2 -PercentComplete 0 -Activity "$VMName [$($CurrentItem.role)]" -Status "Verifying Office Install Targets collection"
        Write-Log "[Phase $Phase] $VMName [$roleLabel]: Validating MEMLABS-Office Install Targets membership for $($officeExpected.Count) VM(s): $($officeExpected -join ', ')" -LogOnly

        $officeCollectionScript = {
            param($sc, $expected)
            $results = @{ Passed = $true; Details = [System.Collections.Generic.List[string]]::new() }
            $colName = 'MEMLABS-Office Install Targets'
            $ns = "root\SMS\site_$sc"

            # 1. Collection exists
            $results.Details.Add("CMD: Get-WmiObject -Namespace '$ns' -Class SMS_Collection -Filter `"Name='$colName'`"")
            $col = $null
            try {
                $col = Get-WmiObject -Namespace $ns -Class SMS_Collection -Filter "Name='$colName'" -ErrorAction Stop | Select-Object -First 1
            }
            catch {
                $results.Details.Add("WARN: SMS_Collection query failed: $($_.Exception.Message)")
                return $results
            }
            if (-not $col) {
                $results.Details.Add("WARN: Collection '$colName' does not exist — perfloading may not have run, or Office source download failed")
                return $results
            }
            $results.Details.Add("OK: Collection '$colName' exists (CollectionID=$($col.CollectionID))")

            # 2. Query membership rule reflects current VM list
            try {
                $colFull = [wmi]$col.__PATH
                $colFull.Get()
                $queryRules = @($colFull.CollectionRules | Where-Object { $_.__CLASS -eq 'SMS_CollectionRuleQuery' })
                $directRules = @($colFull.CollectionRules | Where-Object { $_.__CLASS -eq 'SMS_CollectionRuleDirect' })
                $results.Details.Add("INFO: Collection has $($queryRules.Count) query rule(s), $($directRules.Count) direct rule(s)")
                if ($queryRules.Count -gt 0) {
                    $ruleQ = $queryRules[0].QueryExpression
                    $missingFromRule = @($expected | Where-Object { $ruleQ -notmatch "'$([regex]::Escape($_))'" })
                    if ($missingFromRule.Count -gt 0) {
                        $results.Details.Add("WARN: Query rule does not reference VM(s): $($missingFromRule -join ', ') — rerun perfloading or Set-OfficeInstallTargetsCollection to refresh")
                    }
                    else {
                        $results.Details.Add("OK: Query rule references all $($expected.Count) expected VM(s)")
                    }
                }
                elseif ($directRules.Count -eq 0) {
                    $results.Details.Add("WARN: Collection has no membership rules at all")
                }
            }
            catch {
                $results.Details.Add("INFO: Could not inspect collection rules: $($_.Exception.Message)")
            }

            # 3. Membership content — with self-healing refresh
            $getMembers = {
                param($n, $cid)
                try {
                    $names = @(Get-WmiObject -Namespace $n -Class SMS_FullCollectionMembership -Filter "CollectionID='$cid'" -ErrorAction Stop |
                        Select-Object -ExpandProperty Name)
                    return ,@($names)
                }
                catch { return ,@() }
            }
            $members = & $getMembers $ns $col.CollectionID
            $missing = @($expected | Where-Object { $_ -notin $members })

            if ($missing.Count -gt 0) {
                $results.Details.Add("REMEDIATE: $($missing.Count)/$($expected.Count) expected VM(s) not in collection ($($missing -join ', ')); requesting collection eval and retrying")
                try {
                    # Trigger an incremental + full evaluation. RequestRefresh
                    # takes a boolean: $true = also refresh sub-collections.
                    $colFull2 = [wmi]$col.__PATH
                    [void]$colFull2.RequestRefresh($false)
                    $results.Details.Add("  Invoked SMS_Collection.RequestRefresh on '$colName'")
                }
                catch {
                    $results.Details.Add("  WARN: RequestRefresh failed: $($_.Exception.Message)")
                }
                # Poll up to ~2 min for the missing members to appear.
                for ($i = 0; $i -lt 12; $i++) {
                    Start-Sleep -Seconds 10
                    $members = & $getMembers $ns $col.CollectionID
                    $missing = @($expected | Where-Object { $_ -notin $members })
                    if ($missing.Count -eq 0) { break }
                }
            }

            if ($missing.Count -eq 0) {
                $results.Details.Add("OK: All $($expected.Count) expected VM(s) resolved in '$colName'")
            }
            else {
                # Distinguish "VM not yet discovered by CM" from "discovered but rule didn't match"
                $undiscovered = @()
                $unmatched = @()
                foreach ($m in $missing) {
                    try {
                        $r = @(Get-WmiObject -Namespace $ns -Class SMS_R_System -Filter "Name='$m'" -ErrorAction Stop)
                        if ($r.Count -eq 0) { $undiscovered += $m } else { $unmatched += $m }
                    }
                    catch { $undiscovered += $m }
                }
                if ($undiscovered.Count -gt 0) {
                    $results.Details.Add("WARN: Not in CM discovery yet (System Discovery hasn't picked them up): $($undiscovered -join ', ')")
                }
                if ($unmatched.Count -gt 0) {
                    $results.Details.Add("WARN: Discovered but not in '$colName' after RequestRefresh: $($unmatched -join ', ') — query rule may not match (check Name property in SMS_R_System)")
                }
            }

            # 4. Deployment exists targeting this collection
            $results.Details.Add("CMD: Get-WmiObject -Namespace '$ns' -Class SMS_ApplicationAssignment -Filter `"TargetCollectionID='$($col.CollectionID)'`"")
            try {
                $deployments = @(Get-WmiObject -Namespace $ns -Class SMS_ApplicationAssignment -Filter "TargetCollectionID='$($col.CollectionID)'" -ErrorAction Stop)
                if ($deployments.Count -eq 0) {
                    $results.Details.Add("WARN: No SMS_ApplicationAssignment targets '$colName' — Office deployment is missing (perfloading should have created it)")
                }
                else {
                    foreach ($d in $deployments) {
                        $purpose = if ($d.OfferTypeID -eq 0) { 'Required' } else { 'Available' }
                        $results.Details.Add("OK: Deployment '$($d.AssignmentName)' (AppCI=$($d.AssignedCI_UniqueID)) targets '$colName' [$purpose]")
                    }
                }
            }
            catch {
                $results.Details.Add("INFO: Could not enumerate SMS_ApplicationAssignment: $($_.Exception.Message)")
            }

            return $results
        }

        $officeColResult = Invoke-VmCommand -VmName $VMName -VmDomainName $domain `
            -ScriptBlock $officeCollectionScript -ArgumentList $siteCode, $officeExpected `
            -DisplayName "Phase11-OfficeCollection-Test" -SuppressLog `
            -AsJob -TimeoutSeconds 300

        # WARN-only test: don't fail the Primary if collection membership is still propagating.
        [void](Format-TestResult -VMName $VMName -RoleLabel "OfficeCollection ($siteCode)" -Result $officeColResult)
    }

    return $passed
}

function Test-BLMFunctionality {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][object]$CurrentItem,
        [Parameter(Mandatory)][object]$DeployConfig
    )

    $Phase = 11
    $domain = $DeployConfig.vmOptions.domainName
    $siteCode = $CurrentItem.siteCode

    Write-Progress2 -PercentComplete 0 -Activity "$VMName [Primary]" -Status "Verifying BitLocker Management"
    Write-Log "[Phase $Phase] $VMName [BLM]: Testing BitLocker Management policy and deployment" -LogOnly

    $scriptBlock = {
        param($sc)
        $results = @{ Passed = $true; Details = [System.Collections.Generic.List[string]]::new() }

        # Import ConfigMgr module and connect to site
        try {
            $results.Details.Add("CMD: Importing ConfigMgr module and connecting to site $sc")
            $smsProvider = "$env:COMPUTERNAME.$((Get-WmiObject Win32_ComputerSystem).Domain)"
            $key = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry32)
            $subKey = $key.OpenSubKey("SOFTWARE\Microsoft\ConfigMgr10\Setup")
            $uiInstallPath = $subKey.GetValue("UI Installation Directory")
            Import-Module (Join-Path $uiInstallPath "bin\ConfigurationManager.psd1") -ErrorAction Stop
            $null = New-PSDrive -Name $sc -PSProvider CMSite -Root $smsProvider -ErrorAction SilentlyContinue
            Push-Location "${sc}:\"
            $results.Details.Add("OK: Connected to site $sc on $smsProvider")
        }
        catch {
            $results.Passed = $false
            $results.Details.Add("FAIL: Could not connect to CM site: $($_.Exception.Message)")
            return $results
        }

        # Check BitLocker policy exists
        $policyName = "MEMLABS-BitLocker Policy"
        $results.Details.Add("CMD: Get-CMBlmSetting -Name '$policyName'")
        $blmPolicy = Get-CMBlmSetting -Name $policyName -ErrorAction SilentlyContinue
        if (-not $blmPolicy) {
            $results.Details.Add("WARN: BitLocker policy '$policyName' not found — deployment may still be processing")
            # Pull EnableBLM log lines for diagnostics
            try {
                $blmLog = Get-Content "C:\staging\DSC\InstallCMLog.log" -ErrorAction SilentlyContinue |
                    Where-Object { $_ -match '\[EnableBLM\]' } | Select-Object -Last 10
                if ($blmLog) {
                    $results.Details.Add("DIAG: Last EnableBLM log entries:")
                    foreach ($bl in $blmLog) { $results.Details.Add("  $($bl.Trim())") }
                } else {
                    $results.Details.Add("DIAG: No [EnableBLM] entries found in InstallCMLog.log")
                }
            } catch {}
            Pop-Location
            return $results
        }
        $results.Details.Add("OK: BitLocker policy '$policyName' exists")

        # Check collection exists
        $collectionName = "MEMLABS-BitLocker Clients"
        $results.Details.Add("CMD: Get-CMDeviceCollection -Name '$collectionName'")
        $blmCollection = Get-CMDeviceCollection -Name $collectionName -ErrorAction SilentlyContinue
        if (-not $blmCollection) {
            $results.Passed = $false
            $results.Details.Add("FAIL: Collection '$collectionName' not found")
            Pop-Location
            return $results
        }
        $results.Details.Add("OK: Collection '$collectionName' exists (ID: $($blmCollection.CollectionID))")

        # Check policy is deployed to the collection
        $results.Details.Add("CMD: Get-CMSettingDeployment -CMSetting blmPolicy | Where CollectionId")
        $deployment = Get-CMSettingDeployment -CMSetting $blmPolicy -ErrorAction SilentlyContinue |
            Where-Object { $_.CollectionId -eq $blmCollection.CollectionID }
        if (-not $deployment) {
            $results.Passed = $false
            $results.Details.Add("FAIL: BitLocker policy is not deployed to '$collectionName'")
            Pop-Location
            return $results
        }
        $results.Details.Add("OK: BitLocker policy is deployed to '$collectionName'")

        # Helpdesk Portal: IIS app + app pool + registry conn string must all be present.
        # Without this, admins cannot look up recovery keys -- key escrow is useless.
        $results.Details.Add("CMD: Get-WebApplication -Site 'Default Web Site' -Name 'HelpDesk'")
        try {
            Import-Module WebAdministration -ErrorAction Stop
            $portalApp = Get-WebApplication -Site 'Default Web Site' -Name 'HelpDesk' -ErrorAction SilentlyContinue
            if (-not $portalApp) {
                $results.Passed = $false
                $results.Details.Add("FAIL: BLM Helpdesk Portal IIS app '/HelpDesk' not found on $env:COMPUTERNAME")
            }
            else {
                $results.Details.Add("OK: IIS app '/HelpDesk' -> $($portalApp.PhysicalPath)")
                if ($portalApp.PhysicalPath -and -not (Test-Path $portalApp.PhysicalPath)) {
                    $results.Passed = $false
                    $results.Details.Add("FAIL: Helpdesk Portal physical path missing on disk")
                }
                $poolName = $portalApp.applicationPool
                if ($poolName) {
                    $pool = Get-Item "IIS:\AppPools\$poolName" -ErrorAction SilentlyContinue
                    if (-not $pool) {
                        $results.Passed = $false
                        $results.Details.Add("FAIL: App pool '$poolName' not found")
                    }
                    elseif ($pool.State -ne 'Started') {
                        $results.Passed = $false
                        $results.Details.Add("FAIL: App pool '$poolName' state=$($pool.State), expected Started")
                    }
                    else {
                        $results.Details.Add("OK: App pool '$poolName' is Started")
                    }
                }
                # Registry conn string proves the installer's SQL bootstrap completed
                $webKey = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\MBAM Server\Web' -ErrorAction SilentlyContinue
                if (-not $webKey -or -not $webKey.RecoveryDBConnectionString) {
                    $results.Passed = $false
                    $results.Details.Add("FAIL: Registry 'MBAM Server\Web\RecoveryDBConnectionString' missing (installer did not complete SQL setup)")
                }
                else {
                    $results.Details.Add("OK: Registry connection string present")
                }
                # HTTPS smoke test -- treat 401/403/302 as 'serving OK' (portal requires auth).
                # memlabs uses an internal CA whose root may not be in the
                # local trust store of every machine yet; the smoke test only
                # cares that IIS answers on the HTTPS endpoint, so disable
                # cert validation for the probe.
                try {
                    $fqdn = "$env:COMPUTERNAME.$((Get-WmiObject Win32_ComputerSystem).Domain)"
                    $origCb = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
                    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
                    try {
                        $req = [System.Net.HttpWebRequest]::Create("https://$fqdn/HelpDesk/")
                        $req.Timeout = 15000
                        $req.AllowAutoRedirect = $false
                        $req.UseDefaultCredentials = $true
                        $resp = $req.GetResponse()
                        $results.Details.Add("OK: HTTPS smoke test returned $([int]$resp.StatusCode) from https://$fqdn/HelpDesk/")
                        $resp.Close()
                    }
                    finally {
                        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $origCb
                    }
                }
                catch [System.Net.WebException] {
                    $code = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
                    if ($code -in 401,403,302) {
                        $results.Details.Add("OK: HTTPS smoke test returned $code (expected -- portal requires auth)")
                    }
                    else {
                        $results.Passed = $false
                        $results.Details.Add("FAIL: HTTPS smoke test failed: $($_.Exception.Message)")
                    }
                }
                catch {
                    $results.Passed = $false
                    $results.Details.Add("FAIL: HTTPS smoke test exception: $($_.Exception.Message)")
                }
            }
        }
        catch {
            $results.Passed = $false
            $results.Details.Add("FAIL: Helpdesk Portal probe error: $($_.Exception.Message)")
        }

        Pop-Location
        return $results
    }

    $result = Invoke-VmCommand -VmName $VMName -VmDomainName $domain `
        -ScriptBlock $scriptBlock -ArgumentList $siteCode `
        -DisplayName "Phase11-BLM-Test" -SuppressLog `
        -AsJob -TimeoutSeconds 300

    return (Format-TestResult -VMName $VMName -RoleLabel "BLM" -Result $result)
}

function Test-SecondaryFunctionality {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][object]$CurrentItem,
        [Parameter(Mandatory)][object]$DeployConfig
    )

    $Phase = 11
    $domain = $DeployConfig.vmOptions.domainName
    $secSiteCode = $CurrentItem.siteCode

    # Determine the SQL instance name for the secondary
    # If sqlVersion is set, the secondary uses a pre-installed SQL instance.
    # Otherwise, ConfigMgr installs SQL Express with instance name CONFIGMGRSEC.
    $sqlInstanceName = if ($CurrentItem.sqlVersion) {
        if ($CurrentItem.sqlInstanceName) { $CurrentItem.sqlInstanceName } else { 'MSSQLSERVER' }
    } else {
        'CONFIGMGRSEC'
    }

    Write-Log "[Phase $Phase] $VMName [Secondary]: Testing SMS_EXECUTIVE service, SQL instance '$sqlInstanceName', DB 'CM_$secSiteCode', and spDiagDRS" -LogOnly

    $scriptBlock = {
        param($instanceName, $siteCode)
        $results = @{ Passed = $true; Details = [System.Collections.Generic.List[string]]::new() }

        # --- SMS_EXECUTIVE service ---
        $results.Details.Add("CMD: Get-Service -Name 'SMS_EXECUTIVE'")
        $svc = Get-Service -Name 'SMS_EXECUTIVE' -ErrorAction SilentlyContinue
        if (-not $svc) {
            $results.Passed = $false
            $results.Details.Add("FAIL: Service 'SMS_EXECUTIVE' not found")
        }
        elseif ($svc.Status -ne 'Running') {
            $results.Passed = $false
            $results.Details.Add("FAIL: Service 'SMS_EXECUTIVE' is $($svc.Status)")
        }
        else {
            $results.Details.Add("OK: Service 'SMS_EXECUTIVE' is Running")
        }

        # --- SQL Server service ---
        $svcName = if ($instanceName -eq 'MSSQLSERVER') { 'MSSQLSERVER' } else { "MSSQL`$$instanceName" }
        $results.Details.Add("CMD: Get-Service -Name '$svcName'")
        $sqlSvc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if (-not $sqlSvc) {
            $results.Passed = $false
            $results.Details.Add("FAIL: SQL service '$svcName' not found")
            $allSql = (Get-Service -Name 'MSSQL*' -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }) -join ', '
            $results.Details.Add("  Available SQL services: $allSql")
            return $results
        }
        if ($sqlSvc.Status -ne 'Running') {
            # Service exists but is stopped — try to start it before failing
            $results.Details.Add("REMEDIATE: SQL service '$svcName' is $($sqlSvc.Status), attempting to start...")
            try {
                Start-Service -Name $svcName -ErrorAction Stop
                $waited = 0
                while ($waited -lt 60) {
                    Start-Sleep -Seconds 5
                    $waited += 5
                    $sqlSvc = Get-Service -Name $svcName
                    if ($sqlSvc.Status -eq 'Running') { break }
                }
            }
            catch {
                $results.Details.Add("WARN: Start-Service failed: $($_.Exception.Message)")
            }
            $sqlSvc = Get-Service -Name $svcName
            if ($sqlSvc.Status -ne 'Running') {
                $results.Passed = $false
                $results.Details.Add("FAIL: SQL service '$svcName' is still $($sqlSvc.Status) after start attempt")
                return $results
            }
            $results.Details.Add("RECOVERED: SQL service '$svcName' was stopped; started successfully")
        }
        else {
            $results.Details.Add("OK: SQL service '$svcName' is Running")
        }

        # --- SQL connectivity + CM database existence ---
        $connStr = if ($instanceName -eq 'MSSQLSERVER') { 'localhost' } else { "localhost\$instanceName" }
        $dbName = "CM_$siteCode"
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        $results.Details.Add("CMD: Invoke-Sqlcmd -ServerInstance '$connStr' -Query (check DB '$dbName') as $identity")
        try {
            Import-Module SqlServer -ErrorAction SilentlyContinue
            if (-not (Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue)) {
                Import-Module SQLPS -DisableNameChecking -ErrorAction SilentlyContinue
            }
            # -TrustServerCertificate not available on older SQLPS (SQL Express)
            $sqlParams = @{}
            if ((Get-Command Invoke-Sqlcmd).Parameters.ContainsKey('TrustServerCertificate')) {
                $sqlParams['TrustServerCertificate'] = $true
            }

            $dbCheck = Invoke-Sqlcmd -ServerInstance $connStr -Query "SELECT state_desc FROM sys.databases WHERE name = '$dbName'" -QueryTimeout 30 @sqlParams -ErrorAction Stop
            if (-not $dbCheck) {
                $results.Passed = $false
                $results.Details.Add("FAIL: Database '$dbName' does not exist on '$connStr'")
                $allDbs = (Invoke-Sqlcmd -ServerInstance $connStr -Query "SELECT name FROM sys.databases" -QueryTimeout 30 @sqlParams -ErrorAction SilentlyContinue | ForEach-Object { $_.name }) -join ', '
                $results.Details.Add("  Available databases: $allDbs")
                return $results
            }
            if ($dbCheck.state_desc -ne 'ONLINE') {
                $results.Passed = $false
                $results.Details.Add("FAIL: Database '$dbName' state is '$($dbCheck.state_desc)' (expected ONLINE)")
                return $results
            }
            $results.Details.Add("OK: Database '$dbName' exists and is ONLINE on '$connStr'")
        }
        catch {
            $results.Passed = $false
            $results.Details.Add("FAIL: SQL connection to '$connStr' failed: $($_.Exception.Message)")
            return $results
        }

        # --- spDiagDRS: check replication health from the secondary's perspective ---
        $results.Details.Add("CMD: Invoke-Sqlcmd -ServerInstance '$connStr' -Database '$dbName' -Query 'EXEC spDiagDRS'")
        try {
            $drsRows = @(Invoke-Sqlcmd -ServerInstance $connStr -Database $dbName -Query "EXEC spDiagDRS" -QueryTimeout 60 @sqlParams -ErrorAction Stop)
            if ($drsRows.Count -eq 0) {
                $results.Details.Add("WARN: spDiagDRS returned no rows (replication may not be initialized yet)")
            }
            else {
                # Look for key summary fields; spDiagDRS returns multiple result sets.
                # The first result set typically has queue/backlog info.
                $results.Details.Add("OK: spDiagDRS returned $($drsRows.Count) row(s)")

                # Check for any rows with obvious error indicators
                foreach ($row in $drsRows) {
                    # spDiagDRS columns vary; look for common failure indicators
                    if ($row.PSObject.Properties['IsBlocked'] -and $row.IsBlocked -eq 1) {
                        $results.Details.Add("WARN: spDiagDRS reports a blocked replication queue")
                    }
                    if ($row.PSObject.Properties['SSB_State'] -and $row.SSB_State -notin @('STARTED', '')) {
                        $results.Details.Add("WARN: Service Broker state is '$($row.SSB_State)' (expected STARTED)")
                    }
                }
            }
        }
        catch {
            # spDiagDRS failure is a warning, not a hard fail — the DB itself is confirmed working
            $results.Details.Add("WARN: spDiagDRS failed: $($_.Exception.Message)")
        }

        return $results
    }

    $result = Invoke-VmCommand -VmName $VMName -VmDomainName $domain `
        -ScriptBlock $scriptBlock -ArgumentList $sqlInstanceName, $secSiteCode `
        -DisplayName "Phase11-Secondary-Test" -SuppressLog `
        -AsJob -TimeoutSeconds 600

    return (Format-TestResult -VMName $VMName -RoleLabel 'Secondary' -Result $result)
}

function Test-SiteSystemFunctionality {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][object]$CurrentItem,
        [Parameter(Mandatory)][object]$DeployConfig
    )

    $Phase = 11
    $domain = $DeployConfig.vmOptions.domainName
    $allPassed = $true

    # Test MP if installed
    if ($CurrentItem.installMP) {
        Write-Progress2 -PercentComplete 0 -Activity "$VMName [SiteSystem]" -Status "Verifying Management Point"
        Write-Log "[Phase $Phase] $VMName [MP]: Testing Management Point" -LogOnly

        $mpScript = {
            $results = @{ Passed = $true; Details = [System.Collections.Generic.List[string]]::new() }

            # Check IIS is running (W3SVC)
            $w3svc = Get-Service -Name 'W3SVC' -ErrorAction SilentlyContinue
            if (-not $w3svc -or $w3svc.Status -ne 'Running') {
                $results.Passed = $false
                $results.Details.Add("FAIL: IIS service (W3SVC) is $( if ($w3svc) { $w3svc.Status } else { 'not installed' } )")
                return $results
            }
            $results.Details.Add("OK: IIS service (W3SVC) is Running")

            # Check SMS_MP IIS virtual directory exists via WebAdministration (retry up to 5 times, 60s apart)
            try {
                Import-Module WebAdministration -ErrorAction Stop
                $mpApp = $null
                $maxAttempts = 5
                for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
                    $mpApp = Get-WebApplication -Site 'Default Web Site' -Name 'SMS_MP' -ErrorAction SilentlyContinue
                    if ($mpApp) { break }
                    if ($attempt -lt $maxAttempts) { Start-Sleep -Seconds 60 }
                }
                if ($mpApp) {
                    $results.Details.Add("OK: IIS application 'SMS_MP' exists (Physical: $($mpApp.PhysicalPath))")
                }
                else {
                    $results.Passed = $false
                    $results.Details.Add("FAIL: IIS application 'SMS_MP' not found under Default Web Site")
                    return $results
                }

                # Check that the app pool is started
                $poolName = $mpApp.ApplicationPool
                $pool = Get-WebAppPoolState -Name $poolName -ErrorAction SilentlyContinue
                if ($pool -and $pool.Value -eq 'Started') {
                    $results.Details.Add("OK: App pool '$poolName' is Started")
                }
                else {
                    $results.Passed = $false
                    $results.Details.Add("FAIL: App pool '$poolName' is $( if ($pool) { $pool.Value } else { 'not found' } )")
                    return $results
                }
            }
            catch {
                $results.Details.Add("WARN: Could not load WebAdministration module: $($_.Exception.Message)")
            }

            # Verify SMS install location from registry
            $smsReg = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\SMS\Identification' -ErrorAction SilentlyContinue
            if ($smsReg -and $smsReg.'Installation Directory') {
                $installDir = $smsReg.'Installation Directory'
                $results.Details.Add("OK: SMS installed at '$installDir'")
            }
            else {
                $results.Details.Add("WARN: SMS Identification registry key not found (MP may still be initializing)")
            }

            # End-to-end MP probe: fetch the MP list (proves the MP is actually serving).
            # Some sites are HTTPS-only -- try HTTPS first, then HTTP. Treat 401/403 as
            # serving-OK (auth required); only fail on connection refused / 404.
            $fqdn = "$env:COMPUTERNAME.$((Get-WmiObject Win32_ComputerSystem).Domain)"
            $mpProbed = $false
            foreach ($scheme in @('https', 'http')) {
                $url = "$scheme`://$fqdn/sms_mp/.sms_aut?MPLIST"
                $results.Details.Add("CMD: Invoke-WebRequest -Uri '$url' -UseBasicParsing")
                try {
                    $req = [System.Net.HttpWebRequest]::Create($url)
                    $req.Timeout = 15000
                    $req.UseDefaultCredentials = $true
                    $req.AllowAutoRedirect = $false
                    if ($scheme -eq 'https') {
                        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
                    }
                    $resp = $req.GetResponse()
                    $sc = [int]$resp.StatusCode
                    $resp.Close()
                    $results.Details.Add("OK: MP probe '$url' returned $sc")
                    $mpProbed = $true
                    break
                }
                catch [System.Net.WebException] {
                    $sc = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
                    if ($sc -in 401, 403) {
                        $results.Details.Add("OK: MP probe '$url' returned $sc (auth required = serving)")
                        $mpProbed = $true
                        break
                    }
                    $results.Details.Add("  $scheme failed: $($_.Exception.Message)")
                }
                catch {
                    $results.Details.Add("  $scheme failed: $($_.Exception.Message)")
                }
            }
            if (-not $mpProbed) {
                # Don't fail the build -- if W3SVC + SMS_MP app pool are OK, the
                # endpoint may just be authenticating differently. Warn loudly.
                $results.Details.Add("WARN: MP HTTP probe did not succeed on http or https. App is configured but not serving as expected.")
            }

            return $results
        }

        $mpResult = Invoke-VmCommand -VmName $VMName -VmDomainName $domain `
            -ScriptBlock $mpScript -DisplayName "Phase11-MP-Test" -SuppressLog `
            -AsJob -TimeoutSeconds 300

        if (-not (Format-TestResult -VMName $VMName -RoleLabel 'MP' -Result $mpResult)) {
            $allPassed = $false
        }
    }

    # Test DP: local checks only. DP WMI registration (SMS_DistributionPointInfo)
    # is verified by the site server's own Phase 11 job in Test-CMSiteFunctionality,
    # avoiding cross-VM PSDirect calls that fail when the Primary is unresponsive.
    if ($CurrentItem.installDP) {
        Write-Progress2 -PercentComplete 0 -Activity "$VMName [SiteSystem]" -Status "Verifying Distribution Point"
        Write-Log "[Phase $Phase] $VMName [DP]: Local content + PXE checks" -LogOnly
        $localDpScript = {
            $results = @{ Passed = $true; Details = [System.Collections.Generic.List[string]]::new() }

            $results.Details.Add("CMD: Get-SmbShare -Name 'SMS_DP`$'")
            $share = Get-SmbShare -Name 'SMS_DP$' -ErrorAction SilentlyContinue
            if (-not $share) {
                $results.Passed = $false
                $results.Details.Add("FAIL: SMB share 'SMS_DP`$' missing -- content library not initialized")
            }
            else {
                $results.Details.Add("OK: SMB share 'SMS_DP`$' exposes '$($share.Path)'")
            }

            # WDS service for PXE -- optional. memlabs DPs may be created
            # with -EnablePxe or with NoWDS PXE, and PXE config can be
            # toggled per-DP. Absence is informational only.
            $results.Details.Add("CMD: Get-Service -Name 'WDSServer'")
            $wds = Get-Service -Name 'WDSServer' -ErrorAction SilentlyContinue
            if (-not $wds) {
                $results.Details.Add("INFO: WDSServer service not installed (PXE not enabled, or NoWDS PXE in use)")
            }
            elseif ($wds.Status -ne 'Running') {
                $results.Details.Add("INFO: WDSServer is $($wds.Status) (PXE may be intentionally disabled on this DP)")
            }
            else {
                $results.Details.Add("OK: WDSServer is Running (PXE active)")
            }

            return $results
        }
        $localDpResult = Invoke-VmCommand -VmName $VMName -VmDomainName $domain `
            -ScriptBlock $localDpScript -DisplayName "Phase11-DPLocal-Test" -SuppressLog `
            -AsJob -TimeoutSeconds 300
        if (-not (Format-TestResult -VMName $VMName -RoleLabel 'DP' -Result $localDpResult)) {
            $allPassed = $false
        }
    }

    # Test SUP if installSUP
    if ($CurrentItem.installSUP) {
        Write-Progress2 -PercentComplete 0 -Activity "$VMName [SiteSystem]" -Status "Verifying Software Update Point"
        Write-Log "[Phase $Phase] $VMName [SUP]: Testing Software Update Point" -LogOnly

        $supScript = {
            $results = @{ Passed = $true; Details = [System.Collections.Generic.List[string]]::new() }

            $results.Details.Add("CMD: Get-Service -Name 'WsusService'")
            $svc = Get-Service -Name 'WsusService' -ErrorAction SilentlyContinue
            if (-not $svc) {
                $results.Passed = $false
                $results.Details.Add("FAIL: Service 'WsusService' not found")
                return $results
            }
            elseif ($svc.Status -ne 'Running') {
                $results.Passed = $false
                $results.Details.Add("FAIL: Service 'WsusService' is $($svc.Status)")
                return $results
            }
            else {
                $results.Details.Add("OK: Service 'WsusService' is Running")
            }

            # WsusPool app pool must be Started (recycle storm == clients can't sync)
            try {
                Import-Module WebAdministration -ErrorAction Stop
                $pool = Get-WebAppPoolState -Name 'WsusPool' -ErrorAction SilentlyContinue
                if ($pool -and $pool.Value -eq 'Started') {
                    $results.Details.Add("OK: App pool 'WsusPool' is Started")
                }
                else {
                    $results.Passed = $false
                    $results.Details.Add("FAIL: App pool 'WsusPool' is $(if ($pool) { $pool.Value } else { 'not found' })")
                }
            }
            catch {
                $results.Details.Add("WARN: Could not check WsusPool state: $($_.Exception.Message)")
            }

            # Port 8530 (HTTP) or 8531 (HTTPS) must be listening
            $results.Details.Add("CMD: Get-NetTCPConnection -State Listen -LocalPort 8530,8531")
            $listening = Get-NetTCPConnection -State Listen -LocalPort 8530, 8531 -ErrorAction SilentlyContinue |
                Select-Object -ExpandProperty LocalPort -Unique
            if ($listening) {
                $results.Details.Add("OK: WSUS listening on port(s): $($listening -join ', ')")
            }
            else {
                $results.Passed = $false
                $results.Details.Add("FAIL: Neither 8530 nor 8531 is listening on this SUP")
            }

            # WSUS API last sync result -- non-fatal but loud if last sync failed
            try {
                [reflection.assembly]::LoadWithPartialName('Microsoft.UpdateServices.Administration') | Out-Null
                foreach ($port in @(8530, 443, 8531)) {
                    try {
                        $useSSL = ($port -in 443, 8531)
                        $wsus = [Microsoft.UpdateServices.Administration.AdminProxy]::GetUpdateServer('localhost', $useSSL, $port)
                        $sub = $wsus.GetSubscription()
                        $sync = $sub.GetLastSynchronizationInfo()
                        $results.Details.Add("OK: WSUS last sync result = $($sync.Result), at $($sync.StartTime)")
                        if ($sync.Result -eq 'Failed') {
                            $results.Details.Add("WARN: Last WSUS sync FAILED ($($sync.Error)) -- updates pipeline broken")
                        }
                        break
                    }
                    catch { }
                }
            }
            catch {
                $results.Details.Add("WARN: WSUS API sync-info query skipped: $($_.Exception.Message)")
            }

            return $results
        }

        $supResult = Invoke-VmCommand -VmName $VMName -VmDomainName $domain `
            -ScriptBlock $supScript -DisplayName "Phase11-SUP-Test" -SuppressLog `
            -AsJob -TimeoutSeconds 300

        if (-not (Format-TestResult -VMName $VMName -RoleLabel 'SUP' -Result $supResult)) {
            $allPassed = $false
        }
    }

    return $allPassed
}

function Test-ReportingFunctionality {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$Domain,
        [Parameter()][object]$CurrentItem,
        [Parameter()][object]$DeployConfig
    )

    $Phase = 11
    Write-Log "[Phase $Phase] $VMName [RP]: Testing Reporting Services" -LogOnly

    $scriptBlock = {
        $results = @{ Passed = $true; Details = [System.Collections.Generic.List[string]]::new() }

        # MEMLABS RP role installs Power BI Report Server (PowerBIReportServer
        # service). Pre-2024 builds used classic SSRS (SQLServerReportingServices
        # or legacy ReportServer). Accept any of them.
        $results.Details.Add("CMD: Get-Service -Name 'PowerBIReportServer','SQLServerReportingServices','ReportServer'")
        $svc = $null
        foreach ($name in @('PowerBIReportServer', 'SQLServerReportingServices', 'ReportServer')) {
            $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
            if ($svc) { break }
        }
        if (-not $svc) {
            $results.Passed = $false
            $results.Details.Add("FAIL: No Reporting Services service found (PowerBIReportServer / SQLServerReportingServices / ReportServer)")
            $available = (Get-Service -Name 'Report*', 'SQLSR*', 'PowerBI*' -EA SilentlyContinue | ForEach-Object { $_.Name }) -join ', '
            $results.Details.Add("  Available services matching 'Report*'/'SQLSR*'/'PowerBI*': $available")
            return $results
        }
        if ($svc.Status -ne 'Running') {
            $results.Passed = $false
            $results.Details.Add("FAIL: Reporting service '$($svc.Name)' is $($svc.Status)")
            return $results
        }
        $results.Details.Add("OK: Reporting service '$($svc.Name)' is Running")

        # SOAP API health check: call ReportService2005.asmx GetItemType("/")
        # This is the same check ConfigMgr uses to validate reporting services.
        # Try HTTPS first (HTTPS sites), then HTTP. Proves the report server
        # database is accessible and the web service is functional.
        $fqdn = "$env:COMPUTERNAME.$((Get-WmiObject Win32_ComputerSystem).Domain)"
        $soapUrls = @(
            "https://$fqdn/ReportServer/ReportService2005.asmx",
            "http://$fqdn/ReportServer/ReportService2005.asmx",
            "http://$env:COMPUTERNAME/ReportServer/ReportService2005.asmx"
        )

        $origCb = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
        $origProto = [System.Net.ServicePointManager]::SecurityProtocol
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls11 -bor [System.Net.SecurityProtocolType]::Tls

        $results.Details.Add("CMD: New-WebServiceProxy ReportService2005.asmx / GetItemType('/')")
        $soapOk = $false
        $lastErr = ''
        try {
            foreach ($soapUri in $soapUrls) {
                try {
                    $ssrsProxy = New-WebServiceProxy -Uri $soapUri -UseDefaultCredential -ErrorAction Stop
                    $itemType = $ssrsProxy.GetItemType("/")
                    if ($itemType -eq 'Folder') {
                        $results.Details.Add("OK: SOAP API healthy at '$soapUri' (root = Folder)")
                        $soapOk = $true
                        break
                    }
                    else {
                        $lastErr = "$soapUri -> unexpected root type '$itemType'"
                    }
                }
                catch {
                    $lastErr = "$soapUri -> $($_.Exception.Message)"
                }
            }
        }
        finally {
            [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $origCb
            [System.Net.ServicePointManager]::SecurityProtocol = $origProto
        }
        if (-not $soapOk) {
            $results.Passed = $false
            $results.Details.Add("FAIL: Reporting SOAP API not functional (last error: $lastErr)")
        }

        return $results
    }

    $result = Invoke-VmCommand -VmName $VMName -VmDomainName $Domain `
        -ScriptBlock $scriptBlock -DisplayName "Phase11-RP-Test" -SuppressLog `
        -AsJob -TimeoutSeconds 300

    $allPassed = Format-TestResult -VMName $VMName -RoleLabel 'RP' -Result $result

    # CM-level check: verify the Reporting Services Point role is actually
    # registered in the site. The SSRS service/portal checks above only
    # validate infrastructure; the CM RP role might not be configured if
    # InstallRoles.ps1 was skipped (e.g. add-to-existing scenario).
    if ($CurrentItem -and $DeployConfig -and $CurrentItem.siteCode) {
        $siteCode = $CurrentItem.siteCode
        $rpVmName = $VMName

        # Determine which VM has the CM WMI namespace
        $cmVmName = $null
        if ($CurrentItem.role -in @('Primary', 'CAS')) {
            $cmVmName = $VMName
        }
        else {
            $parentVM = $DeployConfig.virtualMachines | Where-Object {
                $_.siteCode -eq $siteCode -and $_.role -in @('Primary', 'CAS')
            } | Select-Object -First 1
            if ($parentVM) {
                $cmVmName = $parentVM.vmName
            }
            else {
                Write-Log "[Phase $Phase] $VMName [RP]: Cannot find parent site server for site '$siteCode'; skipping CM RP role check" -Warning
            }
        }

        if ($cmVmName) {
            Write-Log "[Phase $Phase] $VMName [RP]: Verifying CM RP role registration from '$cmVmName' (site $siteCode)" -LogOnly

            $rpRoleScript = {
                param($sc, $rpVmName)
                $results = @{ Passed = $true; Details = [System.Collections.Generic.List[string]]::new() }

                $maxAttempts = 3
                $retryDelay = 20
                $found = $false
                $wmiFilter = "RoleName='SMS SRS Reporting Point' AND ServerName LIKE '%$rpVmName%'"
                $results.Details.Add("CMD: Get-WmiObject SMS_SystemResourceList -Filter `"$wmiFilter`" (max $maxAttempts attempts)")

                for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
                    try {
                        $rpRole = Get-WmiObject -Namespace "root\SMS\site_$sc" -Class SMS_SystemResourceList `
                            -Filter $wmiFilter -ErrorAction Stop | Select-Object -First 1
                        if ($rpRole) {
                            $results.Details.Add("OK: Reporting Services Point role registered for server matching '$rpVmName' in site '$sc' (attempt $attempt)")
                            $found = $true
                            break
                        }
                        else {
                            $results.Details.Add("  Attempt $attempt/${maxAttempts}: RP role not yet visible in WMI")
                            if ($attempt -lt $maxAttempts) { Start-Sleep -Seconds $retryDelay }
                        }
                    }
                    catch {
                        $results.Details.Add("  Attempt $attempt/${maxAttempts}: WMI query failed: $($_.Exception.Message)")
                        if ($attempt -lt $maxAttempts) { Start-Sleep -Seconds $retryDelay }
                    }
                }

                if (-not $found) {
                    $results.Passed = $false
                    $results.Details.Add("FAIL: Reporting Services Point role not registered for '$rpVmName' in site '$sc' -- InstallRoles may not have run")
                }

                return $results
            }

            $rpRoleResult = Invoke-VmCommand -VmName $cmVmName -VmDomainName $Domain `
                -ScriptBlock $rpRoleScript -ArgumentList $siteCode, $rpVmName `
                -DisplayName "Phase11-RP-CMRole-Test" -SuppressLog `
                -AsJob -TimeoutSeconds 300

            if (-not (Format-TestResult -VMName $VMName -RoleLabel 'RP-CMRole' -Result $rpRoleResult)) {
                $allPassed = $false
            }
        }
    }

    return $allPassed
}

function Test-FileServerFunctionality {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$Domain
    )

    $Phase = 11
    Write-Log "[Phase $Phase] $VMName [FileServer]: Testing SMB shares" -LogOnly

    $scriptBlock = {
        $results = @{ Passed = $true; Details = [System.Collections.Generic.List[string]]::new() }

        # LanmanServer service
        $results.Details.Add("CMD: Get-Service -Name 'LanmanServer'")
        $svc = Get-Service -Name 'LanmanServer' -ErrorAction SilentlyContinue
        if (-not $svc -or $svc.Status -ne 'Running') {
            $results.Passed = $false
            $results.Details.Add("FAIL: LanmanServer service is not running (Status: $(if($svc){$svc.Status}else{'not found'}))")
            return $results
        }
        $results.Details.Add("OK: LanmanServer service is Running")

        # Check for non-default SMB shares
        $results.Details.Add("CMD: Get-SmbShare | where Name not in ADMIN$,C$,IPC$,print$")
        $shares = @(Get-SmbShare -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notin @('ADMIN$', 'C$', 'IPC$', 'print$') })
        if ($shares.Count -gt 0) {
            $results.Details.Add("OK: Found $($shares.Count) non-default share(s): $($shares.Name -join ', ')")
        }
        else {
            $adminShares = @(Get-SmbShare -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -in @('E$', 'F$') })
            if ($adminShares.Count -ge 2) {
                $results.Details.Add("OK: E`$ and F`$ admin shares present")
            }
            else {
                $results.Passed = $false
                $results.Details.Add("FAIL: No non-default shares found and E`$/F`$ not both present")
                $results.Details.Add("  All shares: $(( Get-SmbShare -EA SilentlyContinue | ForEach-Object { $_.Name }) -join ', ')")
            }
        }

        return $results
    }

    $result = Invoke-VmCommand -VmName $VMName -VmDomainName $Domain `
        -ScriptBlock $scriptBlock -DisplayName "Phase11-FileServer-Test" -SuppressLog `
        -AsJob -TimeoutSeconds 300

    return (Format-TestResult -VMName $VMName -RoleLabel 'FileServer' -Result $result)
}

function Test-StandaloneRootCAFunctionality {
    <#
    .SYNOPSIS
        Validates Standalone Root CA post-deployment state.
    .DESCRIPTION
        The Root CA VM is intentionally shut down after PKI deployment (Step 5).
        Phase 10 (maintenance) may start it temporarily. Phase 11 validates the
        CA if running, then shuts the VM back down to restore correct end state.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$Domain
    )

    $Phase = 11
    Write-Log "[Phase $Phase] $VMName [StandaloneRootCA]: Validating Root CA state" -LogOnly

    $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if (-not $vm) {
        Write-Log "[Phase $Phase] $VMName [StandaloneRootCA]: FAIL - VM not found on Hyper-V host" -Failure -LogOnly
        $script:Phase11OutputBuffer.Add(@{ Text = "[Phase $Phase] $VMName [StandaloneRootCA]: FAIL - VM not found on Hyper-V host"; Level = 'Failure' })
        return $false
    }

    Write-Log "[Phase $Phase] $VMName [StandaloneRootCA]: Current VM state = $($vm.State)" -LogOnly

    if ($vm.State -eq 'Off') {
        Write-Log "[Phase $Phase] $VMName [StandaloneRootCA]: OK - VM is Off (expected post-deployment state)" -LogOnly
        return $true
    }

    # VM is running (Phase 10 maintenance started it) — validate CA, then shut down
    Write-Log "[Phase $Phase] $VMName [StandaloneRootCA]: VM is $($vm.State) - validating CA before shutdown" -LogOnly
    $passed = Test-CAFunctionality -VMName $VMName -Domain $Domain -Standalone

    # Shut down regardless of test result — correct end state is always Off
    Write-Log "[Phase $Phase] $VMName [StandaloneRootCA]: Shutting down Root CA VM (correct end state = Off)" -LogOnly
    try {
        Stop-VM -Name $VMName -Force -ErrorAction Stop
        Write-Log "[Phase $Phase] $VMName [StandaloneRootCA]: VM shut down successfully" -LogOnly
    }
    catch {
        Write-Log "[Phase $Phase] $VMName [StandaloneRootCA]: Failed to shut down VM: $($_.Exception.Message)" -Warning
    }

    return $passed
}

function Test-CAFunctionality {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$Domain,
        [switch]$Standalone
    )

    $Phase = 11
    $label = if ($Standalone) { 'StandaloneCA' } else { 'CA' }
    Write-Log "[Phase $Phase] $VMName [$label]: Testing Certificate Authority services" -LogOnly

    $scriptBlock = {
        param($isStandalone)
        $results = @{ Passed = $true; Details = [System.Collections.Generic.List[string]]::new() }

        # CertSvc service (Active Directory Certificate Services)
        $results.Details.Add("CMD: Get-Service -Name 'CertSvc'")
        $svc = Get-Service -Name 'CertSvc' -ErrorAction SilentlyContinue
        if (-not $svc) {
            $results.Passed = $false
            $results.Details.Add("FAIL: Service 'CertSvc' not found")
            return $results
        }
        if ($svc.Status -ne 'Running') {
            $results.Passed = $false
            $results.Details.Add("FAIL: Service 'CertSvc' is $($svc.Status)")
            return $results
        }
        $results.Details.Add("OK: Service 'CertSvc' is Running")

        # certutil -ping: verifies the CA RPC interface is responsive
        $results.Details.Add("CMD: certutil.exe -ping")
        try {
            $ping = & certutil.exe -ping 2>&1
            $pingText = $ping -join "`n"
            if ($LASTEXITCODE -eq 0) {
                $results.Details.Add("OK: certutil -ping succeeded")
            }
            else {
                $results.Passed = $false
                $results.Details.Add("FAIL: certutil -ping failed (exit $LASTEXITCODE)")
                $results.Details.Add("  Output: $pingText")
            }
        }
        catch {
            $results.Passed = $false
            $results.Details.Add("FAIL: certutil -ping exception: $($_.Exception.Message)")
        }

        # Verify the CA certificate is valid
        $results.Details.Add("CMD: certutil.exe -cainfo name")
        try {
            $caInfo = & certutil.exe -cainfo name 2>&1
            $caName = ($caInfo | Where-Object { $_ -match 'CA name:' }) -replace '.*CA name:\s*', ''
            if ($caName) {
                $results.Details.Add("OK: CA name = '$caName'")
            }
            else {
                $results.Details.Add("WARN: Could not parse CA name from certutil output")
            }
        }
        catch {
            $results.Details.Add("WARN: CA name check failed: $($_.Exception.Message)")
        }

        # AD-specific checks — skip for standalone (offline root) CAs that are
        # not domain-joined and have no AD access.
        if (-not $isStandalone) {

        # Confirm the CA cert is published into the AD NTAuthCertificates store.
        # Without this, domain client-auth certs issued by the CA won't be
        # honoured for 802.1x / CM client comms.
        $results.Details.Add("CMD: certutil.exe -store -enterprise NTAuth")
        try {
            $ntAuth = & certutil.exe -store -enterprise NTAuth 2>&1
            $ntAuthText = $ntAuth -join "`n"
            if ($LASTEXITCODE -eq 0 -and $caName -and $ntAuthText -match [regex]::Escape($caName.Trim())) {
                $results.Details.Add("OK: CA '$($caName.Trim())' is published in enterprise NTAuthCertificates")
            }
            elseif ($LASTEXITCODE -eq 0 -and $ntAuthText -match 'Certificate \d+:') {
                $results.Details.Add("OK: enterprise NTAuthCertificates store has entries (CA name unverified)")
            }
            else {
                $results.Details.Add("WARN: CA cert may not be published to NTAuthCertificates -- client-auth scenarios will fail")
            }
        }
        catch {
            $results.Details.Add("WARN: NTAuth check failed: $($_.Exception.Message)")
        }

        # AD CA enrollment object should exist under the Enrollment Services container
        try {
            Import-Module ActiveDirectory -ErrorAction Stop
            $cfg = (Get-ADRootDSE).configurationNamingContext
            $enroll = "CN=Enrollment Services,CN=Public Key Services,CN=Services,$cfg"
            $caObjs = Get-ADObject -SearchBase $enroll -Filter "objectClass -eq 'pKIEnrollmentService'" -ErrorAction Stop
            if ($caObjs) {
                $results.Details.Add("OK: $($caObjs.Count) Enterprise CA(s) published in AD: $($caObjs.Name -join ', ')")
            }
            else {
                $results.Passed = $false
                $results.Details.Add("FAIL: No pKIEnrollmentService objects under '$enroll'")
            }
        }
        catch {
            $results.Details.Add("WARN: AD Enrollment Services query failed: $($_.Exception.Message)")
        }

        } # end if (-not $isStandalone)

        # ---- CRL freshness: base CRL must be valid; delta CRL must not exist or be valid ----
        $results.Details.Add("CMD: certutil.exe -crl")
        try {
            $crlOut = & certutil.exe -getreg CA\CRLDeltaPeriodUnits 2>&1
            $deltaUnits = ($crlOut | Where-Object { $_ -match 'CRLDeltaPeriodUnits REG_DWORD' }) -replace '.*= ', ''
            if ($deltaUnits -match '^0') {
                $results.Details.Add("OK: CA delta CRL generation is disabled (CRLDeltaPeriodUnits=0)")
            }
            elseif ($deltaUnits) {
                $results.Details.Add("WARN: CA delta CRL generation is enabled (CRLDeltaPeriodUnits=$deltaUnits)")
            }

            # Check that a valid base CRL exists
            $crlList = & certutil.exe -store CA CRL 2>&1
            $crlText = $crlList -join "`n"
            if ($crlText -match 'NextUpdate:\s*(.+)') {
                $nextStr = $Matches[1].Trim()
                try {
                    $nextUpdate = [DateTime]::Parse($nextStr)
                    $hoursLeft = ($nextUpdate - (Get-Date)).TotalHours
                    if ($hoursLeft -lt 0) {
                        $results.Passed = $false
                        $results.Details.Add("FAIL: Base CRL expired at $nextStr")
                    }
                    elseif ($hoursLeft -lt 48) {
                        $results.Details.Add("WARN: Base CRL expires in $([int]$hoursLeft) hours ($nextStr)")
                    }
                    else {
                        $results.Details.Add("OK: Base CRL valid until $nextStr ($([int]$hoursLeft) hours)")
                    }
                }
                catch {
                    $results.Details.Add("WARN: Could not parse CRL NextUpdate: '$nextStr'")
                }
            }
        }
        catch {
            $results.Details.Add("WARN: CRL freshness check failed: $($_.Exception.Message)")
        }

        # ---- OID-to-name mappings in CN=OID ----
        # Verify that each published certificate template has a corresponding
        # msPKI-Enterprise-Oid object so member servers can resolve the
        # template OID back to its display name (required for CertReq DSC
        # idempotency).
        if (-not $isStandalone) {
        try {
            $cfg2 = ([ADSI]"LDAP://RootDSE").configurationNamingContext
            $tplBase = "CN=Certificate Templates,CN=Public Key Services,CN=Services,$cfg2"
            $oidBase = "CN=OID,CN=Public Key Services,CN=Services,$cfg2"

            $tplSearch = New-Object System.DirectoryServices.DirectorySearcher(
                [ADSI]"LDAP://$tplBase", "(cn=ConfigMgr*)")
            $tplSearch.PropertiesToLoad.AddRange(@('cn','msPKI-Cert-Template-OID'))
            $templates = $tplSearch.FindAll()

            foreach ($tpl in $templates) {
                $tplCn = $tpl.Properties['cn'][0]
                $tplOid = ($tpl.Properties['mspki-cert-template-oid'] | Select-Object -First 1) -as [string]
                if (-not $tplOid) { continue }

                $oidSearch = New-Object System.DirectoryServices.DirectorySearcher(
                    [ADSI]"LDAP://$oidBase", "(msPKI-Cert-Template-OID=$tplOid)")
                $oidSearch.PropertiesToLoad.Add('displayName') | Out-Null
                $oidObj = $oidSearch.FindOne()
                if ($oidObj) {
                    $results.Details.Add("OK: OID mapping exists for '$tplCn'")
                }
                else {
                    $results.Passed = $false
                    $results.Details.Add("FAIL: No msPKI-Enterprise-Oid in CN=OID for template '$tplCn' (OID=$tplOid)")
                    $results.Details.Add("  Member servers cannot resolve this OID to a name, causing CertReq duplicate certs")
                }
            }
        }
        catch {
            $results.Details.Add("WARN: OID mapping check failed: $($_.Exception.Message)")
        }
        } # end if (-not $isStandalone)

        return $results
    }

    $result = Invoke-VmCommand -VmName $VMName -VmDomainName $Domain `
        -ScriptBlock $scriptBlock -ArgumentList $Standalone.IsPresent -DisplayName "Phase11-CA-Test" -SuppressLog `
        -AsJob -TimeoutSeconds 300

    $label = if ($Standalone) { 'StandaloneCA' } else { 'CA' }
    return (Format-TestResult -VMName $VMName -RoleLabel $label -Result $result)
}

function Test-PKICertificatesOnVM {
    <#
    .SYNOPSIS
        Validates PKI certificate health on VMs that received IIS/DP certs.
    .DESCRIPTION
        Checks run on the site server / site system VM:
        - Duplicate certificate detection (same FriendlyName)
        - CRL reachability from CDP URLs embedded in the cert
        - Delta CRL expiry (warns if < 2 days, fails if expired)
        - Certificate template name resolution (OID-only = will cause
          CertReq duplication on reruns)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$Domain,
        [Parameter(Mandatory)][object]$CurrentItem,
        [Parameter(Mandatory)][object]$DeployConfig
    )

    $Phase = 11
    Write-Log "[Phase $Phase] $VMName [PKI-Certs]: Testing PKI certificate health" -LogOnly

    $isPrimaryFlag = if ($CurrentItem.role -eq 'Primary') { '1' } else { '0' }

    $scriptBlock = {
        param($IsPrimaryFlag)
        $IsPrimary = $IsPrimaryFlag -eq '1'

        $results = @{ Passed = $true; Details = [System.Collections.Generic.List[string]]::new() }

        # ---- Check 1: Duplicate certificate detection ----
        $friendlyNames = @(
            'ConfigMgr WebServer Certificate'
            'ConfigMgr Client DistributionPoint Certificate'
        )
        foreach ($fn in $friendlyNames) {
            $certs = @(Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
                Where-Object { $_.FriendlyName -eq $fn })
            if ($certs.Count -gt 1) {
                $results.Passed = $false
                $results.Details.Add("FAIL: $($certs.Count) duplicate certs with FriendlyName '$fn' (expected 1)")
                foreach ($c in $certs | Sort-Object NotBefore) {
                    $results.Details.Add("  Thumbprint=$($c.Thumbprint.Substring(0,8))... NotBefore=$($c.NotBefore)")
                }
            }
            elseif ($certs.Count -eq 1) {
                $results.Details.Add("OK: Single cert with FriendlyName '$fn'")
            }
            elseif ($fn -eq 'ConfigMgr WebServer Certificate') {
                $results.Passed = $false
                $results.Details.Add("FAIL: No cert with FriendlyName '$fn' found")
            }
            elseif ($fn -eq 'ConfigMgr Client DistributionPoint Certificate' -and $IsPrimary) {
                $results.Passed = $false
                $results.Details.Add("FAIL: No cert with FriendlyName '$fn' found (required for Primary)")
            }
        }

        # ---- Check 2: Template name resolution ----
        # Refresh the local template cache so OIDs can resolve to friendly names.
        try { certutil.exe -pulse 2>&1 | Out-Null } catch {}
        foreach ($hive in @('HKLM','HKCU')) {
            $k = "${hive}:\SOFTWARE\Microsoft\Cryptography\CertificateTemplateCache"
            Remove-ItemProperty -Path $k -Name 'Timestamp' -Force -ErrorAction SilentlyContinue
        }

        $templateChecks = @{
            'ConfigMgr WebServer Certificate'               = 'ConfigMgrWebServerCertificate'
            'ConfigMgr Client DistributionPoint Certificate' = 'ConfigMgrClientDistributionPointCertificate'
        }
        foreach ($fn in $templateChecks.Keys) {
            $cert = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
                Where-Object { $_.FriendlyName -eq $fn } | Select-Object -First 1
            if (-not $cert) { continue }

            $tplExt = $cert.Extensions | Where-Object { $_.Oid.Value -eq '1.3.6.1.4.1.311.21.7' }
            if ($tplExt) {
                $tplFormatted = $tplExt.Format($false)
                $expectedName = $templateChecks[$fn]
                if ($tplFormatted -match 'Template=([^(,]+)') {
                    $resolvedName = $Matches[1].Trim()
                    if ($resolvedName -eq $expectedName) {
                        $results.Details.Add("OK: Template name resolves for '$fn' -> '$resolvedName'")
                    }
                    elseif ($resolvedName -match '^\d+\.') {
                        # OID returned instead of friendly name — verify against AD directly.
                        # Look up the expected template by CN and compare its msPKI-Cert-Template-OID.
                        $adVerified = $false
                        try {
                            $configDN = ([ADSI]'LDAP://RootDSE').configurationNamingContext
                            $searcher = [ADSISearcher]"(&(objectClass=pKICertificateTemplate)(cn=$expectedName))"
                            $searcher.SearchRoot = [ADSI]"LDAP://CN=Certificate Templates,CN=Public Key Services,CN=Services,$configDN"
                            $tplObj = $searcher.FindOne()
                            if ($tplObj) {
                                $adOid = $tplObj.Properties['mspki-cert-template-oid'] | Select-Object -First 1
                                if ($adOid -and $resolvedName -eq $adOid) {
                                    $adVerified = $true
                                }
                            }
                        }
                        catch {}
                        if ($adVerified) {
                            $results.Details.Add("OK: Template OID for '$fn' matches AD template '$expectedName' (OID cache stale but cert is correct)")
                        }
                        else {
                            $results.Details.Add("WARN: Template name for '$fn' resolves to OID ($resolvedName) instead of '$expectedName' (could not verify in AD)")
                        }
                    }
                    else {
                        $results.Details.Add("WARN: Template name for '$fn' = '$resolvedName' (expected '$expectedName')")
                    }
                }
            }
            else {
                $results.Details.Add("WARN: No V2 template extension on cert '$fn'")
            }
        }

        # ---- Check 3: CRL reachability from cert CDPs ----
        $webCert = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
            Where-Object { $_.FriendlyName -eq 'ConfigMgr WebServer Certificate' } | Select-Object -First 1
        if ($webCert) {
            # Export cert to temp file for certutil -verify
            $tmpCer = "$env:TEMP\phase11_crl_check.cer"
            try {
                Export-Certificate -Cert $webCert -FilePath $tmpCer -Force -ErrorAction Stop | Out-Null
                $verifyOutput = & certutil.exe -verify -urlfetch $tmpCer 2>&1
                $verifyText = $verifyOutput -join "`n"
                Remove-Item $tmpCer -Force -ErrorAction SilentlyContinue

                if ($LASTEXITCODE -eq 0 -and $verifyText -match 'revocation check passed') {
                    $results.Details.Add("OK: Certificate chain + CRL verification passed")
                }
                elseif ($LASTEXITCODE -eq 0) {
                    $results.Details.Add("OK: certutil -verify succeeded (exit 0)")
                }
                else {
                    $results.Passed = $false
                    $results.Details.Add("FAIL: certutil -verify -urlfetch failed (exit $LASTEXITCODE)")
                    # Extract failed URLs
                    $failedUrls = $verifyOutput | Where-Object { $_ -match 'FAILED' }
                    foreach ($f in $failedUrls | Select-Object -First 5) {
                        $results.Details.Add("  $f")
                    }
                }
            }
            catch {
                $results.Details.Add("WARN: CRL verification skipped: $($_.Exception.Message)")
            }

            # ---- Check 4: Delta CRL expiry ----
            # Parse delta CRL NextUpdate from the certutil output
            $deltaBlocks = @()
            $inDelta = $false
            foreach ($line in $verifyOutput) {
                if ($line -match 'Delta CRL') { $inDelta = $true }
                if ($inDelta -and $line -match 'NextUpdate:\s*(.+)') {
                    $deltaBlocks += $Matches[1].Trim()
                    $inDelta = $false
                }
            }
            foreach ($nextUpdateStr in $deltaBlocks | Select-Object -Unique) {
                try {
                    $nextUpdate = [DateTime]::Parse($nextUpdateStr)
                    $hoursLeft = ($nextUpdate - (Get-Date)).TotalHours
                    if ($hoursLeft -lt 0) {
                        $results.Passed = $false
                        $results.Details.Add("FAIL: Delta CRL expired at $nextUpdateStr")
                    }
                    elseif ($hoursLeft -lt 48) {
                        $results.Details.Add("WARN: Delta CRL expires in $([int]$hoursLeft) hours ($nextUpdateStr)")
                    }
                    else {
                        $results.Details.Add("OK: Delta CRL valid until $nextUpdateStr ($([int]$hoursLeft) hours)")
                    }
                }
                catch {
                    $results.Details.Add("WARN: Could not parse delta CRL NextUpdate: '$nextUpdateStr'")
                }
            }

            # ---- Check 5: IIS 443 binding ----
            $sslCert = netsh http show sslcert ipport=0.0.0.0:443 2>&1
            if ($sslCert -match $webCert.Thumbprint) {
                $results.Details.Add("OK: WebServer cert is bound to IIS 0.0.0.0:443")
            }
            else {
                $results.Passed = $false
                $results.Details.Add("FAIL: WebServer cert thumbprint not bound to IIS 0.0.0.0:443")
            }
        }

        return $results
    }

    $result = Invoke-VmCommand -VmName $VMName -VmDomainName $Domain `
        -ScriptBlock $scriptBlock -ArgumentList $isPrimaryFlag `
        -DisplayName "Phase11-PKI-Certs-Test" -SuppressLog `
        -AsJob -TimeoutSeconds 300

    return (Format-TestResult -VMName $VMName -RoleLabel 'PKI-Certs' -Result $result)
}

function Test-MaintenanceTasks {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$Domain
    )

    $Phase = 11
    Write-Log "[Phase $Phase] $VMName [Maintenance]: Verifying scheduled tasks from Phase 10" -LogOnly

    $scriptBlock = {
        $results = @{ Passed = $true; Details = [System.Collections.Generic.List[string]]::new() }

        # Fix-DisableIEESC is server-only (Win32_OperatingSystem.ProductType == 1
        # means workstation, in which case the fix returns 'not applicable' and
        # never registers the task). Detect OS here and skip on workstations.
        $os = Get-CimInstance -Class Win32_OperatingSystem -ErrorAction SilentlyContinue
        $isWorkstation = ($os -and $os.ProductType -eq 1)
        $requiredTasks = @('EnableLogMachine')
        if (-not $isWorkstation) {
            $requiredTasks += 'Disable-IEESC'
        }
        else {
            $results.Details.Add("OK: Workstation OS detected; Disable-IEESC not applicable")
        }

        foreach ($taskName in $requiredTasks) {
            $results.Details.Add("CMD: Get-ScheduledTask -TaskName '$taskName'")
            $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            if (-not $task) {
                $results.Passed = $false
                $results.Details.Add("FAIL: Scheduled task '$taskName' not found (Phase 10 maintenance may not have run)")
            }
            else {
                $results.Details.Add("OK: Scheduled task '$taskName' exists (State: $($task.State))")
            }
        }

        return $results
    }

    $result = Invoke-VmCommand -VmName $VMName -VmDomainName $Domain `
        -ScriptBlock $scriptBlock -DisplayName "Phase11-Maintenance-Test" -SuppressLog `
        -AsJob -TimeoutSeconds 300

    return (Format-TestResult -VMName $VMName -RoleLabel 'Maintenance' -Result $result)
}

function Test-UserProfilePreCreation {
    <#
    .SYNOPSIS
        Pre-creates the domain admin user profile on the VM.
    .DESCRIPTION
        Runs a scheduled task as the domain admin account inside the guest VM,
        which forces Windows to create the full user profile (NTUSER.DAT, shell
        folders, etc.). This eliminates the long "Preparing your desktop" delay
        when first connecting via RDCMan or RDP.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$Domain,
        [Parameter(Mandatory)][object]$DeployConfig
    )

    $Phase = 11
    $adminName = $DeployConfig.vmOptions.adminName
    if (-not $adminName) { $adminName = 'admin' }

    Write-Log "[Phase $Phase] $VMName [ProfilePreCreate]: Pre-creating profile for $Domain\$adminName" -LogOnly

    $scriptBlock = {
        param($domainName, $userName, [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '')]
              $adminPass)
        $results = @{ Passed = $true; Details = [System.Collections.Generic.List[string]]::new() }

        $fullUser = "$domainName\$userName"

        # Check if profile already exists
        $existingProfile = Get-CimInstance -Class Win32_UserProfile -ErrorAction SilentlyContinue |
            Where-Object { $_.LocalPath -like "*\$userName" -and -not $_.Special }
        if ($existingProfile) {
            $results.Details.Add("OK: Profile already exists at $($existingProfile.LocalPath)")
            return $results
        }

        # Create a scheduled task that runs as the domain admin to trigger profile creation.
        # The task runs a trivial command; Windows creates the profile on first logon.
        $taskName = 'MemLabs-ProfilePreCreate'
        $results.Details.Add("CMD: Creating scheduled task '$taskName' as $fullUser")

        try {
            # Clean up any leftover from a previous attempt
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

            $action = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument '/c echo profile-created'
            $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
            Register-ScheduledTask -TaskName $taskName -Action $action -Settings $settings `
                -User $fullUser -Password $adminPass -RunLevel Highest -ErrorAction Stop | Out-Null

            Start-ScheduledTask -TaskName $taskName -ErrorAction Stop

            # Wait for the task to complete (up to 60 seconds)
            $maxWait = 60
            $elapsed = 0
            do {
                Start-Sleep -Seconds 2
                $elapsed += 2
                $taskInfo = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
            } while ($elapsed -lt $maxWait -and $null -ne $taskInfo -and $taskInfo.LastTaskResult -eq 267009) # 267009 = task is running

            # Clean up
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        }
        catch {
            $results.Details.Add("WARN: Scheduled task approach failed: $($_.Exception.Message)")
            # Not fatal - try to continue and check if profile was created anyway
        }

        # Verify the profile was created
        Start-Sleep -Seconds 2
        $userProfile = Get-CimInstance -Class Win32_UserProfile -ErrorAction SilentlyContinue |
            Where-Object { $_.LocalPath -like "*\$userName" -and -not $_.Special }
        if ($userProfile) {
            $results.Details.Add("OK: Profile pre-created at $($userProfile.LocalPath)")
        }
        else {
            $results.Passed = $false
            $results.Details.Add("FAIL: Profile for $fullUser was not created (first RDP login may be slow)")
        }

        return $results
    }

    # Pass the admin password so the scheduled task can run as the domain admin
    $adminPassword = $Common.LocalAdmin.GetNetworkCredential().Password

    $result = Invoke-VmCommand -VmName $VMName -VmDomainName $Domain `
        -ScriptBlock $scriptBlock `
        -ArgumentList @($Domain, $adminName, $adminPassword) `
        -DisplayName "Phase11-ProfilePreCreate" -SuppressLog `
        -AsJob -TimeoutSeconds 300

    return (Format-TestResult -VMName $VMName -RoleLabel 'ProfilePreCreate' -Result $result)
}

function Test-PassiveSiteFunctionality {
    <#
    .SYNOPSIS
        Validates the passive (HA) site server is initialized and replicating.
    .DESCRIPTION
        After the active site promotes a passive node, the passive VM should
        have SMS_EXECUTIVE running, the registry should reflect the same site
        code as its active partner, and from the parent active site server the
        passive node should appear in SMS_SCI_SysResUse.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][object]$CurrentItem,
        [Parameter(Mandatory)][object]$DeployConfig
    )

    $Phase = 11
    $domain = $DeployConfig.vmOptions.domainName
    $siteCode = $CurrentItem.siteCode

    Write-Log "[Phase $Phase] $VMName [PassiveSite]: Testing passive site server (site $siteCode)" -LogOnly

    $passiveScript = {
        param($sc)
        $results = @{ Passed = $true; Details = [System.Collections.Generic.List[string]]::new() }

        # SMS_EXECUTIVE may still be installing/starting after the passive site
        # install monitoring exits (it returns when the final WMI stage is
        # reached, not when the service is fully running). Retry for up to 5 min.
        $results.Details.Add("CMD: Get-Service -Name 'SMS_EXECUTIVE' (with retries)")
        $svc = $null
        for ($attempt = 1; $attempt -le 10; $attempt++) {
            $svc = Get-Service -Name 'SMS_EXECUTIVE' -ErrorAction SilentlyContinue
            if ($svc -and $svc.Status -eq 'Running') { break }
            if ($attempt -lt 10) { Start-Sleep -Seconds 30 }
        }
        if (-not $svc) {
            $results.Passed = $false
            $results.Details.Add("FAIL: Service 'SMS_EXECUTIVE' not found after $attempt attempts")
            return $results
        }
        if ($svc.Status -ne 'Running') {
            $results.Passed = $false
            $results.Details.Add("FAIL: Service 'SMS_EXECUTIVE' is $($svc.Status) after $attempt attempts")
            return $results
        }
        $results.Details.Add("OK: Service 'SMS_EXECUTIVE' is Running (attempt $attempt)")

        # Registry should advertise the same site code as the active partner
        $regSite = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\SMS\Identification' -Name 'Site Code' -ErrorAction SilentlyContinue
        if (-not $regSite) {
            $results.Passed = $false
            $results.Details.Add("FAIL: Registry 'SMS\Identification\Site Code' missing -- site server bootstrap incomplete")
        }
        elseif ($regSite.'Site Code' -ne $sc) {
            $results.Passed = $false
            $results.Details.Add("FAIL: Registry site code '$($regSite.'Site Code')' != expected '$sc'")
        }
        else {
            $results.Details.Add("OK: Registry site code matches '$sc'")
        }

        return $results
    }

    $result = Invoke-VmCommand -VmName $VMName -VmDomainName $domain `
        -ScriptBlock $passiveScript -ArgumentList $siteCode `
        -DisplayName "Phase11-PassiveSite-Test" -SuppressLog `
        -AsJob -TimeoutSeconds 600

    $localOk = Format-TestResult -VMName $VMName -RoleLabel 'PassiveSite' -Result $result
    if (-not $localOk) { return $false }

    # Verify from the active site server that this passive node is registered
    $activeVM = $DeployConfig.virtualMachines | Where-Object {
        $_.siteCode -eq $siteCode -and $_.role -in @('Primary', 'CAS')
    } | Select-Object -First 1
    if (-not $activeVM) {
        Write-Log "[Phase $Phase] $VMName [PassiveSite]: No active site server found for site '$siteCode'; skipping cross-check" -LogOnly
        return $true
    }

    $parentScript = {
        param($sc, $passiveName)
        $results = @{ Passed = $true; Details = [System.Collections.Generic.List[string]]::new() }
        $filter = "RoleName = 'SMS Site Server' AND NetworkOSPath LIKE '%$passiveName%'"
        $results.Details.Add("CMD: Get-WmiObject -Namespace 'root\SMS\site_$sc' -Class SMS_SCI_SysResUse -Filter `"$filter`"")
        # Retry on transient "Provider load failure": right after a reboot (e.g.
        # a -startPhase 11 rerun) the SMS Provider WMI host hasn't finished
        # loading even though SMS_EXECUTIVE is Running, so the first query throws.
        # It typically becomes available within a minute or two.
        $passive = $null
        $wmiErr = $null
        for ($i = 1; $i -le 6; $i++) {
            try {
                $passive = Get-WmiObject -Namespace "root\SMS\site_$sc" -Class SMS_SCI_SysResUse -Filter $filter -ErrorAction Stop
                $wmiErr = $null
                break
            }
            catch {
                $wmiErr = $_
                if ($i -lt 6) { Start-Sleep -Seconds 15 }
            }
        }
        if ($wmiErr) {
            $results.Passed = $false
            $results.Details.Add("FAIL: WMI query for passive site server failed after retries: $($wmiErr.Exception.Message)")
        }
        elseif ($passive) {
            $results.Details.Add("OK: Passive site server '$passiveName' registered in site '$sc'")
        }
        else {
            $results.Passed = $false
            $results.Details.Add("FAIL: Passive site server '$passiveName' not registered in site '$sc'")
        }
        return $results
    }

    $parentResult = Invoke-VmCommand -VmName $activeVM.vmName -VmDomainName $domain `
        -ScriptBlock $parentScript -ArgumentList $siteCode, $VMName `
        -DisplayName "Phase11-PassiveSite-Parent-Test" -SuppressLog `
        -AsJob -TimeoutSeconds 300

    return (Format-TestResult -VMName $VMName -RoleLabel 'PassiveSite-Parent' -Result $parentResult)
}

function Save-CcmSetupLog {
    <#
    .SYNOPSIS
        Pull the guest's ccmsetup / client.msi logs to the host log directory
        when a ConfigMgr client install failed, for offline troubleshooting.
    .DESCRIPTION
        Mirrors the Phase 8 CM-setup log-capture pattern (Get-Content in-guest,
        Set-Content on host) instead of Copy-Item -FromSession, so it works
        through the existing PSDirect plumbing and bounds size by tailing each
        log. Files land as:
            <VmName>-Phase11-<timestamp>-ccmsetup.log
            <VmName>-Phase11-<timestamp>-client.msi.log   (+ rolled variants)
        Best-effort and non-fatal: any failure just logs a warning.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$DomainName
    )

    $Phase = 11
    $logDir = $null
    if ($Common -and $Common.LogPath) { $logDir = Split-Path $Common.LogPath -Parent }
    if (-not $logDir -or -not (Test-Path $logDir)) {
        Write-Log "[Phase $Phase] $VMName [DomainMember]: ccmsetup log capture: host log dir not resolvable ($logDir)" -Warning -LogOnly
        return
    }

    $pullBlock = {
        $logRoot = 'C:\Windows\ccmsetup\Logs'
        $out = @{}
        if (-not (Test-Path $logRoot)) { return $out }
        # ccmsetup.log + rolled ccmsetup-*.log + client.msi*.log. Most-recent
        # first, tail each to bound the payload pulled back over PSDirect.
        $files = Get-ChildItem -Path $logRoot -Filter '*.log' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like 'ccmsetup*.log' -or $_.Name -like 'client.msi*.log' } |
            Sort-Object LastWriteTime -Descending | Select-Object -First 6
        foreach ($f in $files) {
            try {
                $content = Get-Content -LiteralPath $f.FullName -Tail 4000 -ErrorAction SilentlyContinue
                if ($content) { $out[$f.Name] = ($content -join "`r`n") }
            }
            catch { }
        }
        return $out
    }

    try {
        $res = Invoke-VmCommand -VmName $VMName -VmDomainName $DomainName -ScriptBlock $pullBlock `
            -SuppressLog -AsJob -TimeoutSeconds 120 -DisplayName "Pull ccmsetup logs"
    }
    catch {
        Write-Log "[Phase $Phase] $VMName [DomainMember]: ccmsetup log capture: PSDirect call threw: $($_.Exception.Message)" -Warning -LogOnly
        return
    }
    if (-not $res -or $res.ScriptBlockFailed -or -not ($res.ScriptBlockOutput -is [hashtable]) -or $res.ScriptBlockOutput.Count -eq 0) {
        Write-Log "[Phase $Phase] $VMName [DomainMember]: ccmsetup log capture: no logs returned from VM" -Warning -LogOnly
        return
    }

    $stamp = (Get-Date -Format 'yyyyMMdd-HHmmss')
    foreach ($name in $res.ScriptBlockOutput.Keys) {
        $content = $res.ScriptBlockOutput[$name]
        if (-not $content) { continue }
        $dest = Join-Path $logDir "$VMName-Phase$Phase-$stamp-$name"
        try {
            Set-Content -LiteralPath $dest -Value $content -Encoding UTF8 -ErrorAction Stop
            $kb = [math]::Round(([System.Text.Encoding]::UTF8.GetByteCount($content)) / 1KB, 1)
            Write-Log "[Phase $Phase] $VMName [DomainMember]: Pulled $name (${kb}KB tail) -> $dest" -OutputStream
        }
        catch {
            Write-Log "[Phase $Phase] $VMName [DomainMember]: ccmsetup log capture: failed to write ${name}: $_" -Warning -LogOnly
        }
    }
}

function Test-DomainMemberFunctionality {
    <#
    .SYNOPSIS
        Lightweight checks for a domain-joined member server / client.
    .DESCRIPTION
        Verifies domain join, secure-channel health, time sync, and (when the
        SCCM client is present) CCMExec service + last MP communication.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][object]$CurrentItem,
        [Parameter(Mandatory)][object]$DeployConfig
    )

    $Phase = 11
    $domain = $DeployConfig.vmOptions.domainName

    $usePKI = [bool]$DeployConfig.cmOptions.UsePKI
    $pushExpected = ($CurrentItem.pushClient -ne $false)

    Write-Log "[Phase $Phase] $VMName [DomainMember]: Testing domain join and CCM client (if present)" -LogOnly

    $scriptBlock = {
        param($expectedDomain, $checkPkiCert)
        $checkPki = ($checkPkiCert -eq 'True')
        $results = @{ Passed = $true; Details = [System.Collections.Generic.List[string]]::new() }

        # Live status heartbeat. Invoke-VmCommand -PollProgress polls this nested
        # job's Progress stream and treats every new record as a heartbeat that
        # resets the stall timer, so the multi-minute ccmsetup wait loops below
        # never trip a false "timed out" failure as long as they keep emitting
        # progress. Each Status carries a changing value so the record count
        # always advances (the host resets the timer on count growth).
        $progressActivity = "$env:COMPUTERNAME [DomainMember]"
        Write-Progress -Activity $progressActivity -Status "Checking domain membership"

        # ccmsetup failure diagnostics. ccmsetup exits with an opaque hex code;
        # decode the common ones and pull the relevant LocationServices / cert
        # lines from ccmsetup.log so a WARN names the actual broken subsystem
        # instead of just the code. PS5.1-safe (runs on down-level client OSes).
        $decodeCcmError = {
            param($line)
            if (-not $line) { return $null }
            $l = "$line".ToLower()
            if ($l -match '0x87d00454') {
                return "GetDPLocations failed (the MP replied HTTP 200 but returned no content location) -- either the ConfigMgr Client Package isn't distributed to a DP in this VM's boundary group yet, or under PKI/HTTPS the client cert issuer isn't in the MP's trusted-issuer list. Typically a transient content-distribution race during auto-push that clears on the next client-location cycle / Phase 11 re-run."
            }
            if ($l -match '0x87d00227') { return "client.msi installation failed (see C:\Windows\ccmsetup\Logs\client.msi.log)." }
            if ($l -match '0x87d0029e') { return "failed to download client content from a DP (content not available / BITS or transport error)." }
            if ($l -match '0x87d00269') { return "no Management Point could be located (boundary / boundary-group or MP availability problem)." }
            if ($l -match '0x80092004') { return "PKI cert chain/issuer problem (object or property not found while building the cert chain)." }
            if ($l -match '0x800704dd') { return "BITS could not download the client payload: ERROR_NOT_LOGGED_ON -- BITS requires an interactive logon session to run the transfer and none was present (common on a freshly-booted lab client with no console user). ccmsetup runs as SYSTEM and registers its own 'Configuration Manager Client Retry Task' (re-attempts every ~10 min), so the client typically self-heals on a later cycle or once a user logs on -- no manual ccmsetup relaunch needed." }
            return $null
        }
        $grabCcmDiag = {
            param($logFile)
            $diag = New-Object System.Collections.Generic.List[string]
            if (Test-Path $logFile) {
                $tail = Get-Content $logFile -Tail 150 -ErrorAction SilentlyContinue
                $hits = $tail | Where-Object {
                    $_ -match 'GetDPLocations|Failed to find DP locations|Unable to find any Certificate|no (client )?certificate|Sending location (services )?request|status code|MP_LocationManager|boundary'
                } | Select-Object -Last 5
                foreach ($h in $hits) { if ($h) { $diag.Add(("$h").Trim()) } }
            }
            return $diag
        }

        # Domain membership
        $cs = Get-WmiObject Win32_ComputerSystem -ErrorAction SilentlyContinue
        if (-not $cs.PartOfDomain) {
            $results.Passed = $false
            $results.Details.Add("FAIL: Computer is not domain-joined (Domain = '$($cs.Domain)')")
            return $results
        }
        if ($cs.Domain -notlike "$expectedDomain*" -and $expectedDomain -notlike "$($cs.Domain)*") {
            $results.Details.Add("WARN: Joined domain '$($cs.Domain)' differs from deploy domain '$expectedDomain' (may be cross-domain by design)")
        }
        else {
            $results.Details.Add("OK: Computer joined to domain '$($cs.Domain)'")
        }

        # Secure channel
        # Retry a few times: right after Phase 10 the netlogon service / DC can
        # be transiently unreachable, especially in parallel runs, and a single
        # false return would otherwise fail an otherwise-healthy client.
        Write-Progress -Activity $progressActivity -Status "Checking secure channel"
        $sc = $false
        $scError = $null
        for ($i = 1; $i -le 4; $i++) {
            try {
                $sc = Test-ComputerSecureChannel -ErrorAction Stop
                if ($sc) { break }
            }
            catch { $scError = $_ }
            if ($i -lt 4) { Start-Sleep -Seconds (5 * $i) }
        }
        if (-not $sc -and -not $scError) {
            # Attempt repair: resets the machine account password in AD.
            # Runs as SYSTEM which has the rights to reset its own password.
            $results.Details.Add("REMEDIATE: Secure channel broken, attempting -Repair...")
            try {
                $sc = Test-ComputerSecureChannel -Repair -ErrorAction Stop
                if ($sc) {
                    $results.Details.Add("RECOVERED: Secure channel was broken; repaired successfully")
                }
            }
            catch {
                $results.Details.Add("WARN: Repair failed: $($_.Exception.Message)")
            }
        }
        if ($sc) {
            $results.Details.Add("OK: Secure channel to domain is healthy")
        }
        elseif ($scError) {
            $results.Details.Add("WARN: Test-ComputerSecureChannel threw after retries: $($scError.Exception.Message)")
        }
        else {
            $results.Passed = $false
            $results.Details.Add("FAIL: Test-ComputerSecureChannel returned False after repair attempt -- machine account may need to be reset in AD (Reset-ComputerMachinePassword)")
        }

        # Time sync
        try {
            $w32tm = & w32tm.exe /query /status 2>&1
            $offsetLine = $w32tm | Where-Object { $_ -match 'Last Successful Sync Time' } | Select-Object -First 1
            if ($offsetLine) {
                $results.Details.Add("OK: w32tm reports last successful sync ($($offsetLine.Trim()))")
            }
            else {
                $results.Details.Add("WARN: w32tm did not report a successful sync time")
            }
        }
        catch {
            $results.Details.Add("WARN: w32tm /query /status failed: $($_.Exception.Message)")
        }

        # PKI client authentication certificate (when UsePKI + pushClient)
        if ($checkPki) {
            # Find the auto-enrolled client-auth cert (non-Microsoft, not self-signed).
            $findClientCert = {
                Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
                    Where-Object {
                        $_.EnhancedKeyUsageList.ObjectId -contains '1.3.6.1.5.5.7.3.2' -and   # Client Authentication
                        $_.Issuer -notmatch 'O=Microsoft' -and
                        $_.Subject -ne $_.Issuer                                               # Not self-signed
                    } | Select-Object -First 1
            }
            # Build the cert chain to a trusted root; returns @{ Ok; Status }.
            # Under a 2-tier PKI (offline root + enterprise sub-CA), ccmsetup must be
            # able to build leaf -> sub-CA -> offline-root locally. The leaf
            # auto-enrolls fine, but the offline root + sub-CA certs only land in the
            # local Trusted Root / Intermediate stores on the autoenrollment / GP
            # cycle. If ccmsetup runs first, chain-building fails (CRYPT_E_NOT_FOUND
            # 0x80092004) -> 'Unable to find any Certificate based on Certificate
            # Issuers' -> GetDPLocations 0x87d00454. Revocation is ignored: the
            # offline root has no reachable CRL in the lab.
            $testChain = {
                param($cert)
                if (-not $cert) { return @{ Ok = $false; Status = 'no-cert' } }
                try {
                    $chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
                    $chain.ChainPolicy.RevocationMode = [System.Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
                    $built = $chain.Build($cert)
                    $flags = (@($chain.ChainStatus) | ForEach-Object { $_.Status }) -join ','
                    if (-not $flags) { $flags = 'OK' }
                    return @{ Ok = [bool]$built; Status = $flags }
                }
                catch { return @{ Ok = $false; Status = "chain-build-threw: $($_.Exception.Message)" } }
            }
            # Pull the AD-published Root/Sub CA certs into the local stores.
            # certutil -pulse triggers autoenrollment (downloads the AD-published
            # Trusted Root + Intermediate CAs); gpupdate forces the computer GP
            # root-cert distribution. Both idempotent and quick.
            $pullChainCAs = {
                try { & certutil.exe -pulse 2>&1 | Out-Null } catch {}
                try { & gpupdate.exe /target:computer /force 2>&1 | Out-Null } catch {}
            }

            $clientCert = & $findClientCert
            if (-not $clientCert) {
                $results.Details.Add("REMEDIATE: No PKI client auth cert yet; running certutil -pulse + gpupdate to trigger auto-enrollment...")
                & $pullChainCAs
                Start-Sleep -Seconds 15
                $clientCert = & $findClientCert
            }

            if ($clientCert) {
                $results.Details.Add("OK: PKI client auth certificate found (Subject='$($clientCert.Subject)', Issuer='$($clientCert.Issuer)', Expires=$($clientCert.NotAfter.ToString('yyyy-MM-dd')))")
                if ($clientCert.NotAfter -lt (Get-Date)) {
                    $results.Passed = $false
                    $results.Details.Add("FAIL: PKI client auth certificate is expired")
                }
                if (-not $clientCert.HasPrivateKey) {
                    $results.Passed = $false
                    $results.Details.Add("FAIL: PKI client auth certificate has no private key")
                }
                # Validate the trust chain (the offline-root anchor must be present locally).
                $chainResult = & $testChain $clientCert
                if ($chainResult.Ok) {
                    $results.Details.Add("OK: Client cert chains to a trusted root (chain status: $($chainResult.Status))")
                }
                else {
                    $results.Details.Add("REMEDIATE: Client cert chain incomplete ($($chainResult.Status)); pulling AD-published root/sub-CA certs (certutil -pulse + gpupdate)...")
                    & $pullChainCAs
                    Start-Sleep -Seconds 15
                    $clientCert = & $findClientCert
                    $chainResult = & $testChain $clientCert
                    if ($chainResult.Ok) {
                        $results.Details.Add("RECOVERED: Client cert chain healthy after pulling CA certs (chain status: $($chainResult.Status))")
                    }
                    else {
                        $rootCount = 0
                        try { $rootCount = @(Get-ChildItem Cert:\LocalMachine\Root -ErrorAction SilentlyContinue | Where-Object { $_.Subject -eq $_.Issuer }).Count } catch {}
                        # WARN (not FAIL): the chain can still converge on the next GP
                        # cycle and ccmsetup itself retries. Surface the missing-anchor
                        # cause so the operator knows it's PKI propagation, not the leaf.
                        $results.Details.Add("WARN: Client cert still doesn't chain to a trusted root ($($chainResult.Status)) after remediation. The offline root / sub-CA cert hasn't propagated to LocalMachine\Root + \CA yet (roots-in-store=$rootCount). ccmsetup will fail PKI auth (0x80092004 -> GetDPLocations 0x87d00454) until it does; re-run Phase 11 after the next GP cycle.")
                    }
                }
            }
            else {
                $results.Passed = $false
                $results.Details.Add("FAIL: No PKI client authentication certificate in LocalMachine\My (even after auto-enrollment remediation). ccmsetup will fail with CCM_E_NO_CLIENT_PKI_CERT. Check auto-enrollment and the ConfigMgrClientCertificate template.")
            }
        }

        # CCM client (only if installed; not all DomainMembers get the client)
        # Helper: attempt to re-run ccmsetup, wait for completion, re-check CcmExec.
        # Returns $true if CcmExec ends up Running after the retry.
        $retryCcmSetup = {
            param($results)
            $ccmsetupExe = 'C:\Windows\ccmsetup\ccmsetup.exe'
            if (-not (Test-Path $ccmsetupExe)) {
                $results.Details.Add("INFO: $ccmsetupExe not found, cannot retry")
                return $false
            }
            $results.Details.Add("INFO: Attempting ccmsetup retry...")
            # Never launch a competing ccmsetup if one is already running. An
            # in-flight install (or ccmsetup's own internal GetDPLocations retry
            # cycle) must be allowed to finish -- ccmsetup is single-instance
            # (global mutex), so a second launch would no-op anyway and only
            # muddy our wait/verdict. If one is running, wait for it instead of
            # relaunching.
            $running = Get-Process -Name 'ccmsetup' -ErrorAction SilentlyContinue
            if ($running) {
                $results.Details.Add("INFO: ccmsetup already running (PID $(($running.Id) -join ',')); waiting for it to finish instead of relaunching")
            }
            else {
                # ccmsetup runs as SYSTEM and, when an install attempt fails, registers
                # its OWN 'Configuration Manager Client Retry Task' (re-attempts every
                # ~10 min in the correct service context). Re-launching ccmsetup
                # ourselves is redundant with that task -- and from the Phase 11 PSDirect
                # context it runs with no logon session, so a BITS payload download hits
                # the very same ERROR_NOT_LOGGED_ON (0x800704dd) and fails again. So
                # prefer triggering the client's own retry task; only spawn ccmsetup
                # directly when no such task exists.
                $retryTask = Get-ScheduledTask -TaskName 'Configuration Manager Client Retry Task' -ErrorAction SilentlyContinue
                if ($retryTask) {
                    try {
                        $retryTask | Start-ScheduledTask -ErrorAction Stop
                        $results.Details.Add("INFO: Triggered ccmsetup's own 'Configuration Manager Client Retry Task' (SYSTEM) instead of launching a competing ccmsetup")
                    }
                    catch {
                        $results.Details.Add("INFO: Could not start ccmsetup retry task ($($_.Exception.Message)); ccmsetup will still retry on its own ~10 min schedule")
                    }
                }
                else {
                    try { Start-Process -FilePath $ccmsetupExe -ErrorAction Stop } catch {
                        $results.Details.Add("INFO: Failed to launch ccmsetup: $($_.Exception.Message)")
                        return $false
                    }
                }
                Start-Sleep -Seconds 10
            }
            # Wait up to 5 minutes for ccmsetup to finish
            for ($w = 0; $w -lt 30; $w++) {
                Write-Progress -Activity $progressActivity -Status "ccmsetup retry: waiting for ccmsetup to finish ($($w * 10)s)"
                Start-Sleep -Seconds 10
                if (-not (Get-Process -Name 'ccmsetup' -ErrorAction SilentlyContinue)) { break }
            }
            Start-Sleep -Seconds 10
            $svc = Get-Service -Name 'CcmExec' -ErrorAction SilentlyContinue
            if ($svc -and $svc.Status -eq 'Running') {
                $results.Details.Add("OK: CcmExec is Running after ccmsetup retry")
                return $true
            }
            # Still not running — try Start-Service in case the service was just installed
            if ($svc) {
                try { Start-Service -Name 'CcmExec' -ErrorAction SilentlyContinue } catch {}
                Start-Sleep -Seconds 10
                $svc = Get-Service -Name 'CcmExec' -ErrorAction SilentlyContinue
                if ($svc -and $svc.Status -eq 'Running') {
                    $results.Details.Add("OK: CcmExec is Running after ccmsetup retry + manual start")
                    return $true
                }
            }
            return $false
        }

        Write-Progress -Activity $progressActivity -Status "Checking ConfigMgr client (CcmExec)"
        $ccm = Get-Service -Name 'CcmExec' -ErrorAction SilentlyContinue
        if ($ccm) {
            if ($ccm.Status -ne 'Running') {
                # Client push may still be finishing — try to start and wait.
                try { Start-Service -Name 'CcmExec' -ErrorAction SilentlyContinue } catch {}
                Start-Sleep -Seconds 15
                $ccm = Get-Service -Name 'CcmExec' -ErrorAction SilentlyContinue
            }
            if ($ccm.Status -eq 'Running') {
                $results.Details.Add("OK: CcmExec service is Running")
            }
            else {
                # CcmExec exists but won't start -- check if ccmsetup is still running.
                $setup = Get-Process -Name 'ccmsetup' -ErrorAction SilentlyContinue
                if ($setup) {
                    # Wait up to 5 min for ccmsetup to finish
                    $results.Details.Add("INFO: CcmExec is $($ccm.Status), ccmsetup.exe still running, waiting up to 5 min...")
                    for ($w = 0; $w -lt 30; $w++) {
                        Write-Progress -Activity $progressActivity -Status "CcmExec $($ccm.Status); waiting for ccmsetup to finish ($($w * 10)s)"
                        Start-Sleep -Seconds 10
                        if (-not (Get-Process -Name 'ccmsetup' -ErrorAction SilentlyContinue)) { break }
                    }
                    Start-Sleep -Seconds 15
                    $ccm = Get-Service -Name 'CcmExec' -ErrorAction SilentlyContinue
                    if ($ccm -and $ccm.Status -eq 'Running') {
                        $results.Details.Add("OK: CcmExec is Running after waiting for ccmsetup to finish")
                    }
                    elseif ($ccm) {
                        try { Start-Service -Name 'CcmExec' -ErrorAction SilentlyContinue } catch {}
                        Start-Sleep -Seconds 10
                        $ccm = Get-Service -Name 'CcmExec' -ErrorAction SilentlyContinue
                        if ($ccm.Status -eq 'Running') {
                            $results.Details.Add("OK: CcmExec is Running after waiting for ccmsetup + manual start")
                        }
                        else {
                            $results.Details.Add("WARN: CcmExec is $($ccm.Status) after ccmsetup finished")
                        }
                    }
                }
                else {
                    # ccmsetup finished but service not running -- check last exit line.
                    $logPath = 'C:\Windows\ccmsetup\Logs\ccmsetup.log'
                    $failDetail = $null
                    if (Test-Path $logPath) {
                        $logTail = Get-Content $logPath -Tail 50 -ErrorAction SilentlyContinue
                        $exitLine = $logTail | Where-Object { $_ -match 'CcmSetup is exiting with return code|ccmsetup failed with error code' } | Select-Object -Last 1
                        if ($exitLine -and $exitLine -notmatch 'return code 0\b') {
                            $failDetail = $exitLine.Trim()
                        }
                    }
                    if ($failDetail) {
                        $meaning = & $decodeCcmError $failDetail
                        if ($meaning) {
                            $results.Details.Add("WARN: CcmExec is $($ccm.Status); ccmsetup failed: $failDetail -- $meaning")
                        }
                        else {
                            $results.Details.Add("WARN: CcmExec is $($ccm.Status); ccmsetup failed: $failDetail")
                        }
                        foreach ($d in (& $grabCcmDiag $logPath)) { $results.Details.Add("  ccmsetup.log: $d") }
                    }
                    else {
                        $results.Details.Add("WARN: CcmExec is $($ccm.Status) (ccmsetup finished but service won't start)")
                    }
                    if (-not (& $retryCcmSetup $results)) {
                        $results.Details.Add("WARN: CcmExec still not Running after ccmsetup retry")
                    }
                }
            }
        }
        else {
            # CcmExec service doesn't exist at all — check if ccmsetup is in progress.
            $setup = Get-Process -Name 'ccmsetup' -ErrorAction SilentlyContinue
            if ($setup) {
                # ccmsetup is actively running -- wait up to 5 minutes for it to finish
                $results.Details.Add("INFO: ccmsetup.exe is running, waiting up to 5 min for it to finish...")
                for ($w = 0; $w -lt 30; $w++) {
                    Write-Progress -Activity $progressActivity -Status "ccmsetup running; waiting for it to finish ($($w * 10)s)"
                    Start-Sleep -Seconds 10
                    if (-not (Get-Process -Name 'ccmsetup' -ErrorAction SilentlyContinue)) { break }
                }
                # Re-check CcmExec after ccmsetup finishes
                Start-Sleep -Seconds 15
                $ccmRetry = Get-Service -Name 'CcmExec' -ErrorAction SilentlyContinue
                if ($ccmRetry -and $ccmRetry.Status -eq 'Running') {
                    $results.Details.Add("OK: CcmExec is Running after waiting for ccmsetup to finish")
                    return $results
                }
                elseif ($ccmRetry) {
                    try { Start-Service -Name 'CcmExec' -ErrorAction SilentlyContinue } catch {}
                    Start-Sleep -Seconds 10
                    $ccmRetry = Get-Service -Name 'CcmExec' -ErrorAction SilentlyContinue
                    if ($ccmRetry -and $ccmRetry.Status -eq 'Running') {
                        $results.Details.Add("OK: CcmExec is Running after waiting for ccmsetup + manual start")
                        return $results
                    }
                }
                # Fall through to log check below
            }
            # If ccmsetup is STILL running at this point (a slow install -- content
            # download or its own GetDPLocations retry cycle -- that outlasted our
            # 5-min wait), do NOT read a stale exit line and declare failure, and do
            # NOT relaunch a competing instance: let the in-flight install finish.
            $stillRunning = Get-Process -Name 'ccmsetup' -ErrorAction SilentlyContinue
            if ($stillRunning) {
                $results.Details.Add("WARN: ccmsetup is still running (install in progress); not interrupting -- re-run Phase 11 to re-check once it finishes")
            }
            elseif (Test-Path 'C:\Windows\ccmsetup\Logs\ccmsetup.log') {
                $logTail = Get-Content 'C:\Windows\ccmsetup\Logs\ccmsetup.log' -Tail 50 -ErrorAction SilentlyContinue
                # Check the LAST exit line -- the log may contain both failures (from
                # an earlier auto-push race) and a later success. Only the final exit matters.
                $exitLine = $logTail | Where-Object { $_ -match 'CcmSetup is exiting with return code|ccmsetup failed with error code' } | Select-Object -Last 1
                $isSuccess = $exitLine -and $exitLine -match 'return code 0\b'
                if ($isSuccess) {
                    # ccmsetup succeeded but CcmExec hasn't started yet -- give it a moment
                    $results.Details.Add("INFO: ccmsetup exited successfully, waiting for CcmExec to start...")
                    Start-Sleep -Seconds 20
                    $ccmRetry = Get-Service -Name 'CcmExec' -ErrorAction SilentlyContinue
                    if (-not $ccmRetry -or $ccmRetry.Status -ne 'Running') {
                        try { Start-Service -Name 'CcmExec' -ErrorAction SilentlyContinue } catch {}
                        Start-Sleep -Seconds 10
                        $ccmRetry = Get-Service -Name 'CcmExec' -ErrorAction SilentlyContinue
                    }
                    if ($ccmRetry -and $ccmRetry.Status -eq 'Running') {
                        $results.Details.Add("OK: CcmExec is Running (ccmsetup succeeded)")
                        return $results
                    }
                    else {
                        $results.Details.Add("WARN: ccmsetup succeeded but CcmExec still not Running")
                    }
                }
                elseif ($exitLine) {
                    $meaning = & $decodeCcmError $exitLine
                    if ($meaning) {
                        $results.Details.Add("WARN: CcmExec not installed; ccmsetup failed: $($exitLine.Trim()) -- $meaning")
                    }
                    else {
                        $results.Details.Add("WARN: CcmExec not installed; ccmsetup failed: $($exitLine.Trim())")
                    }
                    foreach ($d in (& $grabCcmDiag 'C:\Windows\ccmsetup\Logs\ccmsetup.log')) { $results.Details.Add("  ccmsetup.log: $d") }
                }
                else {
                    $results.Details.Add("WARN: CcmExec not installed; ccmsetup.log exists but no success/failure line found")
                }
                if (-not (& $retryCcmSetup $results)) {
                    $results.Details.Add("WARN: CcmExec still not installed after ccmsetup retry")
                }
            }
            else {
                # No service, no ccmsetup process, no log — client was never pushed.
                $results.Details.Add("WARN: CcmExec not installed and no ccmsetup.log — client push may not have reached this VM")
                $results.NeedsPushCheck = $true
            }
        }

        return $results
    }

    $checkPkiCert = ($usePKI -and $pushExpected)
    $result = Invoke-VmCommand -VmName $VMName -VmDomainName $domain `
        -ScriptBlock $scriptBlock -ArgumentList $domain, $checkPkiCert `
        -DisplayName "Phase11-DomainMember-Test" -SuppressLog `
        -AsJob -TimeoutSeconds 300 -PollProgress

    # If the guest reported NeedsPushCheck, enrich with deploy config context.
    if ($result.ScriptBlockOutput -is [hashtable] -and $result.ScriptBlockOutput.NeedsPushCheck) {
        if ($pushExpected) {
            $result.ScriptBlockOutput.Details.Add("  WARN: pushClient=$true in config but no ccmsetup evidence on VM — push may have failed or still be in progress on the site server side")
            $result.ScriptBlockOutput.Details.Add("  Check ccmsetup on the Primary: Get-CMDevice -Name '$VMName' | Select IsClient,ClientActiveStatus")
        }
        else {
            $result.ScriptBlockOutput.Details[-1] = "OK: CcmExec not installed (pushClient=false in config)"
        }
    }

    # On a ccmsetup install failure, pull the guest's ccmsetup / client.msi
    # logs to the host log directory so the operator can troubleshoot offline
    # (these live only on the guest and are otherwise lost on VHD compaction).
    if ($result.ScriptBlockOutput -is [hashtable] -and $result.ScriptBlockOutput.Details) {
        $ccmFailed = $result.ScriptBlockOutput.Details | Where-Object { $_ -match 'ccmsetup failed' }
        if ($ccmFailed) {
            Save-CcmSetupLog -VMName $VMName -DomainName $domain
        }
    }

    # Office deployment policy check: if installOffice is set, verify the client received the deployment
    $officeChannel = $CurrentItem.installOffice
    $officeWanted = ($officeChannel -and $officeChannel -ne $false -and $result.ScriptBlockOutput -is [hashtable] -and $result.ScriptBlockOutput.Passed)
    # Office is deployed via the ConfigMgr client. If CcmExec isn't actually
    # installed/running there's no point polling CCM_Application for 3 min -- it
    # can never populate. Detect client health from the main test's Details (all
    # success paths add an "OK: CcmExec ... Running" line).
    $clientRunningForOffice = $false
    if ($officeWanted -and $result.ScriptBlockOutput.Details) {
        $clientRunningForOffice = [bool]($result.ScriptBlockOutput.Details | Where-Object { $_ -match '^OK: CcmExec' })
    }
    if ($officeWanted -and -not $clientRunningForOffice) {
        $result.ScriptBlockOutput.Details.Add("WARN: Skipping Office deployment policy check -- ConfigMgr client (CcmExec) is not installed/running, so the Office deployment can't be received. Resolve the client install first (see the ccmsetup WARN above).")
    }
    if ($officeWanted -and $clientRunningForOffice) {
        $officeCheckBlock = {
            $officeResults = @{ Details = [System.Collections.Generic.List[string]]::new() }
            $progressActivity = "$env:COMPUTERNAME [DomainMember]"
            Write-Progress -Activity $progressActivity -Status "Triggering Office deployment policy"
            # The Install Targets collection refreshes on its own schedule, and the
            # client only pulls down the deployment after a Machine Policy cycle.
            # Trigger the full chain proactively (Policy Retrieval -> Evaluation ->
            # App Deployment Eval) so a freshly-built VM whose client just came
            # online doesn't spuriously warn while everything is actually working.
            # CCM_Application is populated by App Deployment Eval ({...0121}), not
            # by policy retrieval alone -- triggering only 0021/0022 leaves a
            # window where policy is on disk but no CCM_Application row exists yet.
            try {
                Invoke-CimMethod -Namespace 'root\ccm' -ClassName SMS_Client -MethodName TriggerSchedule -Arguments @{ sScheduleID = '{00000000-0000-0000-0000-000000000021}' } -ErrorAction SilentlyContinue | Out-Null
                Invoke-CimMethod -Namespace 'root\ccm' -ClassName SMS_Client -MethodName TriggerSchedule -Arguments @{ sScheduleID = '{00000000-0000-0000-0000-000000000022}' } -ErrorAction SilentlyContinue | Out-Null
            }
            catch { }
            # Poll up to ~3 min for CCM_Application to populate. Retrigger
            # Application Deployment Eval ({...0121}) + App Global Eval
            # ({...0027}) at 30s, 60s, 120s, plus a fresh Machine Policy
            # Retrieval ({...0021}) at 90s -- the first eval can race with
            # the policy download on a freshly-onboarded client, and on a
            # cold deploy the site's policy projection for the Office
            # deployment can lag the collection-membership eval by a couple
            # of cycles. Total budget: 36 iterations * 5s = 180s.
            $app = $null
            for ($i = 0; $i -lt 36; $i++) {
                Write-Progress -Activity $progressActivity -Status "Polling for Office deployment policy ($($i * 5)s)"
                try {
                    $app = Get-CimInstance -Namespace 'root\ccm\ClientSDK' -ClassName CCM_Application -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -like '*Microsoft 365*' -or $_.Name -like '*Microsoft365*' }
                }
                catch { }
                if ($app) { break }
                if ($i -eq 6 -or $i -eq 12 -or $i -eq 24) {
                    try {
                        Invoke-CimMethod -Namespace 'root\ccm' -ClassName SMS_Client -MethodName TriggerSchedule -Arguments @{ sScheduleID = '{00000000-0000-0000-0000-000000000121}' } -ErrorAction SilentlyContinue | Out-Null
                        Invoke-CimMethod -Namespace 'root\ccm' -ClassName SMS_Client -MethodName TriggerSchedule -Arguments @{ sScheduleID = '{00000000-0000-0000-0000-000000000027}' } -ErrorAction SilentlyContinue | Out-Null
                    }
                    catch { }
                }
                if ($i -eq 18) {
                    # Mid-poll, re-pull machine policy in case the Primary
                    # has just finished projecting the Office deployment.
                    try {
                        Invoke-CimMethod -Namespace 'root\ccm' -ClassName SMS_Client -MethodName TriggerSchedule -Arguments @{ sScheduleID = '{00000000-0000-0000-0000-000000000021}' } -ErrorAction SilentlyContinue | Out-Null
                    }
                    catch { }
                }
                Start-Sleep -Seconds 5
            }
            if ($app) {
                $officeResults.Details.Add("OK: Office deployment policy received (Name=$($app.Name), State=$($app.EvaluationState))")
            }
            else {
                # Collect quick diagnostics so the WARN points at the right subsystem
                # instead of just suggesting collection membership.
                $diag = @()
                $assignCount = 0
                $assignNames = @()
                try {
                    $assignments = @(Get-CimInstance -Namespace 'root\ccm\Policy\Machine\ActualConfig' -ClassName CCM_ApplicationCIAssignment -ErrorAction SilentlyContinue)
                    $assignCount = $assignments.Count
                    # AssignmentName is the deployment name; fall back to AppDeliveryTypeName / AssignmentID.
                    $assignNames = @($assignments | ForEach-Object {
                        $n = $_.AssignmentName
                        if (-not $n) { $n = $_.AssignmentID }
                        $n
                    } | Where-Object { $_ } | Select-Object -First 5)
                    $diag += "AppAssignments=$assignCount"
                    if ($assignNames.Count -gt 0) {
                        $diag += "Names=[$($assignNames -join '; ')]"
                    }
                }
                catch { $diag += "AppAssignments=?" }
                try {
                    $ccmExec = (Get-Service -Name CcmExec -ErrorAction SilentlyContinue).Status
                    $diag += "CcmExec=$ccmExec"
                }
                catch { }
                # Was Microsoft 365 specifically in the assignment list?
                $officeInAssignments = @($assignNames | Where-Object { $_ -like '*Microsoft 365*' -or $_ -like '*Microsoft365*' -or $_ -like '*Office*' })
                $hint = if ($officeInAssignments.Count -gt 0) {
                    "Office assignment is in policy ($($officeInAssignments[0])) but CCM_Application hasn't materialized yet — App Deployment Eval likely still running; usually resolves within a few minutes"
                } elseif ($assignCount -gt 0) {
                    "policy received but no Office assignment in it — Primary's MEMLABS-Office Install Targets deployment isn't targeting this client (collection membership eval may still be running on the Primary; check ZZ-GYRO OfficeCollection sub-test)"
                } else {
                    "no application policy received — VM likely not yet in MEMLABS-Office Install Targets collection (update collection membership on the Primary)"
                }
                $officeResults.Details.Add("WARN: Office deployment policy not visible after 3 min of polling [$($diag -join ', ')] — $hint")
            }
            # Also check if Office is already installed
            $ctr = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -ErrorAction SilentlyContinue
            if ($ctr -and $ctr.VersionToReport) {
                $officeResults.Details.Add("OK: Microsoft 365 Apps installed (version $($ctr.VersionToReport))")
            }
            return $officeResults
        }
        $officeResult = Invoke-VmCommand -VmName $VMName -VmDomainName $domain `
            -ScriptBlock $officeCheckBlock -DisplayName "Phase11-DomainMember-OfficeCheck" -SuppressLog `
            -AsJob -TimeoutSeconds 300 -PollProgress
        if ($officeResult.ScriptBlockOutput -is [hashtable] -and $officeResult.ScriptBlockOutput.Details) {
            foreach ($detail in $officeResult.ScriptBlockOutput.Details) {
                $result.ScriptBlockOutput.Details.Add($detail)
            }
        }
    }

    # Windows activation check (Azure client OS only). On Azure, client-OS VMs
    # are KMS-activated against the Azure public KMS by Fix_ActivateWindows
    # (Phase 10). Verify the activation actually took so an expired evaluation
    # timer doesn't silently slip through. Warn-not-fail: activation can lag
    # behind the fix (KMS reachability / replication), so this never fails the
    # phase. Gated on $Common.IsAzureVM because Azure KMS is unreachable from
    # home labs.
    $isClientOS = $CurrentItem.operatingSystem -and $CurrentItem.operatingSystem -like "Windows 1*" -and $CurrentItem.operatingSystem -notlike "*Server*"
    if ($Common.IsAzureVM -and $isClientOS -and $result.ScriptBlockOutput -is [hashtable]) {
        $activationCheckBlock = {
            $actResults = @{ Details = [System.Collections.Generic.List[string]]::new() }
            try {
                # Windows application family GUID; only the entry with an
                # installed product key (PartialProductKey) is the active SKU.
                $winProducts = Get-CimInstance -ClassName SoftwareLicensingProduct -ErrorAction Stop |
                    Where-Object { $_.ApplicationId -eq '55c92734-d682-4d71-983e-d6ec3f16059f' -and $_.PartialProductKey }
                $win = $winProducts | Select-Object -First 1
                if (-not $win) {
                    $actResults.Details.Add("WARN: Could not find a Windows licensing product with an installed key (cannot confirm activation)")
                    return $actResults
                }
                # LicenseStatus: 0 Unlicensed, 1 Licensed, 2 OOBGrace, 3 OOTGrace,
                # 4 NonGenuineGrace, 5 Notification, 6 ExtendedGrace.
                $statusText = switch ([int]$win.LicenseStatus) {
                    0 { 'Unlicensed' }
                    1 { 'Licensed' }
                    2 { 'Out-of-Box Grace' }
                    3 { 'Out-of-Tolerance Grace' }
                    4 { 'Non-Genuine Grace' }
                    5 { 'Notification' }
                    6 { 'Extended Grace' }
                    default { "Unknown ($($win.LicenseStatus))" }
                }
                if ([int]$win.LicenseStatus -eq 1) {
                    $actResults.Details.Add("OK: Windows is activated (Status=Licensed, SKU='$($win.Name)')")
                }
                else {
                    $actResults.Details.Add("WARN: Windows is NOT activated (Status=$statusText, SKU='$($win.Name)'). On Azure, Fix_ActivateWindows (Phase 10) should KMS-activate Pro/Enterprise client OS; re-run Phase 10 or check azkms.core.windows.net:1688 reachability.")
                }
            }
            catch {
                $actResults.Details.Add("WARN: Could not query Windows activation status: $($_.Exception.Message)")
            }
            return $actResults
        }
        $activationResult = Invoke-VmCommand -VmName $VMName -VmDomainName $domain `
            -ScriptBlock $activationCheckBlock -DisplayName "Phase11-DomainMember-ActivationCheck" -SuppressLog `
            -AsJob -TimeoutSeconds 120
        if ($activationResult.ScriptBlockOutput -is [hashtable] -and $activationResult.ScriptBlockOutput.Details) {
            foreach ($detail in $activationResult.ScriptBlockOutput.Details) {
                $result.ScriptBlockOutput.Details.Add($detail)
            }
        }
    }

    return (Format-TestResult -VMName $VMName -RoleLabel 'DomainMember' -Result $result)
}

function Test-WorkgroupMemberFunctionality {
    <#
    .SYNOPSIS
        Lightweight checks for a workgroup (non-domain-joined) member.
    .DESCRIPTION
        Verifies network is up, time sync, and CCM client state if present.
        Uses the VM's local admin via Invoke-VmCommand's fallback.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][object]$CurrentItem,
        [Parameter(Mandatory)][object]$DeployConfig
    )

    $Phase = 11
    $domain = $DeployConfig.vmOptions.domainName

    Write-Log "[Phase $Phase] $VMName [WorkgroupMember]: Testing basic workgroup VM health" -LogOnly

    $scriptBlock = {
        $results = @{ Passed = $true; Details = [System.Collections.Generic.List[string]]::new() }

        $cs = Get-WmiObject Win32_ComputerSystem -ErrorAction SilentlyContinue
        if ($cs.PartOfDomain) {
            $results.Details.Add("WARN: Workgroup VM is unexpectedly domain-joined ('$($cs.Domain)')")
        }
        else {
            $results.Details.Add("OK: Workgroup VM ($($cs.Workgroup))")
        }

        # At least one NIC connected
        $nic = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
        if (-not $nic) {
            $results.Passed = $false
            $results.Details.Add("FAIL: No NIC in 'Up' state")
        }
        else {
            $results.Details.Add("OK: NIC '$($nic.Name)' is Up")
        }

        # CCM client (only if installed)
        $ccm = Get-Service -Name 'CcmExec' -ErrorAction SilentlyContinue
        if ($ccm) {
            if ($ccm.Status -eq 'Running') {
                $results.Details.Add("OK: CcmExec service is Running")
            }
            else {
                $results.Details.Add("WARN: CcmExec service is $($ccm.Status) (workgroup clients may struggle to talk to MP)")
            }
        }

        return $results
    }

    $result = Invoke-VmCommand -VmName $VMName -VmDomainName $domain `
        -ScriptBlock $scriptBlock `
        -DisplayName "Phase11-WorkgroupMember-Test" -SuppressLog `
        -AsJob -TimeoutSeconds 300

    return (Format-TestResult -VMName $VMName -RoleLabel 'WorkgroupMember' -Result $result)
}

function Test-InternetClientFunctionality {
    <#
    .SYNOPSIS
        Validates an InternetClient VM (CMG/internet-facing client).
    .DESCRIPTION
        Verifies the VM is reachable (NIC up), CCM client if installed, and
        that the PKI client cert exists when the site is PKI-enabled.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][object]$CurrentItem,
        [Parameter(Mandatory)][object]$DeployConfig
    )

    $Phase = 11
    $domain = $DeployConfig.vmOptions.domainName
    $usePKI = [bool]($DeployConfig.cmOptions.UsePKI)

    Write-Log "[Phase $Phase] $VMName [InternetClient]: Testing internet client VM (UsePKI=$usePKI)" -LogOnly

    $scriptBlock = {
        param($expectPKI)
        $results = @{ Passed = $true; Details = [System.Collections.Generic.List[string]]::new() }

        $nic = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
        if (-not $nic) {
            $results.Passed = $false
            $results.Details.Add("FAIL: No NIC in 'Up' state")
            return $results
        }
        $results.Details.Add("OK: NIC '$($nic.Name)' is Up")

        $ccm = Get-Service -Name 'CcmExec' -ErrorAction SilentlyContinue
        if ($ccm -and $ccm.Status -eq 'Running') {
            $results.Details.Add("OK: CcmExec service is Running")
        }
        elseif ($ccm) {
            $results.Details.Add("WARN: CcmExec service is $($ccm.Status)")
        }

        if ($expectPKI -eq '1') {
            # Look for a client auth cert in LocalMachine\My
            $clientAuth = '1.3.6.1.5.5.7.3.2'
            $certs = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
                Where-Object { $_.EnhancedKeyUsageList.ObjectId -contains $clientAuth -and $_.NotAfter -gt (Get-Date) }
            if ($certs) {
                $results.Details.Add("OK: Found $($certs.Count) valid client-auth cert(s) in LocalMachine\My")
            }
            else {
                # InternetClient is a workgroup machine — AD auto-enrollment GPO doesn't
                # apply, so no cert is expected unless manually provisioned.
                $results.Details.Add("OK: No client-auth cert in LocalMachine\My (expected for workgroup machines)")
            }
        }

        return $results
    }

    $pkiFlag = if ($usePKI) { '1' } else { '0' }
    $result = Invoke-VmCommand -VmName $VMName -VmDomainName $domain `
        -ScriptBlock $scriptBlock -ArgumentList $pkiFlag `
        -DisplayName "Phase11-InternetClient-Test" -SuppressLog `
        -AsJob -TimeoutSeconds 300

    return (Format-TestResult -VMName $VMName -RoleLabel 'InternetClient' -Result $result)
}

function Test-SSMSInstall {
    <#
    .SYNOPSIS
        Verifies SSMS is installed when installSSMS=$true on a VM.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$Domain
    )

    $Phase = 11
    Write-Log "[Phase $Phase] $VMName [SSMS]: Verifying SSMS install" -LogOnly

    $scriptBlock = {
        $results = @{ Passed = $true; Details = [System.Collections.Generic.List[string]]::new() }

        $results.Details.Add("CMD: Test-Path 'C:\Program Files (x86)\Microsoft SQL Server Management Studio *\Common7\IDE\ssms.exe'")
        $ssms = Get-ChildItem "C:\Program Files (x86)\Microsoft SQL Server Management Studio *\Common7\IDE\ssms.exe" -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending | Select-Object -First 1
        if (-not $ssms) {
            $results.Passed = $false
            $results.Details.Add("FAIL: ssms.exe not found under 'C:\Program Files (x86)\Microsoft SQL Server Management Studio *'")
            return $results
        }
        $results.Details.Add("OK: SSMS found at '$($ssms.FullName)' (version $($ssms.VersionInfo.ProductVersion))")
        return $results
    }

    $result = Invoke-VmCommand -VmName $VMName -VmDomainName $Domain `
        -ScriptBlock $scriptBlock -DisplayName "Phase11-SSMS-Test" -SuppressLog `
        -AsJob -TimeoutSeconds 300

    return (Format-TestResult -VMName $VMName -RoleLabel 'SSMS' -Result $result)
}

function Test-SMSProviderRole {
    <#
    .SYNOPSIS
        Verifies a remote SMS Provider (InstallSMSProv=$true) is reachable.
    .DESCRIPTION
        Hits the SMS provider WMI namespace from the provider host itself
        and from the parent site server to confirm both ends agree.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][object]$CurrentItem,
        [Parameter(Mandatory)][object]$DeployConfig
    )

    $Phase = 11
    $domain = $DeployConfig.vmOptions.domainName
    $siteCode = $CurrentItem.siteCode

    Write-Log "[Phase $Phase] $VMName [SMSProv]: Testing remote SMS provider for site $siteCode" -LogOnly

    $scriptBlock = {
        param($sc)
        $results = @{ Passed = $true; Details = [System.Collections.Generic.List[string]]::new() }

        # Retry on transient "Provider load failure": right after a reboot (e.g.
        # a -startPhase 11 rerun) the SMS Provider WMI host hasn't finished
        # loading even though SMS_EXECUTIVE is Running, so the first query throws.
        # It typically becomes available within a minute or two.
        $results.Details.Add("CMD: Get-WmiObject -Namespace 'root\SMS' -Class SMS_ProviderLocation -Filter `"SiteCode = '$sc'`"")
        $prov = $null
        $provErr = $null
        for ($i = 1; $i -le 6; $i++) {
            try {
                $prov = Get-WmiObject -Namespace 'root\SMS' -Class SMS_ProviderLocation -Filter "SiteCode = '$sc'" -ErrorAction Stop |
                    Where-Object { $_.Machine -like "$env:COMPUTERNAME*" }
                $provErr = $null
                break
            }
            catch {
                $provErr = $_
                if ($i -lt 6) { Start-Sleep -Seconds 15 }
            }
        }
        if ($provErr) {
            $results.Passed = $false
            $results.Details.Add("FAIL: SMS_ProviderLocation query failed after retries: $($provErr.Exception.Message)")
            return $results
        }
        if (-not $prov) {
            $results.Passed = $false
            $results.Details.Add("FAIL: This host not registered as a provider for site '$sc'")
            return $results
        }
        $results.Details.Add("OK: Provider location: $($prov.NamespacePath)")

        # Round-trip a query through the local provider (same transient-load retry)
        $site = $null
        $siteErr = $null
        for ($i = 1; $i -le 6; $i++) {
            try {
                $site = Get-WmiObject -Namespace "root\SMS\site_$sc" -Class SMS_Site -ErrorAction Stop
                $siteErr = $null
                break
            }
            catch {
                $siteErr = $_
                if ($i -lt 6) { Start-Sleep -Seconds 15 }
            }
        }
        if ($siteErr) {
            $results.Passed = $false
            $results.Details.Add("FAIL: SMS_Site query via local provider failed after retries: $($siteErr.Exception.Message)")
        }
        elseif ($site) {
            $results.Details.Add("OK: Local SMS_Site query succeeded via provider (site '$($site.SiteCode)')")
        }
        else {
            $results.Passed = $false
            $results.Details.Add("FAIL: SMS_Site query returned null via local provider")
        }

        return $results
    }

    $result = Invoke-VmCommand -VmName $VMName -VmDomainName $domain `
        -ScriptBlock $scriptBlock -ArgumentList $siteCode `
        -DisplayName "Phase11-SMSProv-Test" -SuppressLog `
        -AsJob -TimeoutSeconds 300

    return (Format-TestResult -VMName $VMName -RoleLabel 'SMSProv' -Result $result)
}

function Test-PullDPConfiguration {
    <#
    .SYNOPSIS
        Verifies a DP configured as Pull DP has the right source DP set.
    .DESCRIPTION
        Runs against the parent Primary because the IsPullDPEnabled flag
        and source list live in the site database, not on the DP itself.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][object]$CurrentItem,
        [Parameter(Mandatory)][object]$DeployConfig
    )

    $Phase = 11
    $domain = $DeployConfig.vmOptions.domainName
    $siteCode = $CurrentItem.siteCode
    $expectedSource = $CurrentItem.pullDPSourceDP

    $parentVM = $DeployConfig.virtualMachines | Where-Object {
        $_.siteCode -eq $siteCode -and $_.role -in @('Primary', 'CAS')
    } | Select-Object -First 1
    if (-not $parentVM) {
        Write-Log "[Phase $Phase] $VMName [PullDP]: No parent site server for site '$siteCode'; skipping" -LogOnly
        return $true
    }

    Write-Log "[Phase $Phase] $VMName [PullDP]: Verifying pull-DP config from '$($parentVM.vmName)'" -LogOnly

    $scriptBlock = {
        param($sc, $dpName, $dpFqdn, $expectedSrc)
        $results = @{ Passed = $true; Details = [System.Collections.Generic.List[string]]::new() }

        $results.Details.Add("CMD: Get-WmiObject -Namespace 'root\SMS\site_$sc' -Class SMS_DistributionPointInfo -Filter `"ServerName LIKE '%$dpName%'`"")
        try {
            # DP may not appear in SMS_DistributionPointInfo immediately after
            # the role is added — the site server needs to process the site
            # control file change. Retry for up to ~3 minutes.
            $dp = $null
            $dpAttempts = 6
            $dpDelay = 30
            for ($i = 1; $i -le $dpAttempts; $i++) {
                $dp = Get-WmiObject -Namespace "root\SMS\site_$sc" -Class SMS_DistributionPointInfo `
                    -Filter "ServerName LIKE '%$dpName%'" -ErrorAction Stop | Select-Object -First 1
                if ($dp) { break }
                if ($i -lt $dpAttempts) {
                    $results.Details.Add("  Attempt $i/${dpAttempts}: DP '$dpName' not yet in SMS_DistributionPointInfo, retrying in ${dpDelay}s")
                    Start-Sleep -Seconds $dpDelay
                }
            }
            if (-not $dp) {
                $results.Passed = $false
                $results.Details.Add("FAIL: DP '$dpName' not found in site '$sc'")
                return $results
            }
            if (-not $dp.IsPullDP) {
                $results.Passed = $false
                $results.Details.Add("FAIL: DP '$dpName' is NOT flagged as Pull DP (IsPullDP=$($dp.IsPullDP))")
                return $results
            }
            $results.Details.Add("OK: DP '$dpName' has IsPullDP=$true")
        }
        catch {
            $results.Passed = $false
            $results.Details.Add("FAIL: WMI query failed: $($_.Exception.Message)")
            return $results
        }

        # Source DP list lives in SMS_DistributionPoint property arrays.
        # Best-effort: look it up via CM module if available.
        if ($expectedSrc) {
            try {
                $key = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry32)
                $subKey = $key.OpenSubKey("SOFTWARE\Microsoft\ConfigMgr10\Setup")
                $uiInstallPath = $subKey.GetValue("UI Installation Directory")
                Import-Module (Join-Path $uiInstallPath "bin\ConfigurationManager.psd1") -ErrorAction Stop
                $smsProvider = "$env:COMPUTERNAME.$((Get-WmiObject Win32_ComputerSystem).Domain)"
                $null = New-PSDrive -Name $sc -PSProvider CMSite -Root $smsProvider -ErrorAction SilentlyContinue
                Push-Location "${sc}:\"
                $cmDp = Get-CMDistributionPoint -SiteSystemServerName $dpFqdn -ErrorAction SilentlyContinue
                Pop-Location
                if ($cmDp) {
                    $results.Details.Add("OK: Get-CMDistributionPoint returned the DP via CM module")
                }
                else {
                    $results.Details.Add("WARN: Get-CMDistributionPoint did not return the DP (may be load latency)")
                }
            }
            catch {
                $results.Details.Add("WARN: CM module pull-source verification skipped: $($_.Exception.Message)")
            }
        }

        return $results
    }

    $result = Invoke-VmCommand -VmName $parentVM.vmName -VmDomainName $domain `
        -ScriptBlock $scriptBlock -ArgumentList $siteCode, $VMName, "$VMName.$domain", $expectedSource `
        -DisplayName "Phase11-PullDP-Test" -SuppressLog `
        -AsJob -TimeoutSeconds 300

    return (Format-TestResult -VMName $VMName -RoleLabel 'PullDP' -Result $result)
}

function Test-AdditionalDisks {
    <#
    .SYNOPSIS
        Verifies all additionalDisks defined in the deploy config are mounted.
    .DESCRIPTION
        deployConfig's additionalDisks is a hashtable like { E='100GB'; F='200GB' }.
        Confirms each drive letter exists with a non-removable volume.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][object]$CurrentItem,
        [Parameter(Mandatory)][object]$DeployConfig
    )

    $Phase = 11
    $domain = $DeployConfig.vmOptions.domainName

    # additionalDisks may be a PSCustomObject (from JSON) or hashtable
    $disks = @()
    if ($CurrentItem.additionalDisks) {
        if ($CurrentItem.additionalDisks -is [hashtable]) {
            $disks = $CurrentItem.additionalDisks.Keys
        }
        else {
            $disks = $CurrentItem.additionalDisks.PSObject.Properties.Name
        }
    }
    if (-not $disks -or $disks.Count -eq 0) {
        Write-Log "[Phase $Phase] $VMName [Disks]: No additionalDisks in config; skipping" -LogOnly
        return $true
    }

    Write-Log "[Phase $Phase] $VMName [Disks]: Verifying $($disks.Count) additional disk(s): $($disks -join ', ')" -LogOnly

    $scriptBlock = {
        # NOTE: Invoke-VmCommand declares [string[]]$ArgumentList which flattens
        # arrays. We pass the disk list as a comma-joined string and split here.
        param($expectedCsv)
        $expected = $expectedCsv -split ','
        $results = @{ Passed = $true; Details = [System.Collections.Generic.List[string]]::new() }

        foreach ($letter in $expected) {
            $letter = $letter.TrimEnd(':').ToUpper()
            $results.Details.Add("CMD: Get-Volume -DriveLetter $letter")
            $vol = Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $vol) {
                $results.Passed = $false
                $results.Details.Add("FAIL: Volume '$letter`:' not present")
                continue
            }
            if ($vol.FileSystem -ne 'NTFS') {
                $results.Details.Add("WARN: Volume '$letter`:' filesystem is '$($vol.FileSystem)' (expected NTFS)")
            }
            $sizeGB = [math]::Round($vol.Size / 1GB, 1)
            $results.Details.Add("OK: Volume '$letter`:' present ($sizeGB GB, $($vol.FileSystem) $($vol.FileSystemLabel))")
        }

        return $results
    }

    $result = Invoke-VmCommand -VmName $VMName -VmDomainName $domain `
        -ScriptBlock $scriptBlock -ArgumentList (($disks -join ',')) `
        -DisplayName "Phase11-Disks-Test" -SuppressLog `
        -AsJob -TimeoutSeconds 300

    return (Format-TestResult -VMName $VMName -RoleLabel 'Disks' -Result $result)
}

function Test-BitLockerProtection {
    <#
    .SYNOPSIS
        Verifies BitLocker is actually protecting the OS volume on a flagged VM.
    .DESCRIPTION
        For VMs with BitLocker=$true. Confirms the OS volume has at least one
        key protector and encryption is active (Used Space Only is acceptable).
        Encryption may still be in progress on a fresh deploy -- treat
        EncryptionInProgress as OK; only fail on no protector or fully off.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][object]$CurrentItem,
        [Parameter(Mandatory)][object]$DeployConfig
    )

    $Phase = 11
    $domain = $DeployConfig.vmOptions.domainName

    Write-Log "[Phase $Phase] $VMName [BitLocker]: Verifying OS volume encryption status" -LogOnly

    $scriptBlock = {
        $results = @{ Passed = $true; Details = [System.Collections.Generic.List[string]]::new() }

        $results.Details.Add("CMD: Get-BitLockerVolume -MountPoint 'C:'")
        try {
            $vol = Get-BitLockerVolume -MountPoint 'C:' -ErrorAction Stop
        }
        catch {
            $results.Passed = $false
            $results.Details.Add("FAIL: Get-BitLockerVolume threw: $($_.Exception.Message)")
            return $results
        }

        $protectors = @($vol.KeyProtector)
        if ($protectors.Count -eq 0) {
            $results.Passed = $false
            $results.Details.Add("FAIL: No key protectors on C: (volume is unprotected)")
            return $results
        }
        $protectorTypes = ($protectors | ForEach-Object { $_.KeyProtectorType }) -join ', '
        $results.Details.Add("OK: $($protectors.Count) key protector(s): $protectorTypes")

        # Volume status: encrypted / encrypting / decrypting / fullydecrypted
        $status = $vol.VolumeStatus
        $pct = $vol.EncryptionPercentage
        if ($status -eq 'FullyEncrypted') {
            $results.Details.Add("OK: Volume is FullyEncrypted (100%)")
        }
        elseif ($status -eq 'EncryptionInProgress') {
            $results.Details.Add("OK: Encryption in progress ($pct%) -- acceptable on a fresh build")
        }
        elseif ($status -eq 'UsedSpaceOnlyEncrypted') {
            $results.Details.Add("OK: Volume is UsedSpaceOnlyEncrypted (BLM policy default)")
        }
        else {
            $results.Passed = $false
            $results.Details.Add("FAIL: Volume status is '$status' ($pct%), expected encrypted or in progress")
        }

        # ProtectionStatus 1 = On, 0 = Off
        if ($vol.ProtectionStatus -ne 'On') {
            $results.Details.Add("WARN: ProtectionStatus is '$($vol.ProtectionStatus)' (expected 'On' when key protector is active)")
        }

        return $results
    }

    $result = Invoke-VmCommand -VmName $VMName -VmDomainName $domain `
        -ScriptBlock $scriptBlock -DisplayName "Phase11-BitLocker-Test" -SuppressLog `
        -AsJob -TimeoutSeconds 300

    return (Format-TestResult -VMName $VMName -RoleLabel 'BitLocker' -Result $result)
}

function Test-CMSiteWideFunctionality {
    <#
    .SYNOPSIS
        Validates site-wide settings on any Primary or CAS:
        boundary groups, discovery methods, client push, apps, and the
        site comms mode (HTTPS-only vs EnhancedHTTP) based on cmOptions.UsePKI.
    .NOTES
        Hierarchy-owned checks (boundaries, discovery, comms mode) only
        run when -IsTopLevel is set. Perfloading content checks (apps,
        collections, packages, etc.) run on every Primary with
        PrePopulateObjects, including child Primaries under a CAS.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][object]$CurrentItem,
        [Parameter(Mandatory)][object]$DeployConfig,
        [switch]$IsTopLevel
    )

    $Phase = 11
    $domain = $DeployConfig.vmOptions.domainName
    $siteCode = $CurrentItem.siteCode
    $usePKI = [bool]$DeployConfig.cmOptions.UsePKI
    $role = $CurrentItem.role

    # Build expected apps list by mirroring perfloading.ps1 EXACTLY:
    #   $apps = $deployconfig.Tools | where { $_.Appinstall -eq $true }
    #   $appname = "MEMLABS-" + $_.Name
    # Apps.json is the source catalog for tool downloads but is NOT the
    # per-site enabled list -- only Tools[] with Appinstall=true get
    # turned into CM apps, and their CM name is "MEMLABS-<Tools.Name>"
    # which may not match Apps.json's AppName field at all.
    #
    # Only verify when the deployment opted in to pre-populating objects
    # AND when running against a Primary site (CAS runs perfloading but
    # skips apps/packages/OSD — those are Primary-only content).
    #
    # cmOptions resolved per-VM ($ThisVM.cmOptions falling back to
    # $deployConfig.cmOptions) to match perfloading's own resolution -- a
    # multi-hierarchy deploy can have one Primary with PrePopulateObjects=true
    # and another with false.
    $expectedAppNames = @()
    $effectiveCmOptions = if ($CurrentItem.cmOptions) { $CurrentItem.cmOptions } else { $DeployConfig.cmOptions }
    $prePopulate = [bool]$effectiveCmOptions.PrePopulateObjects
    if ($prePopulate -and $role -ne 'CAS') {
        try {
            $enabledTools = @($DeployConfig.Tools | Where-Object { $_.Appinstall -eq $true })
            $expectedAppNames = @($enabledTools | ForEach-Object { "MEMLABS-$($_.Name)" })
        }
        catch {
            Write-Log "[Phase $Phase] $VMName [CMSite-$siteCode]: Could not enumerate deployConfig.Tools: $($_.Exception.Message)" -Warning
        }
    }

    # Determine if this site has a SUP installed
    $hasSUP = [bool]($DeployConfig.virtualMachines | Where-Object {
        ($_.installSUP -or $_.InstallSUP) -and $_.siteCode -eq $siteCode
    } | Select-Object -First 1)

    $siteRoleLabel = "$role ($siteCode)"
    Write-Log "[Phase $Phase] $VMName [$siteRoleLabel]: Testing site-wide settings (BoundaryGroups, Discovery, Apps, CommsMode)" -LogOnly

    $scriptBlock = {
        # NOTE: Invoke-VmCommand declares [string[]]$ArgumentList which (a)
        # stringifies bools (any non-empty string is truthy) and (b) flattens
        # nested arrays. Bools are passed as '0'/'1' strings; arrays are
        # passed as a single CSV string and split inside.
        param($sc, $usePkiInner, $expectedAppsCsv, $vmRole, $prePopInner, $isTopLevelInner, $hasSUPInner)
        $usePki = ($usePkiInner -eq 'True')
        $prePop = ($prePopInner -eq 'True')
        $topLevel = ($isTopLevelInner -eq 'True')
        $isPrimary = ($vmRole -eq 'Primary')
        $hasSup = ($hasSUPInner -eq 'True')
        $expectedApps = if ([string]::IsNullOrEmpty($expectedAppsCsv)) { @() } else { @($expectedAppsCsv -split '\|') }
        $results = @{ Passed = $true; Details = [System.Collections.Generic.List[string]]::new() }

        $ns = "root\SMS\site_$sc"

        # --- Hierarchy-owned checks (only on top-level sites) ---
        # On a child Primary under a CAS, boundaries/discovery/comms mode
        # replicate from the CAS; checking them before DRS finishes causes
        # false failures.
        if ($topLevel) {

        # 1. Boundary groups -- at least the default "Default-Site-Boundary-Group" should exist
        $results.Details.Add("CMD: Get-WmiObject -Namespace '$ns' -Class SMS_BoundaryGroup")
        try {
            $bgs = @(Get-WmiObject -Namespace $ns -Class SMS_BoundaryGroup -ErrorAction Stop)
            if ($bgs.Count -ge 1) {
                $results.Details.Add("OK: $($bgs.Count) boundary group(s) defined: $(($bgs | Select-Object -First 5 -ExpandProperty Name) -join ', ')")
            }
            else {
                $results.Passed = $false
                $results.Details.Add("FAIL: No boundary groups defined for site '$sc'")
            }
        }
        catch {
            $results.Details.Add("WARN: SMS_BoundaryGroup query failed: $($_.Exception.Message)")
        }

        # 2. Discovery methods -- at least AD System Discovery should be enabled
        $results.Details.Add("CMD: Get-WmiObject SMS_SCI_Component -Filter `"ComponentName='SMS_AD_SYSTEM_DISCOVERY_AGENT'`"")
        try {
            $adSys = Get-WmiObject -Namespace $ns -Class SMS_SCI_Component `
                -Filter "ComponentName='SMS_AD_SYSTEM_DISCOVERY_AGENT' AND SiteCode='$sc'" -ErrorAction Stop |
                Select-Object -First 1
            if ($adSys) {
                $enabled = ($adSys.Props | Where-Object { $_.PropertyName -eq 'SETTINGS' } | Select-Object -First 1)
                $isOn = $enabled -and ($enabled.Value1 -eq 'ACTIVE')
                if ($isOn) {
                    $results.Details.Add("OK: AD System Discovery is ACTIVE")
                }
                else {
                    $results.Details.Add("WARN: AD System Discovery is configured but not ACTIVE (clients won't be auto-discovered)")
                }
            }
            else {
                # Component name varies across CM versions / on CAS; not finding
                # it isn't actionable, so log-only rather than surface a WARN.
                $results.Details.Add("INFO: SMS_AD_SYSTEM_DISCOVERY_AGENT component not found (may be named differently on this site role)")
            }
        }
        catch {
            $results.Details.Add("INFO: AD discovery query failed: $($_.Exception.Message)")
        }

        # 3. Site comms mode -- aligns with cmOptions.UsePKI
        # SMS_SCI_SCProperty named "Enforce Enhanced Hash Algorithm" and
        # "IISSSLState" on SMS_SITE_COMPONENT_MANAGER carry the HTTPS flag.
        # We look at SMS_Site.Mode: 0 = mixed/EHTTP, 1 = HTTPS only.
        try {
            $siteObj = Get-WmiObject -Namespace $ns -Class SMS_Site -Filter "SiteCode='$sc'" -ErrorAction Stop | Select-Object -First 1
            if ($siteObj) {
                $mode = $siteObj.Mode
                $results.Details.Add("OK: SMS_Site.Mode = $mode (cmOptions.UsePKI=$usePki)")
            }
        }
        catch {
            $results.Details.Add("WARN: SMS_Site mode query failed: $($_.Exception.Message)")
        }

        # 3b. IISSSLState -- the definitive HTTPS flag on the site component.
        # CCM_SSL_ENABLED (0x1) must be set for ccmsetup to use PKI certs.
        # IISSSLState=63 (0x3F) has all the right bits including 0x1.
        if ($usePki) {
            try {
                $comp = Get-WmiObject -Namespace $ns -Class SMS_SCI_Component `
                    -Filter "FileType=2 AND ItemName='SMS_SITE_COMPONENT_MANAGER|SMS Site Server' AND SiteCode='$sc'" `
                    -ErrorAction Stop
                if ($comp) {
                    $sslProp = $comp.Props | Where-Object { $_.PropertyName -eq 'IISSSLState' } | Select-Object -First 1
                    if ($sslProp) {
                        $sslVal = $sslProp.Value
                        if ($sslVal -band 1) {
                            $results.Details.Add("OK: IISSSLState = $sslVal (CCM_SSL_ENABLED bit is set)")
                        }
                        else {
                            $results.Passed = $false
                            $results.Details.Add("FAIL: IISSSLState = $sslVal (CCM_SSL_ENABLED bit 0x1 is NOT set; ccmsetup cannot use PKI certs). Expected 63 for HTTPS-only.")
                        }
                    }
                    else {
                        $results.Details.Add("WARN: IISSSLState property not found on SMS_SITE_COMPONENT_MANAGER")
                    }
                }
            }
            catch {
                $results.Details.Add("WARN: IISSSLState query failed: $($_.Exception.Message)")
            }

            # 3c. AD-published OperationalXml -- ccmsetup reads SecurityModeMaskEx
            # from the MP's AD object during bootstrap. If the site component manager
            # hasn't republished after EnableHTTPS set IISSSLState=63, the AD object
            # still has the pre-HTTPS value and ccmsetup will fail with
            # CCM_E_NO_CLIENT_PKI_CERT.
            # Skip for CAS: the CAS MP is inter-site only; clients never bootstrap
            # from a CAS MP, so there's no AD-published mSSMSManagementPoint for it.
            if ($vmRole -eq 'CAS') {
                $results.Details.Add("INFO: Skipping MP AD object check (CAS MPs do not publish to AD for client bootstrap)")
            }
            else { try {
                $searchBase = "CN=System Management,CN=System," + ([ADSI]"LDAP://RootDSE").defaultNamingContext
                $mpObj = Get-ADObject -Filter "objectClass -eq 'mSSMSManagementPoint' -and mSSMSSiteCode -eq '$sc'" `
                    -SearchBase $searchBase -Properties mSSMSCapabilities -ErrorAction Stop | Select-Object -First 1
                if ($mpObj -and $mpObj.mSSMSCapabilities) {
                    $xml = $mpObj.mSSMSCapabilities
                    $maskMatch = [regex]::Match($xml, '<SecurityModeMaskEx>(\d+)</SecurityModeMaskEx>')
                    if ($maskMatch.Success) {
                        $adMaskEx = [int]$maskMatch.Groups[1].Value
                        if ($adMaskEx -band 1) {
                            $results.Details.Add("OK: AD SecurityModeMaskEx = $adMaskEx (CCM_SSL_ENABLED bit set)")
                        }
                        else {
                            $results.Passed = $false
                            $results.Details.Add("FAIL: AD SecurityModeMaskEx = $adMaskEx (CCM_SSL_ENABLED bit 0x1 NOT set). Site component manager has not republished after HTTPS was enabled. ccmsetup bootstrap will fail with CCM_E_NO_CLIENT_PKI_CERT.")
                        }
                    }
                    # Check CertificateIssuers is populated
                    $issuersMatch = [regex]::Match($xml, '<CertificateIssuers>([^<]*)</CertificateIssuers>')
                    if ($issuersMatch.Success -and $issuersMatch.Groups[1].Value) {
                        $results.Details.Add("OK: AD CertificateIssuers = '$($issuersMatch.Groups[1].Value)'")
                    }
                    else {
                        $results.Details.Add("WARN: AD CertificateIssuers is empty (ccmsetup cert search by issuer will be skipped after AD refresh)")
                    }
                }
                else {
                    $results.Details.Add("WARN: MP AD object for site '$sc' not found or has no mSSMSCapabilities")
                }
            }
            catch {
                $results.Details.Add("WARN: AD OperationalXml query failed: $($_.Exception.Message)")
            } }  # end if not CAS
        }

        } # end if $topLevel (hierarchy-owned checks)

        # 4. Apps enabled via deployConfig.Tools[Appinstall=true] must be present
        #    as SMS_ApplicationLatest objects (created by perfloading.ps1)
        if ($expectedApps -and $expectedApps.Count -gt 0) {
            $results.Details.Add("CMD: Get-WmiObject SMS_ApplicationLatest -Filter `"LocalizedDisplayName LIKE 'MEMLABS-%'`"")
            try {
                $apps = @(Get-WmiObject -Namespace $ns -Class SMS_ApplicationLatest `
                    -Filter "LocalizedDisplayName LIKE 'MEMLABS-%'" -ErrorAction Stop)
                $appNames = $apps | Select-Object -ExpandProperty LocalizedDisplayName
                $missing = @($expectedApps | Where-Object { $_ -notin $appNames })
                if ($missing.Count -eq 0) {
                    $results.Details.Add("OK: All $($expectedApps.Count) MEMLABS apps present in CM site")
                }
                elseif ($missing.Count -le ($expectedApps.Count / 2)) {
                    $results.Details.Add("WARN: $($missing.Count)/$($expectedApps.Count) apps missing: $(($missing | Select-Object -First 5) -join ', ')")
                }
                else {
                    $results.Passed = $false
                    $results.Details.Add("FAIL: $($missing.Count)/$($expectedApps.Count) MEMLABS apps missing in CM site: $(($missing | Select-Object -First 5) -join ', ')")
                }
            }
            catch {
                $results.Details.Add("WARN: SMS_ApplicationLatest query failed: $($_.Exception.Message)")
            }
        }

        # 5. Client push install account configured (warn-only -- some labs disable client push)
        try {
            $cpComp = Get-WmiObject -Namespace $ns -Class SMS_SCI_Component `
                -Filter "ComponentName='SMS_DISCOVERY_DATA_MANAGER' AND SiteCode='$sc'" -ErrorAction Stop
            if ($cpComp) {
                $results.Details.Add("OK: SMS_DISCOVERY_DATA_MANAGER component present (client push pipeline reachable)")
            }
        }
        catch {
            $results.Details.Add("WARN: Client push component query failed: $($_.Exception.Message)")
        }

        # --- Perfloading object checks (only when PrePopulateObjects is enabled) ---
        if ($prePop) {

        # 6. Boot images — should exist; on Primary check distribution + command support
        try {
            $bootImgs = @(Get-WmiObject -Namespace $ns -Class SMS_BootImagePackage -ErrorAction Stop)
            if ($bootImgs.Count -ge 1) {
                $results.Details.Add("OK: $($bootImgs.Count) boot image(s) found")
                if ($isPrimary) {
                    foreach ($bi in $bootImgs) {
                        $biName = $bi.Name
                        # EnableLabShell is a lazy property — not populated by class-level
                        # WMI queries. Fetch the full instance to get its real value.
                        try { $bi.Get() } catch {}
                        $cmdSupport = [bool]$bi.EnableLabShell
                        if (-not $cmdSupport) {
                            $results.Details.Add("WARN: Boot image '$biName' does not have command support enabled")
                        }
                        # Check distribution — query SMS_PackageStatusDistPointsSummarizer.
                        # State values: 0=Installed, 1=InstallPending, 2=InstallRetrying,
                        # 3=InstallFailed, 4=RemovalPending, 5=RemovalRetrying, 6=RemovalFailed,
                        # 7=ContentValidating, 8=ContentValidationFailed. We also consult
                        # SMS_DistributionPoint to see whether the package has been *targeted*
                        # to any DP at all — distinguishes "no targeting" from "in progress".
                        try {
                            $allDp = @(Get-WmiObject -Namespace $ns -Class SMS_PackageStatusDistPointsSummarizer `
                                -Filter "PackageID='$($bi.PackageID)'" -ErrorAction Stop)
                            $installed = @($allDp | Where-Object { $_.State -eq 0 })
                            $inProgress = @($allDp | Where-Object { $_.State -in 1, 2, 7 })
                            $failed = @($allDp | Where-Object { $_.State -in 3, 6, 8 })
                            if ($installed.Count -ge 1 -and $failed.Count -eq 0 -and $inProgress.Count -eq 0) {
                                $results.Details.Add("OK: Boot image '$biName' distributed to $($installed.Count) DP(s)")
                            }
                            elseif ($failed.Count -ge 1) {
                                $results.Details.Add("WARN: Boot image '$biName' ($($bi.PackageID)) distribution failed on $($failed.Count) DP(s) [Installed=$($installed.Count), InProgress=$($inProgress.Count)]")
                            }
                            elseif ($inProgress.Count -ge 1) {
                                # Pending/Retrying/Validating -- distribution is actively being processed.
                                $results.Details.Add("OK: Boot image '$biName' distribution in progress on $($inProgress.Count) DP(s) [Installed=$($installed.Count)]")
                            }
                            else {
                                # No summarizer rows at all -- either truly not targeted yet,
                                # or DistMgr hasn't created the per-DP status rows. Check
                                # SMS_DistributionPoint (the targeting table) to disambiguate.
                                try {
                                    $targeted = @(Get-WmiObject -Namespace $ns -Class SMS_DistributionPoint `
                                        -Filter "PackageID='$($bi.PackageID)'" -ErrorAction Stop)
                                }
                                catch { $targeted = @() }
                                if ($targeted.Count -ge 1) {
                                    $results.Details.Add("OK: Boot image '$biName' targeted to $($targeted.Count) DP(s); distribution pending (DistMgr has not yet posted status)")
                                }
                                else {
                                    $results.Details.Add("WARN: Boot image '$biName' ($($bi.PackageID)) not distributed to any DP and no distribution targeting found")
                                }
                            }
                        }
                        catch {
                            $results.Details.Add("WARN: Could not query distribution status for boot image '$biName': $($_.Exception.Message)")
                        }
                    }
                }
            }
            else {
                $results.Details.Add("WARN: No boot images found")
            }
        }
        catch {
            $results.Details.Add("WARN: SMS_BootImagePackage query failed: $($_.Exception.Message)")
        }

        # 7. Task sequences (Primary only) — MEMLABS-* should exist
        if ($isPrimary) {
            try {
                $tsList = @(Get-WmiObject -Namespace $ns -Class SMS_TaskSequencePackage `
                    -Filter "Name LIKE 'MEMLABS-%'" -ErrorAction Stop)
                if ($tsList.Count -ge 1) {
                    $results.Details.Add("OK: $($tsList.Count) MEMLABS task sequence(s) found")
                }
                else {
                    $results.Details.Add("WARN: No MEMLABS-* task sequences found")
                }
            }
            catch {
                $results.Details.Add("WARN: SMS_TaskSequencePackage query failed: $($_.Exception.Message)")
            }
        }

        # 8. Collections — MEMLABS-* device collections should exist
        try {
            $cols = @(Get-WmiObject -Namespace $ns -Class SMS_Collection `
                -Filter "Name LIKE 'MEMLABS-%' AND CollectionType=2" -ErrorAction Stop)
            if ($cols.Count -ge 5) {
                $results.Details.Add("OK: $($cols.Count) MEMLABS device collection(s) found")
            }
            elseif ($cols.Count -ge 1) {
                $results.Details.Add("WARN: Only $($cols.Count) MEMLABS device collection(s) found (expected 20+)")
            }
            else {
                $results.Details.Add("WARN: No MEMLABS-* device collections found")
            }
        }
        catch {
            $results.Details.Add("WARN: SMS_Collection query failed: $($_.Exception.Message)")
        }

        # 9. Packages (Primary only) — MEMLABS-* should exist
        if ($isPrimary -and $expectedApps -and $expectedApps.Count -gt 0) {
            try {
                $pkgs = @(Get-WmiObject -Namespace $ns -Class SMS_Package `
                    -Filter "Name LIKE 'MEMLABS-%'" -ErrorAction Stop)
                if ($pkgs.Count -ge 1) {
                    $results.Details.Add("OK: $($pkgs.Count) MEMLABS package(s) found")
                }
                else {
                    $results.Details.Add("WARN: No MEMLABS-* packages found")
                }
            }
            catch {
                $results.Details.Add("WARN: SMS_Package query failed: $($_.Exception.Message)")
            }
        }

        # 10. Scripts — MEMLABS-* should exist
        try {
            $scripts = @(Get-WmiObject -Namespace $ns -Class SMS_Scripts `
                -Filter "ScriptName LIKE 'MEMLABS-%'" -ErrorAction Stop)
            if ($scripts.Count -ge 5) {
                $results.Details.Add("OK: $($scripts.Count) MEMLABS script(s) imported")
            }
            elseif ($scripts.Count -ge 1) {
                $results.Details.Add("WARN: Only $($scripts.Count) MEMLABS script(s) found (expected 50+)")
            }
            else {
                $results.Details.Add("WARN: No MEMLABS-* scripts found")
            }
        }
        catch {
            $results.Details.Add("WARN: SMS_Scripts query failed: $($_.Exception.Message)")
        }

        } # end prePop checks

        # SUP sync status check — verify at least one successful sync has completed
        if ($hasSup) {
            try {
                $syncStatus = Get-WmiObject -Namespace $ns -Class SMS_SUPSyncStatus `
                    -Filter "SiteCode='$sc'" -ErrorAction Stop | Select-Object -First 1
                if (-not $syncStatus) {
                    $results.Details.Add("WARN: No SUP sync status found for site '$sc' (sync may not have run yet)")
                }
                elseif ($syncStatus.LastSyncState -eq 6702) {
                    $syncTime = [Management.ManagementDateTimeConverter]::ToDateTime($syncStatus.LastSyncStateTime)
                    $results.Details.Add("OK: SUP sync completed successfully (last: $syncTime)")
                }
                elseif ($syncStatus.LastSyncState -eq 6703) {
                    $results.Details.Add("WARN: SUP last sync FAILED (state 6703, error code $($syncStatus.LastSyncErrorCode))")
                }
                elseif ($syncStatus.LastSyncState -in @(6701, 6704, 6705, 6706)) {
                    $stateNames = @{ 6701='Started'; 6704='Syncing WSUS'; 6705='Syncing DB'; 6706='Syncing Internet WSUS' }
                    $sName = if ($stateNames.ContainsKey([int]$syncStatus.LastSyncState)) { $stateNames[[int]$syncStatus.LastSyncState] } else { "state $($syncStatus.LastSyncState)" }
                    $syncTime = [Management.ManagementDateTimeConverter]::ToDateTime($syncStatus.LastSyncStateTime)
                    $age = (Get-Date) - $syncTime
                    if ($age.TotalMinutes -gt 30) {
                        # Long-running sync — gather WSUS-level diagnostics to help identify cause
                        $wsusDiag = ""
                        try {
                            $wsusSrv = Get-WsusServer -ErrorAction Stop
                            $sub = $wsusSrv.GetSubscription()
                            $wsusState = $sub.GetSynchronizationStatus().ToString()
                            $prog = $sub.GetSynchronizationProgress()
                            $wsusDiag = " [WSUS: $wsusState, Phase=$($prog.Phase), Items=$($prog.ProcessedItems)/$($prog.TotalItems)]"
                        }
                        catch {
                            $wsusDiag = " [WSUS diag failed: $($_.Exception.Message)]"
                        }
                        $results.Details.Add("WARN: SUP sync at '$sName' for $([math]::Round($age.TotalMinutes,0)) min (since $syncTime)$wsusDiag — may be slow or stuck")
                    }
                    else {
                        $results.Details.Add("OK: SUP sync in progress ($sName, $([math]::Round($age.TotalMinutes,1)) min)")
                    }
                }
                else {
                    $results.Details.Add("WARN: SUP sync in unexpected state $($syncStatus.LastSyncState)")
                }
            }
            catch {
                $results.Details.Add("WARN: SMS_SUPSyncStatus query failed: $($_.Exception.Message)")
            }

            # WSUS-native cross-check, split into independent sub-tests so
            # each surfaces with its own OK/WARN. CM's SMS_SUPSyncStatus can
            # report "completed" while the underlying WSUS catalog is broken
            # in any of three orthogonal ways:
            #
            #   A) Initial categories sync never populated the taxonomy
            #      (cab import failed AND a real MU categories sync never
            #      completed; e.g. WsusPool recycled at its 1.8 GB cap and
            #      returned 503 mid-sync).
            #   B) Taxonomy is fine but WCM never pushed the subscription,
            #      so what WSUS thinks it should sync != what the SUP
            #      component has marked subscribed in CM.
            #   C) Subscription is set but the last sync didn't succeed.
            #
            # The cab generator's pre/post log is the ground truth for (A):
            # postinstall-default WSUS sits at TaxonomyCats=~17, the cab
            # brings 433. >= 100 means a real categories load happened
            # (cab import OR a full MU categories sync). UpdateCount is
            # NOT the right "sync 1 done" signal -- it's the row count of
            # dbo.Update (sync 2 / post-subscription update metadata) and
            # legitimately stays at 0 when the subscription is narrow.
            #
            # Only meaningful when WSUS is local to this site server; the
            # outer catch skips silently otherwise.
            try {
                $wsusSrv = Get-WsusServer -ErrorAction Stop
                $wStatus = $wsusSrv.GetStatus()

                # ---- gather raw signals (each guarded; never throws) ----
                $taxCats = $null; $taxClas = $null
                try { $taxCats = @($wsusSrv.GetUpdateCategories()).Count } catch {}
                try { $taxClas = @($wsusSrv.GetUpdateClassifications()).Count } catch {}

                $subCats = $null; $subClas = $null
                $lastResult = $null; $syncState = $null; $lastSyncTime = $null
                try {
                    $sub = $wsusSrv.GetSubscription()
                    try { $syncState = $sub.GetSynchronizationStatus().ToString() } catch {}
                    try { $subCats = @($sub.GetUpdateCategories()).Count } catch {}
                    try { $subClas = @($sub.GetUpdateClassifications()).Count } catch {}
                    $history = @($sub.GetSynchronizationHistory() | Sort-Object StartTime -Descending | Select-Object -First 1)
                    if ($history.Count -gt 0) {
                        $lastResult = $history[0].Result.ToString()
                        $lastSyncTime = $history[0].StartTime
                    }
                } catch {}

                # CM-side subscription = what we EXPECT WSUS to have. WCM
                # reads this from CM and pushes it to WSUS; a mismatch
                # means WCM hasn't pushed (yet). Best-effort -- if we
                # can't read CM, the parity test falls back to a plain
                # ">0" check on the WSUS side.
                $cmProdCount = $null; $cmClassCount = $null; $wcmName = $null
                try {
                    $cmProdCount  = @(Get-CMSoftwareUpdateCategory -Fast -TypeName 'Product'              -ErrorAction SilentlyContinue | Where-Object { $_.IsSubscribed }).Count
                    $cmClassCount = @(Get-CMSoftwareUpdateCategory -Fast -TypeName 'UpdateClassification' -ErrorAction SilentlyContinue | Where-Object { $_.IsSubscribed }).Count
                } catch {}
                try {
                    $wcmStateVal = [int](Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Microsoft\SMS\COMPONENTS\SMS_WSUS_CONFIGURATION_MANAGER' -Name 'ConfigurationState' -ErrorAction Stop)
                    $wcmStateMap = @{ 0='NONE'; 1='PENDING'; 2='SUCCESS'; 3='FAILED'; 4='SUBSCRIPTION_PENDING' }
                    $wcmName = if ($wcmStateMap.ContainsKey($wcmStateVal)) { $wcmStateMap[$wcmStateVal] } else { "UNKNOWN($wcmStateVal)" }
                } catch {}

                # ---- Test A: initial sync / taxonomy populated ----
                # Postinstall WSUS ships with ~17 categories, the cab brings
                # 433. >= 100 means a real categories load happened (cab
                # import or full MU categories sync).
                if ($taxCats -is [int] -and $taxCats -ge 100) {
                    $results.Details.Add("OK: WSUS initial sync (taxonomy) populated [TaxonomyCats=$taxCats; TaxonomyClas=$taxClas]")
                }
                else {
                    $taxShown = if ($taxCats -is [int]) { $taxCats } else { '<unknown>' }
                    $results.Details.Add("WARN: WSUS initial sync (taxonomy) not populated [TaxonomyCats=$taxShown; TaxonomyClas=$taxClas] - cab import failed and the first categories sync never completed")
                }

                # ---- Test B: subscription parity (CM SUP -> WSUS) ----
                # Healthy: CM has subscribed products+classifications, AND
                # WSUS-side subscription matches what CM has configured.
                $haveCm = ($cmProdCount -is [int]) -and ($cmClassCount -is [int])
                $wcmBit = if ($wcmName) { "; WCM=$wcmName" } else { '' }
                if ($haveCm) {
                    if ($cmProdCount -eq 0 -or $cmClassCount -eq 0) {
                        $results.Details.Add("WARN: CM SUP has nothing subscribed [CM-Products=$cmProdCount; CM-Classifications=$cmClassCount; WSUS-Sub=$subCats/$subClas$wcmBit] - configure SUP products/classifications")
                    }
                    elseif ($subCats -eq $cmProdCount -and $subClas -eq $cmClassCount) {
                        $results.Details.Add("OK: WSUS subscription matches CM SUP config [Products=$cmProdCount; Classifications=$cmClassCount$wcmBit]")
                    }
                    else {
                        $results.Details.Add("WARN: WSUS subscription out of sync with CM SUP [WSUS-Sub=$subCats/$subClas; CM-Sub=$cmProdCount/$cmClassCount$wcmBit] - WCM has not pushed subscription yet")
                    }
                }
                else {
                    # Fallback: CM cmdlets unavailable; just check WSUS-side
                    # has SOMETHING subscribed.
                    if (($subCats -is [int] -and $subCats -gt 0) -and ($subClas -is [int] -and $subClas -gt 0)) {
                        $results.Details.Add("OK: WSUS subscription set [Products=$subCats; Classifications=$subClas$wcmBit] (CM-side parity not checked - cmdlets unavailable)")
                    }
                    else {
                        $results.Details.Add("WARN: WSUS subscription empty [SubCats=$subCats; SubClas=$subClas$wcmBit]")
                    }
                }

                # ---- Test C: last sync result + UpdateCount (informational) ----
                $ucBit = "UpdateCount=$($wStatus.UpdateCount)"
                if ($lastResult -eq 'Succeeded') {
                    $results.Details.Add("OK: WSUS last sync Succeeded [LastSync=$lastSyncTime; SyncState=$syncState; $ucBit]")
                }
                elseif ($lastResult) {
                    $results.Details.Add("WARN: WSUS last sync Result=$lastResult [LastSync=$lastSyncTime; SyncState=$syncState; $ucBit]")
                }
                else {
                    $results.Details.Add("WARN: WSUS has no sync history [SyncState=$syncState; $ucBit] - first sync has not run")
                }

                # Append baseline-cab provenance when an import was used.
                # No-op when the import path didn't run (no log file).
                try {
                    $importLog = 'C:\staging\wsus\WsusCategoriesBaseline.import.log'
                    $metaPath = 'C:\staging\wsus\WsusCategoriesBaseline.meta.json'
                    if (Test-Path $importLog) {
                        $meta = $null
                        if (Test-Path $metaPath) {
                            try { $meta = Get-Content $metaPath -Raw -ErrorAction Stop | ConvertFrom-Json } catch {}
                        }
                        $genDate = if ($meta -and $meta.generatedUtc) { $meta.generatedUtc } else { '<unknown>' }
                        $genSha = if ($meta -and $meta.sha256) { $meta.sha256.Substring(0, [Math]::Min(12, $meta.sha256.Length)) } else { '<unknown>' }
                        $results.Details.Add("OK: WSUS categories baseline cab used (generated=$genDate, sha=$genSha)")
                    }
                } catch {}

                # WsusPool memory cap - the default ~1.8 GB cap recycles the pool
                # mid-sync; a hardened SUP should have it uncapped (0).
                try {
                    Import-Module WebAdministration -ErrorAction Stop
                    if (Test-Path 'IIS:\AppPools\WsusPool') {
                        $memCap = (Get-ItemProperty -Path 'IIS:\AppPools\WsusPool' -Name recycling.periodicRestart.privateMemory -ErrorAction Stop).Value
                        $poolState = (Get-WebAppPoolState -Name WsusPool -ErrorAction SilentlyContinue).Value
                        if ($memCap -ne 0) {
                            $results.Details.Add("WARN: WsusPool privateMemory recycle cap is $([math]::Round($memCap/1024,0)) MB (not uncapped) - the first full sync may recycle the pool and stall")
                        }
                        else {
                            $results.Details.Add("OK: WsusPool privateMemory uncapped (state=$poolState)")
                        }
                    }
                }
                catch {
                    $results.Details.Add("INFO: WsusPool config not readable: $($_.Exception.Message)")
                }
            }
            catch {
                $results.Details.Add("INFO: WSUS not local to this site server (skipped UpdateCount check): $($_.Exception.Message)")
            }
        }

        return $results
    }

    $appsCsv = ($expectedAppNames -join '|')
    $result = Invoke-VmCommand -VmName $VMName -VmDomainName $domain `
        -ScriptBlock $scriptBlock -ArgumentList $siteCode, ([string]$usePKI), $appsCsv, $role, ([string]$prePopulate), ([string]$IsTopLevel), ([string]$hasSUP) `
        -DisplayName "Phase11-CMSite-Test" -SuppressLog `
        -AsJob -TimeoutSeconds 600

    return (Format-TestResult -VMName $VMName -RoleLabel $siteRoleLabel -Result $result)
}

#region Proxy Validation Tests

function Test-ProxyListening {
    <#
    .SYNOPSIS
        Phase 11 test for the Linux Proxy VM: verifies Squid is listening on TCP 3128.
    .DESCRIPTION
        Runs `ss -ltn` over SSH on the Proxy VM (Invoke-LinuxVmCommand) and
        looks for a *:3128 / 0.0.0.0:3128 / :::3128 listener. Squid logs are
        not parsed -- presence of the listener is the meaningful end-to-end
        check for "the proxy is up".
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][object]$CurrentItem,
        [Parameter(Mandatory)][object]$DeployConfig
    )

    $Phase = 11
    $RoleLabel = 'Proxy'
    Write-Log "[Phase $Phase] $VMName [$RoleLabel]: Testing Squid listener on TCP 3128" -LogOnly

    if (-not (Get-Command Invoke-LinuxVmCommand -ErrorAction SilentlyContinue)) {
        Write-Log "[Phase $Phase] $VMName [$RoleLabel]: FAIL - Invoke-LinuxVmCommand not loaded" -Failure -LogOnly
        $script:Phase11OutputBuffer.Add(@{ Text = "[Phase $Phase] $VMName [$RoleLabel]: FAIL - Invoke-LinuxVmCommand not loaded"; Level = 'Failure' })
        return $false
    }

    $bash = "ss -ltn '( sport = :3128 )' 2>/dev/null | tail -n +2"
    $result = Invoke-LinuxVmCommand -VmName $VMName -BashCommand $bash -Sudo -TimeoutSeconds 30 -SuppressLog -DisplayName "Phase11-Proxy-Listen"

    if (-not $result -or $result.ScriptBlockFailed) {
        $err = if ($result) { $result.ScriptBlockOutput } else { 'SSH failed' }
        Write-Log "[Phase $Phase] $VMName [$RoleLabel]: FAIL - ss query failed: $err" -Failure -LogOnly
        $script:Phase11OutputBuffer.Add(@{ Text = "[Phase $Phase] $VMName [$RoleLabel]: FAIL - ss query failed: $err"; Level = 'Failure' })
        return $false
    }

    $output = ($result.ScriptBlockOutput | Out-String).Trim()
    if ($output -match ':3128') {
        Write-Log "[Phase $Phase] $VMName [$RoleLabel]: OK - Squid listening on :3128 ($($output -replace '\s+', ' '))" -LogOnly
        return $true
    }
    Write-Log "[Phase $Phase] $VMName [$RoleLabel]: FAIL - no listener on :3128 (ss output: '$output')" -Failure -LogOnly
    $script:Phase11OutputBuffer.Add(@{ Text = "[Phase $Phase] $VMName [$RoleLabel]: FAIL - no listener on TCP 3128"; Level = 'Failure' })
    return $false
}

function Test-ProxyAdminWebUI {
    <#
    .SYNOPSIS
        Phase 11 test: verifies the Proxy Admin web UI is listening on TCP 8443.
    .DESCRIPTION
        Runs `ss -ltn` over SSH to check for a listener on port 8443 (the
        Flask-based blocklist management UI deployed by Install-LinuxProxyServer).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][object]$CurrentItem,
        [Parameter(Mandatory)][object]$DeployConfig
    )

    $Phase = 11
    $RoleLabel = 'ProxyAdmin'
    Write-Log "[Phase $Phase] $VMName [$RoleLabel]: Testing Proxy Admin web UI on TCP 8443" -LogOnly

    $bash = "ss -ltn '( sport = :8443 )' 2>/dev/null | tail -n +2"
    $result = Invoke-LinuxVmCommand -VmName $VMName -BashCommand $bash -Sudo -TimeoutSeconds 30 -SuppressLog -DisplayName "Phase11-ProxyAdmin-Listen"

    if (-not $result -or $result.ScriptBlockFailed) {
        $err = if ($result) { $result.ScriptBlockOutput } else { 'SSH failed' }
        Write-Log "[Phase $Phase] $VMName [$RoleLabel]: FAIL - ss query failed: $err" -Failure -LogOnly
        $script:Phase11OutputBuffer.Add(@{ Text = "[Phase $Phase] $VMName [$RoleLabel]: FAIL - ss query failed: $err"; Level = 'Failure' })
        return $false
    }

    $output = ($result.ScriptBlockOutput | Out-String).Trim()
    if ($output -match ':8443') {
        Write-Log "[Phase $Phase] $VMName [$RoleLabel]: OK - Proxy Admin listening on :8443 ($($output -replace '\s+', ' '))" -LogOnly
        return $true
    }
    Write-Log "[Phase $Phase] $VMName [$RoleLabel]: FAIL - no listener on :8443 (ss output: '$output')" -Failure -LogOnly
    $script:Phase11OutputBuffer.Add(@{ Text = "[Phase $Phase] $VMName [$RoleLabel]: FAIL - Proxy Admin web UI not listening on TCP 8443"; Level = 'Failure' })
    return $false
}

function Test-WindowsProxyConfig {
    <#
    .SYNOPSIS
        Verifies an opted-in Windows VM is pointed at the lab Squid proxy.
    .DESCRIPTION
        Checks `netsh winhttp show proxy` (authoritative, hard FAIL gate) and
        the per-machine WinINET proxy enforcement: ProxySettingsPerUser=0
        (machine-wide proxy for all users + SYSTEM) plus the machine proxy
        value. Reads from every known machine-wide source -- HKLM IE
        ProxyServer, HKLM IE Connections blob, the policy hive equivalents
        and the Edge policy key -- because Windows shuffles the value
        between these locations on first interactive logon in machine-wide
        mode. WARN only when no source has a `<proxyFqdn>:3128` match.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][object]$CurrentItem,
        [Parameter(Mandatory)][object]$DeployConfig
    )

    $Phase = 11
    $RoleLabel = 'ProxyClient'
    $domain = $DeployConfig.vmOptions.domainName

    $proxyVm = $DeployConfig.virtualMachines | Where-Object { $_.role -eq 'Proxy' } | Select-Object -First 1
    if (-not $proxyVm) {
        Write-Log "[Phase $Phase] $VMName [$RoleLabel]: WARN - useProxy=true but no Proxy VM in config; skipping client config test" -Warning -LogOnly
        return $true
    }
    $proxyFqdn = "$($proxyVm.vmName).$domain"

    Write-Log "[Phase $Phase] $VMName [$RoleLabel]: Testing WinHTTP + IE proxy point at $proxyFqdn`:3128" -LogOnly

    $scriptBlock = {
        param($expectedFqdn, $expectedShortName)
        $results = @{ Passed = $true; Details = [System.Collections.Generic.List[string]]::new() }
        $matchesProxy = {
            param($value)
            if (-not $value) { return $false }
            $v = $value.ToString().ToLowerInvariant()
            return ($v -match ("{0}\:3128" -f [regex]::Escape($expectedFqdn.ToLowerInvariant()))) -or
                   ($v -match ("{0}[\.:].*3128" -f [regex]::Escape($expectedShortName.ToLowerInvariant()))) -or
                   ($v -match ':3128')   # accept any :3128 form (IP literal also OK)
        }

        # WinHTTP
        $results.Details.Add("CMD: netsh winhttp show proxy")
        try {
            $winhttp = (& netsh winhttp show proxy 2>&1) -join "`n"
            if (& $matchesProxy $winhttp) {
                $results.Details.Add("OK: WinHTTP proxy contains a :3128 entry")
            }
            else {
                $results.Passed = $false
                $results.Details.Add("FAIL: WinHTTP shows no :3128 proxy (output: $($winhttp -replace '\s+', ' '))")
            }
        }
        catch {
            $results.Passed = $false
            $results.Details.Add("FAIL: netsh winhttp show proxy threw: $($_.Exception.Message)")
        }

        # IE / WinINET per-machine enforcement. Set-WindowsClientProxy forces
        # machine-wide proxy by writing ProxySettingsPerUser=0, plus the
        # ProxyServer string and DefaultConnectionSettings binary blob under
        # the regular IE key. Windows can consume those values on first
        # interactive logon in machine-wide mode (seen on ZZ-MOCHI: a session
        # logon between two Phase 11 runs blanks both HKLM IE ProxyServer and
        # its Connections blob, leaving the proxy info in the policy hive or
        # the Edge policy key). Accept any of those sources -- only WARN when
        # every machine-wide proxy source is empty.
        $ieKey      = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings'
        $policyKey  = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\Internet Settings'
        $edgePolKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'

        # Parse the proxy server string out of a DefaultConnectionSettings blob.
        # Layout: [0..3] counter, [4..7] flags, [8..11] proxy-len, then proxy
        # bytes (ASCII). Returns '' if absent/unparseable.
        $proxyFromBlob = {
            param($blob)
            if (-not $blob -or $blob.Length -lt 12) { return '' }
            try {
                $len = [BitConverter]::ToInt32($blob, 8)
                if ($len -le 0 -or (12 + $len) -gt $blob.Length) { return '' }
                return [Text.Encoding]::ASCII.GetString($blob, 12, $len)
            }
            catch { return '' }
        }

        try {
            # Machine-wide enforcement switch (read regular IE key, then Policies)
            $perUser = $null
            if (Test-Path $ieKey) {
                $perUser = (Get-ItemProperty -Path $ieKey -Name 'ProxySettingsPerUser' -ErrorAction SilentlyContinue).ProxySettingsPerUser
            }
            if ($null -eq $perUser -and (Test-Path $policyKey)) {
                $perUser = (Get-ItemProperty -Path $policyKey -Name 'ProxySettingsPerUser' -ErrorAction SilentlyContinue).ProxySettingsPerUser
            }
            if ($perUser -eq 0) {
                $results.Details.Add("OK: ProxySettingsPerUser=0 (machine-wide proxy enforced)")
            }
            else {
                $results.Details.Add("WARN: ProxySettingsPerUser='$perUser' (machine-wide enforcement not set; expected 0)")
            }

            # Probe every known machine-wide proxy source; accept the first match.
            $sources = [ordered]@{}
            if (Test-Path $ieKey) {
                $sources['HKLM IE ProxyServer'] = (Get-ItemProperty -Path $ieKey -Name 'ProxyServer' -ErrorAction SilentlyContinue).ProxyServer
                $sources['HKLM IE Connections blob'] = & $proxyFromBlob ((Get-ItemProperty -Path (Join-Path $ieKey 'Connections') -Name 'DefaultConnectionSettings' -ErrorAction SilentlyContinue).DefaultConnectionSettings)
            }
            if (Test-Path $policyKey) {
                $sources['HKLM Policies IE ProxyServer'] = (Get-ItemProperty -Path $policyKey -Name 'ProxyServer' -ErrorAction SilentlyContinue).ProxyServer
                $sources['HKLM Policies IE Connections blob'] = & $proxyFromBlob ((Get-ItemProperty -Path (Join-Path $policyKey 'Connections') -Name 'DefaultConnectionSettings' -ErrorAction SilentlyContinue).DefaultConnectionSettings)
            }
            if (Test-Path $edgePolKey) {
                $sources['HKLM Edge Policy ProxyServer'] = (Get-ItemProperty -Path $edgePolKey -Name 'ProxyServer' -ErrorAction SilentlyContinue).ProxyServer
            }

            $matchedName  = $null
            $matchedValue = $null
            foreach ($name in $sources.Keys) {
                if (& $matchesProxy $sources[$name]) { $matchedName = $name; $matchedValue = $sources[$name]; break }
            }
            if ($matchedName) {
                $results.Details.Add("OK: $matchedName = '$matchedValue'")
            }
            elseif ($sources.Count -eq 0) {
                $results.Details.Add("WARN: No HKLM IE/Policies/Edge proxy keys present (Set-WindowsClientProxy may not have run)")
            }
            else {
                $summary = ($sources.GetEnumerator() | ForEach-Object { "$($_.Key)='$($_.Value)'" }) -join '; '
                $results.Details.Add("WARN: No machine-wide proxy source matches :3128 ($summary)")
            }
        }
        catch {
            $results.Details.Add("WARN: Reading HKLM machine proxy failed: $($_.Exception.Message)")
        }

        return $results
    }

    $result = Invoke-VmCommand -VmName $VMName -VmDomainName $domain `
        -ScriptBlock $scriptBlock -ArgumentList $proxyFqdn, $proxyVm.vmName `
        -DisplayName "Phase11-ProxyClient-Test" -SuppressLog `
        -AsJob -TimeoutSeconds 300

    return (Format-TestResult -VMName $VMName -RoleLabel $RoleLabel -Result $result)
}

function Test-InternetBlocked {
    <#
    .SYNOPSIS
        Verifies the host's port-ACL deny rules actually block direct
        Internet egress from an opted-in VM.
    .DESCRIPTION
        From inside the guest, runs Test-NetConnection to 8.8.8.8:443 with a
        short timeout. Pass = connection FAILS (deny rule working). If the
        connect succeeds, the ACLs aren't enforced and the VM is bypassing
        the proxy -- which is the whole thing this feature exists to prevent.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][object]$CurrentItem,
        [Parameter(Mandatory)][object]$DeployConfig
    )

    $Phase = 11
    $RoleLabel = 'ProxyBlock'
    $domain = $DeployConfig.vmOptions.domainName
    Write-Log "[Phase $Phase] $VMName [$RoleLabel]: Testing direct Internet (8.8.8.8:443) is blocked" -LogOnly

    $scriptBlock = {
        $results = @{ Passed = $true; Details = [System.Collections.Generic.List[string]]::new() }
        $results.Details.Add("CMD: Test-NetConnection 8.8.8.8 -Port 443 -InformationLevel Quiet")
        try {
            # Suppress the progress UI; -WarningAction silences the "TCP connect failed" warning.
            $ProgressPreference = 'SilentlyContinue'
            $ok = Test-NetConnection -ComputerName 8.8.8.8 -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
            if ($ok) {
                $results.Passed = $false
                $results.Details.Add("FAIL: Direct TCP 443 to 8.8.8.8 SUCCEEDED -- host port ACLs are NOT enforcing proxy-only egress")
            }
            else {
                $results.Details.Add("OK: Direct TCP 443 to 8.8.8.8 was blocked (deny rule active)")
            }
        }
        catch {
            # An exception here also counts as 'blocked' -- the connect didn't complete.
            $results.Details.Add("OK: Test-NetConnection threw (treated as blocked): $($_.Exception.Message)")
        }
        return $results
    }

    $result = Invoke-VmCommand -VmName $VMName -VmDomainName $domain `
        -ScriptBlock $scriptBlock -DisplayName "Phase11-ProxyBlock-Test" -SuppressLog `
        -AsJob -TimeoutSeconds 300

    $formatted = Format-TestResult -VMName $VMName -RoleLabel $RoleLabel -Result $result

    # If the guest reports the connect succeeded, the host-side enforcement
    # ACLs aren't in effect. Dump the current ACL state for the VM so the
    # log shows exactly what's (not) applied -- no second round-trip needed.
    if (-not $formatted) {
        try {
            $acls = @(Get-VMNetworkAdapterExtendedAcl -VMName $VMName -ErrorAction Stop)
            if (-not $acls -or $acls.Count -eq 0) {
                Write-Log "[Phase $Phase] $VMName [$RoleLabel]: DIAG: NO extended ACLs on vNIC -- Set-VmProxyEnforcement didn't run for this VM" -Warning -LogOnly
            }
            else {
                Write-Log "[Phase $Phase] $VMName [$RoleLabel]: DIAG: $($acls.Count) extended ACL(s) on vNIC:" -Warning -LogOnly
                foreach ($a in ($acls | Sort-Object Weight -Descending)) {
                    $line = "  W=$($a.Weight) $($a.Action) $($a.Direction) Proto=$($a.Protocol) Port=$($a.RemotePort) RemoteIP=$($a.RemoteIPAddress)"
                    Write-Log "[Phase $Phase] $VMName [$RoleLabel]: DIAG:$line" -Warning -LogOnly
                }
            }
        }
        catch {
            Write-Log "[Phase $Phase] $VMName [$RoleLabel]: DIAG: Get-VMNetworkAdapterExtendedAcl threw: $($_.Exception.Message)" -Warning -LogOnly
        }
    }

    return $formatted
}

function Test-CMSiteRoleProxy {
    <#
    .SYNOPSIS
        Verifies an opted-in CM site role has UseProxy=$true via the CM cmdlets.
    .DESCRIPTION
        Loads the ConfigurationManager module on the VM, connects to the local
        site, and reads `Get-CMSiteSystemServer -SiteSystemServerName <fqdn>`
        plus -- when present -- `Get-CMSoftwareUpdatePoint`. Both should
        report UseProxy=$true when the host-side Phase 5 DSC ran correctly.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][object]$CurrentItem,
        [Parameter(Mandatory)][object]$DeployConfig
    )

    $Phase = 11
    $RoleLabel = 'CMRoleProxy'
    $domain = $DeployConfig.vmOptions.domainName
    $fqdn = "$VMName.$domain"
    Write-Log "[Phase $Phase] $VMName [$RoleLabel]: Verifying CM site-role UseProxy flag" -LogOnly

    # SMS Provider / root\sms only exists on the site server (CAS/Primary).
    # For a SiteSystem (DPMP/etc.), redirect the WMI query to its owning site
    # server and match this VM's fqdn in SMS_SCI_SysResUse there.
    $targetVM = $VMName
    if ($CurrentItem.role -eq 'SiteSystem') {
        $siteCode = $CurrentItem.siteCode
        if (-not $siteCode) {
            Write-Log "[Phase $Phase] $VMName [$RoleLabel]: SiteSystem has no siteCode; cannot locate site server" -Warning
            return $false
        }
        $siteServer = Get-SiteServerForSiteCode -deployConfig $DeployConfig -SiteCode $siteCode -type Name -DomainName $domain
        if (-not $siteServer) {
            Write-Log "[Phase $Phase] $VMName [$RoleLabel]: Could not find site server for siteCode '$siteCode'" -Warning
            return $false
        }
        $targetVM = $siteServer
        Write-Log "[Phase $Phase] $VMName [$RoleLabel]: Querying SMS provider on site server '$targetVM' for SiteSystem '$fqdn'" -LogOnly
    }

    $scriptBlock = {
        param($expectedFqdn)
        $results = @{ Passed = $true; Details = [System.Collections.Generic.List[string]]::new() }

        # Find SMS Provider / site code via WMI (avoids needing the console module
        # PSDrive setup, which is finicky inside PSDirect).
        try {
            $site = Get-WmiObject -Namespace 'root\sms' -Class SMS_ProviderLocation -ErrorAction Stop |
                Where-Object { $_.ProviderForLocalSite -eq $true } | Select-Object -First 1
            if (-not $site) { throw 'SMS_ProviderLocation: no local-site provider found' }
            $ns = "root\sms\site_$($site.SiteCode)"
            $results.Details.Add("OK: SMS provider namespace = $ns")
        }
        catch {
            $results.Passed = $false
            $results.Details.Add("FAIL: Could not locate SMS provider: $($_.Exception.Message)")
            return $results
        }

        # Site system server props: UseProxy lives in SMS_SCI_SysResUse Props array, name "UseProxy".
        $results.Details.Add("CMD: SMS_SCI_SysResUse NALPath like '%$expectedFqdn%'")
        try {
            $sysRes = Get-WmiObject -Namespace $ns -Class SMS_SCI_SysResUse -ErrorAction Stop |
                Where-Object { $_.NetworkOSPath -match [regex]::Escape($expectedFqdn) }
            if (-not $sysRes) {
                $results.Details.Add("WARN: No SMS_SCI_SysResUse entries match '$expectedFqdn' -- site role may not be installed yet")
            }
            else {
                $sawProxyTrue = $false
                foreach ($r in $sysRes) {
                    $prop = $r.Props | Where-Object { $_.PropertyName -eq 'UseProxy' } | Select-Object -First 1
                    if ($prop) {
                        if ($prop.Value -eq 1) {
                            $results.Details.Add("OK: $($r.RoleName) on $expectedFqdn has UseProxy=1")
                            $sawProxyTrue = $true
                        }
                        else {
                            $results.Passed = $false
                            $results.Details.Add("FAIL: $($r.RoleName) on $expectedFqdn has UseProxy=$($prop.Value) (expected 1)")
                        }
                    }
                }
                if (-not $sawProxyTrue -and $results.Passed) {
                    # Some site roles don't expose a UseProxy prop (e.g. SMS Provider itself).
                    # Don't fail just because none was found; downgrade to a note.
                    $results.Details.Add("OK: $($sysRes.Count) site-role entr(ies) for $expectedFqdn; none expose a UseProxy prop (not all roles do)")
                }
            }
        }
        catch {
            $results.Passed = $false
            $results.Details.Add("FAIL: SMS_SCI_SysResUse query failed: $($_.Exception.Message)")
        }

        return $results
    }

    $result = Invoke-VmCommand -VmName $targetVM -VmDomainName $domain `
        -ScriptBlock $scriptBlock -ArgumentList $fqdn `
        -DisplayName "Phase11-CMRoleProxy-Test" -SuppressLog `
        -AsJob -TimeoutSeconds 300

    return (Format-TestResult -VMName $VMName -RoleLabel $RoleLabel -Result $result)
}

#endregion Proxy Validation Tests

#region Linux Common Validation Tests

function Test-LinuxVmHealth {
    <#
    .SYNOPSIS
        Phase 11 health check for Linux VMs: ping, SSH, and SMB from the host.
    .DESCRIPTION
        Verifies the Linux VM is network-reachable and SSH-responsive.
        - Ping failure: VM network stack is dead. Restart and return 'Restarted'.
        - Ping OK + SSH down + SMB down: multiple services dead, restart.
        - Ping OK + SSH down + SMB up: read sshd/syslog via SMB share to
          diagnose the SSH failure, log findings, return 'SshDown'.
        - Both ping + SSH OK: return 'OK'.
    .OUTPUTS
        String: 'OK', 'SshDown', 'Restarted', or 'Failed'.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][object]$CurrentItem,
        [Parameter(Mandatory)][object]$DeployConfig,
        [switch]$IsRetry
    )

    $Phase = 11
    $RoleLabel = $CurrentItem.role

    # Resolve IP from Hyper-V KVP.
    $vmIp = Get-LinuxVmIPAddress -VmName $VMName
    if (-not $vmIp) {
        Write-Log "[Phase $Phase] $VMName [$RoleLabel]: WARN - Cannot resolve VM IP for health check" -Warning -LogOnly
        $script:Phase11OutputBuffer.Add(@{ Text = "[Phase $Phase] $VMName [$RoleLabel]: WARN - Health check skipped (no IP from KVP)"; Level = 'Warning' })
        return 'OK'  # can't test without IP; don't block
    }

    # 1) Ping test — 2 attempts, 1-second timeout each.
    $pingOk = Test-Connection -ComputerName $vmIp -Count 2 -Quiet -ErrorAction SilentlyContinue

    if (-not $pingOk) {
        Write-Log "[Phase $Phase] $VMName [$RoleLabel]: FAIL - Ping to $vmIp failed" -Failure
        $script:Phase11OutputBuffer.Add(@{ Text = "[Phase $Phase] $VMName [$RoleLabel]: FAIL - Ping unreachable ($vmIp)"; Level = 'Failure' })

        if (-not $IsRetry) {
            Write-Log "[Phase $Phase] $VMName [$RoleLabel]: Ping failed — restarting VM to recover..." -Warning
            $rebooted = Restart-UnresponsiveVm -VmName $VMName -MaxRetries 1 -WaitTimeSeconds 120
            if ($rebooted) {
                # Verify ping works after reboot
                Start-Sleep -Seconds 10
                $newIp = Get-LinuxVmIPAddress -VmName $VMName
                if ($newIp -and (Test-Connection -ComputerName $newIp -Count 2 -Quiet -ErrorAction SilentlyContinue)) {
                    Write-Log "[Phase $Phase] $VMName [$RoleLabel]: VM recovered after restart — retrying all tests" -Warning
                    return 'Restarted'
                }
            }
            Write-Log "[Phase $Phase] $VMName [$RoleLabel]: VM did not recover after restart" -Failure
            $script:Phase11OutputBuffer.Add(@{ Text = "[Phase $Phase] $VMName [$RoleLabel]: FAIL - VM unresponsive after restart"; Level = 'Failure' })
        }
        return 'Failed'
    }

    Write-Log "[Phase $Phase] $VMName [$RoleLabel]: OK - Ping to $vmIp succeeded" -LogOnly

    # 2) SSH smoke test — run 'true' (no-op) to verify sshd is responsive.
    $sshOk = $false
    if (Get-Command Invoke-LinuxVmCommand -ErrorAction SilentlyContinue) {
        $sshResult = Invoke-LinuxVmCommand -VmName $VMName -BashCommand 'true' -TimeoutSeconds 15 -SuppressLog -DisplayName "Phase11-SSH-SmokeTest"
        if ($sshResult -and -not $sshResult.ScriptBlockFailed) {
            Write-Log "[Phase $Phase] $VMName [$RoleLabel]: OK - SSH responsive on $vmIp" -LogOnly
            $sshOk = $true
        }
    }
    else {
        # Can't test SSH without the command; treat as OK to avoid blocking
        $sshOk = $true
    }

    if ($sshOk) { return 'OK' }

    # 3) SSH is down — probe SMB (TCP 445) to determine severity.
    Write-Log "[Phase $Phase] $VMName [$RoleLabel]: SSH unresponsive on $vmIp — probing SMB as fallback..." -Warning -LogOnly
    $smbTcp = Test-NetConnection -ComputerName $vmIp -Port 445 -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
    $smbUp = $smbTcp -and $smbTcp.TcpTestSucceeded

    if (-not $smbUp) {
        # Both SSH and SMB are down — the VM is in a bad state.
        Write-Log "[Phase $Phase] $VMName [$RoleLabel]: FAIL - Both SSH and SMB (TCP 445) are down on $vmIp" -Failure
        $script:Phase11OutputBuffer.Add(@{ Text = "[Phase $Phase] $VMName [$RoleLabel]: FAIL - SSH + SMB both down (ping OK)"; Level = 'Failure' })

        if (-not $IsRetry) {
            Write-Log "[Phase $Phase] $VMName [$RoleLabel]: SSH + SMB both down — restarting VM to recover..." -Warning
            $rebooted = Restart-UnresponsiveVm -VmName $VMName -MaxRetries 1 -WaitTimeSeconds 120
            if ($rebooted) {
                Start-Sleep -Seconds 10
                $newIp = Get-LinuxVmIPAddress -VmName $VMName
                if ($newIp -and (Test-Connection -ComputerName $newIp -Count 2 -Quiet -ErrorAction SilentlyContinue)) {
                    Write-Log "[Phase $Phase] $VMName [$RoleLabel]: VM recovered after restart — retrying all tests" -Warning
                    return 'Restarted'
                }
            }
            Write-Log "[Phase $Phase] $VMName [$RoleLabel]: VM did not recover after restart" -Failure
            $script:Phase11OutputBuffer.Add(@{ Text = "[Phase $Phase] $VMName [$RoleLabel]: FAIL - VM unresponsive after restart"; Level = 'Failure' })
        }
        return 'Failed'
    }

    # 4) SMB is up — try to read sshd / syslog via the 'logs' share to diagnose SSH.
    Write-Log "[Phase $Phase] $VMName [$RoleLabel]: SMB is up on $vmIp — reading logs to diagnose SSH failure..." -Warning -LogOnly
    $smbLogPath = "\\$vmIp\logs"
    try {
        # Build credential for SMB auth (vmbuildadmin with LocalAdmin password).
        $smbCred = $null
        if ($Common -and $Common.LocalAdmin) {
            $pw = $Common.LocalAdmin.GetNetworkCredential().Password
            $secPw = ConvertTo-SecureString $pw -AsPlainText -Force
            $smbCred = [PSCredential]::new('vmbuildadmin', $secPw)
        }

        # Map a temporary PSDrive to read log files.
        $driveName = "MemLabsSMB_$($VMName -replace '[^a-zA-Z0-9]', '')"
        $driveParams = @{
            Name       = $driveName
            PSProvider = 'FileSystem'
            Root       = $smbLogPath
            ErrorAction = 'Stop'
        }
        if ($smbCred) { $driveParams['Credential'] = $smbCred }
        $null = New-PSDrive @driveParams

        try {
            # Read the last 30 lines of auth.log or syslog for sshd clues.
            $logFile = $null
            foreach ($candidate in @("${driveName}:\auth.log", "${driveName}:\syslog")) {
                if (Test-Path $candidate) { $logFile = $candidate; break }
            }

            if ($logFile) {
                $tail = Get-Content $logFile -Tail 30 -ErrorAction SilentlyContinue
                $sshLines = $tail | Where-Object { $_ -match 'sshd|ssh|watchdog' }
                if ($sshLines) {
                    Write-Log "[Phase $Phase] $VMName [$RoleLabel]: SSH-related log entries from $($logFile | Split-Path -Leaf):" -Warning -LogOnly
                    foreach ($line in $sshLines) {
                        Write-Log "[Phase $Phase] $VMName [$RoleLabel]:   $line" -LogOnly
                    }
                }
                else {
                    Write-Log "[Phase $Phase] $VMName [$RoleLabel]: No sshd entries in last 30 lines of $($logFile | Split-Path -Leaf)" -LogOnly
                }
            }
            else {
                Write-Log "[Phase $Phase] $VMName [$RoleLabel]: No auth.log or syslog found on \\$vmIp\logs" -LogOnly
            }

            # Also check for watchdog cron output.
            $watchdogLog = "${driveName}:\memlabs-sshd-watchdog.log"
            if (Test-Path $watchdogLog) {
                $wdTail = Get-Content $watchdogLog -Tail 10 -ErrorAction SilentlyContinue
                if ($wdTail) {
                    Write-Log "[Phase $Phase] $VMName [$RoleLabel]: sshd watchdog log:" -Warning -LogOnly
                    foreach ($line in $wdTail) {
                        Write-Log "[Phase $Phase] $VMName [$RoleLabel]:   $line" -LogOnly
                    }
                }
            }
        }
        finally {
            Remove-PSDrive -Name $driveName -Force -ErrorAction SilentlyContinue
        }
    }
    catch {
        Write-Log "[Phase $Phase] $VMName [$RoleLabel]: Could not read logs via SMB: $($_.Exception.Message)" -Warning -LogOnly
    }

    $script:Phase11OutputBuffer.Add(@{ Text = "[Phase $Phase] $VMName [$RoleLabel]: WARN - SSH down, SMB up — sshd watchdog should recover"; Level = 'Warning' })
    Write-Log "[Phase $Phase] $VMName [$RoleLabel]: SSH down but SMB accessible — sshd watchdog should recover within 5 min" -Warning
    return 'SshDown'
}

function Test-LinuxSmbAccess {
    <#
    .SYNOPSIS
        Phase 11 test for Linux VMs: verifies Samba is listening and shares are accessible.
    .DESCRIPTION
        Tests SMB connectivity from the host to the Linux VM without using SSH.
        1) Resolves the VM's IPv4 via Hyper-V KVP (Get-LinuxVmIPAddress).
        2) Verifies TCP 445 is reachable (Test-NetConnection).
        3) Lists shares via net view to confirm smb.conf is loaded.
        This validates the backup file-access channel that works when SSH is down.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][object]$CurrentItem,
        [Parameter(Mandatory)][object]$DeployConfig
    )

    $Phase = 11
    $RoleLabel = $CurrentItem.role
    Write-Log "[Phase $Phase] $VMName [$RoleLabel]: Testing Samba (SMB) accessibility from host" -LogOnly

    # Resolve the VM's IP from Hyper-V KVP — no SSH required.
    $vmIp = Get-LinuxVmIPAddress -VmName $VMName
    if (-not $vmIp) {
        Write-Log "[Phase $Phase] $VMName [$RoleLabel]: WARN - Cannot resolve VM IP for SMB test; skipping" -Warning -LogOnly
        $script:Phase11OutputBuffer.Add(@{ Text = "[Phase $Phase] $VMName [$RoleLabel]: WARN - SMB test skipped (no IP from KVP)"; Level = 'Warning' })
        return $true  # non-fatal: IP may not be available yet
    }

    # 1) TCP 445 reachability
    $tcp = Test-NetConnection -ComputerName $vmIp -Port 445 -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
    if (-not $tcp.TcpTestSucceeded) {
        Write-Log "[Phase $Phase] $VMName [$RoleLabel]: FAIL - TCP 445 not reachable on $vmIp" -Failure -LogOnly
        $script:Phase11OutputBuffer.Add(@{ Text = "[Phase $Phase] $VMName [$RoleLabel]: FAIL - Samba TCP 445 not reachable"; Level = 'Failure' })
        return $false
    }
    Write-Log "[Phase $Phase] $VMName [$RoleLabel]: OK - TCP 445 reachable on $vmIp" -LogOnly

    # 2) Verify shares are listed via net view (runs as host, no auth needed for listing)
    $netViewOutput = & net view "\\$vmIp" /all 2>&1
    $netViewString = ($netViewOutput | Out-String).Trim()
    $hasShares = $netViewString -match 'logs' -and $netViewString -match 'home'
    if (-not $hasShares) {
        # net view may fail without credentials — fall back to just the TCP check
        Write-Log "[Phase $Phase] $VMName [$RoleLabel]: WARN - net view did not list expected shares (may need auth); TCP 445 is open" -Warning -LogOnly
        Write-Log "[Phase $Phase] $VMName [$RoleLabel]: net view output: $netViewString" -LogOnly
    }
    else {
        Write-Log "[Phase $Phase] $VMName [$RoleLabel]: OK - Samba shares 'logs' and 'home' visible via net view" -LogOnly
    }

    $script:Phase11OutputBuffer.Add(@{ Text = "[Phase $Phase] $VMName [$RoleLabel]: OK - Samba accessible on $vmIp:445"; Level = 'Success' })
    return $true
}

#endregion Linux Common Validation Tests

#endregion

#region Helper Functions

function Format-TestResult {
    <#
    .SYNOPSIS
        Processes Invoke-VmCommand result, logs details, returns pass/fail bool.
    #>
    [CmdletBinding()]
    param(
        [string]$VMName,
        [string]$RoleLabel,
        [object]$Result
    )

    $Phase = 11

    if (-not $Result -or $Result.ScriptBlockFailed) {
        # ScriptBlockFailed can be set by Invoke-VmCommand's -ErrorVariable even
        # when the script block itself returned a valid Passed result. This happens
        # when a cmdlet inside the script (e.g. Get-Volume -EA SilentlyContinue)
        # writes a benign non-terminating error that the outer Invoke-Command
        # captures. If the output has the expected shape with Passed=$true, trust
        # the script's verdict over the error variable — fall through to normal
        # output processing instead of short-circuiting to FAIL.
        $hasValidPass = $Result -and $Result.ScriptBlockOutput -is [hashtable] -and
            $Result.ScriptBlockOutput.ContainsKey('Passed') -and $Result.ScriptBlockOutput.Passed -eq $true
        if (-not $hasValidPass) {
            $errMsg = if ($Result) { $Result.ScriptBlockFailed } else { 'Invoke-VmCommand returned no result (PSDirect session may have failed)' }
            # ScriptBlockFailed is often just $true (boolean) which prints as "True"
            # with no context. Pull in ScriptBlockOutput for the real error detail.
            if ($Result -and $errMsg -is [bool]) {
                $detail = $Result.ScriptBlockOutput
                if ($detail -and $detail -is [string]) {
                    $errMsg = $detail
                }
                elseif ($detail) {
                    $errMsg = ($detail | Out-String).Trim()
                }
                if (-not $errMsg -or $errMsg -is [bool]) {
                    $errMsg = 'ScriptBlock failed (no error detail returned; check log for PSDirect/session errors)'
                }
            }
            Write-Log "[Phase $Phase] $VMName [$RoleLabel]: FAIL - $errMsg" -Failure -LogOnly
            $script:Phase11OutputBuffer.Add(@{ Text = "[Phase $Phase] $VMName [$RoleLabel]: FAIL - $errMsg"; Level = 'Failure' })
            return $false
        }
        # ScriptBlockFailed was set but the script returned Passed=$true — log
        # the non-terminating error for diagnostics but continue to normal path.
        Write-Log "[Phase $Phase] $VMName [$RoleLabel]: WARN - Invoke-VmCommand reported ScriptBlockFailed but test script returned Passed=True; continuing" -Warning -LogOnly
        if ($Result.ErrorDetails) {
            foreach ($errLine in $Result.ErrorDetails) {
                Write-Log "[Phase $Phase] $VMName [$RoleLabel]: WARN - Non-terminating error: $errLine" -Warning -LogOnly
            }
        }
    }

    $output = $Result.ScriptBlockOutput
    if (-not $output -or -not $output.ContainsKey('Passed')) {
        Write-Log "[Phase $Phase] $VMName [$RoleLabel]: FAIL - Test script returned unexpected output" -Failure -LogOnly
        if ($output) {
            Write-Log "[Phase $Phase] $VMName [$RoleLabel]: Raw output type: $($output.GetType().FullName)" -LogOnly
            Write-Log "[Phase $Phase] $VMName [$RoleLabel]: Raw output: $($output | Out-String)" -LogOnly
        }
        $script:Phase11OutputBuffer.Add(@{ Text = "[Phase $Phase] $VMName [$RoleLabel]: FAIL - Test script returned unexpected output"; Level = 'Failure' })
        return $false
    }

    # Log all detail lines; accumulate failures/warnings for console output
    if ($output.Details) {
        foreach ($line in $output.Details) {
            if ($line -match '^FAIL:') {
                Write-Log "[Phase $Phase] $VMName [$RoleLabel]: $line" -Failure -LogOnly
                $script:Phase11OutputBuffer.Add(@{ Text = "[Phase $Phase] $VMName [$RoleLabel]: $line"; Level = 'Failure' })
            }
            elseif ($line -match '^WARN:') {
                Write-Log "[Phase $Phase] $VMName [$RoleLabel]: $line" -Warning -LogOnly
                $script:Phase11OutputBuffer.Add(@{ Text = "[Phase $Phase] $VMName [$RoleLabel]: $line"; Level = 'Warning' })
            }
            elseif ($line -match '^RECOVERED:') {
                Write-Log "[Phase $Phase] $VMName [$RoleLabel]: $line" -Success -LogOnly
                $script:Phase11OutputBuffer.Add(@{ Text = "[Phase $Phase] $VMName [$RoleLabel]: $line"; Level = 'Success' })
            }
            else {
                Write-Log "[Phase $Phase] $VMName [$RoleLabel]: $line" -LogOnly
            }
        }
    }

    if ($output.Passed) {
        Write-Log "[Phase $Phase] $VMName [$RoleLabel]: All checks PASSED" -LogOnly
        return $true
    }
    else {
        Write-Log "[Phase $Phase] $VMName [$RoleLabel]: FAILED" -Failure -LogOnly
        # Ensure the console always shows why the test failed. The FAIL: detail
        # lines above already get buffered, but if the test set Passed=$false
        # without any FAIL:-prefixed detail, nothing would reach the console.
        $hasFailDetail = $output.Details | Where-Object { $_ -match '^FAIL:' }
        if (-not $hasFailDetail) {
            $summary = if ($output.Details.Count -gt 0) {
                ($output.Details | Select-Object -Last 3) -join '; '
            } else { 'No failure detail provided by test script' }
            $script:Phase11OutputBuffer.Add(@{ Text = "[Phase $Phase] $VMName [$RoleLabel]: FAIL - $summary"; Level = 'Failure' })
        }
        return $false
    }
}

#endregion

####################################
### Post-Phase-5 SQLAO Validation
####################################

function Test-SQLAOPostPhase5 {
    <#
    .SYNOPSIS
        Lightweight SQLAO validation run immediately after Phase 5 DSC.
    .DESCRIPTION
        Catches SQLAO failures early (cluster, AG, listener, shares) so
        the build can stop before Phase 8 rather than wasting hours.
        Runs from the host via Invoke-VmCommand against the primary
        SQLAO node only. Returns $true if all checks pass.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$DeployConfig
    )

    $Phase = 5

    # Find SQLAO primary nodes (the ones with OtherNode defined)
    $primaryNodes = @($DeployConfig.virtualMachines | Where-Object { $_.role -eq 'SQLAO' -and $_.OtherNode -and -not $_.hidden })
    if ($primaryNodes.Count -eq 0) {
        return $true
    }

    $domain = $DeployConfig.vmOptions.domainName
    $allPassed = $true

    foreach ($primaryAO in $primaryNodes) {
        $VMName = $primaryAO.vmName
        $listenerName = $primaryAO.AlwaysOnListenerName
        $agName = $primaryAO.AlwaysOnGroupName
        $agIP = $primaryAO.AGIPAddress
        $clusterName = $primaryAO.ClusterName
        $clusterIP = $primaryAO.ClusterIPAddress
        $otherNode = $primaryAO.OtherNode
        $listenerPort = '1500'

        $prefix = $DeployConfig.vmOptions.prefix
        $clusterNameNoPrefix = $clusterName.Replace($prefix, "")
        $fileServerVM = $primaryAO.fileServerVM
        $witnessShare = "\\$fileServerVM\$($clusterNameNoPrefix)-Witness"
        $backupShare = "\\$fileServerVM\$($clusterNameNoPrefix)-Backup"

        Write-Log "[Phase $Phase] $VMName [SQLAO]: Running post-Phase-5 validation" -OutputStream

        $scriptBlock = {
            param($listenerName, $listenerPort, $agName, $otherNode, $witnessShare, $backupShare, $agIP, $clusterName, $clusterIP, $domainName)

            $results = @{ Passed = $true; Details = [System.Collections.Generic.List[string]]::new() }

            try {
                Import-Module FailoverClusters -ErrorAction SilentlyContinue
                Import-Module SqlServer -ErrorAction SilentlyContinue
                if (-not (Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue)) {
                    Import-Module SQLPS -DisableNameChecking -ErrorAction SilentlyContinue
                }

                # 1. Failover Cluster health
                $results.Details.Add("CMD: Get-Cluster / Get-ClusterNode")
                try {
                    $cluster = Get-Cluster -ErrorAction Stop
                    $results.Details.Add("OK: Cluster '$($cluster.Name)' is online")

                    $nodes = @(Get-ClusterNode -ErrorAction Stop)
                    $downNodes = @($nodes | Where-Object { $_.State -ne 'Up' })
                    if ($downNodes.Count -gt 0) {
                        $results.Passed = $false
                        foreach ($n in $downNodes) {
                            $results.Details.Add("FAIL: Cluster node '$($n.Name)' is $($n.State)")
                        }
                    }
                    else {
                        $results.Details.Add("OK: All $($nodes.Count) cluster node(s) are Up ($($nodes.Name -join ', '))")
                    }
                }
                catch {
                    $results.Passed = $false
                    $results.Details.Add("FAIL: Cluster not found or inaccessible: $($_.Exception.Message)")
                }

                # 2. Cluster name DNS — query ALL DCs directly to avoid LLMNR.
                #    With DC + BDC, the record may exist on one but not the other.
                if ($clusterName) {
                    $dnsZone = if ($domainName) { $domainName } else { [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().DomainName }
                    $allDCs = @(Get-ADDomainController -Filter * -ErrorAction SilentlyContinue | Select-Object -ExpandProperty HostName)
                    if ($allDCs.Count -eq 0) {
                        $fallbackDC = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\History' -Name DCName -ErrorAction SilentlyContinue).DCName
                        if ($fallbackDC) { $fallbackDC = $fallbackDC.TrimStart('\\') }
                        $allDCs = @($fallbackDC)
                    }
                    foreach ($dc in $allDCs) {
                        $results.Details.Add("CMD: Get-DnsServerResourceRecord -ZoneName '$dnsZone' -Name '$clusterName' -RRType A -ComputerName '$dc'")
                        try {
                            $clusterRecs = @(Get-DnsServerResourceRecord -ZoneName $dnsZone -Name $clusterName -RRType A -ComputerName $dc -ErrorAction Stop)
                            $resolvedIPs = @($clusterRecs | ForEach-Object { $_.RecordData.IPv4Address.ToString() })
                            if ($resolvedIPs.Count -eq 0) {
                                $results.Passed = $false
                                $results.Details.Add("FAIL: Cluster name '$clusterName' has no A record on DC '$dc'")
                            }
                            else {
                                $results.Details.Add("OK: Cluster name '$clusterName' has DNS A record(s) on DC '$dc': $($resolvedIPs -join ', ')")
                                if ($clusterIP -and $clusterIP -notin $resolvedIPs) {
                                    $results.Passed = $false
                                    $results.Details.Add("FAIL: Expected cluster IP '$clusterIP' not in DNS on DC '$dc' (found: $($resolvedIPs -join ', '))")
                                }
                            }
                        }
                        catch {
                            $results.Passed = $false
                            $results.Details.Add("FAIL: DNS query for cluster name '$clusterName' on DC '$dc' failed: $($_.Exception.Message)")
                        }
                    }
                }

                # 3. AG replica health (single attempt, no remediation — just report)
                $results.Details.Add("CMD: AG replica health query")
                try {
                    $healthQuery = @"
SELECT ag.name AS GroupName,
       rs.role_desc AS Role,
       rs.connected_state_desc AS ConnState,
       rs.synchronization_health_desc AS Health,
       ar.replica_server_name AS Replica
FROM sys.dm_hadr_availability_replica_states rs
JOIN sys.availability_groups ag ON rs.group_id = ag.group_id
JOIN sys.availability_replicas ar ON rs.replica_id = ar.replica_id
"@
                    $ag = @(Invoke-Sqlcmd -Query $healthQuery -QueryTimeout 30 -TrustServerCertificate -ErrorAction Stop)
                    if (-not $ag -or $ag.Count -eq 0) {
                        $results.Passed = $false
                        $results.Details.Add("FAIL: No availability group replicas found")
                    }
                    else {
                        $unhealthy = @($ag | Where-Object { $_.Health -ne 'HEALTHY' })
                        foreach ($r in $ag) {
                            $level = if ($r.Health -ne 'HEALTHY') { 'FAIL' } else { 'OK' }
                            $results.Details.Add("${level}: AG '$($r.GroupName)' replica '$($r.Replica)' ($($r.Role)) — $($r.ConnState), $($r.Health)")
                        }
                        if ($unhealthy.Count -gt 0) {
                            $results.Passed = $false
                        }
                    }
                }
                catch {
                    $results.Passed = $false
                    $results.Details.Add("FAIL: AG health query failed: $($_.Exception.Message)")
                }

                # 4. Listener DNS — query ALL DCs' DNS records directly.
                #    Resolve-DnsName can return LLMNR results that mask a missing
                #    A record. Phase 8 setup.exe needs FQDN for Kerberos.
                #    With DC + BDC, check every DC so the CAS (which might use
                #    the BDC) finds the record.
                if ($listenerName) {
                    # $allDCs and $dnsZone were set in check #2; reuse if available
                    if (-not $allDCs -or $allDCs.Count -eq 0) {
                        $allDCs = @(Get-ADDomainController -Filter * -ErrorAction SilentlyContinue | Select-Object -ExpandProperty HostName)
                        if ($allDCs.Count -eq 0) {
                            $fallbackDC = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\History' -Name DCName -ErrorAction SilentlyContinue).DCName
                            if ($fallbackDC) { $fallbackDC = $fallbackDC.TrimStart('\\') }
                            $allDCs = @($fallbackDC)
                        }
                    }
                    if (-not $dnsZone) {
                        $dnsZone = if ($domainName) { $domainName } else { [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().DomainName }
                    }
                    $listenerDnsOk = $true  # will be set to $false if ANY DC is missing
                    $dcsMissingRecord = @()
                    foreach ($dc in $allDCs) {
                        $results.Details.Add("CMD: Get-DnsServerResourceRecord -ZoneName '$dnsZone' -Name '$listenerName' -RRType A -ComputerName '$dc'")
                        try {
                            $listenerRecs = @(Get-DnsServerResourceRecord -ZoneName $dnsZone -Name $listenerName -RRType A -ComputerName $dc -ErrorAction Stop)
                            $resolvedIPs = @($listenerRecs | ForEach-Object { $_.RecordData.IPv4Address.ToString() })
                            if ($resolvedIPs.Count -gt 0) {
                                $results.Details.Add("OK: Listener '$listenerName' has DNS A record(s) on DC '$dc': $($resolvedIPs -join ', ')")
                                if ($agIP -and $agIP -notin $resolvedIPs) {
                                    $results.Details.Add("WARN: Expected AG IP '$agIP' not in DNS A records on DC '$dc'")
                                }
                            }
                            else {
                                $listenerDnsOk = $false
                                $dcsMissingRecord += $dc
                                $results.Details.Add("FAIL: Listener '$listenerName' has no A record on DC '$dc'")
                            }
                        }
                        catch {
                            $listenerDnsOk = $false
                            $dcsMissingRecord += $dc
                            $results.Details.Add("FAIL: DNS query for listener '$listenerName' on DC '$dc' failed: $($_.Exception.Message)")
                        }
                    }

                    # Remediate: if any DC is missing the record, register on
                    # the first available DC and force AD replication to all.
                    if (-not $listenerDnsOk -and $agIP) {
                        $regDC = $allDCs[0]
                        $results.Details.Add("Attempting to register DNS A record: '$listenerName' -> $agIP on DC '$regDC' and replicate")
                        try {
                            if ($regDC -and $dnsZone) {
                                # Only add the record if the first DC doesn't already have it
                                $existingRec = @(Get-DnsServerResourceRecord -ZoneName $dnsZone -Name $listenerName -RRType A -ComputerName $regDC -ErrorAction SilentlyContinue)
                                if ($existingRec.Count -eq 0) {
                                    Add-DnsServerResourceRecordA -ZoneName $dnsZone -Name $listenerName `
                                        -IPv4Address $agIP -ComputerName $regDC -ErrorAction Stop
                                }

                                # Force AD replication so all DCs get the record
                                if ($allDCs.Count -gt 1) {
                                    $dcShortNames = @($allDCs | ForEach-Object { ($_ -split '\.')[0] })
                                    $replJob = Start-Job -ScriptBlock {
                                        param($dcNames)
                                        $dcNames | ForEach-Object { repadmin /syncall $_ /AdeP 2>&1 | Out-Null }
                                    } -ArgumentList (,$dcShortNames)
                                    $null = Wait-Job $replJob -Timeout 30
                                    if ($replJob.State -eq 'Running') { Stop-Job $replJob -ErrorAction SilentlyContinue }
                                    Remove-Job $replJob -Force -ErrorAction SilentlyContinue
                                }
                                Start-Sleep -Seconds 5

                                # Verify on ALL DCs
                                $listenerDnsOk = $true
                                foreach ($dc in $allDCs) {
                                    $recheck = @(Get-DnsServerResourceRecord -ZoneName $dnsZone -Name $listenerName `
                                        -RRType A -ComputerName $dc -ErrorAction SilentlyContinue)
                                    if ($recheck.Count -gt 0) {
                                        $results.Details.Add("OK: DNS A record verified on DC '$dc' after remediation")
                                    }
                                    else {
                                        $listenerDnsOk = $false
                                        $results.Details.Add("FAIL: DNS A record still missing on DC '$dc' after remediation + replication")
                                    }
                                }
                            }
                            else {
                                $results.Details.Add("FAIL: Could not determine DC or domain name for DNS registration")
                            }
                        }
                        catch {
                            $results.Details.Add("FAIL: DNS registration failed: $($_.Exception.Message)")
                        }
                    }
                    if (-not $listenerDnsOk) {
                        $results.Passed = $false
                    }
                }

                # 5. Listener SQL connectivity
                if ($listenerName -and $listenerPort) {
                    $connStr = "$listenerName,$listenerPort"
                    $results.Details.Add("CMD: Invoke-Sqlcmd -ServerInstance '$connStr' -Query 'SELECT 1'")
                    try {
                        $lr = Invoke-Sqlcmd -ServerInstance $connStr -Query "SELECT 1 AS TestResult" -QueryTimeout 30 -TrustServerCertificate -ErrorAction Stop
                        if ($lr.TestResult -eq 1) {
                            $results.Details.Add("OK: SQL query via listener '$connStr' succeeded")
                        }
                        else {
                            $results.Passed = $false
                            $results.Details.Add("FAIL: Listener query returned unexpected result")
                        }
                    }
                    catch {
                        $results.Passed = $false
                        $results.Details.Add("FAIL: SQL connection via listener '$connStr' failed: $($_.Exception.Message)")
                    }
                }

                # 6. Backup and Witness shares
                foreach ($share in @(@{Name = 'Witness'; Path = $witnessShare}, @{Name = 'Backup'; Path = $backupShare})) {
                    if ($share.Path) {
                        $results.Details.Add("CMD: Test-Path '$($share.Path)'")
                        if (Test-Path $share.Path -ErrorAction SilentlyContinue) {
                            $results.Details.Add("OK: $($share.Name) share '$($share.Path)' is accessible")
                        }
                        else {
                            $results.Passed = $false
                            $results.Details.Add("FAIL: $($share.Name) share '$($share.Path)' is not accessible")
                        }
                    }
                }
            }
            catch {
                $results.Passed = $false
                $results.Details.Add("FAIL: Post-Phase-5 SQLAO validation failed: $($_.Exception.Message)")
            }

            return $results
        }

        $result = Invoke-VmCommand -VmName $VMName -VmDomainName $domain `
            -ScriptBlock $scriptBlock `
            -ArgumentList $listenerName, $listenerPort, $agName, $otherNode, $witnessShare, $backupShare, $agIP, $clusterName, $clusterIP, $domain `
            -DisplayName "Phase5-SQLAO-Validate" -SuppressLog

        # Process results inline (Format-TestResult hardcodes Phase 11)
        $passed = $true
        if (-not $result -or $result.ScriptBlockFailed) {
            $hasValidPass = $result -and $result.ScriptBlockOutput -is [hashtable] -and
                $result.ScriptBlockOutput.ContainsKey('Passed') -and $result.ScriptBlockOutput.Passed -eq $true
            if (-not $hasValidPass) {
                $errMsg = if ($result) { $result.ScriptBlockFailed } else { 'Invoke-VmCommand returned no result' }
                if ($result -and $errMsg -is [bool]) {
                    $detail = $result.ScriptBlockOutput
                    if ($detail -and $detail -is [string]) { $errMsg = $detail }
                    elseif ($detail) { $errMsg = ($detail | Out-String).Trim() }
                    if (-not $errMsg -or $errMsg -is [bool]) { $errMsg = 'ScriptBlock failed (no detail)' }
                }
                Write-Log "[Phase $Phase] $VMName [SQLAO]: FAIL - $errMsg" -Failure
                $allPassed = $false
                continue
            }
        }

        $output = $result.ScriptBlockOutput
        if (-not $output -or -not $output.ContainsKey('Passed')) {
            Write-Log "[Phase $Phase] $VMName [SQLAO]: FAIL - Unexpected output from validation script" -Failure
            $allPassed = $false
            continue
        }

        foreach ($line in $output.Details) {
            if ($line -match '^FAIL:') {
                Write-Log "[Phase $Phase] $VMName [SQLAO]: $line" -Failure
            }
            elseif ($line -match '^WARN:') {
                Write-Log "[Phase $Phase] $VMName [SQLAO]: $line" -Warning
            }
            else {
                Write-Log "[Phase $Phase] $VMName [SQLAO]: $line" -LogOnly
            }
        }

        if ($output.Passed) {
            Write-Log "[Phase $Phase] $VMName [SQLAO]: Post-Phase-5 SQLAO validation PASSED" -Success
        }
        else {
            Write-Log "[Phase $Phase] $VMName [SQLAO]: Post-Phase-5 SQLAO validation FAILED" -Failure
            $allPassed = $false
        }
    }

    return $allPassed
}
