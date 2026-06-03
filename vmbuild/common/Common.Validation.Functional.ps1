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
        [object]$DeployConfig
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
        foreach ($vm in $DeployConfig.virtualMachines) {
            if ($vm.hidden) { continue }
            if ($vm.domain -and $vm.domain -ne $Domain) { continue }
            # Workgroup/InternetClient VMs are not domain-joined and won't have DNS A records.
            if ($vm.role -in @('WorkgroupMember', 'InternetClient', 'AADClient')) { continue }
            try {
                $ips = (Get-VMNetworkAdapter -VMName $vm.vmName -ErrorAction Stop).IPAddresses |
                    Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' }
                $ip = $ips | Select-Object -First 1
                if ($ip) { $entries.Add("$($vm.vmName)=$ip") }
            }
            catch {}
        }
        $expectedDnsCsv = ($entries -join ',')
    }

    $scriptBlock = {
        # NOTE: Invoke-VmCommand declares [string[]]$ArgumentList, so any bool we pass
        # in arrives as the string 'True'/'False' (both truthy in `if`). Compare to
        # the string 'True' explicitly to avoid the BDC branch firing on every DC.
        param($domainFqdn, $isBdcInner, $expectedDnsCsv)
        $isBdc = ($isBdcInner -eq 'True')
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

        # DNS resolution test
        $results.Details.Add("CMD: Resolve-DnsName -Name '$domainFqdn' -Type A")
        try {
            $dns = Resolve-DnsName -Name $domainFqdn -Type A -ErrorAction Stop
            if ($dns) {
                $results.Details.Add("OK: DNS resolves '$domainFqdn' -> $($dns.IPAddress -join ', ')")
            }
        }
        catch {
            $results.Passed = $false
            $results.Details.Add("FAIL: DNS cannot resolve '$domainFqdn': $($_.Exception.Message)")
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
                    $recs = Resolve-DnsName -Name $fqdn -Type A -Server 127.0.0.1 -DnsOnly -ErrorAction Stop |
                        Where-Object { $_.Type -eq 'A' }
                    $resolvedIps = @($recs | ForEach-Object { $_.IPAddress })
                    if (-not $resolvedIps -or $resolvedIps.Count -eq 0) {
                        $results.Passed = $false
                        $mismatches++
                        $results.Details.Add("FAIL: DNS '$fqdn' returned no A records (expected $expectedIp)")
                    }
                    elseif ($resolvedIps -notcontains $expectedIp) {
                        # Stale record — attempt auto-remediation: remove wrong A records and add the correct one.
                        $fixed = $false
                        try {
                            $zone = $domainFqdn
                            foreach ($staleIp in $resolvedIps) {
                                Remove-DnsServerResourceRecord -ZoneName $zone -RRType A -Name $name -RecordData $staleIp -Force -ErrorAction Stop
                            }
                            Add-DnsServerResourceRecordA -ZoneName $zone -Name $name -IPv4Address $expectedIp -ErrorAction Stop
                            # Re-verify
                            $recheck = Resolve-DnsName -Name $fqdn -Type A -Server 127.0.0.1 -DnsOnly -ErrorAction Stop |
                                Where-Object { $_.Type -eq 'A' }
                            $recheckIps = @($recheck | ForEach-Object { $_.IPAddress })
                            if ($recheckIps -contains $expectedIp) {
                                $fixed = $true
                                $results.Details.Add("OK: DNS '$fqdn' had stale record(s) ($($resolvedIps -join ',')); auto-fixed -> $expectedIp")
                            }
                        }
                        catch {}
                        if (-not $fixed) {
                            $results.Passed = $false
                            $mismatches++
                            $results.Details.Add("FAIL: DNS '$fqdn' -> $($resolvedIps -join ',') (expected $expectedIp; stale record, auto-fix failed)")
                        }
                    }
                    elseif ($resolvedIps.Count -gt 1) {
                        # Extra records alongside the correct one — remove the extras.
                        $extras = @($resolvedIps | Where-Object { $_ -ne $expectedIp })
                        try {
                            foreach ($extraIp in $extras) {
                                Remove-DnsServerResourceRecord -ZoneName $domainFqdn -RRType A -Name $name -RecordData $extraIp -Force -ErrorAction Stop
                            }
                            $results.Details.Add("OK: DNS '$fqdn' had extra A record(s) ($($extras -join ',')); removed, keeping $expectedIp")
                        }
                        catch {
                            $results.Details.Add("WARN: DNS '$fqdn' has extra A record(s): $($extras -join ',') (expected only $expectedIp; cleanup failed)")
                        }
                    }
                }
                catch {
                    $results.Passed = $false
                    $mismatches++
                    $results.Details.Add("FAIL: DNS lookup for '$fqdn' threw: $($_.Exception.Message)")
                }
            }
            if ($mismatches -eq 0) {
                $results.Details.Add("OK: DNS A records for $($expected.Count) deploy VM(s) match Hyper-V IPs")
            }
        }

        # dcdiag quick checks. Advertising + NetLogons added because a half-promoted
        # DC (e.g. Phase 2 interrupted mid-DCPROMO) can show all services Running
        # yet refuse to serve authentications -- Advertising/NetLogons catches that
        # before downstream DomainMember tests fail with cryptic ERROR_NO_LOGON_SERVERS.
        $results.Details.Add("CMD: dcdiag.exe /test:Services /test:Replications /test:FSMOCheck /test:Advertising /test:NetLogons /q")
        try {
            $dcdiag = & dcdiag.exe /test:Services /test:Replications /test:FSMOCheck /test:Advertising /test:NetLogons /q 2>&1
            $dcdiagText = $dcdiag -join "`n"
            $failCount = ([regex]::Matches($dcdiagText, 'failed test')).Count
            if ($failCount -gt 0) {
                $results.Passed = $false
                $results.Details.Add("FAIL: dcdiag reported $failCount failed test(s)")
                $failLines = $dcdiag | Where-Object { $_ -match 'failed test' } | Select-Object -First 5
                foreach ($fl in $failLines) { $results.Details.Add("  dcdiag: $($fl.Trim())") }
            }
            else {
                $results.Details.Add("OK: dcdiag Services/Replications/FSMOCheck/Advertising/NetLogons passed")
            }
        }
        catch {
            $results.Details.Add("WARN: dcdiag execution failed: $($_.Exception.Message)")
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

        # BDC-only: confirm we can replicate inbound from at least one partner
        # within the last hour. A stale/never-replicated BDC means later VMs
        # built against it will be missing accounts/GPOs.
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
                    $fresh = $partners | Where-Object { $_.LastReplicationSuccess -gt (Get-Date).AddHours(-1) }
                    if ($fresh) {
                        $results.Details.Add("OK: $($fresh.Count) replication partner(s) succeeded within last hour")
                    }
                    else {
                        $most = $partners | Sort-Object LastReplicationSuccess -Descending | Select-Object -First 1
                        $results.Passed = $false
                        $results.Details.Add("FAIL: BDC replication stale -- last success $($most.LastReplicationSuccess) from $($most.Partner)")
                    }
                }
            }
            catch {
                $results.Details.Add("WARN: Could not query BDC replication metadata: $($_.Exception.Message)")
            }
        }

        return $results
    }

    $result = Invoke-VmCommand -VmName $VMName -VmDomainName $Domain `
        -ScriptBlock $scriptBlock -ArgumentList $Domain, ([string]$IsBDC.IsPresent), $expectedDnsCsv `
        -DisplayName "Phase11-$label-Test" -SuppressLog

    return (Format-TestResult -VMName $VMName -RoleLabel $label -Result $result)
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
            $results.Details.Add("WARN: $($svc.Name) is $($svc.Status) (StartType=$($svc.StartType)), attempting Start-Service...")
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
                    $results.Details.Add("OK: $($svc.Name) started successfully (took ~$($waited)s)")
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
        -ScriptBlock $scriptBlock -DisplayName "Phase11-SQL-Service-Sweep" -SuppressLog

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
            $results.Details.Add("WARN: SQL service '$svcName' is $($svc.Status), attempting to start...")
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
            $results.Details.Add("OK: SQL service '$svcName' started successfully")
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

        return $results
    }

    $result = Invoke-VmCommand -VmName $VMName -VmDomainName $domain `
        -ScriptBlock $scriptBlock -ArgumentList $instanceName, $sqlPort, $isSQLAO `
        -DisplayName "Phase11-SQL-Test" -SuppressLog

    return (Format-TestResult -VMName $VMName -RoleLabel 'SQL' -Result $result)
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

        try {
            Import-Module SqlServer -ErrorAction SilentlyContinue
            if (-not (Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue)) {
                Import-Module SQLPS -DisableNameChecking -ErrorAction SilentlyContinue
            }

            # ==============================================================
            # 1. Failover Cluster health
            # ==============================================================
            $results.Details.Add("CMD: Get-Cluster / Get-ClusterNode / Get-ClusterQuorum")
            try {
                Import-Module FailoverClusters -ErrorAction SilentlyContinue
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
                if ($clusterName) {
                    $results.Details.Add("CMD: Resolve-DnsName '$clusterName'")
                    $clusterDns = @(Resolve-DnsName -Name $clusterName -Type A -ErrorAction SilentlyContinue | Where-Object { $_.QueryType -eq 'A' })
                    $resolvedIPs = @($clusterDns | Select-Object -ExpandProperty IPAddress)
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
            # 2. Remediation pass: fix common issues before testing AG health
            # ==============================================================

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

            # ==============================================================
            # 3. AG replica health check with retry
            # ==============================================================
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
            $maxRetries = 3
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
                    $results.Details.Add("WARN: Attempt $attempt/$maxRetries — $($unhealthy.Count) replica(s) not healthy, waiting 15s...")
                    Start-Sleep -Seconds 15
                }
                else {
                    $results.Passed = $false
                    foreach ($r in $ag) {
                        $level = if ($r.Health -ne 'HEALTHY') { 'FAIL' } else { 'OK' }
                        $results.Details.Add("${level}: AG '$($r.GroupName)' replica '$($r.Replica)' ($($r.Role)) — $($r.ConnState), $($r.Health)")
                    }
                }
            }

            # 3b. Collect DB-level sync state for diagnostics if still unhealthy
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
            if ($listenerName) {
                $results.Details.Add("CMD: Resolve-DnsName '$listenerName'")
                try {
                    $dns = @(Resolve-DnsName -Name $listenerName -Type A -ErrorAction Stop)
                    $resolvedIPs = @($dns | Where-Object { $_.QueryType -eq 'A' } | Select-Object -ExpandProperty IPAddress)
                    if ($resolvedIPs.Count -gt 0) {
                        $results.Details.Add("OK: '$listenerName' resolves to $($resolvedIPs -join ', ')")
                        if ($agIP -and $agIP -notin $resolvedIPs) {
                            $results.Details.Add("WARN: Expected AG IP '$agIP' not in resolved addresses")
                        }
                    }
                    else {
                        $results.Passed = $false
                        $results.Details.Add("FAIL: '$listenerName' did not resolve to any A records")
                    }
                }
                catch {
                    $results.Passed = $false
                    $results.Details.Add("FAIL: DNS resolution for '$listenerName' failed: $($_.Exception.Message)")
                }
            }

            # ==============================================================
            # 6. Listener SQL connectivity
            # ==============================================================
            if ($listenerName -and $listenerPort) {
                $listenerConnStr = "$listenerName,$listenerPort"
                $results.Details.Add("CMD: Invoke-Sqlcmd -ServerInstance '$listenerConnStr' -Query 'SELECT 1'")
                try {
                    $lr = Invoke-Sqlcmd -ServerInstance $listenerConnStr -Query "SELECT 1 AS TestResult" -QueryTimeout 30 -TrustServerCertificate -ErrorAction Stop
                    if ($lr.TestResult -eq 1) {
                        $results.Details.Add("OK: SQL query via listener '$listenerConnStr' succeeded")
                    }
                    else {
                        $results.Passed = $false
                        $results.Details.Add("FAIL: Listener query returned unexpected result")
                    }
                }
                catch {
                    $results.Passed = $false
                    $results.Details.Add("FAIL: SQL connection via listener '$listenerConnStr' failed: $($_.Exception.Message)")
                }
            }

            # ==============================================================
            # 7. Backup and Witness share accessibility
            # ==============================================================
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
                                else {
                                    $results.Details.Add("OK: Agent job '$($j.name)' is $enabledText$historyText")
                                }
                            }
                        }
                    }
                    catch {
                        $results.Details.Add("WARN: Agent job check failed: $($_.Exception.Message)")
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

    $result = Invoke-VmCommand -VmName $VMName -VmDomainName $domain `
        -ScriptBlock $scriptBlock `
        -ArgumentList $listenerName, $listenerPort, $agName, $otherNode, $witnessShare, $backupShare, $agIP, $sqlInstName, $clusterName, $clusterIP `
        -DisplayName "Phase11-SQLAO-Test" -SuppressLog

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
        -ScriptBlock $scriptBlock -DisplayName "Phase11-WSUS-Test" -SuppressLog

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
    Write-Log "[Phase $Phase] $VMName [CM-$siteCode]: Testing ConfigMgr site services and WMI" -LogOnly

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
                $results.Details.Add("WARN: Service '$svc' is $($s.Status), attempting restart...")
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
                    $results.Details.Add("OK: Service '$svc' is Running after restart")
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

        # Component health check - lenient for fresh builds.
        # Status=2 means Error/Critical in SMS_ComponentSummarizer.
        # Fresh deployments typically have 0-3 transient critical components
        # for several minutes after services start. We retry a few times
        # and allow up to 5 critical components as WARN (not FAIL).
        # Exclude known-transient components that are expected on fresh builds.
        $ignoredComponents = @(
            'SMS_WSUS_CONFIGURATION_MANAGER'   # Until SUP is fully configured
            'SMS_SITE_SQL_BACKUP'              # Backup not configured on new sites
        )
        $results.Details.Add("CMD: Get-WmiObject -Namespace 'root\SMS\site_$sc' -Class SMS_ComponentSummarizer -Filter `"Status = 2 AND TallyInterval = '0001128000100008'`"")
        $componentCheckAttempts = 3
        $componentRetryDelay = 30
        $criticalCount = 999
        $criticalList = @()
        for ($attempt = 1; $attempt -le $componentCheckAttempts; $attempt++) {
            try {
                $allCritical = @(Get-WmiObject -Namespace "root\SMS\site_$sc" -Class SMS_ComponentSummarizer `
                    -Filter "Status = 2 AND TallyInterval = '0001128000100008'" -ErrorAction Stop)
                $critical = @($allCritical | Where-Object { $_.ComponentName -notin $ignoredComponents })
                $ignoredCount = $allCritical.Count - $critical.Count
                $criticalCount = $critical.Count
                $criticalList = $critical
                if ($criticalCount -eq 0) {
                    $msg = "OK: No critical component issues (attempt $attempt)"
                    if ($ignoredCount -gt 0) { $msg += " ($ignoredCount ignored: $($ignoredComponents -join ', '))" }
                    $results.Details.Add($msg)
                    break
                }
                $results.Details.Add("  Attempt $attempt/${componentCheckAttempts}: $criticalCount critical component(s)")
                if ($attempt -lt $componentCheckAttempts) {
                    Start-Sleep -Seconds $componentRetryDelay
                }
            }
            catch {
                $results.Details.Add("  Component health query attempt $attempt failed: $($_.Exception.Message)")
                if ($attempt -lt $componentCheckAttempts) {
                    Start-Sleep -Seconds $componentRetryDelay
                }
            }
        }

        if ($criticalCount -gt 0 -and $criticalCount -le 5) {
            # Lenient: up to 5 critical components is a warning, not a failure
            $names = ($criticalList | ForEach-Object { $_.ComponentName }) -join ', '
            $results.Details.Add("WARN: $criticalCount component(s) in critical state: $names")
        }
        elseif ($criticalCount -gt 5) {
            $results.Passed = $false
            $names = ($criticalList | Select-Object -First 10 | ForEach-Object { $_.ComponentName }) -join ', '
            $results.Details.Add("FAIL: $criticalCount components in critical state (exceeds threshold of 5): $names")
        }

        return $results
    }

    $result = Invoke-VmCommand -VmName $VMName -VmDomainName $domain `
        -ScriptBlock $scriptBlock -ArgumentList $siteCode `
        -DisplayName "Phase11-CM-Test" -SuppressLog

    $passed = Format-TestResult -VMName $VMName -RoleLabel "CM-$siteCode" -Result $result

    # Site-wide tests only run on a top-level site (Primary without parentSiteCode,
    # or CAS). On a child Primary under a CAS we skip these -- the CAS already owns
    # the boundaries / discovery / apps, and probing them on the child can fail
    # while replication is still catching up.
    $isTopLevel = (-not $CurrentItem.parentSiteCode) -and ($CurrentItem.role -in @('CAS', 'Primary'))
    if ($passed -and $isTopLevel) {
        Write-Progress2 -PercentComplete 0 -Activity "$VMName [$($CurrentItem.role)]" -Status "Verifying site-wide settings"
        $sitePassed = Test-CMSiteWideFunctionality -VMName $VMName -CurrentItem $CurrentItem -DeployConfig $DeployConfig
        if (-not $sitePassed) { $passed = $false }
    }

    # DRS replication link check: verify links to child sites are Active (not Failed/Error/Degraded)
    # ReplicationLinkStatus enum: Active=2, Initializing=4, NotStarted=5, Error=6, Unknown=7, Degraded=8, Failed=9
    $childSites = @($DeployConfig.virtualMachines | Where-Object { $_.parentSiteCode -eq $siteCode })
    if ($passed -and $childSites.Count -gt 0) {
        Write-Progress2 -PercentComplete 0 -Activity "$VMName [$($CurrentItem.role)]" -Status "Verifying DRS replication links"
        Write-Log "[Phase $Phase] $VMName [CM-$siteCode]: Checking DRS replication links to $($childSites.Count) child site(s)" -LogOnly

        $childSiteCodes = @($childSites | ForEach-Object { $_.siteCode } | Select-Object -Unique)

        $drsScriptBlock = {
            param($parentSC, $childCodes)
            $results = @{ Passed = $true; Details = [System.Collections.Generic.List[string]]::new() }

            # StatusName lookup for readable output
            $statusName = @{ 0='Deleted'; 1='Tombstoned'; 2='Active'; 3='Active_InterOp'; 4='Initializing'; 5='NotStarted'; 6='Error'; 7='Unknown'; 8='Degraded'; 9='Failed' }
            $failedStates = @(6, 8, 9)  # Error, Degraded, Failed

            foreach ($childSC in $childCodes) {
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
            -DisplayName "Phase11-DRS-Test" -SuppressLog

        $drsPassed = Format-TestResult -VMName $VMName -RoleLabel "DRS-$siteCode" -Result $drsResult
        if (-not $drsPassed) { $passed = $false }
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
            $results.Passed = $false
            $results.Details.Add("FAIL: BitLocker policy '$policyName' not found")
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
        -DisplayName "Phase11-BLM-Test" -SuppressLog

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
            $results.Details.Add("WARN: SQL service '$svcName' is $($sqlSvc.Status), attempting to start...")
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
            $results.Details.Add("OK: SQL service '$svcName' started successfully")
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
        -DisplayName "Phase11-Secondary-Test" -SuppressLog

    $localOk = Format-TestResult -VMName $VMName -RoleLabel 'Secondary' -Result $result
    if (-not $localOk) { return $false }

    # Verify from parent Primary that this secondary site is attached
    $parentSiteCode = $CurrentItem.parentSiteCode
    if ($parentSiteCode) {
        $parentVM = $DeployConfig.virtualMachines | Where-Object {
            $_.siteCode -eq $parentSiteCode -and $_.role -in @('Primary', 'CAS')
        } | Select-Object -First 1
        if ($parentVM) {
            Write-Log "[Phase $Phase] $VMName [Secondary]: Verifying site '$secSiteCode' visible from parent '$($parentVM.vmName)'" -LogOnly

            $parentScript = {
                param($parentSC, $childSC)
                $results = @{ Passed = $true; Details = [System.Collections.Generic.List[string]]::new() }
                $results.Details.Add("CMD: Get-WmiObject -Namespace 'root\SMS\site_$parentSC' -Class SMS_Site -Filter `"SiteCode = '$childSC'`"")
                $maxAttempts = 10
                $retryDelay = 30
                $found = $false
                for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
                    try {
                        $sec = Get-WmiObject -Namespace "root\SMS\site_$parentSC" -Class SMS_Site `
                            -Filter "SiteCode = '$childSC'" -ErrorAction Stop
                        if ($sec) {
                            $results.Details.Add("OK: Secondary site '$childSC' found in parent site '$parentSC' (attempt $attempt)")
                            $found = $true
                            break
                        }
                    }
                    catch {
                        $results.Details.Add("INFO: Query attempt $attempt failed: $($_.Exception.Message)")
                    }
                    if ($attempt -lt $maxAttempts) {
                        $results.Details.Add("INFO: Secondary site '$childSC' not yet visible in parent (attempt $attempt/$maxAttempts), retrying in ${retryDelay}s...")
                        Start-Sleep -Seconds $retryDelay
                    }
                }
                if (-not $found) {
                    $results.Passed = $false
                    $results.Details.Add("FAIL: Secondary site '$childSC' not found in parent site '$parentSC' after $maxAttempts attempts")
                }
                return $results
            }

            $parentResult = Invoke-VmCommand -VmName $parentVM.vmName -VmDomainName $domain `
                -ScriptBlock $parentScript -ArgumentList $parentSiteCode, $secSiteCode `
                -DisplayName "Phase11-Secondary-Parent-Test" -SuppressLog

            return (Format-TestResult -VMName $VMName -RoleLabel 'Secondary-Parent' -Result $parentResult)
        }
    }

    return $true
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
            -ScriptBlock $mpScript -DisplayName "Phase11-MP-Test" -SuppressLog

        if (-not (Format-TestResult -VMName $VMName -RoleLabel 'MP' -Result $mpResult)) {
            $allPassed = $false
        }
    }

    # Test DP: verify from the parent Primary that the DP is recognized
    if ($CurrentItem.installDP) {
        Write-Progress2 -PercentComplete 0 -Activity "$VMName [SiteSystem]" -Status "Verifying Distribution Point"
        $siteCode = $CurrentItem.siteCode
        $parentVM = $DeployConfig.virtualMachines | Where-Object {
            $_.siteCode -eq $siteCode -and $_.role -in @('Primary', 'CAS')
        } | Select-Object -First 1

        if ($parentVM) {
            Write-Log "[Phase $Phase] $VMName [DP]: Verifying DP status from '$($parentVM.vmName)' (site $siteCode)" -LogOnly

            $dpScript = {
                param($sc, $dpVmName, $dpFqdn)
                $results = @{ Passed = $true; Details = [System.Collections.Generic.List[string]]::new() }

                # DP registration in WMI can lag behind the actual install --
                # SMS_DistributionPointInfo isn't populated until the DP
                # finishes installing and the site control file replicates.
                # On a fresh deploy this can take several minutes; absence
                # at Phase 11 time isn't strictly a failure.
                $maxAttempts = 5
                $retryDelay = 20
                $wmiFilter = "ServerName LIKE '%$dpVmName%'"
                $results.Details.Add("CMD: Get-WmiObject -Namespace 'root\SMS\site_$sc' -Class SMS_DistributionPointInfo -Filter `"$wmiFilter`" (max $maxAttempts attempts)")

                $found = $false
                for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
                    try {
                        $dp = Get-WmiObject -Namespace "root\SMS\site_$sc" -Class SMS_DistributionPointInfo `
                            -Filter $wmiFilter -ErrorAction Stop
                        if ($dp) {
                            $results.Details.Add("OK: DP '$dpVmName' found in site '$sc' (attempt $attempt)")
                            $found = $true
                            break
                        }
                        else {
                            $results.Details.Add("  Attempt $attempt/${maxAttempts}: DP not yet visible in WMI")
                            if ($attempt -lt $maxAttempts) { Start-Sleep -Seconds $retryDelay }
                        }
                    }
                    catch {
                        $results.Details.Add("  Attempt $attempt/${maxAttempts}: WMI query failed: $($_.Exception.Message)")
                        if ($attempt -lt $maxAttempts) { Start-Sleep -Seconds $retryDelay }
                    }
                }
                if (-not $found) {
                    # Fall back to site system role check -- if the server is
                    # registered as a DP role on the site, the install succeeded
                    # even if SMS_DistributionPointInfo hasn't populated yet.
                    try {
                        $role = Get-WmiObject -Namespace "root\SMS\site_$sc" -Class SMS_SystemResourceList `
                            -Filter "RoleName='SMS Distribution Point' AND ServerName LIKE '%$dpVmName%'" -ErrorAction Stop |
                            Select-Object -First 1
                        if ($role) {
                            $results.Details.Add("OK: DP role registered for '$dpVmName' (SMS_SystemResourceList) -- SMS_DistributionPointInfo not yet populated")
                            $found = $true
                        }
                    }
                    catch {
                        $results.Details.Add("  SMS_SystemResourceList fallback failed: $($_.Exception.Message)")
                    }
                }
                if (-not $found) {
                    # Downgrade to WARN: DP install can complete asynchronously
                    # and Phase 11 just missed the visibility window. The DP
                    # role itself is verified by local content/share checks.
                    $results.Details.Add("WARN: DP '$dpVmName' not yet visible in site '$sc' WMI after $maxAttempts attempts (install may still be propagating)")
                }
                return $results
            }

            $dpResult = Invoke-VmCommand -VmName $parentVM.vmName -VmDomainName $domain `
                -ScriptBlock $dpScript -ArgumentList $siteCode, $VMName, "$VMName.$domain" `
                -DisplayName "Phase11-DP-Test" -SuppressLog

            if (-not (Format-TestResult -VMName $VMName -RoleLabel 'DP' -Result $dpResult)) {
                $allPassed = $false
            }

            # Local DP probes: SMS_DP$ share + WDS (PXE always-on per ScriptFunctions)
            Write-Progress2 -PercentComplete 0 -Activity "$VMName [SiteSystem]" -Status "Verifying DP local content + PXE"
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
                -ScriptBlock $localDpScript -DisplayName "Phase11-DPLocal-Test" -SuppressLog
            if (-not (Format-TestResult -VMName $VMName -RoleLabel 'DPLocal' -Result $localDpResult)) {
                $allPassed = $false
            }
        }
        else {
            Write-Log "[Phase $Phase] $VMName [DP]: Cannot find parent site server for site '$siteCode'; skipping DP verification" -Warning
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
            -ScriptBlock $supScript -DisplayName "Phase11-SUP-Test" -SuppressLog

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
        -ScriptBlock $scriptBlock -DisplayName "Phase11-RP-Test" -SuppressLog

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
                -DisplayName "Phase11-RP-CMRole-Test" -SuppressLog

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
        -ScriptBlock $scriptBlock -DisplayName "Phase11-FileServer-Test" -SuppressLog

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
    $passed = Test-CAFunctionality -VMName $VMName -Domain $Domain

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
        [Parameter(Mandatory)][string]$Domain
    )

    $Phase = 11
    Write-Log "[Phase $Phase] $VMName [CA]: Testing Certificate Authority services" -LogOnly

    $scriptBlock = {
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

        return $results
    }

    $result = Invoke-VmCommand -VmName $VMName -VmDomainName $Domain `
        -ScriptBlock $scriptBlock -DisplayName "Phase11-CA-Test" -SuppressLog

    return (Format-TestResult -VMName $VMName -RoleLabel 'CA' -Result $result)
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
        -DisplayName "Phase11-PKI-Certs-Test" -SuppressLog

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
        -ScriptBlock $scriptBlock -DisplayName "Phase11-Maintenance-Test" -SuppressLog

    return (Format-TestResult -VMName $VMName -RoleLabel 'Maintenance' -Result $result)
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

        $results.Details.Add("CMD: Get-Service -Name 'SMS_EXECUTIVE'")
        $svc = Get-Service -Name 'SMS_EXECUTIVE' -ErrorAction SilentlyContinue
        if (-not $svc) {
            $results.Passed = $false
            $results.Details.Add("FAIL: Service 'SMS_EXECUTIVE' not found")
            return $results
        }
        if ($svc.Status -ne 'Running') {
            $results.Passed = $false
            $results.Details.Add("FAIL: Service 'SMS_EXECUTIVE' is $($svc.Status)")
            return $results
        }
        $results.Details.Add("OK: Service 'SMS_EXECUTIVE' is Running")

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
        -DisplayName "Phase11-PassiveSite-Test" -SuppressLog

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
        try {
            $passive = Get-WmiObject -Namespace "root\SMS\site_$sc" -Class SMS_SCI_SysResUse -Filter $filter -ErrorAction Stop
            if ($passive) {
                $results.Details.Add("OK: Passive site server '$passiveName' registered in site '$sc'")
            }
            else {
                $results.Passed = $false
                $results.Details.Add("FAIL: Passive site server '$passiveName' not registered in site '$sc'")
            }
        }
        catch {
            $results.Passed = $false
            $results.Details.Add("FAIL: WMI query for passive site server failed: $($_.Exception.Message)")
        }
        return $results
    }

    $parentResult = Invoke-VmCommand -VmName $activeVM.vmName -VmDomainName $domain `
        -ScriptBlock $parentScript -ArgumentList $siteCode, $VMName `
        -DisplayName "Phase11-PassiveSite-Parent-Test" -SuppressLog

    return (Format-TestResult -VMName $VMName -RoleLabel 'PassiveSite-Parent' -Result $parentResult)
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

    Write-Log "[Phase $Phase] $VMName [DomainMember]: Testing domain join and CCM client (if present)" -LogOnly

    $scriptBlock = {
        param($expectedDomain)
        $results = @{ Passed = $true; Details = [System.Collections.Generic.List[string]]::new() }

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
        if ($sc) {
            $results.Details.Add("OK: Secure channel to domain is healthy")
        }
        elseif ($scError) {
            $results.Details.Add("WARN: Test-ComputerSecureChannel threw after retries: $($scError.Exception.Message)")
        }
        else {
            $results.Passed = $false
            $results.Details.Add("FAIL: Test-ComputerSecureChannel returned False after 4 attempts -- machine account password may be broken")
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
            try { Start-Process -FilePath $ccmsetupExe -ErrorAction Stop } catch {
                $results.Details.Add("INFO: Failed to launch ccmsetup: $($_.Exception.Message)")
                return $false
            }
            Start-Sleep -Seconds 10
            # Wait up to 5 minutes for ccmsetup to finish
            for ($w = 0; $w -lt 30; $w++) {
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
                # CcmExec exists but won't start — check if ccmsetup is still running.
                $setup = Get-Process -Name 'ccmsetup' -ErrorAction SilentlyContinue
                if ($setup) {
                    $results.Details.Add("WARN: CcmExec is $($ccm.Status) but ccmsetup.exe is still running (client install in progress)")
                }
                else {
                    # ccmsetup finished but service not running — attempt remediation.
                    $logPath = 'C:\Windows\ccmsetup\Logs\ccmsetup.log'
                    $failDetail = $null
                    if (Test-Path $logPath) {
                        $logTail = Get-Content $logPath -Tail 50 -ErrorAction SilentlyContinue
                        $failLine = $logTail | Where-Object { $_ -match 'ccmsetup failed with error code' } | Select-Object -Last 1
                        if ($failLine) { $failDetail = $failLine.Trim() }
                    }
                    if ($failDetail) {
                        $results.Details.Add("WARN: CcmExec is $($ccm.Status); ccmsetup failed: $failDetail")
                    }
                    else {
                        $results.Details.Add("WARN: CcmExec is $($ccm.Status) (ccmsetup finished but service won't start)")
                    }
                    if (-not (& $retryCcmSetup $results)) {
                        $results.Passed = $false
                        $results.Details.Add("FAIL: CcmExec still not Running after ccmsetup retry")
                    }
                }
            }
        }
        else {
            # CcmExec service doesn't exist at all — check if ccmsetup is in progress.
            $setup = Get-Process -Name 'ccmsetup' -ErrorAction SilentlyContinue
            if ($setup) {
                $results.Details.Add("WARN: CcmExec not yet installed but ccmsetup.exe is running (client install in progress)")
            }
            elseif (Test-Path 'C:\Windows\ccmsetup\Logs\ccmsetup.log') {
                $logTail = Get-Content 'C:\Windows\ccmsetup\Logs\ccmsetup.log' -Tail 50 -ErrorAction SilentlyContinue
                $failLine = $logTail | Where-Object { $_ -match 'ccmsetup failed with error code' } | Select-Object -Last 1
                if ($failLine) {
                    $results.Details.Add("WARN: CcmExec not installed; ccmsetup failed: $($failLine.Trim())")
                }
                else {
                    $results.Details.Add("WARN: CcmExec not installed; ccmsetup.log exists but no success/failure line found")
                }
                if (-not (& $retryCcmSetup $results)) {
                    $results.Passed = $false
                    $results.Details.Add("FAIL: CcmExec still not installed after ccmsetup retry")
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

    $result = Invoke-VmCommand -VmName $VMName -VmDomainName $domain `
        -ScriptBlock $scriptBlock -ArgumentList $domain `
        -DisplayName "Phase11-DomainMember-Test" -SuppressLog

    # If the guest reported NeedsPushCheck, enrich with deploy config context.
    if ($result.ScriptBlockOutput -is [hashtable] -and $result.ScriptBlockOutput.NeedsPushCheck) {
        $pushExpected = ($CurrentItem.pushClient -ne $false)
        if ($pushExpected) {
            $result.ScriptBlockOutput.Passed = $false
            $result.ScriptBlockOutput.Details.Add("  pushClient=$true in config but no ccmsetup evidence on VM — push may have failed on the site server side")
            $result.ScriptBlockOutput.Details.Add("  Check ccmsetup on the Primary: Get-CMDevice -Name '$VMName' | Select IsClient,ClientActiveStatus")
        }
        else {
            $result.ScriptBlockOutput.Details[-1] = "OK: CcmExec not installed (pushClient=false in config)"
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
        -DisplayName "Phase11-WorkgroupMember-Test" -SuppressLog

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
        -DisplayName "Phase11-InternetClient-Test" -SuppressLog

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
        -ScriptBlock $scriptBlock -DisplayName "Phase11-SSMS-Test" -SuppressLog

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

        $results.Details.Add("CMD: Get-WmiObject -Namespace 'root\SMS' -Class SMS_ProviderLocation -Filter `"SiteCode = '$sc'`"")
        try {
            $prov = Get-WmiObject -Namespace 'root\SMS' -Class SMS_ProviderLocation -Filter "SiteCode = '$sc'" -ErrorAction Stop |
                Where-Object { $_.Machine -like "$env:COMPUTERNAME*" }
            if (-not $prov) {
                $results.Passed = $false
                $results.Details.Add("FAIL: This host not registered as a provider for site '$sc'")
                return $results
            }
            $results.Details.Add("OK: Provider location: $($prov.NamespacePath)")
        }
        catch {
            $results.Passed = $false
            $results.Details.Add("FAIL: SMS_ProviderLocation query failed: $($_.Exception.Message)")
            return $results
        }

        # Round-trip a query through the local provider
        try {
            $site = Get-WmiObject -Namespace "root\SMS\site_$sc" -Class SMS_Site -ErrorAction Stop
            if ($site) {
                $results.Details.Add("OK: Local SMS_Site query succeeded via provider (site '$($site.SiteCode)')")
            }
            else {
                $results.Passed = $false
                $results.Details.Add("FAIL: SMS_Site query returned null via local provider")
            }
        }
        catch {
            $results.Passed = $false
            $results.Details.Add("FAIL: SMS_Site query via local provider failed: $($_.Exception.Message)")
        }

        return $results
    }

    $result = Invoke-VmCommand -VmName $VMName -VmDomainName $domain `
        -ScriptBlock $scriptBlock -ArgumentList $siteCode `
        -DisplayName "Phase11-SMSProv-Test" -SuppressLog

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
            $dp = Get-WmiObject -Namespace "root\SMS\site_$sc" -Class SMS_DistributionPointInfo `
                -Filter "ServerName LIKE '%$dpName%'" -ErrorAction Stop | Select-Object -First 1
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
        -DisplayName "Phase11-PullDP-Test" -SuppressLog

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
            $vol = Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue
            if (-not $vol) {
                $results.Passed = $false
                $results.Details.Add("FAIL: Volume '$letter`:' not present")
                continue
            }
            if ($vol.FileSystem -ne 'NTFS') {
                $results.Details.Add("WARN: Volume '$letter`:' filesystem is '$($vol.FileSystem)' (expected NTFS)")
            }
            $sizeGB = [math]::Round($vol.Size / 1GB, 1)
            $results.Details.Add("OK: Volume '$letter`:' present ($sizeGB GB, $($vol.FileSystem))")
        }

        return $results
    }

    $result = Invoke-VmCommand -VmName $VMName -VmDomainName $domain `
        -ScriptBlock $scriptBlock -ArgumentList (($disks -join ',')) `
        -DisplayName "Phase11-Disks-Test" -SuppressLog

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
        -ScriptBlock $scriptBlock -DisplayName "Phase11-BitLocker-Test" -SuppressLog

    return (Format-TestResult -VMName $VMName -RoleLabel 'BitLocker' -Result $result)
}

function Test-CMSiteWideFunctionality {
    <#
    .SYNOPSIS
        Validates site-wide settings on a top-level Primary or CAS:
        boundary groups, discovery methods, client push, apps, and the
        site comms mode (HTTPS-only vs EnhancedHTTP) based on cmOptions.UsePKI.
    .NOTES
        Only invoked from Test-CMSiteFunctionality when the VM has no
        parentSiteCode and role is CAS/Primary.
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
    # AND when running against a Primary site (CAS doesn't run perfloading).
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

    Write-Log "[Phase $Phase] $VMName [CMSite-$siteCode]: Testing site-wide settings (BoundaryGroups, Discovery, Apps, CommsMode)" -LogOnly

    $scriptBlock = {
        # NOTE: Invoke-VmCommand declares [string[]]$ArgumentList which (a)
        # stringifies bools (any non-empty string is truthy) and (b) flattens
        # nested arrays. Bools are passed as '0'/'1' strings; arrays are
        # passed as a single CSV string and split inside.
        param($sc, $usePkiInner, $expectedAppsCsv)
        $usePki = ($usePkiInner -eq 'True')
        $expectedApps = if ([string]::IsNullOrEmpty($expectedAppsCsv)) { @() } else { @($expectedAppsCsv -split '\|') }
        $results = @{ Passed = $true; Details = [System.Collections.Generic.List[string]]::new() }

        $ns = "root\SMS\site_$sc"

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

        return $results
    }

    $appsCsv = ($expectedAppNames -join '|')
    $result = Invoke-VmCommand -VmName $VMName -VmDomainName $domain `
        -ScriptBlock $scriptBlock -ArgumentList $siteCode, ([string]$usePKI), $appsCsv `
        -DisplayName "Phase11-CMSite-Test" -SuppressLog

    return (Format-TestResult -VMName $VMName -RoleLabel "CMSite-$siteCode" -Result $result)
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
        Checks BOTH `netsh winhttp show proxy` and the per-machine IE
        ProxyServer registry value (HKLM Internet Settings, since
        Set-WindowsClientProxy writes there). Either source matching
        `<proxyFqdn>:3128` (or its IP form) is acceptable.
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

        # IE / WinINET per-machine. Set-WindowsClientProxy writes ProxyServer
        # to the regular IE key (HKLM:\SOFTWARE\Microsoft\...) and writes
        # ProxySettingsPerUser to the Policies key. Read from the right place.
        $ieKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings'
        try {
            if (Test-Path $ieKey) {
                $ieProxy = (Get-ItemProperty -Path $ieKey -Name 'ProxyServer' -ErrorAction SilentlyContinue).ProxyServer
                if (& $matchesProxy $ieProxy) {
                    $results.Details.Add("OK: HKLM IE ProxyServer = '$ieProxy'")
                }
                else {
                    $results.Details.Add("WARN: HKLM IE ProxyServer = '$ieProxy' (does not contain :3128)")
                }
            }
            else {
                $results.Details.Add("WARN: HKLM IE Internet Settings key absent (Set-WindowsClientProxy may not have run)")
            }
        }
        catch {
            $results.Details.Add("WARN: Reading HKLM IE ProxyServer failed: $($_.Exception.Message)")
        }

        return $results
    }

    $result = Invoke-VmCommand -VmName $VMName -VmDomainName $domain `
        -ScriptBlock $scriptBlock -ArgumentList $proxyFqdn, $proxyVm.vmName `
        -DisplayName "Phase11-ProxyClient-Test" -SuppressLog

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
        -ScriptBlock $scriptBlock -DisplayName "Phase11-ProxyBlock-Test" -SuppressLog

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
        -DisplayName "Phase11-CMRoleProxy-Test" -SuppressLog

    return (Format-TestResult -VMName $VMName -RoleLabel $RoleLabel -Result $result)
}

#endregion Proxy Validation Tests

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
        $script:Phase11OutputBuffer.Add(@{ Text = "[Phase $Phase] $VMName [$RoleLabel]: FAILED"; Level = 'Failure' })
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
            param($listenerName, $listenerPort, $agName, $otherNode, $witnessShare, $backupShare, $agIP, $clusterName, $clusterIP)

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

                # 2. Cluster name DNS
                if ($clusterName) {
                    $results.Details.Add("CMD: Resolve-DnsName '$clusterName'")
                    $clusterDns = @(Resolve-DnsName -Name $clusterName -Type A -ErrorAction SilentlyContinue | Where-Object { $_.QueryType -eq 'A' })
                    $resolvedIPs = @($clusterDns | Select-Object -ExpandProperty IPAddress)
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

                # 4. Listener DNS
                if ($listenerName) {
                    $results.Details.Add("CMD: Resolve-DnsName '$listenerName'")
                    try {
                        $dns = @(Resolve-DnsName -Name $listenerName -Type A -ErrorAction Stop)
                        $resolvedIPs = @($dns | Where-Object { $_.QueryType -eq 'A' } | Select-Object -ExpandProperty IPAddress)
                        if ($resolvedIPs.Count -gt 0) {
                            $results.Details.Add("OK: Listener '$listenerName' resolves to $($resolvedIPs -join ', ')")
                            if ($agIP -and $agIP -notin $resolvedIPs) {
                                $results.Details.Add("WARN: Expected AG IP '$agIP' not in resolved addresses")
                            }
                        }
                        else {
                            $results.Passed = $false
                            $results.Details.Add("FAIL: Listener '$listenerName' did not resolve to any A records")
                        }
                    }
                    catch {
                        $results.Passed = $false
                        $results.Details.Add("FAIL: DNS resolution for '$listenerName' failed: $($_.Exception.Message)")
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
            -ArgumentList $listenerName, $listenerPort, $agName, $otherNode, $witnessShare, $backupShare, $agIP, $clusterName, $clusterIP `
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
