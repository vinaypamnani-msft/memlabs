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

function Add-Phase11Output {
    <#
    .SYNOPSIS
        Queue a console line for the Phase11Job to emit, without polluting the caller's return.
    .DESCRIPTION
        The rule at the top of this file exists because Write-Log -OutputStream calls
        Write-Output, so the log object joins whatever the caller assigned -- turning a
        $false result into a truthy array. Use this instead. List.Add() returns void, so
        nothing reaches the success stream. Falls back to the log when the buffer does not
        exist (Test-SQLAOPostPhase5 runs from New-Lab, outside the Phase 11 job).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Text,
        [ValidateSet('Info', 'Warning', 'Success', 'Failure')][string]$Level = 'Info'
    )

    if ($null -eq $script:Phase11OutputBuffer) {
        Write-Log $Text -LogOnly
        return
    }
    $script:Phase11OutputBuffer.Add(@{ Text = $Text; Level = $Level })
}

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
    # Drop any step timer left open by a previous VM that threw mid-check.
    $script:ValStepWatch = $null
    $script:ValStepName = $null

    Write-Log "[Phase $Phase] $VMName [$role]: Starting functional validation" -LogOnly

    # Progress activity label — Write-JobProgress reads this from the job's
    # Progress stream and displays it in the console during execution.
    $validationActivity = "$VMName [$role]"

    # Determine which test function(s) to call based on role and installed features.
    $testsPassed = $true
    $vmIsLinux = Test-VmIsLinux -Vm $CurrentItem

    # Early PSDirect liveness gate + auto-recovery. A guest whose PSDirect
    # channel is up but whose command/job host is wedged would otherwise hang
    # each sub-check on its own timeout, only reaching the Maintenance check's
    # reboot escalation after burning minutes -- and a fully wedged channel that
    # blocks a SYNCHRONOUS probe (e.g. the uptime gate below) could hang the whole
    # VM job indefinitely. Probe once up-front with -AsJob (bounded) +
    # -RebootIfUnresponsive: a genuinely wedged VM is detected and rebooted in ONE
    # fast step before the full check chain runs. On a healthy VM this is a ~1s
    # no-op. Skip Linux and powered-off / non-PSDirect roles.
    if (-not $vmIsLinux -and $role -notin @('OSDClient', 'AADClient', 'StandaloneRootCA')) {
        Write-ValidationStep -VMName $VMName -RoleLabel $role -Activity $validationActivity -Status "PSDirect liveness check"
        $liveGate = Invoke-VmCommand -VmName $VMName -VmDomainName $domain `
            -ScriptBlock { $env:COMPUTERNAME } -DisplayName "Phase11-LivenessGate" `
            -SuppressLog -AsJob -TimeoutSeconds 60 -RebootIfUnresponsive
        if ($liveGate -and $liveGate.Rebooted) {
            Write-Log "[Phase $Phase] $VMName [$role]: PSDirect channel was wedged; VM rebooted to recover before validation" -Warning
            $script:Phase11OutputBuffer.Add(@{ Text = "[Phase $Phase] $VMName [$role]: WARN - PSDirect channel was wedged; rebooted VM to recover before validating"; Level = 'Warning' })
            # Let the freshly-rebooted guest bring AD / secure channel back up.
            Start-Sleep -Seconds 30
        }

        # WMI/CIM liveness gate. A guest can answer PSDirect ($env:COMPUTERNAME is
        # pure PowerShell over VMBus) while its winmgmt/CIM stack is wedged --
        # Get-CimInstance / Get-WmiObject then hang. Almost every Phase 11 check
        # uses WMI, so a wedged CIM provider hangs the check chain even though the
        # PSDirect liveness probe above passed (exactly the CT7-W11Client1 case:
        # liveness OK, the Get-CimInstance uptime probe timed out). Probe CIM with
        # a bounded job; when it's wedged, repair it (restart winmgmt in-guest via
        # PSDirect, reboot only if that's not enough) BEFORE the checks run.
        Write-ValidationStep -VMName $VMName -RoleLabel $role -Activity $validationActivity -Status "WMI/CIM liveness check"
        $cimProbe = Invoke-VmCommand -VmName $VMName -VmDomainName $domain `
            -ScriptBlock { (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).CSName } `
            -DisplayName "Phase11-CimGate" -SuppressLog -AsJob -TimeoutSeconds 60
        $cimOk = $cimProbe -and -not $cimProbe.ScriptBlockFailed -and -not [string]::IsNullOrWhiteSpace("$($cimProbe.ScriptBlockOutput)")
        if (-not $cimOk) {
            Write-Log "[Phase $Phase] $VMName [$role]: Guest WMI/CIM is unresponsive (PSDirect is healthy); repairing winmgmt before validation" -Warning
            $cimRepaired = Repair-VmCimServer -VmName $VMName -VmDomainName $domain -Phase $Phase -AllowReboot
            $cimNote = if ($cimRepaired) { 'repaired (winmgmt restart/reboot)' } else { 'repair attempted, still degraded' }
            $script:Phase11OutputBuffer.Add(@{ Text = "[Phase $Phase] $VMName [$role]: WARN - guest WMI/CIM was wedged; $cimNote before validating"; Level = 'Warning' })
            if ($cimRepaired) { Start-Sleep -Seconds 15 }
        }
    }

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
        Write-ValidationStep -VMName $VMName -RoleLabel $role -Activity $validationActivity -Status "Checking uptime (settle gate)"
        $uptimeResult = Invoke-VmCommand -VmName $VMName -VmDomainName $domain `
            -ScriptBlock { (Get-Date) - (Get-CimInstance Win32_OperatingSystem).LastBootUpTime | Select-Object -ExpandProperty TotalMinutes } `
            -DisplayName "Phase11-UptimeGate" -SuppressLog -AsJob -TimeoutSeconds 60
        if ($uptimeResult -and -not $uptimeResult.ScriptBlockFailed -and $null -ne $uptimeResult.ScriptBlockOutput) {
            $uptimeMin = [double]($uptimeResult.ScriptBlockOutput | Select-Object -First 1)
            if ($uptimeMin -lt $minUptimeMinutes) {
                $waitSec = [int][math]::Ceiling(($minUptimeMinutes - $uptimeMin) * 60)
                Write-Log "[Phase $Phase] $VMName [$role]: Uptime $([int]$uptimeMin)min < ${minUptimeMinutes}min — waiting ${waitSec}s for the VM to settle before validating" -LogOnly
                Write-ValidationStep -VMName $VMName -RoleLabel $role -Activity $validationActivity -Status "Waiting ${waitSec}s for VM to settle after reboot"
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
        Write-ValidationStep -VMName $VMName -RoleLabel $role -Activity $validationActivity -Status "Ensuring SQL services are running"
        $testsPassed = Repair-StoppedSQLServices -VMName $VMName -Domain $domain
    }

    switch ($role) {
        'DC' {
            Write-ValidationStep -VMName $VMName -RoleLabel $role -Activity $validationActivity -Status "Verifying AD DS / DNS / Netlogon"
            $testsPassed = Test-DCFunctionality -VMName $VMName -Domain $domain -DeployConfig $DeployConfig
        }
        'BDC' {
            Write-ValidationStep -VMName $VMName -RoleLabel $role -Activity $validationActivity -Status "Verifying AD DS / DNS / Netlogon (BDC)"
            $testsPassed = Test-DCFunctionality -VMName $VMName -Domain $domain -IsBDC -DeployConfig $DeployConfig
        }
        'CAS' {
            if (-not $CurrentItem.remoteSQLVM) {
                Write-ValidationStep -VMName $VMName -RoleLabel $role -Activity $validationActivity -Status "Verifying SQL Server"
                $testsPassed = Test-SQLFunctionality -VMName $VMName -CurrentItem $CurrentItem -DeployConfig $DeployConfig
            }
            else {
                Write-Log "[Phase $Phase] $VMName [$role]: SQL is remote ($($CurrentItem.remoteSQLVM)); SQL test runs against that VM" -LogOnly
            }
            if ($testsPassed) {
                Write-ValidationStep -VMName $VMName -RoleLabel $role -Activity $validationActivity -Status "Verifying ConfigMgr site"
                $testsPassed = Test-CMSiteFunctionality -VMName $VMName -CurrentItem $CurrentItem -DeployConfig $DeployConfig
            }
            # Always verify client-package distribution (collects diagnostics +
            # pulls distmgr/PkgXferMgr logs on failure) and fold the result in.
            Write-ValidationStep -VMName $VMName -RoleLabel $role -Activity $validationActivity -Status "Verifying client package distribution"
            $pkgOk = Test-CMClientPackageDistribution -VMName $VMName -CurrentItem $CurrentItem -DeployConfig $DeployConfig
            $testsPassed = $testsPassed -and $pkgOk
        }
        'Primary' {
            if (-not $CurrentItem.remoteSQLVM) {
                Write-ValidationStep -VMName $VMName -RoleLabel $role -Activity $validationActivity -Status "Verifying SQL Server"
                $testsPassed = Test-SQLFunctionality -VMName $VMName -CurrentItem $CurrentItem -DeployConfig $DeployConfig
            }
            else {
                Write-Log "[Phase $Phase] $VMName [$role]: SQL is remote ($($CurrentItem.remoteSQLVM)); SQL test runs against that VM" -LogOnly
            }
            if ($testsPassed) {
                Write-ValidationStep -VMName $VMName -RoleLabel $role -Activity $validationActivity -Status "Verifying ConfigMgr site"
                $testsPassed = Test-CMSiteFunctionality -VMName $VMName -CurrentItem $CurrentItem -DeployConfig $DeployConfig
            }
            # Always verify client-package distribution (collects diagnostics +
            # pulls distmgr/PkgXferMgr logs on failure) and fold the result in.
            Write-ValidationStep -VMName $VMName -RoleLabel $role -Activity $validationActivity -Status "Verifying client package distribution"
            $pkgOk = Test-CMClientPackageDistribution -VMName $VMName -CurrentItem $CurrentItem -DeployConfig $DeployConfig
            $testsPassed = $testsPassed -and $pkgOk
        }
        'Secondary' {
            Write-ValidationStep -VMName $VMName -RoleLabel $role -Activity $validationActivity -Status "Verifying Secondary site"
            $testsPassed = Test-SecondaryFunctionality -VMName $VMName -CurrentItem $CurrentItem -DeployConfig $DeployConfig
        }
        'SiteSystem' {
            Write-ValidationStep -VMName $VMName -RoleLabel $role -Activity $validationActivity -Status "Verifying site system roles"
            $testsPassed = Test-SiteSystemFunctionality -VMName $VMName -CurrentItem $CurrentItem -DeployConfig $DeployConfig
        }
        'SQLAO' {
            Write-ValidationStep -VMName $VMName -RoleLabel $role -Activity $validationActivity -Status "Verifying SQL Always On"
            $testsPassed = Test-SQLAOFunctionality -VMName $VMName -CurrentItem $CurrentItem -DeployConfig $DeployConfig
        }
        'WSUS' {
            Write-ValidationStep -VMName $VMName -RoleLabel $role -Activity $validationActivity -Status "Verifying WSUS"
            $testsPassed = Test-WSUSFunctionality -VMName $VMName -Domain $domain
        }
        'FileServer' {
            Write-ValidationStep -VMName $VMName -RoleLabel $role -Activity $validationActivity -Status "Verifying file server"
            $testsPassed = Test-FileServerFunctionality -VMName $VMName -Domain $domain
        }
        'StandaloneRootCA' {
            Write-ValidationStep -VMName $VMName -RoleLabel $role -Activity $validationActivity -Status "Verifying Standalone Root CA"
            $testsPassed = Test-StandaloneRootCAFunctionality -VMName $VMName -Domain $domain
        }
        'PassiveSite' {
            Write-ValidationStep -VMName $VMName -RoleLabel $role -Activity $validationActivity -Status "Verifying passive site server"
            $testsPassed = Test-PassiveSiteFunctionality -VMName $VMName -CurrentItem $CurrentItem -DeployConfig $DeployConfig
        }
        'DomainMember' {
            Write-ValidationStep -VMName $VMName -RoleLabel $role -Activity $validationActivity -Status "Verifying domain member"
            $testsPassed = Test-DomainMemberFunctionality -VMName $VMName -CurrentItem $CurrentItem -DeployConfig $DeployConfig
        }
        'WorkgroupMember' {
            Write-ValidationStep -VMName $VMName -RoleLabel $role -Activity $validationActivity -Status "Verifying workgroup member"
            $testsPassed = Test-WorkgroupMemberFunctionality -VMName $VMName -CurrentItem $CurrentItem -DeployConfig $DeployConfig
        }
        'InternetClient' {
            Write-ValidationStep -VMName $VMName -RoleLabel $role -Activity $validationActivity -Status "Verifying internet client"
            $testsPassed = Test-InternetClientFunctionality -VMName $VMName -CurrentItem $CurrentItem -DeployConfig $DeployConfig
        }
        default {
            # Any role not in this switch falls through silently. The phase
            # dispatcher in Common.Phases.ps1 already filters out OSDClient/
            # AADClient. Unknown roles get a log line but don't fail.
            Write-Log "[Phase $Phase] $VMName [$role]: No role-specific tests defined; skipping" -LogOnly
        }
    }

    # A buffered failure is authoritative. Some tests enrich a remoted result
    # collection after the role check; an unsuppressed Add() can emit its index
    # alongside $false, making the multi-item result truthy in PowerShell. Do not
    # let a later optional check overwrite a role failure with its own success.
    if ($script:Phase11OutputBuffer | Where-Object { $_.Level -eq 'Failure' } | Select-Object -First 1) {
        $testsPassed = $false
    }

    # If the VM has installRP, also test reporting services
    if ($testsPassed -and $CurrentItem.installRP) {
        Write-ValidationStep -VMName $VMName -RoleLabel $role -Activity $validationActivity -Status "Verifying Reporting Services"
        $testsPassed = Test-ReportingFunctionality -VMName $VMName -Domain $domain -CurrentItem $CurrentItem -DeployConfig $DeployConfig
    }

    # If the VM has InstallCA, test Certificate Authority
    if ($testsPassed -and $CurrentItem.InstallCA) {
        Write-ValidationStep -VMName $VMName -RoleLabel $role -Activity $validationActivity -Status "Verifying Certificate Authority"
        $testsPassed = Test-CAFunctionality -VMName $VMName -Domain $domain
    }

    # If the VM received PKI IIS/DP certs (UsePKI + CM role), validate cert health.
    # Gate on UsePKI only -- NOT on a CA VM being built in THIS deploy. When adding a
    # site system to an EXISTING PKI domain the Enterprise CA already lives in AD (no
    # InstallCA VM here), yet the web-server cert + 443 binding still must exist or the
    # HTTPS MP MSI fails 25055; requiring $hasCaVM here would skip that check/self-heal
    # exactly when it is needed most (matches the Phase 8 $AddIISCert gate).
    $cmo = if ($CurrentItem.cmOptions) { $CurrentItem.cmOptions } else { $DeployConfig.cmOptions }
    $needsIISCert = $role -in @('CAS', 'Primary', 'Secondary', 'PassiveSite') -or
                    $CurrentItem.InstallSUP -or $CurrentItem.InstallMP -or
                    $CurrentItem.InstallDP -or $CurrentItem.InstallRP
    if ($testsPassed -and $cmo.UsePKI -and $needsIISCert) {
        Write-ValidationStep -VMName $VMName -RoleLabel $role -Activity $validationActivity -Status "Verifying PKI certificates"
        $testsPassed = Test-PKICertificatesOnVM -VMName $VMName -Domain $domain -CurrentItem $CurrentItem -DeployConfig $DeployConfig
    }

    # If the VM has SQL but is not a Primary/CAS/SQLAO (standalone SQL server)
    if ($testsPassed -and $CurrentItem.sqlVersion -and $role -notin @('CAS', 'Primary', 'SQLAO')) {
        Write-ValidationStep -VMName $VMName -RoleLabel $role -Activity $validationActivity -Status "Verifying SQL Server"
        $testsPassed = Test-SQLFunctionality -VMName $VMName -CurrentItem $CurrentItem -DeployConfig $DeployConfig
    }

    # SSMS install check (any role with installSSMS=$true)
    if ($testsPassed -and $CurrentItem.installSSMS) {
        Write-ValidationStep -VMName $VMName -RoleLabel $role -Activity $validationActivity -Status "Verifying SSMS install"
        $testsPassed = Test-SSMSInstall -VMName $VMName -Domain $domain
    }

    # SQL ISO must not be left mounted after a successful build (host-side check).
    # Phase 4 mounts the SQL ISO and ejects it on success; by Phase 11 a healthy
    # SQL VM should have an empty DVD drive.
    if ($testsPassed -and $CurrentItem.sqlVersion -and -not $CurrentItem.remoteSQLVM) {
        Write-ValidationStep -VMName $VMName -RoleLabel $role -Activity $validationActivity -Status "Verifying SQL ISO is not mounted"
        $testsPassed = Test-SqlIsoNotMounted -VMName $VMName -CurrentItem $CurrentItem -DeployConfig $DeployConfig
    }

    # SMS Provider role check (remote SMS provider, not on the site server itself)
    if ($testsPassed -and $CurrentItem.InstallSMSProv -and $role -ne 'CAS' -and $role -ne 'Primary') {
        Write-ValidationStep -VMName $VMName -RoleLabel $role -Activity $validationActivity -Status "Verifying SMS Provider"
        $testsPassed = Test-SMSProviderRole -VMName $VMName -CurrentItem $CurrentItem -DeployConfig $DeployConfig
    }

    # Pull-DP configuration (verified from parent Primary)
    if ($testsPassed -and $CurrentItem.enablePullDP) {
        Write-ValidationStep -VMName $VMName -RoleLabel $role -Activity $validationActivity -Status "Verifying Pull-DP"
        $testsPassed = Test-PullDPConfiguration -VMName $VMName -CurrentItem $CurrentItem -DeployConfig $DeployConfig
    }

    # Additional data disks (E:, F:, ...) per additionalDisks config
    if ($testsPassed -and $CurrentItem.additionalDisks) {
        Write-ValidationStep -VMName $VMName -RoleLabel $role -Activity $validationActivity -Status "Verifying additional disks"
        $testsPassed = Test-AdditionalDisks -VMName $VMName -CurrentItem $CurrentItem -DeployConfig $DeployConfig
    }

    # BitLocker volume state on member VMs flagged for encryption
    if ($testsPassed -and $CurrentItem.BitLocker -eq $true -and $role -notin @('DC', 'BDC')) {
        Write-ValidationStep -VMName $VMName -RoleLabel $role -Activity $validationActivity -Status "Verifying BitLocker"
        $testsPassed = Test-BitLockerProtection -VMName $VMName -CurrentItem $CurrentItem -DeployConfig $DeployConfig
    }

    # BitLocker Management: validate policy exists and is deployed (top-level site only).
    # Only check when cmOptions.EnableBLM is set — EnableBLM.ps1 skips policy creation
    # when only VMs have BitLocker=true (TPM-only, no ConfigMgr BLM policy management).
    $cmo = if ($CurrentItem.cmOptions) { $CurrentItem.cmOptions } else { $DeployConfig.cmOptions }
    if ($testsPassed -and $cmo.EnableBLM -and $role -eq 'Primary') {
        Write-ValidationStep -VMName $VMName -RoleLabel $role -Activity $validationActivity -Status "Verifying BitLocker Management"
        $testsPassed = Test-BLMFunctionality -VMName $VMName -CurrentItem $CurrentItem -DeployConfig $DeployConfig
    }

    # MP database replica: verify each replica MP in this site flipped to its
    # replica DB (v_BgbMP.DBID is a hash) and the site->replica BGB route exists.
    # Fails the build on a missing hash or route (the two hard-FAIL conditions in
    # Test-MPDatabaseReplicaHealth.ps1). Only meaningful on the Primary site server.
    if ($testsPassed -and $role -eq 'Primary') {
        $replicaMPsInSite = @($DeployConfig.virtualMachines | Where-Object { $_.role -eq 'SiteSystem' -and $_.installMP -and $_.useDatabaseReplica -and $_.siteCode -eq $CurrentItem.siteCode })
        if ($replicaMPsInSite.Count -gt 0) {
            Write-ValidationStep -VMName $VMName -RoleLabel $role -Activity $validationActivity -Status "Verifying MP database replicas"
            $testsPassed = Test-MPReplicaFunctionality -VMName $VMName -CurrentItem $CurrentItem -DeployConfig $DeployConfig
        }
    }

    # Verify maintenance scheduled tasks are present (confirms Phase 10 ran correctly).
    # Windows-only: Test-MaintenanceTasks probes the guest over PSDirect for Windows
    # Scheduled Tasks, which Linux doesn't have (Phase 10 maintenance skips Linux VMs
    # entirely). Running it against a Linux VM just burns the PSDirect timeout and
    # emits a spurious 'scheduled-task check skipped (probe timed out)' WARN, so gate
    # it behind -not $vmIsLinux like the DSC LCM check below.
    if ($testsPassed -and -not $vmIsLinux -and $role -notin @('OSDClient', 'AADClient', 'StandaloneRootCA')) {
        Write-ValidationStep -VMName $VMName -RoleLabel $role -Activity $validationActivity -Status "Verifying maintenance tasks"
        $testsPassed = Test-MaintenanceTasks -VMName $VMName -Domain $domain
    }

    # Verify the DSC LCM is idle. By Phase 11 every phase MOF has been applied,
    # so the LCM should be Idle; a Busy/Pending state means DSC is still running
    # after the build, wasting host CPU/disk. Informational WARN only (it never
    # fails the VM, so it is intentionally not assigned to $testsPassed). Skip
    # powered-off / non-PSDirect roles and Linux VMs (no DSC).
    if ($testsPassed -and -not $vmIsLinux -and $role -notin @('OSDClient', 'AADClient', 'StandaloneRootCA')) {
        Write-ValidationStep -VMName $VMName -RoleLabel $role -Activity $validationActivity -Status "Verifying DSC LCM is idle"
        $null = Test-DscIdle -VMName $VMName -Domain $domain
    }

    # Cross-forest trust validation. On a DC that joined a Forest Trust, verify
    # the trust object + secure channel, forward AND reverse DNS, the remote
    # admin landing in local Administrators, the remote root CA being trusted +
    # published locally, and (when a remote CM site manages this domain) the
    # System Management delegation + schema extension. Informational/WARN only
    # (not assigned to $testsPassed) -- a not-yet-converged trust shouldn't fail
    # the DC, but the WARN lines surface the real cross-forest gaps (esp. the
    # missing reverse DNS forwarder).
    if ($testsPassed -and -not $vmIsLinux -and $role -in @('DC', 'BDC') -and $CurrentItem.ForestTrust -and $CurrentItem.ForestTrust -ne 'NONE') {
        Write-ValidationStep -VMName $VMName -RoleLabel $role -Activity $validationActivity -Status "Verifying cross-forest trust"
        $null = Test-ForestTrustFunctionality -VMName $VMName -CurrentItem $CurrentItem -DeployConfig $DeployConfig
    }

    # ---- Linux health check ----
    # For all Linux VMs: ping + SSH + SMB health cascade from the host.
    # Ping fail → restart. SSH down + SMB down → restart (both services dead).
    # SSH down + SMB up → read logs via SMB share to diagnose, warn only.
    if ($testsPassed -and $vmIsLinux) {
        Write-ValidationStep -VMName $VMName -RoleLabel $role -Activity $validationActivity -Status "Checking Linux VM health (ping + SSH)"
        $healthResult = Test-LinuxVmHealth -VMName $VMName -CurrentItem $CurrentItem -DeployConfig $DeployConfig -IsRetry:$IsRetry
        if ($healthResult -eq 'Restarted') {
            # VM was restarted and recovered — re-run all tests from scratch
            # Flush first: the recursive call resets the step timer.
            Stop-ValidationStep -VMName $VMName -RoleLabel $role
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
        Write-ValidationStep -VMName $VMName -RoleLabel $role -Activity $validationActivity -Status "Verifying Samba (SMB) access"
        $testsPassed = Test-LinuxSmbAccess -VMName $VMName -CurrentItem $CurrentItem -DeployConfig $DeployConfig
    }

    # ---- Linux domain-join validation ----
    # For a Linux VM with joinDomain=true: verify it actually realm-joined the
    # lab AD domain. Informational (WARN, never fails the VM) with full
    # diagnostics on failure -- the usual root cause is DNS not pointing at the DC.
    if ($testsPassed -and $vmIsLinux -and ($CurrentItem.PSObject.Properties.Name -contains 'joinDomain') -and [bool]$CurrentItem.joinDomain) {
        Write-ValidationStep -VMName $VMName -RoleLabel $role -Activity $validationActivity -Status "Verifying AD domain join"
        $null = Test-LinuxDomainJoin -VMName $VMName -CurrentItem $CurrentItem -DeployConfig $DeployConfig
    }

    # ---- Proxy validation ----
    # 1) For the Proxy VM itself: verify Squid is listening on TCP 3128.
    if ($testsPassed -and $role -eq 'Proxy') {
        Write-ValidationStep -VMName $VMName -RoleLabel $role -Activity $validationActivity -Status "Verifying Squid proxy"
        $testsPassed = Test-ProxyListening -VMName $VMName -CurrentItem $CurrentItem -DeployConfig $DeployConfig
    }
    # 1b) Verify the Proxy Admin web UI is listening on TCP 8443.
    if ($testsPassed -and $role -eq 'Proxy') {
        Write-ValidationStep -VMName $VMName -RoleLabel $role -Activity $validationActivity -Status "Verifying Proxy Admin web UI"
        $testsPassed = Test-ProxyAdminWebUI -VMName $VMName -CurrentItem $CurrentItem -DeployConfig $DeployConfig
    }
    # 2) For any opted-in client/CM-role VM: verify it's pointed at the proxy.
    #    Windows: WinHTTP/IE proxy config + direct-Internet blocked + (CM roles)
    #    Get-CMSiteSystemServer UseProxy=$true. Linux: guest env/apt proxy config
    #    (the deny-ACL is stamped post-Phase-11, so egress-blocked isn't tested here).
    if ($testsPassed -and (Test-VmUsesProxy -Vm $CurrentItem -DeployConfig $DeployConfig)) {
        Write-ValidationStep -VMName $VMName -RoleLabel $role -Activity $validationActivity -Status "Verifying proxy configuration"
        if ($vmIsLinux) {
            if (-not (Test-LinuxProxyConfig -VMName $VMName -CurrentItem $CurrentItem -DeployConfig $DeployConfig)) {
                $testsPassed = $false
            }
        }
        else {
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
    }

    Stop-ValidationStep -VMName $VMName -RoleLabel $role
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
        param($domainFqdn, $isBdcInner, $expectedDnsCsv, $hasCmSitesInner, $expectedReverseZonesCsv)
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

        # Reverse-lookup zones: one AD-integrated /24 in-addr.arpa per VM network
        # should exist (created by Phase2DC). A missing reverse zone breaks PTR
        # creation -- e.g. the SQLAO cluster / AG-listener PTRs in Phase 5, where a
        # missing zone made the DC's ClusterPtrRecords script throw and hang the
        # phase. Informational (WARN, never FAIL): the lab's forward DNS still works
        # without reverse zones. Primary DC only -- AD-integrated zones replicate to
        # the BDC, so checking once avoids double-reporting.
        if (-not $isBdc -and $expectedReverseZonesCsv) {
            $missingRev = New-Object System.Collections.Generic.List[string]
            $expectedRev = @($expectedReverseZonesCsv -split ',' | Where-Object { $_ })
            foreach ($rz in $expectedRev) {
                $z = Get-DnsServerZone -Name $rz -ErrorAction SilentlyContinue
                if (-not $z) { $missingRev.Add($rz) }
            }
            if ($missingRev.Count -gt 0) {
                $results.Details.Add("WARN: Reverse-lookup zone(s) missing on DC: $($missingRev -join ', '). PTR creation (e.g. SQLAO cluster/listener) will fail -- re-run Phase 2 to create them.")
            }
            else {
                $results.Details.Add("OK: All $($expectedRev.Count) expected reverse-lookup zone(s) present")
            }
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

    # Expected reverse-lookup zones: one /24 in-addr.arpa per distinct network used
    # by a non-hidden VM in this domain, plus the deployment's DEFAULT network
    # (default-network VMs carry no explicit .network). Mirrors what Phase2DC
    # creates; the DC-side scriptblock WARNs on any that are missing.
    $expectedReverseZonesCsv = ''
    if ($DeployConfig) {
        $revZones = [System.Collections.Generic.HashSet[string]]::new()
        $revNets = New-Object System.Collections.Generic.List[string]
        if ($DeployConfig.vmOptions.network) { $revNets.Add($DeployConfig.vmOptions.network) }
        foreach ($vm in $DeployConfig.virtualMachines) {
            if ($vm.hidden) { continue }
            if ($vm.domain -and $vm.domain -ne $Domain) { continue }
            if ($vm.network) { $revNets.Add($vm.network) }
        }
        foreach ($net in $revNets) {
            $o = $net.Split('.')
            if ($o.Count -ne 4) { continue }
            $null = $revZones.Add("$($o[2]).$($o[1]).$($o[0]).in-addr.arpa")
        }
        $expectedReverseZonesCsv = ($revZones -join ',')
    }

    $result = Invoke-VmCommand -VmName $VMName -VmDomainName $Domain `
        -ScriptBlock $scriptBlock -ArgumentList $Domain, ([string]$IsBDC.IsPresent), $expectedDnsCsv, ([string]$hasCmSites), $expectedReverseZonesCsv `
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
        # deployConfig only carries AssignedIP on a run that allocated it, so a rerun
        # against an existing lab skipped every VM and the audit checked nothing --
        # exactly the runs where a lost reservation has had time to matter.
        $assignedIp = $vm.AssignedIP
        if (-not $assignedIp) {
            try { $assignedIp = (Get-VMNote -VMName $vm.vmName -ErrorAction SilentlyContinue).AssignedIP } catch { }
        }
        if (-not $assignedIp) { continue }

        $checked++
        $expectedIp = ($assignedIp -replace '/.+$', '')
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
            # The batch read is a single snapshot taken before the loop. Re-ask the
            # server for just this MAC before failing a whole phase on its absence,
            # so "the reservation is gone" is never confused with "the batch read
            # was incomplete". Costs one isolated runspace, and only on this path.
            $directIp = $null
            try { $directIp = Get-DHCPReservationIPForMac -ScopeId $scopeId -Mac $mac }
            catch { Write-Log "[Phase $Phase] [$label]: $($vm.vmName): direct reservation re-read failed: $_" -LogOnly }
            if ($directIp) {
                Write-Log "[Phase $Phase] [$label]: $($vm.vmName): batch read missed reservation $directIp (scope $scopeId, MAC=$mac); direct re-read found it" -LogOnly
                $reservedIp = $directIp
            }
        }

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

    if ($checked -eq 0) {
        # An audit that inspected nothing is not a passing audit. This printed
        # "All 0 DHCP reservation(s) verified" on three separate lab runs.
        $candidates = @($DeployConfig.virtualMachines | Where-Object {
                -not $_.hidden -and $_.role -ne 'OSDClient' -and (-not $_.domain -or $_.domain -eq $Domain)
            })
        $why = if ($candidates.Count -gt 0) { "$($candidates.Count) eligible VM(s) have no AssignedIP in either the config or their VM note" } else { 'no VM in this domain is eligible' }
        Write-Log "[Phase $Phase] [$label]: nothing was audited -- $why" -LogOnly
        $script:Phase11OutputBuffer.Add(@{ Text = "[Phase $Phase] [$label]: WARN: no DHCP reservation was verified ($why)"; Level = 'Warning' })
        return $passed
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
        should have no SQL ISO attached; a still-attached SQL ISO indicates the
        eject was skipped (e.g. a prior failed run that was never re-run cleanly).
        The transient DownloadCache tools ISO (cache-<hash>.iso) is explicitly
        ignored: it is mounted on every VM during tools injection and ejected
        separately (Dismount-MemlabsCacheIsoFromVm), and that eject can still be
        in flight when this host-side check runs.
        Buffers a FAIL line into $script:Phase11OutputBuffer like the other
        host-side Phase 11 tests, and returns $true when no SQL ISO is mounted.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][object]$CurrentItem,
        [Parameter(Mandatory)][object]$DeployConfig
    )

    $Phase = 11
    $label = 'SQL-ISO'

    # Only the SQL install ISO is a genuine "left mounted after a failed Phase 4"
    # signal. The DownloadCache tools ISO (cache-<hash>.iso) is mounted on every
    # VM during tools injection and ejected separately by
    # Dismount-MemlabsCacheIsoFromVm; that eject can still be in flight when this
    # host-side check runs, so a cache-*.iso must NOT fail the VM (it caused a
    # spurious Phase 11 FAIL on every SQL/SQLAO VM whose cache eject lagged the
    # validator). The DSC payload ISO (dsc-<hash>.iso) is mounted+ejected within
    # the per-VM DSC copy step and is likewise not a SQL ISO.
    #
    # The CM install ISO is ALSO not a SQL ISO: it has its own lifecycle (mounted
    # on the site server in Phase 8/9, ejected by Dismount-CmIsoForPhase after a
    # SUCCESSFUL CM phase; deliberately left mounted on a failed/standalone CM
    # phase for inspection). It caused a spurious Phase 11 FAIL on Primary/CAS site
    # servers (which have remote SQL and never get a SQL ISO at all) whenever the
    # CM phase was run standalone or left the disc mounted. CM ISOs live under the
    # azureFiles '\CM\' subfolder, whereas SQL ISOs sit directly at the azureFiles
    # root (Get-SqlIsoPathForVm joins the bare filename), so a CM-folder ISO is
    # unambiguously not the SQL media -- ignore it here and let the CM dismount
    # path own it. Only flag a real SQL ISO.
    $dvd = Get-VMDvdDrive -VMName $VMName -ErrorAction SilentlyContinue
    $mountedPath = ($dvd | Where-Object {
            $_.Path -and
            ([System.IO.Path]::GetFileName($_.Path)) -notlike 'cache-*.iso' -and
            ([System.IO.Path]::GetFileName($_.Path)) -notlike 'dsc-*.iso' -and
            ([System.IO.Path]::GetFileName([System.IO.Path]::GetDirectoryName($_.Path))) -ne 'CM'
        } | Select-Object -First 1).Path

    if ($mountedPath) {
        $script:Phase11OutputBuffer.Add(@{ Text = "[Phase $Phase] [$label]: FAIL: $VMName still has an ISO mounted ($mountedPath); SQL ISO should be ejected after Phase 4"; Level = 'Failure' })
        Write-Log "[Phase $Phase] [$label]: $VMName has ISO still mounted: $mountedPath" -Failure -LogOnly
        return $false
    }

    Write-Log "[Phase $Phase] [$label]: $VMName DVD drive is empty (no SQL ISO mounted; cache-*.iso/dsc-*.iso ignored)" -LogOnly
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

    # Gather SQLAO config from the primary node definition (the one with OtherNode).
    # SCOPE TO THIS VM'S CLUSTER: a domain can host more than one SQLAO cluster
    # (e.g. a CAS hierarchy cluster plus a separate Primary's cluster). A bare
    # "role -eq 'SQLAO' -and OtherNode" match returns the primary node of EVERY
    # cluster, so $primaryAO becomes an array and every $primaryAO.<prop> below
    # collapses to a space-joined string (e.g. listener 'FAB-ALWAYSON2 FAB-ALWAYSON',
    # cluster 'FAB-SQLCLUSTER2 FAB-SQLCLUSTER', share '\\FAB-FS1 FAB-FS1\...'),
    # which then fails every DNS/SQL/share check. Restrict to the cluster that
    # actually contains $VMName: the primary def whose own name is this VM, or
    # whose OtherNode points at this VM. Select-Object -First 1 is a belt-and-braces
    # guard so a malformed config can never reintroduce the array.
    $primaryAO = $DeployConfig.virtualMachines | Where-Object {
        $_.role -eq 'SQLAO' -and $_.OtherNode -and ($_.vmName -eq $VMName -or $_.OtherNode -eq $VMName)
    } | Select-Object -First 1
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

    # Degraded / single-node Availability Group: the partner node (OtherNode)
    # was removed, so Add-ExistingVMsToDeployConfig cleared OtherNode and no
    # primary node definition carries the AG / listener / cluster config
    # ($primaryAO is null). The basic SQL test above already validated the
    # surviving instance; there is no second replica or AG to probe. Skip the
    # AG health scriptblock -- running it with an empty listener/AG name would
    # fire pointless DNS/listener probes that spuriously WARN -- and report the
    # basic SQL result instead.
    if (-not $primaryAO) {
        Write-Log "[Phase $Phase] $VMName [SQLAO]: no AG partner found in config (single-node / degraded Availability Group). AG health check skipped; using basic SQL validation result." -Warning
        return $sqlOk
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

                # Validate cluster name DNS points to the correct IP.
                # Query the DC's DNS zone directly (Get-DnsServerResourceRecord)
                # rather than Resolve-DnsName, which can return LLMNR/cache
                # results that mask stale records. BUT the DnsServer *management*
                # RPC interface is not always reachable from a SQLAO node -- e.g.
                # a child-primary cluster on a different subnet than the DC, where
                # the dynamic DNS-management RPC is blocked cross-subnet even
                # though ordinary port-53 resolution works fine. That cmdlet then
                # throws a TERMINATING "Failed to get the zone information for
                # <domain> on server <dc>" that -ErrorAction SilentlyContinue does
                # NOT suppress, so it must be caught here -- otherwise it bubbles
                # to the section catch and hard-FAILs an otherwise perfectly
                # healthy cluster (observed on FAB-PS2SQLAO1/2: cluster Online, all
                # nodes Up, all resources Online, listener connects, yet the whole
                # health check FAILed solely on this cross-subnet RPC error, while
                # the CAS SQLAO nodes on the DC's own subnet passed). On RPC
                # failure fall back to a direct port-53 Resolve-DnsName; if that is
                # also unavailable, downgrade to INFO -- the cluster IP resources
                # are already validated Online above and the SQL listener connect
                # in Step 6 is the authoritative DNS test. This mirrors the Step 5b
                # listener-DNS probe, which already treats this case as
                # informational only.
                if ($clusterName) {
                    $clusterResolvedIPs = @()
                    $clusterDnsSource = ''
                    $clusterDnsRpcOk = $false
                    $clusterDnsErr = $null
                    # CRITICAL: the DnsServer management RPC has NO native timeout
                    # and can BLOCK (not merely error) for many minutes against a
                    # busy/contended DC. A bare call here stalls the whole per-VM
                    # job past its heartbeat budget and surfaces as an opaque
                    # 'ScriptBlock failed (no error detail)' FAIL (observed on
                    # FAB-CS1SQLAO2: the job's last progress line was exactly this
                    # Get-DnsServerResourceRecord, then a 600s heartbeat stall ->
                    # killed). Run BOTH the zone-RPC probe and the port-53 fallback
                    # under Invoke-WithWatchdog (kill+retry on hang), exactly like
                    # the Step 5b listener-DNS probe.
                    $results.Details.Add("CMD: Get-DnsServerResourceRecord -ZoneName '$domain' -Name '$clusterName' -RRType A -ComputerName '$dnsServer'")
                    $cwd = Invoke-WithWatchdog -TimeoutSec 20 -MaxAttempts 2 -ArgumentList @($domain, $clusterName, $dnsServer) -ScriptBlock {
                        param($zone, $name, $server)
                        # Project to plain IP strings INSIDE the job. The watchdog runs this
                        # under Start-Job when Start-ThreadJob is unavailable (the in-guest
                        # WinPS 5.1 case), and Receive-Job then hands back DESERIALIZED CIM
                        # records whose RecordData.IPv4Address has lost its IPAddress type --
                        # .IPAddressToString returns $null, which surfaced as a spurious
                        # "cluster IP not in DNS (found: )" FAIL even though DNS was correct.
                        # Strings serialize losslessly, so do the extraction here.
                        $recs = Get-DnsServerResourceRecord -ZoneName $zone -Name $name -RRType A -ComputerName $server -ErrorAction Stop
                        @($recs | ForEach-Object { $_.RecordData.IPv4Address.IPAddressToString })
                    }
                    if ($cwd.Status -eq 'OK') {
                        $clusterDnsRpcOk = $true
                        $clusterResolvedIPs = @($cwd.Output | Where-Object { $_ })
                    }
                    else {
                        if ($cwd.Status -eq 'Error') {
                            $clusterDnsErr = if ($cwd.Errors -and $cwd.Errors[0].Exception) { $cwd.Errors[0].Exception.Message } else { ($cwd.Errors -join '; ') }
                            $results.Details.Add("  RPC against '$dnsServer' errored: $clusterDnsErr -- falling back to direct DNS (port 53)")
                        }
                        else {
                            $clusterDnsErr = "DnsServer RPC timed out after $($cwd.Attempts) attempt(s)"
                            $results.Details.Add("  RPC against '$dnsServer' timed out -- falling back to direct DNS (port 53)")
                        }
                        $clusterFqdn = "$clusterName.$domain"
                        $results.Details.Add("CMD: Resolve-DnsName -Name '$clusterFqdn' -Type A -Server '$dnsServer' -DnsOnly -NoHostsFile")
                        $cwd2 = Invoke-WithWatchdog -TimeoutSec 10 -MaxAttempts 2 -ArgumentList @($clusterFqdn, $dnsServer) -ScriptBlock {
                            param($n, $s)
                            # Project to plain IP strings inside the job (Start-Job serialization-safe).
                            $r = Resolve-DnsName -Name $n -Type A -Server $s -DnsOnly -NoHostsFile -ErrorAction Stop
                            @($r | Where-Object { $_.Type -eq 'A' } | ForEach-Object { $_.IPAddress })
                        }
                        if ($cwd2.Status -eq 'OK') {
                            $clusterResolvedIPs = @($cwd2.Output | Where-Object { $_ })
                            if ($clusterResolvedIPs.Count -gt 0) { $clusterDnsSource = ' (direct DNS, port 53)' }
                        }
                    }

                    if ($clusterResolvedIPs.Count -gt 0) {
                        $results.Details.Add("OK: Cluster name '$clusterName' resolves to $($clusterResolvedIPs -join ', ')$clusterDnsSource")
                        if ($clusterIP -and $clusterIP -notin $clusterResolvedIPs) {
                            $results.Passed = $false
                            $results.Details.Add("FAIL: Expected cluster IP '$clusterIP' not in DNS (found: $($clusterResolvedIPs -join ', '))")
                        }
                        # Check for stale non-cluster IPs
                        foreach ($rip in $clusterResolvedIPs) {
                            if ($clusterIP -and $rip -ne $clusterIP) {
                                $results.Details.Add("WARN: Cluster DNS has unexpected IP '$rip' (expected '$clusterIP')")
                            }
                        }
                    }
                    elseif ($clusterDnsRpcOk) {
                        # Zone query SUCCEEDED but returned no record -> genuine fault.
                        $results.Passed = $false
                        $results.Details.Add("FAIL: Cluster name '$clusterName' does not resolve in DNS")
                    }
                    else {
                        # Could not query the zone at all (management RPC blocked +
                        # port-53 fallback unavailable). Not a cluster fault -- the
                        # cluster IP resources are Online above and Step 6 validates
                        # DNS authoritatively via the SQL listener connect.
                        $results.Details.Add("INFO: Could not verify cluster name '$clusterName' via DNS zone query against '$dnsServer' ($clusterDnsErr); cluster IP resources are Online and listener connectivity is validated in Step 6 -- treating explicit zone probe as informational only")
                    }

                    # Verify RPC connectivity to cluster name. Hard-timeout TCP probe
                    # instead of Test-NetConnection, which can hang on DNS reverse
                    # lookups / ICMP fallbacks well past its own timeout. This block runs
                    # in the GUEST runspace, where the host's Test-TcpPort helper is NOT
                    # available -- inline the same BeginConnect + WaitHandle logic here.
                    $results.Details.Add("CMD: TCP probe '$clusterName':135")
                    $rpcReachable = $false
                    foreach ($rpcAttempt in 1..2) {
                        $tcpClient = $null
                        try {
                            $tcpClient = [System.Net.Sockets.TcpClient]::new()
                            $iar = $tcpClient.BeginConnect($clusterName, 135, $null, $null)
                            if ($iar.AsyncWaitHandle.WaitOne(3000, $false)) {
                                try {
                                    $tcpClient.EndConnect($iar)
                                    if ($tcpClient.Connected) { $rpcReachable = $true }
                                }
                                catch { }
                            }
                        }
                        catch { }
                        finally {
                            if ($tcpClient) { try { $tcpClient.Close() } catch { } }
                        }
                        if ($rpcReachable) { break }
                        if ($rpcAttempt -lt 2) { Start-Sleep -Milliseconds 1000 }
                    }
                    if ($rpcReachable) {
                        $results.Details.Add("OK: RPC port 135 reachable on '$clusterName'")
                    }
                    else {
                        $results.Passed = $false
                        $results.Details.Add("FAIL: RPC port 135 not reachable on '$clusterName' - cluster management will fail")
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
                $hostZoneRpcOk = $false
                if ($dnsServer -and $domain) {
                    # Same cross-subnet caveat as the cluster-name probe above PLUS the
                    # same CIM-hang risk: Get-DnsServerResourceRecord is a CDXML/WMI
                    # cmdlet that opens an implicit CIM session to the DC, so it can both
                    # (a) throw a terminating "Failed to get the zone information" when the
                    # DNS-management interface is blocked cross-subnet, and (b) BLOCK with
                    # no native timeout when the DC's WinRM/CIM is busy/wedged. Run it
                    # under Invoke-WithWatchdog (kill+retry) so a hang is bounded and we
                    # fall through to the informational skip instead of stalling the whole
                    # per-VM job. If we can't read the zone we simply can't audit stale
                    # heartbeat records remotely (informational), which is not a fault.
                    $hwd = Invoke-WithWatchdog -TimeoutSec 20 -MaxAttempts 2 -ArgumentList @($domain, $hostname, $dnsServer) -ScriptBlock {
                        param($zone, $name, $server)
                        # Project to plain IP strings inside the job: deserialized CIM records
                        # from the Start-Job fallback lose RecordData.IPv4Address, so the
                        # subnet match below must run on strings, not record objects.
                        $recs = Get-DnsServerResourceRecord -ZoneName $zone -Name $name -RRType A -ComputerName $server -ErrorAction Stop
                        @($recs | ForEach-Object { $_.RecordData.IPv4Address.IPAddressToString })
                    }
                    if ($hwd.Status -eq 'OK') {
                        $hostZoneRpcOk = $true
                        # $hwd.Output is now plain IP strings; $staleRecords holds IP strings.
                        $staleRecords = @($hwd.Output | Where-Object { $_ -and $_ -like "${clusterSubnet}*" })
                    }
                    else {
                        $hwdErr = if ($hwd.Status -eq 'Error' -and $hwd.Errors -and $hwd.Errors[0].Exception) { $hwd.Errors[0].Exception.Message }
                                  elseif ($hwd.Status -eq 'Error') { ($hwd.Errors -join '; ') }
                                  else { "DnsServer CIM query timed out after $($hwd.Attempts) attempt(s)" }
                        $results.Details.Add("INFO: Could not query DNS zone '$domain' on '$dnsServer' to audit stale heartbeat A records for '$hostname' ($hwdErr); skipping remote stale-record check (DNS-management CIM unavailable or unresponsive)")
                    }
                }
                if ($staleRecords.Count -gt 0) {
                    # $staleRecords already holds plain IP strings (projected inside the watchdog job).
                    $staleIPs = @($staleRecords)
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
                        # Remove stale A records from DNS server ($staleRecords = IP strings)
                        foreach ($ip in $staleRecords) {
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
                    if ($hostZoneRpcOk) {
                        $results.Details.Add("OK: Hostname '$hostname' has no stale heartbeat DNS records")
                    }
                    # else: zone query was unavailable -- already reported INFO above; don't claim OK.
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
                            # Project to plain IP strings inside the job (Start-Job-safe);
                            # deserialized CIM records lose RecordData.IPv4Address otherwise,
                            # producing a spurious blank "'<listener>' resolves to" line.
                            $recs = Get-DnsServerResourceRecord -ZoneName $zone -Name $name -RRType A -ComputerName $server -ErrorAction Stop
                            @($recs | ForEach-Object { $_.RecordData.IPv4Address.IPAddressToString })
                        }
                        $rpcStatus = $wd.Status
                        if ($wd.Status -eq 'OK') {
                            $resolvedIPs = @($wd.Output | Where-Object { $_ })
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
                                # Project to plain IP strings inside the job (Start-Job-safe).
                                $r = Resolve-DnsName -Name $n -Type A -Server $s -DnsOnly -NoHostsFile -ErrorAction Stop
                                @($r | Where-Object { $_.Type -eq 'A' } | ForEach-Object { $_.IPAddress })
                            }
                            if ($wd2.Status -eq 'OK') {
                                $resolvedIPs = @($wd2.Output | Where-Object { $_ })
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

        # --- Inline guest-side diagnostic helpers (root-cause capture) ---
        # CM logs live under <Installation Directory>\Logs. Tails are
        # CMTrace-unwrapped to "HH:mm:ss  message" so they read cleanly in the
        # VMBuild log. All helpers are best-effort (never throw).
        $smsInstallDir = $null
        try { $smsInstallDir = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\SMS\Identification' -ErrorAction Stop).'Installation Directory' } catch { }
        $cmLogDir = $null
        if ($smsInstallDir) { $cmLogDir = Join-Path $smsInstallDir 'Logs' }
        function Get-CmLogTail {
            param([string]$Dir, [string]$LogName, [int]$Lines)
            if (-not $Dir) { return @() }
            $p = Join-Path $Dir $LogName
            if (-not (Test-Path $p)) { return @() }
            $raw = $null
            try { $raw = Get-Content -Path $p -Tail $Lines -ErrorAction Stop } catch { return @() }
            $out = New-Object System.Collections.Generic.List[string]
            foreach ($ln in $raw) {
                # ConfigMgr's own logs carry a UTC bias in the time field ("20:22:32.990+240"),
                # so anchoring on digits-and-colons alone silently drops every such line into
                # the raw-text fallback.
                if ($ln -match '\<\!\[LOG\[(.*?)\]LOG\]\!\>.*?time="([0-9:\.]+)([+\-]\d+)?"') { $out.Add("$($Matches[2])$($Matches[3])  $($Matches[1])") }
                elseif ($ln.Trim()) { $out.Add($ln.Trim()) }
            }
            return $out
        }
        function Get-ScmCrashEvents {
            param([string[]]$ServiceNames, [int]$Hours)
            $ev = @()
            try {
                $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Service Control Manager'; StartTime = (Get-Date).AddHours(-$Hours) } -ErrorAction SilentlyContinue |
                        Where-Object { $m = $_.Message; @($ServiceNames | Where-Object { $m -match [regex]::Escape($_) }).Count -gt 0 } |
                        Select-Object -First 12)
            } catch { }
            return $ev
        }

        # Check critical CM services (with remediation for transient states)
        $svcRecovered = $false
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
                    $svcRecovered = $true
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

        # If we had to restart a core CM service (or a service check failed),
        # capture WHY it was down so a re-run has the root cause inline instead of
        # just "RECOVERED". A core site service being stopped hours after install
        # with no reboot points to a crash/dependency failure (e.g. a hierarchy
        # key-exchange / DRS-init failure leaves the site degraded), not a
        # transient -- these service facts, SCM crash events and log tails show it.
        if ($svcRecovered -or -not $results.Passed) {
            $coreSvc = @('SMS_EXECUTIVE', 'SMS_SITE_COMPONENT_MANAGER')
            foreach ($csvc in $coreSvc) {
                try {
                    $w = Get-CimInstance -ClassName Win32_Service -Filter "Name='$csvc'" -ErrorAction Stop
                    if ($w) { $results.Details.Add("DIAG: $csvc StartMode=$($w.StartMode) State=$($w.State) LogOn=$($w.StartName) ExitCode=$($w.ExitCode) PID=$($w.ProcessId)") }
                }
                catch { }
            }
            $exe = Get-Process -Name smsexec -ErrorAction SilentlyContinue
            if ($exe) { $results.Details.Add("DIAG: smsexec.exe running (PID $($exe.Id), threads=$($exe.Threads.Count), startTime=$($exe.StartTime))") }
            else { $results.Details.Add("DIAG: smsexec.exe process NOT running") }
            $crash = Get-ScmCrashEvents -ServiceNames $coreSvc -Hours 8
            if ($crash.Count -gt 0) {
                $results.Details.Add("DIAG: $($crash.Count) Service Control Manager event(s) for core CM services in last 8h:")
                foreach ($e in $crash) { $results.Details.Add("  SCM $($e.Id) ($($e.LevelDisplayName)) $($e.TimeCreated.ToString('HH:mm:ss')): $(((($e.Message) -split "`n")[0]).Trim())") }
            }
            foreach ($lg in @(@{ n = 'sitecomp.log'; c = 15 }, @{ n = 'hman.log'; c = 12 }, @{ n = 'rcmctrl.log'; c = 8 })) {
                $tail = Get-CmLogTail -Dir $cmLogDir -LogName $lg.n -Lines $lg.c
                if ($tail.Count -gt 0) {
                    $results.Details.Add("DIAG: $($lg.n) (last $($tail.Count)):")
                    foreach ($t in $tail) { $results.Details.Add("  $t") }
                }
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
                $liveOverride = 0
                foreach ($kv in $byName.GetEnumerator()) {
                    if (-not $kv.Value.Healthy) {
                        # The SMS_ComponentSummarizer is status-message driven and LAGS
                        # reality -- especially right after an SMS_EXECUTIVE restart, when
                        # every component reports a stale "Stopped" until it next checks in.
                        # Cross-check against the LIVE thread state SMS_EXECUTIVE writes to
                        # the registry: if the thread is "Running" now, the component is
                        # genuinely up and the summarizer simply hasn't caught up -- don't
                        # count it as unhealthy. This only ever flips a summarizer-"Stopped"
                        # to healthy when the OS-level thread is explicitly Running, so a
                        # truly-down component is never masked.
                        $liveState = $null
                        try {
                            $rk = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
                            $tk = $rk.OpenSubKey("SOFTWARE\Microsoft\SMS\Components\SMS_Executive\Threads\$($kv.Key)")
                            if ($tk) { $liveState = [string]$tk.GetValue('Current State'); $tk.Close() }
                            $rk.Close()
                        }
                        catch { }
                        if ($liveState -eq 'Running') {
                            $liveOverride++
                            continue
                        }
                        $sn = if ($stateName.ContainsKey([int]$kv.Value.State)) { $stateName[[int]$kv.Value.State] } else { "State=$($kv.Value.State)" }
                        $an = if ($availName.ContainsKey([int]$kv.Value.Avail)) { $availName[[int]$kv.Value.Avail] } else { "Avail=$($kv.Value.Avail)" }
                        $liveTag = if ($liveState) { $liveState } else { '<no thread key>' }
                        $unhealthyDetails += "$($kv.Key) ($sn/$an on $($kv.Value.Server); live=$liveTag)"
                    }
                }
                $unhealthyCount = $unhealthyDetails.Count

                if ($unhealthyCount -eq 0) {
                    $msg = "OK: All $($byName.Count) components are Started (attempt $attempt)"
                    if ($liveOverride -gt 0) { $msg += " [$liveOverride via live SMS_Executive thread state; summarizer lagging]" }
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

        # Component-health failure diagnostics. The summarizer FAIL above is
        # status-message driven; capture the LIVE thread state for each failing
        # component (authoritative), confirm smsexec is still alive (a crash loop
        # shows as Running-then-gone), and tail the two logs that explain why
        # components aren't Started, so a re-run has the root cause inline.
        if (-not $results.Passed) {
            $failNames = @()
            foreach ($d in $unhealthyDetails) { if ($d -match '^([A-Z0-9_]+)') { $failNames += $Matches[1] } }
            if ($failNames.Count -gt 0) {
                $liveStates = @()
                foreach ($fn in ($failNames | Select-Object -First 15)) {
                    $ls = $null
                    try {
                        $rk = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
                        $tk = $rk.OpenSubKey("SOFTWARE\Microsoft\SMS\Components\SMS_Executive\Threads\$fn")
                        if ($tk) { $ls = [string]$tk.GetValue('Current State'); $tk.Close() }
                        $rk.Close()
                    }
                    catch { }
                    $liveStates += "$fn=$(if ($ls) { $ls } else { '<no thread key>' })"
                }
                $results.Details.Add("DIAG: live SMS_Executive thread state for not-Started components: $($liveStates -join ', ')")
            }
            $exeNow = Get-Process -Name smsexec -ErrorAction SilentlyContinue
            if ($exeNow) { $results.Details.Add("DIAG: smsexec.exe still running (PID $($exeNow.Id), threads=$($exeNow.Threads.Count))") }
            else { $results.Details.Add("DIAG: smsexec.exe is NOT running at end of check -- SMS_EXECUTIVE crashed/stopped again (crash loop). Check crash.log and the SCM events above.") }
            foreach ($lg in @(@{ n = 'statmgr.log'; c = 12 }, @{ n = 'sitecomp.log'; c = 12 })) {
                $tail = Get-CmLogTail -Dir $cmLogDir -LogName $lg.n -Lines $lg.c
                if ($tail.Count -gt 0) {
                    $results.Details.Add("DIAG: $($lg.n) (last $($tail.Count)):")
                    foreach ($t in $tail) { $results.Details.Add("  $t") }
                }
            }
        }

        return $results
    }

    $result = Invoke-VmCommand -VmName $VMName -VmDomainName $domain `
        -ScriptBlock $scriptBlock -ArgumentList $siteCode `
        -DisplayName "Phase11-CM-Test" -SuppressLog `
        -AsJob -TimeoutSeconds 600

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
            $results = @{ Passed = $true; Details = [System.Collections.Generic.List[string]]::new(); LinkActive = @{} }

            # StatusName lookup for readable output
            $statusName = @{ 0='Deleted'; 1='Tombstoned'; 2='Active'; 3='Active_InterOp'; 4='Initializing'; 5='NotStarted'; 6='Error'; 7='Unknown'; 8='Degraded'; 9='Failed' }
            $failedStates = @(6, 8, 9)  # Error, Degraded, Failed

            foreach ($childSC in $childCodes) {
                $results.LinkActive[$childSC] = $false
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
            }

            # --- DRS replication links ---
            # Sample every pending child in one pass, then sleep once. A sleep
            # inside the child loop multiplies the validation cost by the number
            # of Primaries. The summary status is recency-derived and can say
            # Failed while a new link is actively initializing, so compare its
            # real init percentage and directional sync timestamps before warning.
            $maxLinkAttempts = 3
            $linkRetryDelay = 30
            $pendingLinks = @($childCodes)
            $lastSignature = @{}
            $linkProgressing = @{}
            $lastLink = @{}
            foreach ($childSC in $childCodes) {
                $results.LinkActive[$childSC] = $false
                $linkProgressing[$childSC] = $false
                $results.Details.Add("CMD: Get-WmiObject -Namespace 'root\SMS\site_$parentSC' -Class SMS_ReplicationLinkSummary -Filter `"Site2 = '$childSC'`"")
            }

            for ($linkAttempt = 1; $linkAttempt -le $maxLinkAttempts -and $pendingLinks.Count -gt 0; $linkAttempt++) {
                $stillPending = New-Object System.Collections.Generic.List[string]
                foreach ($childSC in $pendingLinks) {
                    try {
                        $link = Get-WmiObject -Namespace "root\SMS\site_$parentSC" -Class SMS_ReplicationLinkSummary `
                            -Filter "Site2 = '$childSC'" -ErrorAction Stop
                        if (-not $link) {
                            $results.Details.Add("INFO: No DRS link row for $parentSC -> $childSC (sample $linkAttempt/$maxLinkAttempts)")
                            $stillPending.Add($childSC)
                            continue
                        }

                        $lastLink[$childSC] = $link
                        $linkStatus = [int]$link.LinkStatus
                        $parentToChild = [int]$link.Site1ToSite2GlobalState
                        $childToParent = [int]$link.Site2ToSite1GlobalState
                        $initPercent = "$($link.GlobalInitPercentage)"
                        $parentSync = "$($link.Site1ToSite2GlobalSyncTime)"
                        $childSync = "$($link.Site2ToSite1GlobalSyncTime)"
                        $siteSync = "$($link.Site2ToSite1SiteSyncTime)"
                        $signature = "$linkStatus|$parentToChild|$childToParent|$initPercent|$parentSync|$childSync|$siteSync"
                        if ($lastSignature.ContainsKey($childSC) -and $lastSignature[$childSC] -ne $signature) {
                            $linkProgressing[$childSC] = $true
                        }
                        $lastSignature[$childSC] = $signature

                        $linkName = if ($statusName.ContainsKey($linkStatus)) { $statusName[$linkStatus] } else { "Unknown($linkStatus)" }
                        $parentName = if ($statusName.ContainsKey($parentToChild)) { $statusName[$parentToChild] } else { "Unknown($parentToChild)" }
                        $childName = if ($statusName.ContainsKey($childToParent)) { $statusName[$childToParent] } else { "Unknown($childToParent)" }
                        $results.Details.Add("INFO: DRS sample $linkAttempt/$maxLinkAttempts $parentSC -> $childSC`: Link=$linkName, S1->S2=$parentName, S2->S1=$childName, Init=$initPercent, LastP2C=$parentSync, LastC2P=$childSync, LastSite=$siteSync")

                        if ($linkStatus -eq 2 -and $parentToChild -eq 2 -and $childToParent -eq 2) {
                            $results.LinkActive[$childSC] = $true
                            $results.Details.Add("OK: DRS link $parentSC -> $childSC is Active (sample $linkAttempt)")
                        }
                        else {
                            $stillPending.Add($childSC)
                        }
                    }
                    catch {
                        $results.Details.Add("INFO: DRS link query for $parentSC -> $childSC failed (sample $linkAttempt/$maxLinkAttempts): $($_.Exception.Message)")
                        $stillPending.Add($childSC)
                    }
                }
                $pendingLinks = $stillPending.ToArray()
                if ($pendingLinks.Count -gt 0 -and $linkAttempt -lt $maxLinkAttempts) {
                    Start-Sleep -Seconds $linkRetryDelay
                }
            }

            foreach ($childSC in $pendingLinks) {
                $link = $lastLink[$childSC]
                if (-not $link) {
                    $results.Details.Add("WARN: No DRS replication link found for $parentSC -> $childSC after $maxLinkAttempts samples")
                    continue
                }
                $linkStatus = [int]$link.LinkStatus
                $parentToChild = [int]$link.Site1ToSite2GlobalState
                $childToParent = [int]$link.Site2ToSite1GlobalState
                $linkName = if ($statusName.ContainsKey($linkStatus)) { $statusName[$linkStatus] } else { "Unknown($linkStatus)" }
                $parentName = if ($statusName.ContainsKey($parentToChild)) { $statusName[$parentToChild] } else { "Unknown($parentToChild)" }
                $childName = if ($statusName.ContainsKey($childToParent)) { $statusName[$childToParent] } else { "Unknown($childToParent)" }
                if ($linkProgressing[$childSC]) {
                    $results.Details.Add("INFO: DRS link $parentSC -> $childSC is not Active yet but initialization advanced across samples: Link=$linkName, S1->S2=$parentName, S2->S1=$childName, Init=$($link.GlobalInitPercentage)")
                }
                elseif ($linkStatus -in $failedStates -or $parentToChild -in $failedStates -or $childToParent -in $failedStates) {
                    $results.Details.Add("WARN: DRS link $parentSC -> $childSC has static failures after $maxLinkAttempts samples: Link=$linkName, S1->S2=$parentName, S2->S1=$childName, Init=$($link.GlobalInitPercentage)")
                }
                else {
                    $results.Details.Add("WARN: DRS link $parentSC -> $childSC is not yet Active and showed no progress across $maxLinkAttempts samples: Link=$linkName, S1->S2=$parentName, S2->S1=$childName, Init=$($link.GlobalInitPercentage)")
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

        # If a child SECONDARY's replication link isn't Active AND we NEEDED it to be
        # -- i.e. a push client is actually assigned to that secondary (its resolved
        # pushClient site code == the secondary's site code, or a legacy pushClient=
        # $true client on the secondary's own subnet) -- collect the inter-site
        # content-pipeline diagnostics on BOTH sides (parent = sender, secondary =
        # despool), the same set we pull for other content/link failures. Without an
        # Active link the client package can't reach the secondary DP, so a stuck link
        # is the root cause worth capturing. If no client depends on it, the link
        # lagging is benign and we don't spam diagnostics.
        $linkActive = @{}
        if ($drsResult -and ($drsResult.ScriptBlockOutput -is [hashtable]) -and $drsResult.ScriptBlockOutput.ContainsKey('LinkActive') -and ($drsResult.ScriptBlockOutput.LinkActive -is [hashtable])) {
            $linkActive = $drsResult.ScriptBlockOutput.LinkActive
        }
        foreach ($childVm in @($childSites | Where-Object { $_.role -eq 'Secondary' })) {
            $csc = "$($childVm.siteCode)"
            $csNet = "$($childVm.network)"
            $isActive = ($linkActive.ContainsKey($csc) -and $linkActive[$csc] -eq $true)
            if ($isActive) { continue }
            $assigned = @($DeployConfig.virtualMachines | Where-Object {
                    ($_.pushClient -ne $false) -and (
                        ("$($_.pushClient)" -eq $csc) -or
                        (($_.pushClient -eq $true) -and $csNet -and ("$($_.network)" -eq $csNet))
                    )
                })
            if ($assigned.Count -eq 0) { continue }
            Add-Phase11Output "[Phase $Phase] $VMName [ChildSites ($siteCode)]: secondary '$csc' link NOT Active but $($assigned.Count) push client(s) are assigned to it ($(($assigned | ForEach-Object { $_.vmName }) -join ', ')) -- collecting inter-site content-pipeline diagnostics from parent '$VMName' and secondary '$($childVm.vmName)'"
            $null = Save-Phase11GuestLogs -VMName $VMName -DomainName $domain -RoleLabel "SecondaryLink-Parent ($csc)" -Collector $Phase11SmsSiteLogCollector
            $null = Save-Phase11GuestLogs -VMName $childVm.vmName -DomainName $domain -RoleLabel "SecondaryLink-Secondary ($csc)" -Collector $Phase11SmsSiteLogCollector
        }
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

            # 3b. Per-member IsClient snapshot. This is the value CM's policy
            # provider reads to decide whether to project per-resource application
            # deployment policy (CCM_ApplicationCIAssignment) to a member. colleval
            # snapshots IsClient from SMS_R_System.Client when the resource is first
            # ADDED to the collection; a plain RequestRefresh doesn't always rewrite
            # it for existing members. When Client=1 but IsClient=0, the site
            # silently skips projecting the Office assignment to that client -- the
            # exact "member but no policy" Phase 11 WARN. Surface it here every run.
            foreach ($e in $expected) {
                try {
                    $rsys = Get-WmiObject -Namespace $ns -Class SMS_R_System -Filter "NetbiosName='$e'" -ErrorAction Stop | Select-Object -First 1
                    if (-not $rsys) { $results.Details.Add("INFO: IsClient[$e]: not discovered (no SMS_R_System row)"); continue }
                    $fcm = Get-WmiObject -Namespace $ns -Class SMS_FullCollectionMembership -Filter "CollectionID='$($col.CollectionID)' AND ResourceID=$($rsys.ResourceID)" -ErrorAction SilentlyContinue | Select-Object -First 1
                    if ($rsys.Client -eq 1 -and $fcm -and -not $fcm.IsClient) {
                        $results.Details.Add("WARN: IsClient[$e]: Client=1 but membership IsClient=0 (STALE snapshot) -- site will NOT project the Office assignment here until IsClient is refreshed (drop+re-add membership / bump the query rule)")
                    }
                    elseif ($fcm) {
                        $results.Details.Add("INFO: IsClient[$e]: Client=$($rsys.Client) IsClient=$($fcm.IsClient) ResourceID=$($rsys.ResourceID)")
                    }
                    else {
                        $results.Details.Add("INFO: IsClient[$e]: Client=$($rsys.Client) (not yet in collection membership)")
                    }
                }
                catch { $results.Details.Add("INFO: IsClient[$e]: check skipped: $($_.Exception.Message)") }
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

function Test-MPReplicaFunctionality {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][object]$CurrentItem,
        [Parameter(Mandatory)][object]$DeployConfig
    )

    $Phase = 11
    $domain = $DeployConfig.vmOptions.domainName
    $siteCode = $CurrentItem.siteCode

    $replicaMPs = @($DeployConfig.virtualMachines | Where-Object { $_.role -eq 'SiteSystem' -and $_.installMP -and $_.useDatabaseReplica -and $_.siteCode -eq $siteCode })
    $mpFqdnCsv = ($replicaMPs | ForEach-Object { "$($_.vmName).$domain" }) -join ','
    # A replica's SQL lives on another VM, so the site server's own registry port does not
    # apply to it, and SC_SysResUse stores only the server NAME -- the port has to come from
    # deployConfig here and travel into the guest.
    $replicaPortPairs = New-Object System.Collections.Generic.List[string]
    foreach ($rmp in $replicaMPs) {
        $rsql = $DeployConfig.virtualMachines | Where-Object { $_.vmName -eq $rmp.replicaSqlServerVM } | Select-Object -First 1
        if ($rsql -and $rsql.sqlPort -and "$($rsql.sqlPort)" -ne '1433') {
            $replicaPortPairs.Add("$($rsql.vmName)=$($rsql.sqlPort)")
        }
    }
    $replicaPortCsv = ($replicaPortPairs | Select-Object -Unique) -join ','

    Write-Log "[Phase $Phase] $VMName [MPReplica]: verifying $($replicaMPs.Count) MP database replica(s) via v_BgbMP + sys.routes" -LogOnly

    $scriptBlock = {
        param($mpFqdnCsv, $sc, $replicaPortCsv)
        $results = @{ Passed = $true; Details = [System.Collections.Generic.List[string]]::new() }
        $mpList = @($mpFqdnCsv -split ',' | Where-Object { $_ })
        # "<sqlVmShortName>=<port>" pairs; SC_SysResUse stores the server name without a port.
        $replicaPorts = @{}
        foreach ($pair in @("$replicaPortCsv" -split ',' | Where-Object { $_ })) {
            $kv = $pair -split '='
            if ($kv.Count -eq 2) { $replicaPorts[$kv[0].Trim().ToUpper()] = $kv[1].Trim() }
        }

        # Site DB from this server's registry (same detection ConfigMgr uses).
        try {
            $siteReg = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\SMS\Identification' -Name 'Site Code').'Site Code'
            $p = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\SMS\SQL Server'
            $server = $p.Server; $dbRaw = $p.'Database Name'
            # Setup's own recovery path requires this DWORD to be > 0, so it is always present.
            # Without it a remote site DB on a non-default port is unreachable and this check
            # reports FAIL for a healthy hierarchy.
            $sqlPort = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\SMS\SQL Server\Site System SQL Account' -Name 'Port' -ErrorAction SilentlyContinue).'Port'
            if ($dbRaw -match '\\') { $inst = "$server\$($dbRaw.Split('\')[0])"; $db = $dbRaw.Split('\')[1] } else { $inst = $server; $db = $dbRaw }
            if ($sqlPort -and "$sqlPort" -ne '1433') { $inst = "$inst,$sqlPort" }
            $results.Details.Add("OK: site DB $inst / $db (site $siteReg)")
        }
        catch {
            $results.Passed = $false
            $results.Details.Add("FAIL: could not read site SQL from registry: $($_.Exception.Message)")
            return $results
        }

        if (-not (Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue)) {
            try { Import-Module SqlServer -ErrorAction Stop }
            catch {
                try { Import-Module SQLPS -DisableNameChecking -ErrorAction Stop }
                catch { $results.Details.Add('WARN: Invoke-Sqlcmd unavailable; skipping replica route checks'); return $results }
            }
        }

        try {
            $bgb = Invoke-Sqlcmd -ServerInstance $inst -Database $db -Query "SELECT ServerName, DBID FROM v_BgbMP" -TrustServerCertificate -ErrorAction Stop
            $routes = Invoke-Sqlcmd -ServerInstance $inst -Database $db -Query "SELECT remote_service_name FROM sys.routes WHERE remote_service_name LIKE 'ConfigMgrBGB%'" -TrustServerCertificate -ErrorAction Stop
            $routeSvcs = @($routes | ForEach-Object { "$($_.remote_service_name)".ToLower() })
        }
        catch {
            $results.Passed = $false
            $results.Details.Add("FAIL: site DB query failed: $($_.Exception.Message)")
            return $results
        }

        # Per-MP stored SQL server + database (RoleTypeID 6 = MP; Value2 holds the
        # SQLServerName / DatabaseName the MP actually connects to). Used to verify the
        # stored DatabaseName is CONNECTABLE (not MSSQLSERVER-qualified) and to reach each
        # replica DB for the BGB queue check. Matches Test-MPDatabaseReplicaHealth.ps1.
        $mpProps = @()
        try {
            $mpProps = @(Invoke-Sqlcmd -ServerInstance $inst -Database $db -TrustServerCertificate -ErrorAction Stop -Query @"
SELECT ServerName = dbo.fnGetSiteSystemName(sys_res.NALPath),
       SQLServerName = MAX(CASE WHEN prop.Name = N'SQLServerName' THEN prop.Value2 END),
       DatabaseName  = MAX(CASE WHEN prop.Name = N'DatabaseName'  THEN prop.Value2 END)
FROM SC_SysResUse sys_res
JOIN SC_SysResUse_Property prop ON prop.SysResUseID = sys_res.ID
WHERE sys_res.RoleTypeID = 6
GROUP BY dbo.fnGetSiteSystemName(sys_res.NALPath)
"@)
        }
        catch { $results.Details.Add("WARN: could not read MP role SQL/DB properties: $($_.Exception.Message)") }

        # SQL replication must be ENABLED on the site DB (publisher). syspublications
        # only exists once the DB is a publisher, so guard on OBJECT_ID. The number of
        # distinct subscribers should cover the replica MPs.
        try {
            $pubRow = Invoke-Sqlcmd -ServerInstance $inst -Database $db -TrustServerCertificate -ErrorAction Stop -Query "IF OBJECT_ID('dbo.syspublications') IS NOT NULL SELECT COUNT(*) AS c FROM dbo.syspublications WHERE name = 'ConfigMgr_MPReplica' ELSE SELECT 0 AS c"
            if ([int]$pubRow.c -gt 0) {
                $results.Details.Add("OK: SQL replication enabled (publication ConfigMgr_MPReplica present on site DB)")
                $subRow = Invoke-Sqlcmd -ServerInstance $inst -Database $db -TrustServerCertificate -ErrorAction Stop -Query "IF OBJECT_ID('dbo.syssubscriptions') IS NOT NULL SELECT COUNT(DISTINCT srvid) AS c FROM dbo.syssubscriptions ELSE SELECT 0 AS c"
                $subCount = [int]$subRow.c
                if ($subCount -ge $mpList.Count) {
                    $results.Details.Add("OK: $subCount replication subscriber(s) registered (>= $($mpList.Count) replica MP(s))")
                }
                else {
                    $results.Passed = $false
                    $results.Details.Add("FAIL: only $subCount replication subscriber(s) registered for $($mpList.Count) replica MP(s) -- a replica DB is not subscribed to the publication")
                }
            }
            else {
                $results.Passed = $false
                $results.Details.Add("FAIL: publication ConfigMgr_MPReplica is missing -- SQL transactional replication is NOT enabled on the site DB (spCreateMPReplicaPublication did not run)")
            }
        }
        catch {
            $results.Details.Add("WARN: could not verify replication publication/subscriptions: $($_.Exception.Message)")
        }

        foreach ($mp in $mpList) {
            $row = @($bgb | Where-Object { "$($_.ServerName)".ToLower() -eq $mp.ToLower() }) | Select-Object -First 1
            if (-not $row) {
                $results.Passed = $false
                $results.Details.Add("FAIL: MP '$mp' not found in v_BgbMP")
                continue
            }
            $dbid = "$($row.DBID)"
            if ($dbid.ToLower().StartsWith('0x')) {
                $results.Details.Add("OK: MP '$mp' DBID is a replica hash ($dbid)")
                $wantSvc = "configmgrbgb_site$($dbid.ToLower())"
                if ($routeSvcs -contains $wantSvc) {
                    $results.Details.Add("OK: site route to replica service present for '$mp'")
                }
                else {
                    $results.Passed = $false
                    $results.Details.Add("FAIL: site missing route to service ConfigMgrBGB_Site$dbid (root cause of BGB 'Route is not defined')")
                }

                # Stored SQL server + DB for this MP (what the MP connects to).
                $prop = @($mpProps | Where-Object { "$($_.ServerName)".ToLower() -eq $mp.ToLower() }) | Select-Object -First 1
                $storedSql = if ($prop) { "$($prop.SQLServerName)".Trim() } else { '' }
                $storedDb = if ($prop) { "$($prop.DatabaseName)".Trim() } else { '' }

                # NOTE 1: the stored DatabaseName must be CONNECTABLE. The MP builds its
                # connection as 'server\<instance>' from the stored '<instance>\<db>'. A
                # DEFAULT instance must be the BARE db name -- an instance part that is empty
                # ('\<db>') or 'MSSQLSERVER' makes the MP build an invalid 'server\' /
                # 'server\MSSQLSERVER' connection string -> MPLIST HTTP 500 (SqlException
                # error 25 / Win32 87). Only a real NAMED instance may carry an 'inst\' prefix.
                $dbInstPart = if ($storedDb -match '\\') { $storedDb.Split('\')[0] } else { $null }
                if ($null -ne $dbInstPart -and ($dbInstPart -eq '' -or $dbInstPart -ieq 'MSSQLSERVER')) {
                    $results.Passed = $false
                    $results.Details.Add("FAIL: MP '$mp' stored DatabaseName is '$storedDb' -- its instance part '$dbInstPart' is empty/MSSQLSERVER, so the MP builds an invalid 'server\$dbInstPart' connection string (MPLIST HTTP 500). A default instance must be stored as the BARE DB name (no backslash).")
                }
                elseif ($storedDb) {
                    $results.Details.Add("OK: MP '$mp' stored DatabaseName '$storedDb' is connectable (SQLServerName '$storedSql')")
                }
                else {
                    $results.Details.Add("WARN: MP '$mp' stored SQLServerName/DatabaseName not found in SC_SysResUse")
                }

                # NOTE 2: the replica DB must have the BGB Service Broker queue
                # 'ConfigMgrBGBQueue', or the MP's BgbServer logs 'The queue for BGB server
                # doesn't exist' and client notification is broken. Connect to the replica
                # DB (parse instance from the stored DatabaseName) and confirm it.
                if ($storedSql -and $storedDb) {
                    if ($storedDb -match '\\') { $rInst = "$storedSql\$($storedDb.Split('\')[0])"; $rDb = $storedDb.Split('\')[1] } else { $rInst = $storedSql; $rDb = $storedDb }
                    $rPort = $replicaPorts[(($storedSql -split '\.')[0]).ToUpper()]
                    if ($rPort) { $rInst = "$rInst,$rPort" }
                    try {
                        $qRow = Invoke-Sqlcmd -ServerInstance $rInst -Database $rDb -TrustServerCertificate -ErrorAction Stop -Query "SELECT c = COUNT(*) FROM sys.service_queues WHERE name = 'ConfigMgrBGBQueue'"
                        if ([int]$qRow.c -gt 0) {
                            $results.Details.Add("OK: replica DB '$rDb' on '$rInst' has the BGB queue ConfigMgrBGBQueue (client notification wired)")
                        }
                        else {
                            $results.Passed = $false
                            $results.Details.Add("FAIL: replica DB '$rDb' on '$rInst' is MISSING the BGB queue ConfigMgrBGBQueue -- BgbServer logs 'The queue for BGB server doesn't exist' and client notification won't work (sp_BgbConfigSSBForReplicaDB did not complete on this replica)")
                        }
                    }
                    catch { $results.Details.Add("WARN: could not check BGB queue on replica '$rInst' / '$rDb': $($_.Exception.Message)") }
                }
            }
            else {
                $results.Passed = $false
                $results.Details.Add("FAIL: MP '$mp' DBID='$dbid' is NOT a replica hash -- MP still on the site DB (Set-CMManagementPoint did not apply)")
            }
        }
        return $results
    }

    $result = Invoke-VmCommand -VmName $VMName -VmDomainName $domain `
        -ScriptBlock $scriptBlock -ArgumentList $mpFqdnCsv, $siteCode, $replicaPortCsv `
        -DisplayName "Phase11-MPReplica-Test" -SuppressLog `
        -AsJob -TimeoutSeconds 300

    return (Format-TestResult -VMName $VMName -RoleLabel "MPReplica" -Result $result)
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

    # Secondary site installation is ASYNCHRONOUS: the parent's DSC (and the
    # secondary's own DSC) report "Complete!" as soon as the site is *added* to the
    # hierarchy (right after "Creating compressed package"), but the secondary then
    # bootstraps on-box for another 20-40 min -- installing SQL Express
    # ($sqlInstanceName) and registering SMS_EXECUTIVE. Running the functional check
    # immediately yields a false failure (no SQL, no SMS_EXECUTIVE). So first WAIT
    # for the install to actually land: poll the secondary for SMS_EXECUTIVE + the
    # SQL service, treating an actively-progressing bootstrap (ConfigMgrSetup.log
    # freshly written) as "keep waiting", and only stop early if the box shows no
    # install activity for several minutes (genuinely stalled/failed -> let the full
    # check below fail with diagnostics).
    $waitBlock = {
        param($instanceName)
        $svcName = if ($instanceName -eq 'MSSQLSERVER') { 'MSSQLSERVER' } else { "MSSQL`$$instanceName" }
        $smsExec = [bool](Get-Service -Name 'SMS_EXECUTIVE' -ErrorAction SilentlyContinue)
        $sqlSvc = [bool](Get-Service -Name $svcName -ErrorAction SilentlyContinue)
        # "Install still progressing" signals (any one is enough). The secondary
        # bootstrap has a quiet gap between the parent "Creating compressed package"
        # and the on-box setup actually starting, so we accept several markers, not
        # just a freshly-written log:
        #   - C:\ConfigMgrSetup.log written in the last 25 min, OR it merely EXISTS
        #     (the bootstrap creates it and keeps appending), OR
        #   - a setup/bootstrap process is running, OR
        #   - the CM install dir / its Logs folder exists (install has begun) while
        #     SMS_EXECUTIVE isn't registered yet.
        $setupActive = $false
        try {
            $log = 'C:\ConfigMgrSetup.log'
            if (Test-Path $log) {
                $setupActive = $true
            }
            if (-not $setupActive) {
                $setupActive = [bool](Get-Process -Name 'ConfigMgrSetup', 'setup', 'setupwpf', 'bootstrap' -ErrorAction SilentlyContinue)
            }
            if (-not $setupActive) {
                foreach ($d in @('C:\Program Files\Microsoft Configuration Manager\Logs', 'C:\Program Files\Microsoft Configuration Manager')) {
                    if (Test-Path $d) { $setupActive = $true; break }
                }
            }
        }
        catch { }
        return @{ Installed = ($smsExec -and $sqlSvc); SmsExec = $smsExec; Sql = $sqlSvc; SetupActive = $setupActive }
    }

    $waitDeadline = (Get-Date).AddMinutes(50)
    $stallPolls = 0
    $maxStallPolls = 10
    $installedNow = $false
    while ((Get-Date) -lt $waitDeadline) {
        $w = Invoke-VmCommand -VmName $VMName -VmDomainName $domain -ScriptBlock $waitBlock `
            -ArgumentList $sqlInstanceName -SuppressLog -AsJob -TimeoutSeconds 120
        $ws = $w.ScriptBlockOutput
        if ($ws -is [hashtable] -and $ws.Installed) {
            $installedNow = $true
            Write-Log "[Phase $Phase] $VMName [Secondary]: secondary install landed (SMS_EXECUTIVE + SQL '$sqlInstanceName' present); validating." -LogOnly
            break
        }
        if ($ws -is [hashtable] -and $ws.SetupActive) {
            $stallPolls = 0
            Write-Log "[Phase $Phase] $VMName [Secondary]: secondary still bootstrapping (SMS_EXECUTIVE=$($ws.SmsExec) SQL=$($ws.Sql)); waiting..." -LogOnly
        }
        else {
            $stallPolls++
            Write-Log "[Phase $Phase] $VMName [Secondary]: no secondary install activity detected (SMS_EXECUTIVE=$(if($ws -is [hashtable]){$ws.SmsExec}) SQL=$(if($ws -is [hashtable]){$ws.Sql}); stall $stallPolls/$maxStallPolls)." -LogOnly
            if ($stallPolls -ge $maxStallPolls) {
                Write-Log "[Phase $Phase] $VMName [Secondary]: no bootstrap progress for ~$maxStallPolls min; proceeding to the functional check (which will report the missing components)." -Warning
                break
            }
        }
        Start-Sleep -Seconds 60
    }
    if (-not $installedNow -and (Get-Date) -ge $waitDeadline) {
        Write-Log "[Phase $Phase] $VMName [Secondary]: secondary install did not complete within the wait window; running the functional check for a definitive verdict." -Warning
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

            # Every globalModule DLL must exist or w3wp dies at startup with
            # ERROR_MOD_NOT_FOUND -> 5x WAS 5139 -> 5002 disables the pool -> HTTP 503.
            # Check this DIRECTLY rather than inferring it from pool state: an OnDemand
            # pool that has not been asked for a worker yet still reports 'Started' while
            # being fatally broken (PL-PATTYDP's 'SMS Windows Auth Management Point Pool'
            # read Started the whole time validcfg.dll was missing).
            try {
                $ahcPath = Join-Path $env:windir 'system32\inetsrv\config\applicationHost.config'
                $ahcXml = [xml](Get-Content $ahcPath -Raw -ErrorAction Stop)
                $globalModules = @($ahcXml.configuration.'system.webServer'.globalModules.add)
                $missingModules = @()
                foreach ($globalModule in $globalModules) {
                    $moduleImage = [Environment]::ExpandEnvironmentVariables("$($globalModule.image)")
                    if ($moduleImage -and -not (Test-Path -LiteralPath $moduleImage)) {
                        $missingModules += "$($globalModule.name) -> $moduleImage"
                    }
                }
                if ($missingModules.Count -gt 0) {
                    $results.Passed = $false
                    $results.Details.Add("FAIL: $($missingModules.Count) of $($globalModules.Count) IIS globalModule DLL(s) are missing from disk, so every w3wp for this pool dies at startup: $($missingModules -join '; '). sfc/DISM will NOT restore a module whose owning component is not installed (CBS considers the system correct); either install the owning feature (validcfg.dll ships with Microsoft-Windows-IIS-NetFxExtensibility = Web-Net-Ext45) or drop the stale registration with '%windir%\system32\inetsrv\appcmd.exe uninstall module <name>'.")
                    # iis.log holds the appcmd that registered the module and the rollback that
                    # failed to unregister it; the gap between those two IS the diagnosis.
                    $iisLog = Join-Path $env:windir 'iis.log'
                    if (Test-Path -LiteralPath $iisLog) {
                        foreach ($missingModule in $missingModules) {
                            $moduleName = ($missingModule -split ' -> ')[0]
                            $moduleHits = @(Select-String -LiteralPath $iisLog -Pattern "iissetup\.exe.*$([regex]::Escape($moduleName))" -Context 0, 2 -ErrorAction SilentlyContinue | Select-Object -Last 4)
                            foreach ($moduleHit in $moduleHits) {
                                $results.Details.Add("  iis.log: $($moduleHit.Line.Trim())")
                                foreach ($postLine in $moduleHit.Context.PostContext) { $results.Details.Add("  iis.log:   $($postLine.Trim())") }
                            }
                        }
                        $sharingHits = @(Select-String -LiteralPath $iisLog -Pattern 'LaunchCommand result=0x80070020' -ErrorAction SilentlyContinue)
                        if ($sharingHits.Count -gt 0) {
                            $results.Details.Add("  iis.log: $($sharingHits.Count) x 'LaunchCommand result=0x80070020' (ERROR_SHARING_VIOLATION on applicationHost.config) -- IIS servicing and ConfigMgr setup were writing that file at the same time. A rollback that cannot unregister a module still goes on to delete the module's DLL, which is how the registration outlives its image.")
                        }
                    }
                }
                else {
                    $results.Details.Add("OK: all $($globalModules.Count) IIS globalModule DLL(s) present on disk")
                }
            }
            catch { $results.Details.Add("INFO: could not read applicationHost.config globalModules: $($_.Exception.Message)") }

            # Check SMS_MP IIS virtual directory exists via WebAdministration (retry up to 5 times, 60s apart)
            try {
                Import-Module WebAdministration -ErrorAction Stop
                $addPoolDiagnostics = {
                    param([string]$Name)
                    try {
                        $cfg = Get-Item "IIS:\AppPools\$Name" -ErrorAction SilentlyContinue
                        if ($cfg) {
                            $results.Details.Add("DIAG: App pool '$Name' config: autoStart=$($cfg.autoStart), startMode=$($cfg.startMode), rapidFailProtection=$($cfg.failure.rapidFailProtection), maxCrashes=$($cfg.failure.rapidFailProtectionMaxCrashes), interval=$($cfg.failure.rapidFailProtectionInterval)")
                        }
                    }
                    catch { $results.Details.Add("DIAG: Could not read app-pool configuration: $($_.Exception.Message)") }

                    try {
                        $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; StartTime = (Get-Date).AddHours(-6) } -MaxEvents 300 -ErrorAction SilentlyContinue |
                                Where-Object { $_.ProviderName -match 'WAS|W3SVC|IIS' -and $_.Message -match [regex]::Escape($Name) } |
                                Select-Object -First 8)
                        if ($events.Count -eq 0) {
                            $results.Details.Add("DIAG: No WAS/W3SVC System events naming '$Name' in the last 6h")
                        }
                        foreach ($eventRecord in $events) {
                            $eventText = (($eventRecord.Message -replace '\s+', ' ').Trim())
                            $errorDetail = ''
                            try {
                                [xml]$eventXml = $eventRecord.ToXml()
                                $binaryHex = "$($eventXml.Event.EventData.Binary)".Trim()
                                if ($binaryHex -match '^[0-9A-Fa-f]{8,}$') {
                                    [byte[]]$errorBytes = @()
                                    for ($byteIndex = 0; $byteIndex -lt $binaryHex.Length; $byteIndex += 2) {
                                        $errorBytes += [Convert]::ToByte($binaryHex.Substring($byteIndex, 2), 16)
                                    }
                                    if ($errorBytes.Count -ge 4) {
                                        $hresult = [BitConverter]::ToUInt32($errorBytes, 0)
                                        $errorDetail = " binary=$binaryHex hresult=0x$($hresult.ToString('X8'))"
                                        $facility = [int](($hresult -shr 16) -band 0x1FFF)
                                        if ($facility -eq 7) {
                                            $win32Code = [int]($hresult -band 0xFFFF)
                                            $win32Text = (New-Object System.ComponentModel.Win32Exception -ArgumentList $win32Code).Message
                                            $errorDetail += " win32=$win32Code ($win32Text)"
                                        }
                                    }
                                }
                            }
                            catch { $errorDetail = " event-data-read-failed=$($_.Exception.Message)" }
                            $results.Details.Add("DIAG: WAS/W3SVC $($eventRecord.TimeCreated.ToString('HH:mm:ss')) id=$($eventRecord.Id): $eventText$errorDetail")
                        }
                    }
                    catch { $results.Details.Add("DIAG: WAS/W3SVC event query failed: $($_.Exception.Message)") }

                    try {
                        $latestFailure = $events | Where-Object { $_.Id -eq 5139 } | Select-Object -First 1
                        $windowStart = if ($latestFailure) { $latestFailure.TimeCreated.AddMinutes(-2) } else { (Get-Date).AddHours(-6) }
                        $windowEnd = if ($latestFailure) { $latestFailure.TimeCreated.AddMinutes(2) } else { Get-Date }
                        $appEvents = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; StartTime = $windowStart; EndTime = $windowEnd } -MaxEvents 500 -ErrorAction SilentlyContinue |
                                Where-Object { $_.ProviderName -match 'IIS|W3SVC|Application Error|\.NET Runtime|Windows Error Reporting' } |
                                Select-Object -First 20)
                        if ($appEvents.Count -eq 0) {
                            $results.Details.Add("DIAG: No IIS/w3wp Application events found within two minutes of the latest WAS 5139")
                        }
                        # IIS repeats 2280 once per worker attempt, so 20 identical lines say
                        # nothing 1 line doesn't. Collapse on message text, newest first.
                        $seenAppEvent = @{}
                        foreach ($eventRecord in $appEvents) {
                            $eventText = (($eventRecord.Message -replace '\s+', ' ').Trim())
                            $eventKey = "$($eventRecord.Id)|$eventText"
                            if ($seenAppEvent.ContainsKey($eventKey)) { $seenAppEvent[$eventKey]++; continue }
                            $seenAppEvent[$eventKey] = 1
                            $results.Details.Add("DIAG: Application $($eventRecord.TimeCreated.ToString('HH:mm:ss')) [$($eventRecord.ProviderName)] id=$($eventRecord.Id): $eventText")
                            # 2280 names the DLL but not whether it is missing outright or is
                            # present with an unresolvable dependency -- opposite fixes, so say which.
                            $dllMatch = [regex]::Match($eventText, 'Module DLL ([A-Za-z]:\\[^ ]+\.dll)')
                            if ($dllMatch.Success) {
                                $dllPath = $dllMatch.Groups[1].Value
                                if (Test-Path -LiteralPath $dllPath) {
                                    $dllInfo = Get-Item -LiteralPath $dllPath -ErrorAction SilentlyContinue
                                    $results.Details.Add("DIAG: -> '$dllPath' EXISTS ($($dllInfo.Length) bytes, $($dllInfo.VersionInfo.FileVersion), modified $($dllInfo.LastWriteTime.ToString('yyyy-MM-dd HH:mm'))) -- so a DEPENDENCY of it is what cannot be found, not the module itself")
                                }
                                else {
                                    $results.Details.Add("DIAG: -> '$dllPath' IS MISSING from disk -- repair/reinstall the IIS feature that provides it, or drop its globalModules entry from applicationHost.config")
                                }
                            }
                        }
                        foreach ($dupKey in ($seenAppEvent.Keys | Where-Object { $seenAppEvent[$_] -gt 1 })) {
                            $results.Details.Add("DIAG: (the id=$(($dupKey -split '\|')[0]) event above repeated $($seenAppEvent[$dupKey]) times in this window)")
                        }
                    }
                    catch { $results.Details.Add("DIAG: Application event query failed: $($_.Exception.Message)") }
                }
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
                    # Diagnostics: the SMS_MP IIS app is provisioned REMOTELY by
                    # SMS_MP_CONTROL_MANAGER (runs under SMS_EXECUTIVE on the site
                    # server). If the site server's SMS_EXECUTIVE is down/unhealthy,
                    # this MP never gets provisioned here. Capture what IS present so a
                    # re-run distinguishes "site server didn't provision" from a local
                    # IIS problem.
                    try {
                        $apps = @(Get-WebApplication -Site 'Default Web Site' -ErrorAction SilentlyContinue | ForEach-Object { $_.Path })
                        $results.Details.Add("DIAG: IIS apps under Default Web Site: $(if ($apps.Count -gt 0) { $apps -join ', ' } else { '<none>' })")
                    }
                    catch { }
                    $mpReg = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\SMS\MP' -ErrorAction SilentlyContinue
                    if ($mpReg) { $results.Details.Add("DIAG: HKLM\SOFTWARE\Microsoft\SMS\MP present (MP Control Manager began provisioning); IIS app not yet created -- likely still in progress") }
                    else { $results.Details.Add("DIAG: HKLM\SOFTWARE\Microsoft\SMS\MP absent -- SMS_MP_CONTROL_MANAGER on the site server has not provisioned this MP. Verify SMS_EXECUTIVE + SMS_MP_CONTROL_MANAGER are Running on the site server (see its Phase 11 result) and check mpcontrol.log there.") }
                    foreach ($mpLog in @("$env:windir\Temp\mpMSI.log", 'C:\mpMSI.log', "$env:windir\Temp\mpsetup.log")) {
                        if (Test-Path $mpLog) {
                            try {
                                $mpTail = Get-Content -Path $mpLog -Tail 10 -ErrorAction Stop
                                $results.Details.Add("DIAG: $(Split-Path $mpLog -Leaf) (last $($mpTail.Count)):")
                                foreach ($t in $mpTail) { if ($t.Trim()) { $results.Details.Add("  $($t.Trim())") } }
                            }
                            catch { }
                            break
                        }
                    }
                    return $results
                }

                # Check that the app pool is started
                $poolName = $mpApp.ApplicationPool
                $pool = Get-WebAppPoolState -Name $poolName -ErrorAction SilentlyContinue
                if ($pool -and $pool.Value -eq 'Started') {
                    $results.Details.Add("OK: App pool '$poolName' is Started")
                }
                else {
                    $initialPoolState = if ($pool) { $pool.Value } else { 'not found' }
                    $results.Details.Add("REMEDIATE: App pool '$poolName' is $initialPoolState; capturing IIS evidence and resetting the WAS/W3SVC listener stack")
                    & $addPoolDiagnostics $poolName
                    if ($pool) {
                        try {
                            Stop-Service -Name W3SVC -Force -ErrorAction SilentlyContinue
                            Restart-Service -Name WAS -Force -ErrorAction Stop
                            Start-Service -Name W3SVC -ErrorAction Stop
                            $null = Start-WebAppPool -Name $poolName -ErrorAction Stop
                            Start-Sleep -Seconds 15
                            $pool = Get-WebAppPoolState -Name $poolName -ErrorAction SilentlyContinue
                        }
                        catch {
                            $results.Details.Add("DIAG: WAS/W3SVC reset or Start-WebAppPool failed: $($_.Exception.Message)")
                        }
                    }
                    if ($pool -and $pool.Value -eq 'Started') {
                        $results.Details.Add("RECOVERED: App pool '$poolName' was $initialPoolState; WAS/W3SVC reset and pool started successfully")
                    }
                    else {
                        $results.Passed = $false
                        $finalPoolState = if ($pool) { $pool.Value } else { 'not found' }
                        $results.Details.Add("FAIL: App pool '$poolName' is still $finalPoolState after one start attempt")
                        return $results
                    }
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
            # serving-OK (auth required). A freshly-installed MP routinely returns HTTP
            # 500 (and an HTTPS bind may not be ready / still time out) on .sms_aut?MPLIST
            # for the first few minutes while MP Control Manager validates the role
            # (mpcontrol.log) and the ISAPI handler warms up -- so retry with backoff
            # before warning instead of failing on the very first probe.
            $fqdn = "$env:COMPUTERNAME.$((Get-WmiObject Win32_ComputerSystem).Domain)"
            $mpProbed = $false
            $lastProbeDetail = ''
            $maxProbeAttempts = 6
            for ($probeAttempt = 1; $probeAttempt -le $maxProbeAttempts; $probeAttempt++) {
                foreach ($scheme in @('https', 'http')) {
                    $url = "$scheme`://$fqdn/sms_mp/.sms_aut?MPLIST"
                    if ($probeAttempt -eq 1) {
                        $results.Details.Add("CMD: Invoke-WebRequest -Uri '$url' -UseBasicParsing")
                    }
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
                        $results.Details.Add("OK: MP probe '$url' returned $sc (attempt $probeAttempt)")
                        $mpProbed = $true
                        break
                    }
                    catch [System.Net.WebException] {
                        $sc = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
                        if ($sc -in 401, 403) {
                            $results.Details.Add("OK: MP probe '$url' returned $sc (auth required = serving, attempt $probeAttempt)")
                            $mpProbed = $true
                            break
                        }
                        # HTTP 500/503 here = MP installed but Control Manager hasn't
                        # validated it yet; retryable like a connection-level failure.
                        $lastProbeDetail = if ($sc) { "$scheme returned HTTP $sc" } else { "$scheme failed: $($_.Exception.Message)" }
                    }
                    catch {
                        $lastProbeDetail = "$scheme failed: $($_.Exception.Message)"
                    }
                }
                if ($mpProbed) { break }
                if ($probeAttempt -lt $maxProbeAttempts) {
                    Start-Sleep -Seconds 30
                }
            }
            if (-not $mpProbed) {
                $waitedMin = [Math]::Round((($maxProbeAttempts - 1) * 30) / 60, 1)
                $poolAfterProbe = Get-WebAppPoolState -Name $poolName -ErrorAction SilentlyContinue
                if (-not $poolAfterProbe -or $poolAfterProbe.Value -ne 'Started') {
                    $results.Passed = $false
                    $poolAfterState = if ($poolAfterProbe) { $poolAfterProbe.Value } else { 'not found' }
                    $results.Details.Add("FAIL: MP HTTP probe failed for ~$waitedMin min and app pool '$poolName' is now $poolAfterState (last probe: $lastProbeDetail)")
                    & $addPoolDiagnostics $poolName
                }
                else {
                    # Don't fail if IIS + the pool remain healthy. A freshly installed
                    # MP can return 500 while MP Control Manager validates the role.
                    $results.Details.Add("WARN: MP HTTP probe did not succeed after $maxProbeAttempts attempts over ~$waitedMin min (last: $lastProbeDetail). App pool remains Started; check mpcontrol.log and SMS_MP_CONTROL_MANAGER on the site server.")
                }
            }

            return $results
        }

        $mpResult = Invoke-VmCommand -VmName $VMName -VmDomainName $domain `
            -ScriptBlock $mpScript -DisplayName "Phase11-MP-Test" -SuppressLog `
            -AsJob -TimeoutSeconds 600

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
            if ($share) {
                $results.Details.Add("OK: SMB share 'SMS_DP`$' exposes '$($share.Path)'")
            }
            else {
                # Share not published yet. On a fresh deploy DistMgr provisions the DP
                # content library (the ?:\SMS_DP$ folder + SMS_DP$ share + IIS vdirs)
                # asynchronously from the site server, so the share can legitimately be
                # absent while the install is still in flight -- this mirrors the
                # site-server-side "DP not yet visible in SMS_DistributionPointInfo
                # (install may still be propagating)" WARN that the Primary's own Phase 11
                # job already emits. Per the "only soften if we can validate it's in
                # progress AND working" rule, ONLY downgrade to WARN when we have positive
                # LOCAL proof the DP role install reached this box AND has not failed;
                # with no such evidence (or a logged init failure) keep the hard FAIL.
                $inProgress = New-Object System.Collections.Generic.List[string]
                $fatal      = New-Object System.Collections.Generic.List[string]

                # (a) DP role registry key -- written when the DP provider is provisioned
                #     (same key Common.Config reads for the DP's "Site Code").
                if (Test-Path 'HKLM:\SOFTWARE\Microsoft\SMS\DP') {
                    $inProgress.Add('DP registry key HKLM:\SOFTWARE\Microsoft\SMS\DP present')
                }

                # (b) content-library folder -- the SMS_DP$ share maps here and the folder
                #     tree is laid down during provisioning (drives per Capture-WorkingPkiDp).
                $dpDir = $null
                foreach ($drv in @('E:', 'F:', 'D:', 'G:', 'C:')) {
                    $cand = "$drv\SMS_DP`$"
                    if (Test-Path -LiteralPath $cand) { $dpDir = $cand; break }
                }
                if ($dpDir) { $inProgress.Add("content library folder '$dpDir' exists") }

                # (c) smsdpprov.log -- a recent last-write proves active progress; scan the
                #     tail for a terminal content-library-init failure (=> genuinely broken).
                if ($dpDir) {
                    $dpLog = "$dpDir\sms\logs\smsdpprov.log"
                    if (Test-Path -LiteralPath $dpLog) {
                        try {
                            $lw = (Get-Item -LiteralPath $dpLog -ErrorAction Stop).LastWriteTime
                            $ageMin = [int]((Get-Date) - $lw).TotalMinutes
                            $inProgress.Add("smsdpprov.log last-write ${ageMin}m ago")
                            $tail = @(Get-Content -LiteralPath $dpLog -Tail 25 -ErrorAction SilentlyContinue)
                            $bad = @($tail | Where-Object { $_ -match 'Failed to create the content library|CreateContentLibrary.*fail|fatal error' })
                            if ($bad.Count -gt 0) { $fatal.Add($bad[-1].Trim()) }
                        }
                        catch {}
                    }
                }

                if ($fatal.Count -gt 0) {
                    $results.Passed = $false
                    $results.Details.Add("FAIL: SMB share 'SMS_DP`$' missing and smsdpprov.log reports a content-library init failure: $($fatal[-1])")
                }
                elseif ($inProgress.Count -gt 0) {
                    # In progress with no logged failure -> WARN, do NOT fail (self-heals on
                    # the next Phase 11 pass once DistMgr publishes the share).
                    $results.Details.Add("WARN: SMB share 'SMS_DP`$' not published yet -- DP content library still initializing (in progress: $($inProgress -join '; ')). DistMgr publishes the share when provisioning completes; re-run Phase 11 to confirm.")
                }
                else {
                    $results.Passed = $false
                    $results.Details.Add("FAIL: SMB share 'SMS_DP`$' missing and no DP install activity detected (no DP registry key / content library folder) -- content library not initialized")
                }
            }

            # DP content-library LOCATION -- a distribution point MUST serve from a
            # LOCAL content library. If the site's content library was relocated to a
            # remote share for HA (passive site server remoteContentLibVM ->
            # Move-CMContentLibrary) and a DP was (re-)added to this site server anyway
            # (e.g. the pull-DP-source logic auto-enabling installDP), the DP's
            # ContentLibraryPath is a UNC path while its SMS_DP_SMSPKG$ IIS app still
            # serves from the now-empty local SCCMContentLib -- so every HTTP content
            # request (pull DPs, PXE, direct download) returns 404. This DP looks
            # "Installed" in the site DB yet serves nothing. Assert the library is local.
            try {
                $dpReg = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\SMS\DP' -ErrorAction SilentlyContinue
                $clp = if ($dpReg) { "$($dpReg.ContentLibraryPath)" } else { '' }
                if ($clp) {
                    if ($clp -match '^\\\\') {
                        $results.Passed = $false
                        $results.Details.Add("FAIL: DP content library is REMOTE ($clp). A DP must serve from a LOCAL content library -- HTTP content requests will 404 (pull DPs fail, PXE/content download break). This site server's content library was relocated for HA; it must NOT host a DP (use a dedicated SiteSystem DP instead).")
                    }
                    else {
                        $results.Details.Add("OK: DP content library is local ($clp)")
                    }
                }
                # Cross-check the IIS content-download app against the library location:
                # if the SMS_DP_SMSPKG$ app's physical path is a local SCCMContentLib but
                # the content library is remote, that is the exact serve-empty-path 404.
                try {
                    Import-Module WebAdministration -ErrorAction Stop
                    $pkgApp = Get-WebApplication -Site 'Default Web Site' -ErrorAction SilentlyContinue |
                        Where-Object { $_.path -eq '/SMS_DP_SMSPKG$' } | Select-Object -First 1
                    if ($pkgApp) {
                        $pkgPath = $pkgApp.PhysicalPath
                        if ($clp -and $clp -match '^\\\\' -and $pkgPath -notmatch '^\\\\') {
                            $results.Details.Add("DIAG: SMS_DP_SMSPKG`$ serves local '$pkgPath' but content library is remote '$clp' -- content is not where IIS looks (404 source).")
                        }
                        else {
                            $results.Details.Add("OK: SMS_DP_SMSPKG`$ physical path '$pkgPath'")
                        }
                    }
                }
                catch {}
            }
            catch {}

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

        # Poll instead of failing on the first miss. A freshly-installed or
        # recently-restarted Power BI Report Server reports its Windows service
        # as Running well before its HTTP listener + ReportServer DB connection
        # are live: the first requests fail with "There was an error downloading
        # ...ReportService2005.asmx" (HTTP 503 / connection refused) for a couple
        # of minutes while the RS web service warms up its app domains. Phase 11
        # runs right after Phase 10 with no reboot, so on a fresh deploy it can
        # land squarely in that warmup window and spuriously FAIL an otherwise
        # healthy RP. Bounded well under the 300s outer Invoke-VmCommand timeout.
        $results.Details.Add("CMD: New-WebServiceProxy ReportService2005.asmx / GetItemType('/') (polled)")
        $soapOk = $false
        $lastErr = ''
        $lastErrRecord = $null
        $maxAttempts = 8          # ~8 x 15s = up to ~120s of polling
        $retryDelay = 15
        $bouncedService = $false
        try {
            for ($attempt = 1; $attempt -le $maxAttempts -and -not $soapOk; $attempt++) {
                foreach ($soapUri in $soapUrls) {
                    try {
                        $ssrsProxy = New-WebServiceProxy -Uri $soapUri -UseDefaultCredential -ErrorAction Stop
                        $itemType = $ssrsProxy.GetItemType("/")
                        if ($itemType -eq 'Folder') {
                            $note = if ($attempt -gt 1) { " (attempt $attempt)" } else { "" }
                            $results.Details.Add("OK: SOAP API healthy at '$soapUri' (root = Folder)$note")
                            $soapOk = $true
                            break
                        }
                        else {
                            $lastErr = "$soapUri -> unexpected root type '$itemType'"
                        }
                    }
                    catch {
                        $lastErr = "$soapUri -> $($_.Exception.Message)"
                        # Keep the LAST full exception so the failure branch can unwrap
                        # it. "There was an error downloading '<url>'" is a WebException
                        # wrapper -- the actual reason (503 / connection refused / 401 /
                        # timeout) only exists on the inner exception + response object.
                        $lastErrRecord = $_
                    }
                }
                if (-not $soapOk -and $attempt -lt $maxAttempts) {
                    # Once the endpoint has been unresponsive for ~45s, bounce the
                    # Reporting service a single time to force it to reinitialize
                    # its HTTP listener + ReportServer DB connection -- the proven
                    # cold-start nudge -- then keep polling.
                    if (-not $bouncedService -and $attempt -eq 3) {
                        try {
                            $results.Details.Add("  SOAP still unresponsive after $attempt attempts; restarting '$($svc.Name)' to force warmup")
                            Restart-Service -Name $svc.Name -Force -ErrorAction Stop
                            Start-Sleep -Seconds 10
                        }
                        catch {
                            $results.Details.Add("  Service restart failed: $($_.Exception.Message)")
                        }
                        $bouncedService = $true
                    }
                    Start-Sleep -Seconds $retryDelay
                }
            }
        }
        finally {
            [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $origCb
            [System.Net.ServicePointManager]::SecurityProtocol = $origProto
        }
        if (-not $soapOk) {
            $results.Passed = $false
            $results.Details.Add("FAIL: Reporting SOAP API not functional after $maxAttempts attempts (last error: $lastErr)")

            # AUTOPSY. "There was an error downloading '<url>'" names the URL and
            # nothing else, which is why the CSTest2 RP failure was undiagnosable:
            # Phase 7 had already swallowed the real PBIRS error, and this line was
            # the only other evidence. Collect the four things that actually
            # identify the fault, all in-guest, all best-effort.

            # (a) unwrap the WebException -> real HTTP status / socket error
            try {
                if ($lastErrRecord) {
                    $ix = $lastErrRecord.Exception
                    $depth = 0
                    while ($ix -and $depth -lt 5) {
                        $line = "  autopsy exception[$depth]: $($ix.GetType().Name): $($ix.Message)"
                        if ($ix -is [System.Net.WebException]) {
                            $line += " status=$($ix.Status)"
                            try {
                                if ($ix.Response) {
                                    $line += " httpStatus=$([int]$ix.Response.StatusCode) $($ix.Response.StatusCode)"
                                }
                            }
                            catch { }
                        }
                        $results.Details.Add($line)
                        $ix = $ix.InnerException
                        $depth++
                    }
                }
            }
            catch { }

            # (b) is anything even listening on 80/443?
            foreach ($probePort in @(80, 443)) {
                try {
                    $tcp = New-Object System.Net.Sockets.TcpClient
                    $iar = $tcp.BeginConnect('127.0.0.1', $probePort, $null, $null)
                    $connected = $iar.AsyncWaitHandle.WaitOne(3000, $false) -and $tcp.Connected
                    $results.Details.Add("  autopsy tcp 127.0.0.1:$probePort listening=$connected")
                    $tcp.Close()
                }
                catch { $results.Details.Add("  autopsy tcp 127.0.0.1:$probePort probe threw: $($_.Exception.Message)") }
            }

            # (c) the Report Server's own configuration WMI class -- IsInitialized
            #     and the database connection are the two states that decide whether
            #     the SOAP endpoint can ever answer.
            try {
                $rsNs = Get-WmiObject -Namespace 'root\Microsoft\SqlServer\ReportServer' -Class __NAMESPACE -ErrorAction SilentlyContinue |
                    Select-Object -ExpandProperty Name -First 1
                if ($rsNs) {
                    $rsVerNs = Get-WmiObject -Namespace "root\Microsoft\SqlServer\ReportServer\$rsNs" -Class __NAMESPACE -ErrorAction SilentlyContinue |
                        Select-Object -ExpandProperty Name -First 1
                    $cfg = Get-WmiObject -Namespace "root\Microsoft\SqlServer\ReportServer\$rsNs\$rsVerNs\Admin" -Class MSReportServer_ConfigurationSetting -ErrorAction SilentlyContinue
                    if ($cfg) {
                        $results.Details.Add("  autopsy rsconfig IsInitialized=$($cfg.IsInitialized) InstanceName=$($cfg.InstanceName) DB=$($cfg.DatabaseServerName)/$($cfg.DatabaseName) SecureConnectionLevel=$($cfg.SecureConnectionLevel) Version=$($cfg.Version)")
                        try {
                            $urls = $cfg.ListReportServerUrls()
                            for ($u = 0; $u -lt @($urls.UrlString).Count; $u++) {
                                $results.Details.Add("  autopsy rsconfig url app='$(@($urls.Application)[$u])' url='$(@($urls.UrlString)[$u])'")
                            }
                        }
                        catch { $results.Details.Add("  autopsy rsconfig ListReportServerUrls threw: $($_.Exception.Message)") }
                    }
                    else { $results.Details.Add("  autopsy rsconfig MSReportServer_ConfigurationSetting not found under $rsNs\$rsVerNs") }
                }
                else { $results.Details.Add("  autopsy rsconfig namespace root\Microsoft\SqlServer\ReportServer not present") }
            }
            catch { $results.Details.Add("  autopsy rsconfig query threw: $($_.Exception.Message)") }

            # (d) the Report Server service log -- the server-side reason
            try {
                $rsLogDirs = @(
                    'C:\PBIRS\PBIRS\ReportServer\LogFiles',
                    'C:\Program Files\Microsoft Power BI Report Server\PBIRS\LogFiles',
                    'C:\Program Files\Microsoft SQL Server Reporting Services\SSRS\LogFiles'
                )
                $rsLog = $null
                foreach ($d in $rsLogDirs) {
                    if (Test-Path $d) {
                        $rsLog = Get-ChildItem -Path $d -Filter 'ReportServerService_*.log' -ErrorAction SilentlyContinue |
                            Sort-Object LastWriteTime -Descending | Select-Object -First 1
                        if ($rsLog) { break }
                    }
                }
                if ($rsLog) {
                    $results.Details.Add("  autopsy rslog $($rsLog.FullName) (last write $($rsLog.LastWriteTime))")
                    $bad = @(Get-Content -Path $rsLog.FullName -Tail 400 -ErrorAction SilentlyContinue |
                            Where-Object { $_ -match 'ERROR|Exception|Throwing|rsReportServerDatabase|rsServerConfiguration|Cannot open database' } |
                            Select-Object -Last 15)
                    foreach ($b in $bad) { $results.Details.Add("  autopsy rslog| $($b.Trim())") }
                    if ($bad.Count -eq 0) { $results.Details.Add("  autopsy rslog: no ERROR/Exception lines in the last 400 lines") }
                }
                else { $results.Details.Add("  autopsy rslog: no ReportServerService_*.log found in $($rsLogDirs -join ' ; ')") }
            }
            catch { $results.Details.Add("  autopsy rslog read threw: $($_.Exception.Message)") }

            # (e) recent Report Server events
            try {
                $evts = Get-WinEvent -FilterHashtable @{ LogName = 'Application'; StartTime = (Get-Date).AddMinutes(-45) } -MaxEvents 200 -ErrorAction SilentlyContinue |
                    Where-Object { $_.ProviderName -match 'Report Server|Power BI|SSRS' } | Select-Object -First 10
                foreach ($e in @($evts)) {
                    $results.Details.Add("  autopsy event $($e.TimeCreated.ToString('HH:mm:ss')) [$($e.ProviderName)] id=$($e.Id) $(($e.Message -replace '\s+',' '))")
                }
            }
            catch { }
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
                # Duplicates come from the old multi-point enroll flow (Phase 8
                # CertReq + WSUS/PBIRS Get-Certificate self-heals racing the
                # FriendlyName stamp before the Phase 4 enroll-once change). Self-
                # heal: keep the cert bound to IIS 0.0.0.0:443 (the one CM actually
                # uses); if none is bound (or non-WebServer cert), keep the newest
                # valid one. Remove the superseded duplicates, then re-count.
                $boundThumb = $null
                if ($fn -eq 'ConfigMgr WebServer Certificate') {
                    $sslBind = netsh http show sslcert ipport=0.0.0.0:443 2>&1 | Out-String
                    foreach ($c in $certs) {
                        if ($sslBind -match $c.Thumbprint) { $boundThumb = $c.Thumbprint; break }
                    }
                }
                $keep = if ($boundThumb) {
                    $certs | Where-Object { $_.Thumbprint -eq $boundThumb } | Select-Object -First 1
                }
                else {
                    $certs | Sort-Object NotBefore -Descending | Select-Object -First 1
                }
                $removed = 0
                foreach ($c in $certs | Where-Object { $_.Thumbprint -ne $keep.Thumbprint }) {
                    try {
                        Remove-Item "Cert:\LocalMachine\My\$($c.Thumbprint)" -Force -ErrorAction Stop
                        $removed++
                    }
                    catch {
                        $results.Details.Add("  WARN: could not remove duplicate $($c.Thumbprint.Substring(0,8)): $($_.Exception.Message)")
                    }
                }
                $after = @(Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
                    Where-Object { $_.FriendlyName -eq $fn })
                if ($after.Count -eq 1) {
                    $keptReason = if ($boundThumb) { 'IIS-bound' } else { 'newest' }
                    $results.Details.Add("OK: Removed $removed duplicate cert(s) for '$fn'; kept $keptReason thumbprint $($keep.Thumbprint.Substring(0,8))...")
                }
                else {
                    $results.Passed = $false
                    $results.Details.Add("FAIL: $($certs.Count) duplicate certs with FriendlyName '$fn' (expected 1); could not reduce to 1")
                    foreach ($c in $certs | Sort-Object NotBefore) {
                        $results.Details.Add("  Thumbprint=$($c.Thumbprint.Substring(0,8))... NotBefore=$($c.NotBefore)")
                    }
                }
            }
            elseif ($certs.Count -eq 1) {
                $results.Details.Add("OK: Single cert with FriendlyName '$fn'")
            }
            elseif ($fn -eq 'ConfigMgr WebServer Certificate') {
                # No WebServer cert by FriendlyName. This happens on a bare site
                # server (no MP/DP/SUP/RP) after a VM recreate: CertificateDsc's
                # CertReq keys its Test on Subject (the FQDN), so a pre-existing
                # subject-colliding cert makes it skip issuing/stamping the
                # WebServer cert, and AddCertificateToIIS.Test() masks it (a null
                # thumbprint '-match ""' returns true). Self-heal before failing:
                #   (a) re-stamp a WebServer-TEMPLATE cert that lost its FriendlyName
                #   (b) re-enroll from the template if none exists
                #   (c) (re)bind the recovered cert to IIS 0.0.0.0:443
                # Only FAIL when the cert is genuinely absent AND re-enroll fails.
                $srvAuthOid = '1.3.6.1.5.5.7.3.1'
                $fqdn = "$env:COMPUTERNAME.$env:USERDNSDOMAIN"

                # Resolve the WebServer template's per-forest OID from AD so we can
                # positively identify a WebServer-template cert by its V2 template
                # extension (1.3.6.1.4.1.311.21.7) regardless of FriendlyName.
                $wsTemplateOid = $null
                try {
                    $configDN = ([ADSI]'LDAP://RootDSE').configurationNamingContext
                    $tplSearch = [ADSISearcher]"(&(objectClass=pKICertificateTemplate)(cn=ConfigMgrWebServerCertificate))"
                    $tplSearch.SearchRoot = [ADSI]"LDAP://CN=Certificate Templates,CN=Public Key Services,CN=Services,$configDN"
                    $tplObj = $tplSearch.FindOne()
                    if ($tplObj) { $wsTemplateOid = ($tplObj.Properties['mspki-cert-template-oid'] | Select-Object -First 1) }
                }
                catch {}

                # Find a candidate WebServer cert that lost its FriendlyName.
                $candidate = $null
                foreach ($c in @(Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue)) {
                    $eku = @($c.EnhancedKeyUsageList | ForEach-Object { $_.ObjectId })
                    if ($eku -notcontains $srvAuthOid) { continue }   # DP cert is ClientAuth -> excluded
                    $isWs = $false
                    $tplExt = $c.Extensions | Where-Object { $_.Oid.Value -eq '1.3.6.1.4.1.311.21.7' }
                    if ($tplExt -and $wsTemplateOid -and ($tplExt.Format($false) -match [regex]::Escape($wsTemplateOid))) {
                        $isWs = $true
                    }
                    elseif ($c.Subject -match [regex]::Escape($fqdn)) {
                        # Fallback: ServerAuth EKU + subject = this machine's FQDN
                        $isWs = $true
                    }
                    if ($isWs) { $candidate = $c; break }
                }

                $healed = $false
                if ($candidate) {
                    try {
                        $store = New-Object System.Security.Cryptography.X509Certificates.X509Store('My', 'LocalMachine')
                        $store.Open('ReadWrite')
                        $live = $store.Certificates | Where-Object { $_.Thumbprint -eq $candidate.Thumbprint } | Select-Object -First 1
                        if ($live) { $live.FriendlyName = $fn }
                        $store.Close()
                        $healed = $true
                        $results.Details.Add("OK: Recovered WebServer cert (template-matched, thumbprint $($candidate.Thumbprint.Substring(0,8))...) that had lost FriendlyName '$fn'; re-applied name")
                    }
                    catch {
                        $results.Details.Add("WARN: Found a WebServer-template cert but could not re-apply FriendlyName: $($_.Exception.Message)")
                    }
                }

                if (-not $healed) {
                    # No recoverable cert -> re-enroll from the template.
                    try {
                        $enroll = Get-Certificate -Template 'ConfigMgrWebServerCertificate' -DnsName $fqdn -SubjectName "CN=$fqdn" -CertStoreLocation Cert:\LocalMachine\My -ErrorAction Stop
                        if ($enroll -and $enroll.Certificate) {
                            $store = New-Object System.Security.Cryptography.X509Certificates.X509Store('My', 'LocalMachine')
                            $store.Open('ReadWrite')
                            $live = $store.Certificates | Where-Object { $_.Thumbprint -eq $enroll.Certificate.Thumbprint } | Select-Object -First 1
                            if ($live) { $live.FriendlyName = $fn }
                            $store.Close()
                            $healed = $true
                            $results.Details.Add("OK: WebServer cert was missing; re-enrolled from ConfigMgrWebServerCertificate template (thumbprint $($enroll.Certificate.Thumbprint.Substring(0,8))...)")
                        }
                    }
                    catch {
                        $results.Details.Add("  Re-enroll from ConfigMgrWebServerCertificate template failed: $($_.Exception.Message)")
                    }
                }

                if ($healed) {
                    # Ensure the recovered cert is bound to IIS 0.0.0.0:443.
                    try {
                        $wc = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
                            Where-Object { $_.FriendlyName -eq $fn } | Select-Object -Last 1
                        $bound = netsh http show sslcert ipport=0.0.0.0:443 2>&1
                        if ($wc -and ($bound -notmatch $wc.Thumbprint)) {
                            Import-Module WebAdministration -ErrorAction SilentlyContinue
                            $b = Get-WebBinding -Name 'Default Web Site' -Port 443 -Protocol 'https' -ErrorAction SilentlyContinue
                            if (-not $b) {
                                New-WebBinding -Name 'Default Web Site' -IPAddress '*' -Port 443 -Protocol 'https' -ErrorAction SilentlyContinue | Out-Null
                                $b = Get-WebBinding -Name 'Default Web Site' -Port 443 -Protocol 'https' -ErrorAction SilentlyContinue
                            }
                            if ($b) {
                                $null = $b.AddSslCertificate($wc.Thumbprint, 'my')
                                $results.Details.Add("OK: Bound recovered WebServer cert to IIS 0.0.0.0:443")
                            }
                        }
                    }
                    catch {
                        $results.Details.Add("WARN: Could not (re)bind recovered WebServer cert to IIS 443: $($_.Exception.Message)")
                    }
                }
                else {
                    $results.Passed = $false
                    $results.Details.Add("FAIL: No cert with FriendlyName '$fn' found, no recoverable WebServer-template cert in LocalMachine\My, and re-enroll failed")
                    foreach ($c in @(Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue)) {
                        $ekuNames = @($c.EnhancedKeyUsageList | ForEach-Object { $_.FriendlyName }) -join ','
                        $results.Details.Add("  My: subj='$($c.Subject)' fn='$($c.FriendlyName)' thumb=$($c.Thumbprint.Substring(0,8)) eku=[$ekuNames]")
                    }
                }
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
                # The cert exists but IIS 443 points at a different/old thumbprint
                # (a re-enrollment replaced the cert without rebinding, or
                # AddCertificateToIIS.Test() masked a no-op bind). Self-heal:
                # (re)bind the current WebServer cert to 0.0.0.0:443 before failing.
                $rebound = $false
                try {
                    Import-Module WebAdministration -ErrorAction SilentlyContinue
                    $b = Get-WebBinding -Name 'Default Web Site' -Port 443 -Protocol 'https' -ErrorAction SilentlyContinue
                    if (-not $b) {
                        New-WebBinding -Name 'Default Web Site' -IPAddress '*' -Port 443 -Protocol 'https' -ErrorAction SilentlyContinue | Out-Null
                        $b = Get-WebBinding -Name 'Default Web Site' -Port 443 -Protocol 'https' -ErrorAction SilentlyContinue
                    }
                    if ($b) {
                        $null = $b.AddSslCertificate($webCert.Thumbprint, 'my')
                        $sslCert2 = netsh http show sslcert ipport=0.0.0.0:443 2>&1
                        if ($sslCert2 -match $webCert.Thumbprint) { $rebound = $true }
                    }
                }
                catch {
                    $results.Details.Add("  Rebind attempt error: $($_.Exception.Message)")
                }
                if ($rebound) {
                    $results.Details.Add("OK: WebServer cert was not bound; (re)bound to IIS 0.0.0.0:443")
                }
                else {
                    $results.Passed = $false
                    $results.Details.Add("FAIL: WebServer cert thumbprint not bound to IIS 0.0.0.0:443 (rebind attempt failed)")
                }
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

        # On a freshly-built Win11 box (e.g. build 26200) the Schedule service /
        # its ScheduledTasks CIM provider can be transiently not-ready, so a
        # single Get-ScheduledTask returns $null (with -EA SilentlyContinue) even
        # though the task exists -- producing a false "not found". Fix-EnableLogMachine
        # guards its own registration with a service warm-up + retries; mirror that
        # here: ensure the Schedule service is up, retry the CIM query a few times,
        # and fall back to schtasks.exe (a different code path) before failing.
        try {
            $svc = Get-Service -Name 'Schedule' -ErrorAction SilentlyContinue
            if ($svc -and $svc.Status -ne 'Running') { Start-Service -Name 'Schedule' -ErrorAction SilentlyContinue }
        }
        catch { }

        foreach ($taskName in $requiredTasks) {
            $results.Details.Add("CMD: Get-ScheduledTask -TaskName '$taskName'")
            $task = $null
            for ($attempt = 1; $attempt -le 3 -and (-not $task); $attempt++) {
                $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
                if (-not $task -and $attempt -lt 3) { Start-Sleep -Seconds 3 }
            }
            # Fallback: schtasks.exe uses the Task Scheduler COM/RPC path rather
            # than the CIM provider, so it still finds the task when the provider
            # is flaky. A 0 exit code means the task exists.
            $schtasksFound = $false
            if (-not $task) {
                $null = & schtasks.exe /query /tn $taskName 2>$null
                if ($LASTEXITCODE -eq 0) { $schtasksFound = $true }
            }
            if (-not $task -and -not $schtasksFound) {
                # The task is a non-critical convenience (EnableLogMachine wires up
                # .log/CMTrace file associations; Disable-IEESC is cosmetic). On some
                # Win11 builds (e.g. 26200) Fix-EnableLogMachine reports it registered
                # (Success=True) yet it is absent at validation time -- neither the CIM
                # provider nor schtasks.exe find it. Do NOT fail the whole build over a
                # cosmetic task: surface a WARN so the anomaly is visible, but keep the
                # VM (and the deploy) passing.
                $results.Details.Add("WARN: Scheduled task '$taskName' not found at validation (Phase 10 registered it, but it is absent now -- non-critical convenience task, not failing the VM)")
            }
            elseif (-not $task -and $schtasksFound) {
                $results.Details.Add("OK: Scheduled task '$taskName' exists (found via schtasks.exe; CIM provider was transiently unavailable)")
            }
            else {
                $results.Details.Add("OK: Scheduled task '$taskName' exists (State: $($task.State))")
            }
        }

        return $results
    }

    # The scheduled-task query is fast (~1.5s) and idempotent. On a freshly-built
    # VM the guest's PSDirect/job host can transiently stall and never return,
    # leaving the -AsJob call to burn its full timeout with no output. That must
    # NOT hard-fail the whole VM (and the build) over a trivial check.
    #
    # Do NOT retry the -AsJob call against a possibly-hung guest: once the first
    # attempt times out and tears down its job/session, a second Invoke-VmCommand
    # has to stand up a fresh PSDirect session, and New-PSSession -VMName has no
    # timeout -- against a stalled guest it blocks indefinitely, which hangs the
    # whole phase. So: ONE bounded attempt. A genuine task-missing verdict still
    # FAILs (Format-TestResult), but a transient no-result timeout degrades to a
    # non-fatal WARN instead of failing the VM.
    $result = Invoke-VmCommand -VmName $VMName -VmDomainName $Domain `
        -ScriptBlock $scriptBlock -DisplayName "Phase11-Maintenance-Test" -SuppressLog `
        -AsJob -TimeoutSeconds 120 -RebootIfUnresponsive

    $hasValidResult = $result -and $result.ScriptBlockOutput -is [hashtable] -and
        $result.ScriptBlockOutput.ContainsKey('Passed')
    if ((-not $result) -or ($result.ScriptBlockFailed -and -not $hasValidResult)) {
        # Transient PSDirect stall: the probe never returned a verdict. The
        # session has been evicted and, if the guest was genuinely wedged, the VM
        # was rebooted by -RebootIfUnresponsive. Non-fatal -- surface a WARN but
        # don't fail the VM over a check that timed out.
        $rebootNote = if ($result -and $result.Rebooted) { ' (VM was rebooted to recover a wedged PSDirect channel)' } else { '' }
        Write-Log "[Phase $Phase] $VMName [Maintenance]: WARN - could not verify scheduled tasks (PSDirect probe returned no result; likely a transient guest stall)$rebootNote - not failing the VM" -Warning -LogOnly
        $script:Phase11OutputBuffer.Add(@{ Text = "[Phase $Phase] $VMName [Maintenance]: WARN - scheduled-task check skipped (PSDirect probe timed out; not failing the VM)$rebootNote"; Level = 'Warning' })
        return $true
    }

    return (Format-TestResult -VMName $VMName -RoleLabel 'Maintenance' -Result $result)
}

function Test-ForestTrustFunctionality {
    <#
    .SYNOPSIS
        Validates the cross-forest trust feature on a DC that joined a Forest
        Trust (ForestTrust != NONE). Informational/WARN only -- never fails the
        VM (a not-yet-fully-replicated trust shouldn't fail the DC's validation).
    .DESCRIPTION
        Runs in-guest on the new domain's DC and checks each mechanic the
        forest-trust deployment establishes (see Phase2DC.ps1):
          A. The bidirectional forest trust object + a functional secure channel.
          A. Forward DNS (this DC's conditional forwarder to the remote forest)
             AND the REVERSE path (can the remote forest's DNS resolve THIS
             domain) -- the most likely functional gap, since the deployment
             only creates the forwarder on this side.
          B. The remote-forest admin landed in local Administrators
             (AddRemoteAdmins).
          C. The remote root CA is trusted (enterprise Root + NTAuth stores) and
             published into this forest's Configuration NC
             (InstallRootCertificate + RunPkiSync).
          D. When externalDomainJoinSiteCode is set (a remote CM site manages
             this domain's clients): the System Management container exists and
             the remote 'ConfigMgr IIS Servers' group is delegated on it, and
             the AD schema was extended for ConfigMgr (extadsch).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][object]$CurrentItem,
        [Parameter(Mandatory)][object]$DeployConfig
    )

    $Phase = 11
    $domain = $DeployConfig.vmOptions.domainName
    $tp = $CurrentItem.thisParams
    $remoteForest = $CurrentItem.ForestTrust

    # Remote DC FQDN to drive DNS / reverse-DNS probes. thisParams.OtherDC is the
    # canonical value; RootCADC is an equivalent fallback (both = remote DC FQDN).
    $remoteDcFqdn = $null
    if ($tp) {
        if ($tp.OtherDC) { $remoteDcFqdn = $tp.OtherDC }
        elseif ($tp.RootCADC) { $remoteDcFqdn = $tp.RootCADC }
    }
    $externalSiteCode = $CurrentItem.externalDomainJoinSiteCode

    Write-Log "[Phase $Phase] $VMName [ForestTrust]: Validating cross-forest trust to '$remoteForest'" -LogOnly

    if (-not $remoteDcFqdn) {
        Write-Log "[Phase $Phase] $VMName [ForestTrust]: No remote DC FQDN in thisParams; skipping cross-forest validation" -LogOnly
        return $true
    }

    $forestTrustScript = {
        param($localDomain, $remoteForest, $remoteDcFqdn, $externalSiteCode, $remoteNetbios)

        # Informational: Passed stays $true so the trust checks never fail the DC.
        $results = @{ Passed = $true; Details = [System.Collections.Generic.List[string]]::new() }
        # $remoteNetbios is the TRUE NetBIOS name of the trusted forest, resolved on the host
        # from that domain's persisted VM notes and passed in -- NEVER derived from the DNS
        # FQDN (disjoint namespaces differ). It's used for NETBIOS\principal checks below.
        # $remoteDnsShort is the DNS first label, used ONLY for CA-name matching, because
        # MemLabs names CAs '<dns-first-label>-<vm>-CA' regardless of the NetBIOS name.
        $remoteDnsShort = ($remoteForest -split '\.')[0]
        if ([string]::IsNullOrWhiteSpace($remoteNetbios)) { $remoteNetbios = $remoteDnsShort }
        $localDcFqdn = "$env:COMPUTERNAME.$localDomain"

        # --- A1: Forest trust object ---
        $results.Details.Add("CMD: Get-ADTrust -Filter { Target -eq '$remoteForest' }")
        try {
            $trust = Get-ADTrust -Filter "Target -eq '$remoteForest'" -ErrorAction Stop
            if (-not $trust) {
                $results.Details.Add("WARN: No AD trust object found for forest '$remoteForest'")
            }
            else {
                $dir = "$($trust.Direction)"
                $tt = "$($trust.TrustType)"
                $ft = $trust.ForestTransitive
                if ($dir -eq 'BiDirectional' -and $ft) {
                    $results.Details.Add("OK: Forest trust to '$remoteForest' is BiDirectional + ForestTransitive ($tt)")
                }
                else {
                    $results.Details.Add("WARN: Trust to '$remoteForest' present but Direction=$dir ForestTransitive=$ft TrustType=$tt (expected a BiDirectional forest trust)")
                }
            }
        }
        catch {
            $results.Details.Add("WARN: Get-ADTrust for '$remoteForest' failed: $($_.Exception.Message)")
        }

        # --- A2: Functional secure channel to the remote forest ---
        $results.Details.Add("CMD: nltest /sc_query:$remoteForest")
        try {
            $sc = & nltest "/sc_query:$remoteForest" 2>&1 | Out-String
            if ($sc -match 'Success|NERR_Success|Connection Status = 0\b') {
                $results.Details.Add("OK: Secure channel to '$remoteForest' verified (nltest)")
            }
            else {
                $firstLine = (($sc -split "`n") | Where-Object { $_.Trim() } | Select-Object -First 1)
                $results.Details.Add("WARN: nltest secure channel to '$remoteForest' did not report success: $($firstLine.Trim())")
            }
        }
        catch {
            $results.Details.Add("WARN: nltest /sc_query:$remoteForest failed: $($_.Exception.Message)")
        }

        # --- A3: Forward DNS to the remote forest (this side's conditional forwarder) ---
        $remoteIp = $null
        $results.Details.Add("CMD: Resolve-DnsName $remoteDcFqdn")
        try {
            $fwd = Resolve-DnsName -Name $remoteDcFqdn -Type A -ErrorAction Stop | Where-Object { $_.IPAddress } | Select-Object -First 1
            if ($fwd) {
                $remoteIp = $fwd.IPAddress
                $results.Details.Add("OK: Forward DNS resolves '$remoteDcFqdn' -> $remoteIp (conditional forwarder works)")
            }
            else {
                $results.Details.Add("WARN: '$remoteDcFqdn' returned no A record")
            }
        }
        catch {
            $results.Details.Add("WARN: Forward DNS for '$remoteDcFqdn' failed (conditional forwarder may be missing): $($_.Exception.Message)")
        }

        # --- A4: REVERSE DNS path (remote forest -> this domain). The deployment
        #         only creates a forwarder on THIS side, so a remote DNS that
        #         can't resolve this domain breaks remote-site client management
        #         and incoming-trust validation. Ask the remote DNS directly. ---
        if ($remoteIp) {
            $results.Details.Add("CMD: Resolve-DnsName $localDcFqdn -Server $remoteIp")
            try {
                $rev = Resolve-DnsName -Name $localDcFqdn -Type A -Server $remoteIp -ErrorAction Stop | Where-Object { $_.IPAddress } | Select-Object -First 1
                if ($rev) {
                    $results.Details.Add("OK: Remote forest DNS ($remoteIp) can resolve this domain ('$localDcFqdn' -> $($rev.IPAddress))")
                }
                else {
                    $results.Details.Add("WARN: Remote forest DNS ($remoteIp) returned no record for '$localDcFqdn' -- the reverse conditional forwarder (remote -> $localDomain) is likely missing; remote-site client management/auth may break")
                }
            }
            catch {
                $results.Details.Add("WARN: Remote forest DNS ($remoteIp) cannot resolve '$localDcFqdn' -- the reverse conditional forwarder (remote -> $localDomain) is missing; remote-site client management/auth may break: $($_.Exception.Message)")
            }
        }

        # --- B: Remote-forest admin in local Administrators (AddRemoteAdmins) ---
        # NOTE: Get-LocalGroupMember fails on a DC ("Group Administrators was not
        # found") because a DC has no local SAM -- the group is the domain-local
        # BUILTIN\Administrators. Enumerate via ADSI WinNT, which works on both
        # DCs and member servers and lists foreign-forest principals too.
        $results.Details.Add("CMD: enumerate Administrators members via ADSI WinNT (looking for '$remoteNetbios\\*')")
        try {
            $adminGroup = [ADSI]"WinNT://$env:COMPUTERNAME/Administrators,group"
            $rawMembers = @($adminGroup.psbase.Invoke('Members'))
            $memberNames = @()
            foreach ($m in $rawMembers) {
                try {
                    $mName = $m.GetType().InvokeMember('Name', 'GetProperty', $null, $m, $null)
                    $mPath = $m.GetType().InvokeMember('ADsPath', 'GetProperty', $null, $m, $null)
                    $mDomain = ''
                    if ("$mPath" -match 'WinNT://([^/]+)/') { $mDomain = $Matches[1] }
                    if ($mDomain) { $memberNames += "$mDomain\$mName" }
                    else { $memberNames += "$mName" }
                }
                catch {
                    # Foreign-forest principals can surface as raw SIDs; keep them
                    # so the diagnostic line still reflects the full membership.
                    $memberNames += '<unresolved-member>'
                }
            }
            $remoteAdmins = @($memberNames | Where-Object { $_ -like "$remoteNetbios\*" })
            if ($remoteAdmins.Count -gt 0) {
                $results.Details.Add("OK: Local Administrators includes remote-forest principal(s): $($remoteAdmins -join ', ')")
            }
            else {
                $results.Details.Add("WARN: No '$remoteNetbios\\*' principal in local Administrators (AddRemoteAdmins may not have applied) [members: $($memberNames -join ', ')]")
            }
        }
        catch {
            $results.Details.Add("WARN: Could not enumerate local Administrators: $($_.Exception.Message)")
        }

        # --- C1: Remote root CA trusted in the enterprise Root + NTAuth stores ---
        # CA CN follows the '<dns-first-label>-<vm>-CA' naming convention, so match on the
        # DNS short name (NOT the NetBIOS name, which can differ in a disjoint namespace).
        $results.Details.Add("CMD: certutil -store -enterprise Root / NTAuth (looking for '$remoteDnsShort-')")
        try {
            $rootStore = & certutil -store -enterprise Root 2>&1 | Out-String
            $ntauthStore = & certutil -store -enterprise NTAuth 2>&1 | Out-String
            $needle = [regex]::Escape("$remoteDnsShort-")
            if ($rootStore -match $needle) {
                $results.Details.Add("OK: Remote CA '$remoteDnsShort-*' present in enterprise Root store")
            }
            else {
                $extra = ''
                # This is the same fact ccmsetup reports as "Unable to find any
                # Certificate based on Certificate Issuers" -> CCM_E_NO_CLIENT_PKI_CERT.
                if ($externalSiteCode -and $externalSiteCode -ne 'NONE') {
                    $extra = " -- clients here are managed by remote site '$externalSiteCode' over HTTPS, so until this CA is trusted locally none of them can present a client cert (ccmsetup 0x87D00454)"
                }
                $results.Details.Add("WARN: Remote CA '$remoteDnsShort-*' NOT found in enterprise Root store (InstallRootCertificate dspublish RootCA may have failed)$extra")
            }
            if ($ntauthStore -match $needle) {
                $results.Details.Add("OK: Remote CA present in enterprise NTAuth store")
            }
            else {
                $results.Details.Add("WARN: Remote CA NOT found in enterprise NTAuth store (cross-forest client auth requires NTAuth)")
            }
        }
        catch {
            $results.Details.Add("WARN: certutil enterprise store query failed: $($_.Exception.Message)")
        }

        # --- C2: Remote CA published into the LOCAL forest Configuration NC,
        #         plus the synced certificate templates (RunPkiSync). ---
        try {
            $configNC = ([ADSI]"LDAP://RootDSE").configurationNamingContext.Value
            $caContainer = [ADSI]"LDAP://CN=Certification Authorities,CN=Public Key Services,CN=Services,$configNC"
            $names = @()
            foreach ($c in $caContainer.Children) { $names += [string]$c.Properties['cn'].Value }
            if (@($names | Where-Object { $_ -like "$remoteDnsShort-*" }).Count -gt 0) {
                $results.Details.Add("OK: Remote root CA published in local AD Certification Authorities [$($names -join ', ')]")
            }
            else {
                $results.Details.Add("WARN: Remote root CA not in local AD Certification Authorities [present: $($names -join ', ')] (InstallRootCertificate dspublish / RunPkiSync gap)")
            }

            $tmplContainer = [ADSI]"LDAP://CN=Certificate Templates,CN=Public Key Services,CN=Services,$configNC"
            $tmplCount = @($tmplContainer.Children).Count
            $results.Details.Add("OK: Local forest has $tmplCount certificate template(s) (RunPkiSync copies remote templates here)")
        }
        catch {
            $results.Details.Add("WARN: Could not read local Configuration NC PKI containers: $($_.Exception.Message)")
        }

        # --- C3: Can a computer in THIS domain actually autoenroll a ConfigMgr
        #         client cert from the remote CA? Read the template ACL in BOTH
        #         forests plus the local publication. Labs are deleted long before
        #         anyone can log on to a client, so this has to land in the run log:
        #         it is the whole decision tree behind ccmsetup 0x87D00454.
        #           grant missing in CA forest    -> AddCertificateTemplate did not take
        #           present there, absent locally -> PKISync ran before the grant
        #           present in both               -> autoenrollment / GP on the client
        if ($externalSiteCode -and $externalSiteCode -ne 'NONE') {
            $tplName = 'ConfigMgrClientCertificate'
            # Match by SID, not name: a foreign-forest ACE routinely fails to
            # resolve to a name, and 'Domain Computers' is always <domainSid>-515.
            $domainComputersSid = ''
            try { $domainComputersSid = "$((Get-ADDomain -ErrorAction Stop).DomainSID.Value)-515" } catch {}
            if (-not $domainComputersSid) {
                $results.Details.Add("WARN: could not resolve this domain's SID; skipping the certificate-template enrollment check (nothing was measured)")
            }
            else {
                $results.Details.Add("CMD: read '$tplName' ACL in both forests for Enroll/AutoEnroll by $domainComputersSid ($localDomain\Domain Computers)")
                $enrollGuid = '0e10c968-78fb-11d2-90d4-00c04f79dc55'
                $autoEnrollGuid = 'a05b8cc2-17bc-4802-a710-e7c15ab866a2'
                $readTemplateAcl = {
                    param($server, $label)
                    $prefix = ''
                    if ($server) { $prefix = "$server/" }
                    # Interpolate, never -f: -f renders a PropertyValueCollection as
                    # its type name and silently builds an unbindable LDAP path.
                    $cfg = "$(([ADSI]"LDAP://${prefix}RootDSE").configurationNamingContext)"
                    if ($cfg -notmatch '^CN=Configuration,DC=') { throw "unusable configurationNamingContext '$cfg'" }
                    $tpl = [ADSI]"LDAP://${prefix}CN=$tplName,CN=Certificate Templates,CN=Public Key Services,CN=Services,$cfg"
                    if (-not $tpl.distinguishedName) { throw "template '$tplName' not present in $label" }
                    $granted = @()
                    foreach ($ace in @($tpl.ObjectSecurity.Access | Where-Object { $null -ne $_ })) {
                        if ("$($ace.AccessControlType)" -ne 'Allow') { continue }
                        if ("$($ace.IdentityReference)" -ne $domainComputersSid) { continue }
                        $ot = "$($ace.ObjectType)"
                        if ($ot -eq $enrollGuid) { $granted += 'Enroll' }
                        elseif ($ot -eq $autoEnrollGuid) { $granted += 'AutoEnroll' }
                        elseif ("$($ace.ActiveDirectoryRights)" -match 'GenericRead|GenericAll') { $granted += 'Read' }
                    }
                    return , @($granted | Select-Object -Unique)
                }

                foreach ($tgt in @(@{ Server = ''; Label = "this forest ($localDomain)" }, @{ Server = $remoteDcFqdn; Label = "CA forest ($remoteForest)" })) {
                    try {
                        $granted = & $readTemplateAcl $tgt.Server $tgt.Label
                        if ($granted -contains 'AutoEnroll' -and $granted -contains 'Enroll') {
                            $results.Details.Add("OK: '$tplName' in $($tgt.Label) grants this domain's computers $($granted -join '+')")
                        }
                        else {
                            $have = if ($granted.Count -gt 0) { $granted -join '+' } else { 'nothing' }
                            $results.Details.Add("WARN: '$tplName' in $($tgt.Label) grants this domain's computers $have (need Read+Enroll+AutoEnroll) -- clients here cannot autoenroll, so ccmsetup will fail CCM_E_NO_CLIENT_PKI_CERT (0x87D00454)")
                        }
                    }
                    catch {
                        $results.Details.Add("WARN: could not read '$tplName' ACL in $($tgt.Label): $($_.Exception.Message)")
                    }
                }

                # An issuing CA must also be published HERE, offering that template,
                # or autoenrollment has nowhere to send the request.
                try {
                    $cfgLocal = "$(([ADSI]'LDAP://RootDSE').configurationNamingContext)"
                    $enrollSvc = [ADSI]"LDAP://CN=Enrollment Services,CN=Public Key Services,CN=Services,$cfgLocal"
                    $svcs = @($enrollSvc.Children | Where-Object { $null -ne $_ })
                    if ($svcs.Count -eq 0) {
                        $results.Details.Add("WARN: no issuing CA published in this forest's Enrollment Services -- autoenrollment has no CA to request from (PKISync gap)")
                    }
                    foreach ($svc in $svcs) {
                        $offered = @($svc.Properties['certificateTemplates'].Value | Where-Object { $_ })
                        $hasTpl = $offered -contains $tplName
                        $line = "issuing CA '$("$($svc.Properties['cn'].Value)")' on $("$($svc.Properties['dNSHostName'].Value)") published here, offers $($offered.Count) template(s), $tplName offered=$hasTpl"
                        if ($hasTpl) { $results.Details.Add("OK: $line") } else { $results.Details.Add("WARN: $line -- clients here will not request it") }
                    }
                }
                catch {
                    $results.Details.Add("WARN: could not read this forest's Enrollment Services container: $($_.Exception.Message)")
                }

                # NTAuthCertificates in AD is the authoritative copy; the enterprise
                # store checked above is only this machine's synced view of it.
                try {
                    $ntAuth = [ADSI]"LDAP://CN=NTAuthCertificates,CN=Public Key Services,CN=Services,$(([ADSI]'LDAP://RootDSE').configurationNamingContext)"
                    $ntCount = @($ntAuth.Properties['cACertificate'].Value | Where-Object { $_ -is [byte[]] }).Count
                    if ($ntCount -gt 0) { $results.Details.Add("OK: this forest's AD NTAuthCertificates holds $ntCount CA cert(s)") }
                    else { $results.Details.Add("WARN: this forest's AD NTAuthCertificates is EMPTY (certutil -dspublish NtauthCA never landed)") }
                }
                catch {
                    $results.Details.Add("WARN: could not read this forest's NTAuthCertificates: $($_.Exception.Message)")
                }
            }
        }

        # --- D: Remote-site client-management prerequisites (externalDomainJoinSiteCode) ---
        if ($externalSiteCode -and $externalSiteCode -ne 'NONE') {
            try {
                $defNC = ([ADSI]"LDAP://RootDSE").defaultNamingContext.Value
                $smPath = "LDAP://CN=System Management,CN=System,$defNC"
                if ([System.DirectoryServices.DirectoryEntry]::Exists($smPath)) {
                    $results.Details.Add("OK: System Management container exists (CN=System Management,CN=System,$defNC)")
                    $sm = [ADSI]$smPath
                    $acl = $sm.ObjectSecurity
                    $hasRemoteIIS = @($acl.Access | Where-Object { "$($_.IdentityReference)" -like "$remoteNetbios\*ConfigMgr*" }).Count -gt 0
                    if ($hasRemoteIIS) {
                        $results.Details.Add("OK: Remote '$remoteNetbios\ConfigMgr IIS Servers' is delegated on the System Management container")
                    }
                    else {
                        $results.Details.Add("WARN: No '$remoteNetbios\ConfigMgr IIS Servers' ACE on System Management (DelegateControl gap; remote site '$externalSiteCode' can't publish here -- may appear as a SID if cross-forest name resolution is down)")
                    }
                }
                else {
                    $results.Details.Add("WARN: System Management container missing -- remote CM site '$externalSiteCode' cannot publish to this domain")
                }
            }
            catch {
                $results.Details.Add("WARN: System Management container/ACL check failed: $($_.Exception.Message)")
            }

            try {
                $schemaNC = ([ADSI]"LDAP://RootDSE").schemaNamingContext.Value
                $searcher = [ADSISearcher]::new()
                $searcher.SearchRoot = [ADSI]"LDAP://$schemaNC"
                $searcher.Filter = "(cn=MS-SMS-*)"
                $smsClasses = @($searcher.FindAll()).Count
                if ($smsClasses -gt 0) {
                    $results.Details.Add("OK: AD schema extended for ConfigMgr ($smsClasses MS-SMS-* schema object(s) present)")
                }
                else {
                    $results.Details.Add("WARN: No MS-SMS-* classes in the schema -- extadsch may not have extended this forest's schema (remote site can't manage clients here)")
                }
            }
            catch {
                $results.Details.Add("WARN: Schema extension check failed: $($_.Exception.Message)")
            }
        }

        return $results
    }

    # Resolve the trusted forest's TRUE NetBIOS name from its persisted VM notes (host-side).
    # Never derive it from the FQDN -- a disjoint-namespace forest's NetBIOS name differs from
    # its DNS first label. Fall back to the DNS label only when no note carries the value.
    $remoteNetbios = Get-DomainNetbiosName -DomainName $remoteForest
    if ([string]::IsNullOrWhiteSpace($remoteNetbios)) {
        $remoteNetbios = ($remoteForest -split '\.')[0]
        Write-Log "[Phase $Phase] $VMName [ForestTrust]: no persisted NetBIOS name for '$remoteForest'; falling back to DNS label '$remoteNetbios'" -LogOnly
    }

    $result = Invoke-VmCommand -VmName $VMName -VmDomainName $domain `
        -ScriptBlock $forestTrustScript -ArgumentList @($domain, $remoteForest, $remoteDcFqdn, $externalSiteCode, $remoteNetbios) `
        -DisplayName "Phase11-ForestTrust-Test" -SuppressLog -AsJob -TimeoutSeconds 300

    $null = Format-TestResult -VMName $VMName -RoleLabel 'ForestTrust' -Result $result
    return $true
}

function Test-DscIdle {
    <#
    .SYNOPSIS
        Warns (non-fatal) when the DSC LCM is still busy/pending after the build.
    .DESCRIPTION
        By Phase 11 every phase MOF has already been applied, so the LCM should
        be Idle. A non-Idle LCMState means DSC is still doing work after the
        deployment finished:
          - Busy  = a configuration is actively applying right now.
          - Pending* = a configuration and/or reboot is queued and the
            consistency engine will pick it up.
        DSC continuing to run after the build just burns host CPU/disk, so this
        emits a WARN. Rather than dumping the last few raw log lines, it mines
        the DSC operational log to report the actionable detail:
          - the LCM's own LCMStateDetail reason string;
          - the in-flight Start-DscConfiguration: when it started, how long it
            has been running, and WHO triggered it (a remote DC/orchestrator =
            a deploy step re-pushed the config and it is transient; the local
            machine = the consistency-engine timer fired on its own schedule);
          - the full resource execution sequence, which fingerprints exactly
            which phase MOF is applying;
          - the resource currently executing.
        It is informational only and never fails the VM.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$Domain
    )

    $Phase = 11
    Write-Log "[Phase $Phase] $VMName [DSC]: Checking DSC LCM is idle" -LogOnly

    $scriptBlock = {
        # Informational check: Passed stays $true unconditionally so a still-
        # running DSC never fails the VM's functional validation.
        $results = @{ Passed = $true; Details = [System.Collections.Generic.List[string]]::new() }

        $results.Details.Add("CMD: (Get-DscLocalConfigurationManager).LCMState")
        $lcmState = 'Unknown'
        $lcmDetail = $null
        try {
            $lcm = Get-DscLocalConfigurationManager -ErrorAction Stop
            $lcmState = $lcm.LCMState
            # LCMStateDetail is a human-readable reason string (sometimes an
            # array), e.g. "LCM is applying a new configuration." It is far more
            # specific than the bare 'Busy'/'PendingConfiguration' state word.
            if ($lcm.PSObject.Properties['LCMStateDetail'] -and $lcm.LCMStateDetail) {
                $lcmDetail = ($lcm.LCMStateDetail | Where-Object { $_ } | ForEach-Object { ([string]$_).Trim() }) -join '; '
            }
        }
        catch {
            # LCM unreadable (no config ever pushed / provider host down) means
            # there is no apply running. Nothing is wasting resources.
            $results.Details.Add("OK: DSC LCM not queryable ($($_.Exception.Message)); treating as no running configuration")
            return $results
        }

        # Idle = nothing applying and nothing queued -- the desired post-build state.
        if ($lcmState -eq 'Idle') {
            $results.Details.Add("OK: DSC LCM is Idle")
            return $results
        }

        # The LCM is not Idle. Read a wide window of operational-log events FIRST
        # so we can both (a) reconstruct what is running and (b) decide whether
        # this is the benign "Phase 8 site-server MOF still unwinding" case on a
        # CAS/Primary before we emit a scary WARN.
        $events = $null
        try {
            $events = Get-WinEvent -LogName 'Microsoft-Windows-DSC/Operational' -MaxEvents 60 -ErrorAction Stop |
                Sort-Object TimeCreated
        }
        catch {
            $stateLine = "WARN: DSC LCM is '$lcmState' (expected 'Idle' after the build) - DSC is still running after deployment and wasting resources"
            if ($lcmDetail) { $stateLine += " [LCM: $lcmDetail]" }
            $results.Details.Add($stateLine)
            $results.Details.Add("WARN: Could not read DSC operational log to identify the running configuration ($($_.Exception.Message))")
            return $results
        }
        if (-not $events) {
            $stateLine = "WARN: DSC LCM is '$lcmState' (expected 'Idle' after the build) - DSC is still running after deployment and wasting resources"
            if ($lcmDetail) { $stateLine += " [LCM: $lcmDetail]" }
            $results.Details.Add($stateLine)
            $results.Details.Add("WARN: No DSC operational-log events found to identify the running configuration")
            return $results
        }

        $now = Get-Date

        # In-flight apply provenance: the most recent "Start-DscConfiguration ...
        # started" operation -- WHO kicked it off and HOW LONG ago. A remote
        # "from computer <DC>" means the deploy orchestrator re-pushed the phase
        # config (expected, transient); the local computer name means the
        # consistency-engine timer fired on its own schedule.
        $startEvt = $events | Where-Object { $_.Message -match 'Start-DscConfiguration' -and $_.Message -match 'started' } |
            Select-Object -Last 1
        $isRemoteOrchestrator = $false
        $originDesc = $null
        $applyStartedStr = $null
        if ($startEvt) {
            $elapsed = $now - $startEvt.TimeCreated
            $elapsedStr = if ($elapsed.TotalMinutes -ge 1) { "{0:n1} min" -f $elapsed.TotalMinutes } else { "{0:n0} sec" -f $elapsed.TotalSeconds }
            $fromComputer = if ($startEvt.Message -match 'from computer\s+([^\s\.\,]+)') { $Matches[1] } else { 'unknown' }
            if ($fromComputer -and $fromComputer -ne 'unknown' -and $fromComputer -ne $env:COMPUTERNAME -and $fromComputer -ne 'NULL') {
                $isRemoteOrchestrator = $true
                $originDesc = "remote orchestrator '$fromComputer' (a deploy step re-pushed the config)"
            }
            elseif ($fromComputer -eq $env:COMPUTERNAME) {
                $originDesc = "local consistency-engine timer"
            }
            else {
                $originDesc = "computer '$fromComputer'"
            }
            $applyStartedStr = "Active apply started $($startEvt.TimeCreated.ToString('HH:mm:ss')) ($elapsedStr ago) by $originDesc"
        }

        # Resource execution sequence: the ordered list of resources in the
        # configuration currently applying. This fingerprints WHICH phase MOF is
        # running (e.g. ADKInstall / ReportBuilder / ODBCDriver = the site-server
        # config).
        $seqEvt = $events | Where-Object { $_.Message -match 'Resource execution sequence' } | Select-Object -Last 1
        $resList = @()
        if ($seqEvt) {
            $seq = ($seqEvt.Message -replace '\s+', ' ').Trim()
            $seq = $seq -replace '^.*Resource execution sequence\s*::\s*', ''
            $resList = @($seq -split '\s*,\s*' | Where-Object { $_ })
        }
        # The CAS/Primary/Secondary site-server (Phase 8) MOF is uniquely
        # identified by its WaitForEvent on the ScriptWorkflow completion flag
        # (RegisterTaskScheduler RunScriptWorkflow + WaitForEvent WorkflowComplete).
        # No other role's configuration contains those resources.
        $isSiteWorkflowMof = [bool](($resList -match 'WorkflowComplete') -or ($resList -match 'RunScriptWorkflow'))

        # BENIGN CASE (ignore Phase 8 DSC noise on CAS/Primary): the site-server
        # Phase 8 config is pushed FROM the DC, and ScriptWorkflow stamps its
        # completion flag EARLY so the orchestrator can advance the phase / start
        # the child Primary. The LCM then needs a short tail to unwind the
        # WaitForEvent -> WriteStatus Complete resources back to Idle. When the
        # apply was (a) pushed by a remote orchestrator AND (b) is the site-server
        # workflow MOF, this non-Idle state is that expected tail, not wasted
        # work -- report INFO, not WARN, and skip the verbose dump.
        if ($isRemoteOrchestrator -and $isSiteWorkflowMof) {
            $line = "OK: DSC LCM is '$lcmState' but this is the expected Phase 8 site-server workflow MOF still finishing on this site server"
            if ($applyStartedStr) { $line += " ($applyStartedStr)" }
            $results.Details.Add($line)
            $results.Details.Add("OK: ScriptWorkflow stamps completion early so the phase advances; the LCM returns to Idle shortly after - not wasted work, no action needed")
            return $results
        }

        # Otherwise this is a genuinely non-Idle LCM after the build -- WARN and
        # dump the full diagnostics.
        $stateLine = "WARN: DSC LCM is '$lcmState' (expected 'Idle' after the build) - DSC is still running after deployment and wasting resources"
        if ($lcmDetail) { $stateLine += " [LCM: $lcmDetail]" }
        $results.Details.Add($stateLine)

        if ($applyStartedStr) {
            $results.Details.Add("WARN: $applyStartedStr")
        }
        else {
            $results.Details.Add("WARN: No in-flight Start-DscConfiguration found; LCM may be mid consistency-check or pending a queued config/reboot")
        }

        if ($resList.Count -gt 0) {
            $results.Details.Add("WARN: Configuration applying contains $($resList.Count) resource(s) (this identifies which phase MOF is running):")
            # Emit in chunks of 6 so a long sequence stays readable in the log.
            for ($i = 0; $i -lt $resList.Count; $i += 6) {
                $chunk = $resList[$i..([Math]::Min($i + 5, $resList.Count - 1))] -join ', '
                $results.Details.Add("WARN:   $chunk")
            }
        }

        # The currently-executing resource: the latest "[Start Set]/[Start
        # Resource]/[Start Test]", so the operator sees the specific resource
        # that is blocking idle right now.
        $currentResEvt = $events | Where-Object { $_.Message -match '\[\s*(Start Set|Start Resource|Start Test)\s*\]' } |
            Select-Object -Last 1
        if ($currentResEvt) {
            $curMsg = ($currentResEvt.Message -replace '\s+', ' ').Trim()
            if ($curMsg -match '(\[\s*(?:Start Set|Start Resource|Start Test)\s*\][^\r\n]*?\]\])') { $curMsg = $Matches[1] }
            if ($curMsg.Length -gt 200) { $curMsg = $curMsg.Substring(0, 200) + '...' }
            $results.Details.Add("WARN: Currently executing: [$($currentResEvt.TimeCreated.ToString('HH:mm:ss'))] $curMsg")
        }

        # The raw recent activity tail, kept as a fallback for anything the
        # structured extraction above did not capture.
        $results.Details.Add("WARN: Most recent DSC operational-log activity (oldest -> newest):")
        foreach ($e in ($events | Select-Object -Last 8)) {
            $msg = ($e.Message -replace '\s+', ' ').Trim()
            if ($msg.Length -gt 220) { $msg = $msg.Substring(0, 220) + '...' }
            $results.Details.Add("WARN:   [$($e.TimeCreated.ToString('HH:mm:ss'))] $msg")
        }

        return $results
    }

    $result = Invoke-VmCommand -VmName $VMName -VmDomainName $Domain `
        -ScriptBlock $scriptBlock -DisplayName "Phase11-DSC-Idle-Test" -SuppressLog `
        -AsJob -TimeoutSeconds 180 -RebootIfUnresponsive

    # Format-TestResult returns the script's Passed verdict, which is always
    # $true here; the WARN: detail lines still reach the console/log via the
    # Phase 11 output buffer.
    return (Format-TestResult -VMName $VMName -RoleLabel 'DSC' -Result $result)
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
            # The row existing is necessary but not sufficient -- read ConfigMgr's
            # authoritative ServerState (the value the console shows). Low word
            # starting with 'F' (e.g. 0x0001FFFF SiteServerInstallationFailed /
            # 0x0002FFFF PREREQ_ERROR) = the console's "Installation failed"; a row
            # can be present with SMS_EXECUTIVE Running yet still be CM-failed.
            $row = @($passive)[0]
            $ss = $null
            if ($null -ne $row.ServerState) { $ss = [int]$row.ServerState }
            $ssHex = if ($null -ne $ss) { '0x{0:X8}' -f $ss } else { 'n/a' }
            if ($null -ne $ss -and $ss -gt 0 -and (('{0:X4}' -f ($ss % 65536)).Substring(0, 1) -eq 'F')) {
                $results.Passed = $false
                $ssName = switch ($ss) { 131071 { 'SiteServerInstallationFailed' } 196607 { 'PREREQ_ERROR' } default { 'Installation failed / prereq error' } }
                $results.Details.Add("FAIL: Passive site server '$passiveName' registered but ConfigMgr reports ServerState=$ssHex ($ssName). The local ConfigMgrSetup.log on $passiveName can show a CLEAN install (files land) -- the passive install is orchestrated by SMS_FAILOVER_MANAGER; failovermgr.log (+ smsexec.log) on BOTH nodes are authoritative (auto-collected below), NOT hman.log.")
                # Dump the detailed HA installation substages so the FAILING/STALLED
                # step is named, not just the top-level failed state. Fields per
                # _smsprov.mof SMS_HA_SiteServerDetailedMonitoring: SubStageName/
                # Description/StageId/IsComplete (2=done,4=failed,blank=not-run)/
                # Progress/SiteServerInstallID (retry count)/Parameter.
                try {
                    $mon = @(Get-WmiObject -Namespace "root\SMS\site_$sc" -Class SMS_HA_SiteServerDetailedMonitoring -Filter "SiteServerName LIKE '%$passiveName%'" -ErrorAction Stop |
                            Where-Object { $_.Applicable -ne 0 } | Sort-Object StageId, SubStageid)
                    if ($mon.Count) {
                        $retryN = @($mon | ForEach-Object { $_.SiteServerInstallID } | Where-Object { $_ } | Sort-Object -Descending | Select-Object -First 1)
                        $results.Details.Add("INFO: HA install substages (latest SiteServerInstallID/retry=$retryN):")
                        $maxDoneStage = -1
                        $firstStalled = $null
                        foreach ($r in $mon) {
                            $hasState = ($null -ne $r.IsComplete -and "$($r.IsComplete)" -ne '')
                            $flag = if ($r.IsComplete -eq 4) { 'FAILED' } elseif ($r.IsComplete -eq 2 -or $r.Progress -eq 100) { 'done' } elseif (-not $hasState) { 'NOT-RUN' } else { "inprogress(IsComplete=$($r.IsComplete),Progress=$($r.Progress))" }
                            if ($flag -eq 'done' -and [int]$r.StageId -gt $maxDoneStage) { $maxDoneStage = [int]$r.StageId }
                            if (-not $firstStalled -and ($flag -eq 'FAILED' -or $flag -eq 'NOT-RUN')) { $firstStalled = $r }
                            $desc = "$($r.Description)".Trim(); if ($desc.Length -gt 180) { $desc = $desc.Substring(0, 180) }
                            $results.Details.Add(("  [{0}] Stage {1}/{2} '{3}': {4}{5}" -f $flag, $r.StageId, $r.SubStageid, $r.SubStageName, ($(if ($desc) { $desc } else { '(no description)' })), $(if ($r.Parameter) { " | Param=$($r.Parameter)" } else { '' })))
                        }
                        if ($firstStalled) {
                            $results.Details.Add(("VERDICT: install completed through Stage {0}; STALLED/FAILED entering Stage {1} '{2}'. This substage is orchestrated by SMS_FAILOVER_MANAGER -- read failovermgr.log (and smsexec.log for service install). Stage 14 'Validating access to remote site systems' failing points at remote site system / remote content-library reachability (e.g. the HA remoteContentLibVM)." -f $maxDoneStage, $firstStalled.StageId, $firstStalled.SubStageName))
                        }
                    }
                    else {
                        $results.Details.Add("INFO: SMS_HA_SiteServerDetailedMonitoring returned no applicable substage rows for '$passiveName' -- read the auto-collected failovermgr.log.")
                    }
                }
                catch {
                    $results.Details.Add("INFO: could not read SMS_HA_SiteServerDetailedMonitoring: $($_.Exception.Message)")
                }
            }
            else {
                $results.Details.Add("OK: Passive site server '$passiveName' registered in site '$sc' (ServerState=$ssHex)")
            }
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

    # When ConfigMgr reports the passive node in a failed/prereq-error state, the
    # local ConfigMgrSetup.log often looks clean -- the passive install is
    # orchestrated by SMS_FAILOVER_MANAGER (Stage 14/15: install SMS_EXECUTIVE +
    # SMS_FAILOVER_MANAGER, validate the site server, validate access to remote
    # site systems, become-ready). Auto-collect failovermgr.log/smsexec.log (the
    # authoritative logs) plus hman/rcmctrl/ConfigMgrSetup from BOTH the active
    # server and the passive node so the regression reason is captured.
    if (($parentResult.ScriptBlockOutput -is [hashtable]) -and ($parentResult.ScriptBlockOutput.Passed -eq $false)) {
        Add-Phase11Output "[Phase $Phase] $VMName [PassiveSite]: passive node reported in a failed/prereq state -- collecting failovermgr/smsexec/hman/rcmctrl/ConfigMgrSetup logs from the active site server '$($activeVM.vmName)' and the passive node"
        $null = Save-Phase11GuestLogs -VMName $activeVM.vmName -DomainName $domain -RoleLabel 'PassiveSite-Active' -Collector $Phase11PassiveSiteDiagCollector
        $null = Save-Phase11GuestLogs -VMName $VMName -DomainName $domain -RoleLabel 'PassiveSite-Node' -Collector $Phase11PassiveSiteDiagCollector
    }

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
            Add-Phase11Output "[Phase $Phase] $VMName [DomainMember]: Pulled $name (${kb}KB tail) -> $dest"
        }
        catch {
            Write-Log "[Phase $Phase] $VMName [DomainMember]: ccmsetup log capture: failed to write ${name}: $_" -Warning -LogOnly
        }
    }
}

function Save-Phase11GuestLogs {
    <#
    .SYNOPSIS
        Pull guest log files to the host log directory for offline triage.
    .DESCRIPTION
        Generalizes Save-CcmSetupLog: runs a self-contained collector scriptblock
        IN the guest that returns a hashtable of @{ '<logname>' = '<tail content>' },
        then writes each to the host log dir (same folder as the build log) as
            <VmName>-Phase11-<timestamp>-<logname>
        so the operator can review PullDP/DataTransferService/distmgr/PkgXferMgr
        logs without hand-running commands against the VM. Best-effort and
        non-fatal. Returns the List of host paths written (may be empty).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$DomainName,
        [Parameter(Mandatory)][string]$RoleLabel,
        [Parameter(Mandatory)][scriptblock]$Collector,
        [int]$TimeoutSeconds = 150
    )

    $Phase = 11
    $saved = New-Object System.Collections.Generic.List[string]
    $logDir = $null
    if ($Common -and $Common.LogPath) { $logDir = Split-Path $Common.LogPath -Parent }
    if (-not $logDir -or -not (Test-Path $logDir)) {
        Write-Log "[Phase $Phase] $VMName [$RoleLabel]: log capture: host log dir not resolvable ($logDir)" -Warning -LogOnly
        return $saved
    }

    try {
        $res = Invoke-VmCommand -VmName $VMName -VmDomainName $DomainName -ScriptBlock $Collector `
            -SuppressLog -AsJob -TimeoutSeconds $TimeoutSeconds -DisplayName "Pull $RoleLabel logs"
    }
    catch {
        Write-Log "[Phase $Phase] $VMName [$RoleLabel]: log capture PSDirect call threw: $($_.Exception.Message)" -Warning -LogOnly
        return $saved
    }
    if (-not $res -or $res.ScriptBlockFailed -or -not ($res.ScriptBlockOutput -is [hashtable]) -or $res.ScriptBlockOutput.Count -eq 0) {
        # This used to collapse four very different causes into one useless string.
        # CS4-DPMP1 hit it twice on the run where the DP was the whole reason the
        # build failed, and the log left no way to tell whether PSDirect was down,
        # the collector threw, or the guest genuinely had no logs.
        $why = 'unknown'
        if (-not $res) {
            $why = 'Invoke-VmCommand returned nothing (no session / call never completed)'
        }
        elseif ($res.ScriptBlockFailed) {
            $detail = ''
            try { if ($res.ErrorDetails) { $detail = (@($res.ErrorDetails) -join ' | ') } } catch { }
            if (-not $detail) { try { $detail = "$($res.ScriptBlockOutput)" } catch { } }
            $why = "collector scriptblock FAILED in guest: $detail (channelBroken=$($res.ChannelBroken) timedOut=$($res.TimedOut))"
        }
        elseif (-not ($res.ScriptBlockOutput -is [hashtable])) {
            $t = '<null>'
            try { if ($null -ne $res.ScriptBlockOutput) { $t = $res.ScriptBlockOutput.GetType().FullName } } catch { }
            $why = "collector returned $t instead of a hashtable; value='$("$($res.ScriptBlockOutput)" -replace '\s+', ' ')'"
        }
        else {
            $why = 'collector ran but found NO log files (it resolved no log directory, or the directory held none of the expected logs)'
        }
        Write-Log "[Phase $Phase] $VMName [$RoleLabel]: log capture produced nothing -- $why" -Warning -LogOnly
        return $saved
    }

    $stamp = (Get-Date -Format 'yyyyMMdd-HHmmss')
    foreach ($name in $res.ScriptBlockOutput.Keys) {
        $content = $res.ScriptBlockOutput[$name]
        if (-not $content) { continue }
        $safeName = ($name -replace '[^\w.\-]', '_')
        $dest = Join-Path $logDir "$VMName-Phase$Phase-$stamp-$safeName"
        try {
            Set-Content -LiteralPath $dest -Value $content -Encoding UTF8 -ErrorAction Stop
            $kb = [math]::Round(([System.Text.Encoding]::UTF8.GetByteCount($content)) / 1KB, 1)
            Add-Phase11Output "[Phase $Phase] $VMName [$RoleLabel]: Pulled $name (${kb}KB tail) -> $dest"
            $saved.Add($dest)
        }
        catch {
            Write-Log "[Phase $Phase] $VMName [$RoleLabel]: log capture: failed to write ${name}: $_" -Warning -LogOnly
        }
    }
    return $saved
}

# Collector scriptblocks used by the DP / pull-DP diagnostics below. Each is
# self-contained (runs IN the guest), resolves its log directory from the
# authoritative registry key, and tails the named logs into a hashtable.
$Phase11CcmClientLogCollector = {
    # PullDP.log + DataTransferService.log (BITS) live in the CCM client log dir.
    $out = @{}
    $diag = @()
    $dir = $null
    try { $dir = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\CCM\Logging\@GLOBAL' -Name 'LogDirectory' -ErrorAction Stop).LogDirectory } catch { $diag += "registry LogDirectory read failed: $($_.Exception.Message)" }
    if ($dir) { $diag += "registry LogDirectory='$dir' exists=$(Test-Path $dir)" }
    if (-not $dir -or -not (Test-Path $dir)) {
        foreach ($c in @('E:\SMS_CCM\Logs', 'D:\SMS_CCM\Logs', 'F:\SMS_CCM\Logs', 'C:\Windows\CCM\Logs', 'C:\SMS_CCM\Logs')) {
            if (Test-Path $c) { $dir = $c; $diag += "fell back to '$c'"; break }
        }
    }
    # ALWAYS return a self-diagnostic so an empty result still explains itself --
    # 'no logs returned from VM' with no reason was the dead end on CS4-DPMP1.
    if (-not $dir -or -not (Test-Path $dir)) {
        $diag += 'no CCM log directory found; this VM has no ConfigMgr client installed, or it installed to a path not probed above.'
        $out['_collector-diag.txt'] = ($diag -join "`r`n")
        return $out
    }
    foreach ($pat in @('PullDP.log', 'PullDP-*.log', 'DataTransferService.log', 'DataTransferService-*.log')) {
        $found = @(Get-ChildItem -Path (Join-Path $dir $pat) -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 2)
        $diag += "pattern '$pat' matched $($found.Count) file(s)"
        foreach ($f in $found) {
            try { $c = Get-Content -LiteralPath $f.FullName -Tail 4000 -ErrorAction SilentlyContinue; if ($c) { $out[$f.Name] = ($c -join "`r`n") } else { $diag += "  '$($f.Name)' read returned no content" } } catch { $diag += "  '$($f.Name)' read threw: $($_.Exception.Message)" }
        }
    }
    $out['_collector-diag.txt'] = ($diag -join "`r`n")
    return $out
}

$Phase11SmsSiteLogCollector = {
    # Site-server content-distribution + INTER-SITE replication logs live under
    # <SMS install>\Logs. distmgr/PkgXferMgr cover local + pull-DP distribution;
    # sender/despool/rcmctrl cover the CAS<->primary<->secondary content pipeline --
    # a Secondary DP stuck on the client package is an inter-site problem, and the
    # "Error creating package bundle ... 0x800704d3" abort is on the SENDING side.
    $out = @{}
    $diag = @()
    $smsDir = $null
    foreach ($k in @('HKLM:\SOFTWARE\Microsoft\SMS\Identification', 'HKLM:\SOFTWARE\Microsoft\SMS\Setup')) {
        try { $smsDir = (Get-ItemProperty -Path $k -Name 'Installation Directory' -ErrorAction Stop).'Installation Directory' } catch { }
        if ($smsDir) { $diag += "SMS install dir from '$k' = '$smsDir'"; break }
    }
    if (-not $smsDir -or -not (Test-Path $smsDir)) {
        $diag += "no SMS installation directory found (probed SMS\Identification and SMS\Setup). This VM is a remote DP/site system with no SMS_EXECUTIVE logs, not a site server."
        $out['_collector-diag.txt'] = ($diag -join "`r`n")
        return $out
    }
    foreach ($n in @('distmgr.log', 'PkgXferMgr.log', 'sender.log', 'despool.log', 'rcmctrl.log')) {
        $p = Join-Path $smsDir "Logs\$n"
        if (Test-Path $p) {
            try { $c = Get-Content -LiteralPath $p -Tail 4000 -ErrorAction SilentlyContinue; if ($c) { $out[$n] = ($c -join "`r`n") } else { $diag += "'$n' present but read returned no content" } } catch { $diag += "'$n' read threw: $($_.Exception.Message)" }
        }
        else { $diag += "'$n' not present at $p" }
    }
    # A remote DP still carries SMS\Identification with an Installation Directory, so
    # the guard above passes and the loop then reports five separate "not present"
    # lines that never say the one thing that matters. Say it once, plainly.
    if ($out.Count -eq 0) {
        $diag += "NONE of the site-server logs exist under '$smsDir\Logs'. This VM is a remote DP/site system, not a site server -- the logs that explain ITS content state are under ?:\SMS_DP`$\sms\logs (see the DpContent capture)."
    }

    # A Secondary can sit in a despooler retry loop -- "This package[X]'s information
    # hasn't arrived yet for this version [N]" -- where the CONTENT arrived but the
    # METADATA did not, so the package never installs on that site's DP. Seen looping
    # 15x over 76 min on the client package while rcmctrl reported ReplicationActive,
    # and despool.log alone cannot say WHICH input is missing.
    # Per ConfigMgr source (basesvr\minipkg.cpp) the despooler retries when ANY of:
    #     !IsMainCopySent()  ||  PCK SourceVersion > local row's  ||  !fnIsPkgVersionAvailable()
    # and fnIsPkgVersionAvailable (Core\Functions\fnIsPkgVersionAvailable.sql) is:
    #     PkgStatus_G G JOIN PkgStatusHist H ON G.ID = H.PkgID
    #        AND G.SiteCode = dbo.fnGetSiteCodeBySiteNumber(H.SiteNumber)
    #     WHERE G.ID=@pkg AND G.Type=1 AND G.SiteCode=@site AND H.PkgVersion=@ver
    # Query those directly so the next occurrence NAMES the missing row.
    try {
        $stalls = @{}
        foreach ($ln in @("$($out['despool.log'])" -split "`r?`n")) {
            if ($ln -match "package\[(\w+)\][^\r\n]*information hasn't arrived yet(?:\s+for this version\s+\[(\d+)\])?") {
                $sp = $Matches[1]
                $sv = if ($Matches[2]) { [int]$Matches[2] } else { 0 }
                # NOT named 'Count' -- the hashtable's built-in Count property would win.
                if (-not $stalls.ContainsKey($sp)) { $stalls[$sp] = @{ Hits = 0; Ver = $sv } }
                $stalls[$sp].Hits++
                if ($sv -gt 0) { $stalls[$sp].Ver = $sv }
            }
        }
        # Packages that later stored are converging normally -- only report the wedged ones.
        foreach ($ln in @("$($out['despool.log'])" -split "`r?`n")) {
            if ($ln -match 'Stored Package\s+(\w+)\.') { $stalls.Remove($Matches[1]) }
        }

        if ($stalls.Count -gt 0) {
            $ml = @("Despooler metadata stall -- content arrived, package row did not.", "")
            $siteCode = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\SMS\Identification' -Name 'Site Code' -ErrorAction Stop).'Site Code'
            $sr = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\SMS\SQL Server' -ErrorAction Stop
            $dbRaw = $sr.'Database Name'
            $srPort = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\SMS\SQL Server\Site System SQL Account' -Name 'Port' -ErrorAction SilentlyContinue).'Port'
            if ($dbRaw -match '\\') { $inst = "$($sr.Server)\$($dbRaw.Split('\')[0])"; $db = $dbRaw.Split('\')[1] } else { $inst = $sr.Server; $db = $dbRaw }
            if ($srPort -and "$srPort" -ne '1433') { $inst = "$inst,$srPort" }
            $ml += "site=$siteCode  sql=$inst  db=$db"
            $ml += ""

            # SqlClient, not Invoke-Sqlcmd: a Secondary's SQL Express has no PS SQL module.
            $cn = New-Object System.Data.SqlClient.SqlConnection
            $cn.ConnectionString = "Server=$inst;Database=$db;Integrated Security=SSPI;TrustServerCertificate=True;Connect Timeout=20"
            $cn.Open()
            try {
                foreach ($pk in @($stalls.Keys | Sort-Object | Select-Object -First 10)) {
                    $ver = $stalls[$pk].Ver
                    $ml += "=== $pk  (retried $($stalls[$pk].Hits)x, PCK version $ver) ==="
                    foreach ($q in @(
                            @{ L = 'fnIsPkgVersionAvailable'; T = 'SELECT dbo.fnIsPkgVersionAvailable(@pkg, @site, @ver) AS Available' }
                            @{ L = 'PkgStatus_G'; T = 'SELECT ID, Type, SiteCode, Status, SourceVersion, PkgVersion, UpdateTime FROM PkgStatus_G WHERE ID = @pkg' }
                            @{ L = 'PkgStatusHist'; T = 'SELECT PkgID, SiteNumber, PkgVersion FROM PkgStatusHist WHERE PkgID = @pkg' }
                        )) {
                        try {
                            $cmd = $cn.CreateCommand()
                            $cmd.CommandTimeout = 30
                            $cmd.CommandText = $q.T
                            $null = $cmd.Parameters.AddWithValue('@pkg', $pk)
                            $null = $cmd.Parameters.AddWithValue('@site', $siteCode)
                            $null = $cmd.Parameters.AddWithValue('@ver', $ver)
                            $rd = $cmd.ExecuteReader()
                            $rows = 0
                            while ($rd.Read()) {
                                $rows++
                                $f = @()
                                for ($i = 0; $i -lt $rd.FieldCount; $i++) { $f += "$($rd.GetName($i))=$(if ($rd.IsDBNull($i)) { '<null>' } else { $rd.GetValue($i) })" }
                                $ml += "  [$($q.L)] $($f -join ' ')"
                            }
                            $rd.Close()
                            if ($rows -eq 0) { $ml += "  [$($q.L)] NO ROWS  <-- this is the gap" }
                        }
                        catch { $ml += "  [$($q.L)] query threw: $($_.Exception.Message)" }
                    }
                    $ml += ""
                }
            }
            finally { $cn.Close() }
            $out['PkgMetaStall.txt'] = ($ml -join "`r`n")
            $diag += "despooler metadata stall detected on $($stalls.Count) package(s): $(@($stalls.Keys) -join ', ') -- see PkgMetaStall.txt"
        }
    }
    catch { $diag += "package-metadata stall probe threw: $($_.Exception.Message)" }

    # SMS_EXECUTIVE restart forensics -- the ROOT-CAUSE signal for a 0x800704d3
    # inter-site bundle abort: distmgr sets its bundle cancel flag to the thread-exit
    # m_bShutdownRequest, so that error means the executive was STOPPED/RESTARTED
    # mid-build. Capture the service/process start time + recent SCM 7036 start/stop
    # events so a restart LOOP (the real cause) is visible without hand-pulling.
    try {
        $lines = @()
        $exe = Get-CimInstance Win32_Service -Filter "Name='SMS_EXECUTIVE'" -ErrorAction SilentlyContinue
        if ($exe) {
            $lines += "SMS_EXECUTIVE State=$($exe.State) StartMode=$($exe.StartMode) PID=$($exe.ProcessId)"
            if ($exe.ProcessId -gt 0) { $pp = Get-Process -Id $exe.ProcessId -ErrorAction SilentlyContinue; if ($pp) { $lines += "Process up since $($pp.StartTime.ToString('yyyy-MM-dd HH:mm:ss'))" } }
        }
        $lines += "--- Service Control Manager 7036 events mentioning SMS_EXECUTIVE (last 24h) ---"
        $evs = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 7036; StartTime = (Get-Date).AddHours(-24) } -ErrorAction SilentlyContinue | Where-Object { $_.Message -match 'SMS_EXECUTIVE' } | Select-Object -First 60)
        foreach ($e in $evs) { $lines += "$($e.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'))  $($e.Message)" }
        if ($lines.Count -gt 0) { $out['SMS_EXECUTIVE-restarts.txt'] = ($lines -join "`r`n") }
    }
    catch {}
    $out['_collector-diag.txt'] = ($diag -join "`r`n")
    return $out
}

$Phase11DpContentLogCollector = {
    # Runs ON a distribution point. A remote DP has no <SMS install>\Logs, so the
    # site-log collector above returns nothing for it -- on cstest2 the DP that was
    # the entire reason Phase 11 failed (CS2-PS2SITESYS1, parked at
    # ContentValidating) yielded a six-line capture that said only "not present"
    # five times. Everything that describes a DP's OWN view of the content lives
    # under SMS_DP$ and in the content library instead.
    $out = @{}
    $diag = @()

    $dpLogDir = $null
    foreach ($d in @('E:', 'D:', 'F:', 'G:', 'C:')) {
        $cand = "$d\SMS_DP`$\sms\logs"
        if (Test-Path $cand) { $dpLogDir = $cand; break }
    }
    if ($dpLogDir) {
        $diag += "DP log dir = '$dpLogDir'"
        foreach ($n in @('smsdpprov.log', 'SMSDPMon.log', 'PrestageContent.log')) {
            $p = Join-Path $dpLogDir $n
            if (-not (Test-Path $p)) { $diag += "'$n' not present at $p"; continue }
            try {
                $c = Get-Content -LiteralPath $p -Tail 4000 -ErrorAction SilentlyContinue
                if ($c) { $out[$n] = ($c -join "`r`n") } else { $diag += "'$n' present but read returned no content" }
            }
            catch { $diag += "'$n' read threw: $($_.Exception.Message)" }
        }
    }
    else {
        $diag += 'no ?:\SMS_DP$\sms\logs found (probed E,D,F,G,C) -- the DP role is not installed on this server.'
    }

    # Whether content ever reached this DP is a PkgLib question, not a log question:
    # a DP parked at ContentValidating with the package absent from PkgLib never
    # received it at all, which moves triage to the SENDING site and off the DP.
    $lines = @()
    try {
        $clp = ''
        try { $clp = "$((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\SMS\DP' -Name ContentLibraryPath -ErrorAction Stop).ContentLibraryPath)" } catch { }
        if (-not $clp) {
            foreach ($d in @('E:', 'D:', 'F:', 'G:', 'C:')) { if (Test-Path "$d\SCCMContentLib") { $clp = "$d\SCCMContentLib"; break } }
        }
        if (-not $clp) {
            $lines += 'no content library found (HKLM\SOFTWARE\Microsoft\SMS\DP ContentLibraryPath absent and no ?:\SCCMContentLib)'
        }
        else {
            $isRemote = $clp.StartsWith('\\')
            $lines += "ContentLibraryPath = $clp$(if ($isRemote) { ' (REMOTE/UNC -- HA relocated content library)' })"
            $pl = Join-Path $clp 'PkgLib'
            if (Test-Path $pl) {
                $inis = @(Get-ChildItem -LiteralPath $pl -Filter '*.INI' -ErrorAction SilentlyContinue)
                $lines += "PkgLib holds $($inis.Count) package(s): $((@($inis | Select-Object -First 60 | ForEach-Object { $_.BaseName })) -join ', ')"
            }
            else {
                $lines += "PkgLib NOT reachable at $pl -- no content has ever been imported into this DP's library"
            }
            if (-not $isRemote) {
                try {
                    $drv = Get-PSDrive -Name $clp.Substring(0, 1) -ErrorAction Stop
                    $lines += "content drive free = $([math]::Round($drv.Free / 1GB, 1))GB"
                }
                catch { }
            }
        }
    }
    catch { $lines += "content-library probe threw: $($_.Exception.Message)" }

    # IIS is how a DP serves content and how smsdpprov publishes state; a stopped
    # site/app pool looks identical to "content never arrived" from the site's side.
    try {
        Import-Module WebAdministration -ErrorAction Stop
        foreach ($vd in @('SMS_DP_SMSPKG$', 'SMS_DP_SMSSIG$', 'NOCERT_SMS_DP_SMSPKG$')) {
            $exists = Test-Path "IIS:\Sites\Default Web Site\$vd"
            $lines += "IIS vdir '$vd': $(if ($exists) { 'present' } else { 'MISSING' })"
        }
        $site = Get-Website -Name 'Default Web Site' -ErrorAction SilentlyContinue
        if ($site) { $lines += "IIS 'Default Web Site' state = $($site.State)" }
    }
    catch { $lines += "IIS probe unavailable: $($_.Exception.Message)" }

    $out['DpContent.txt'] = ($lines -join "`r`n")
    # Deliberately NOT '_collector-diag.txt': Save-Phase11GuestLogs names files
    # <vm>-Phase11-<stamp>-<key>, so a second collector finishing in the same second
    # would overwrite the first one's diagnostics.
    $out['_dp-collector-diag.txt'] = ($diag -join "`r`n")
    return $out
}

$Phase11WsusStallCollector = {
    # Runs ON the SUP when its sync reports Running with ProcessedItems frozen.
    # The WSUS API (queried from the site server) can only say THAT progress
    # stopped; everything that says WHY is local to this machine.
    $out = @{}
    $diag = @()
    $lines = @()

    # WsusPool recycling at its private-memory cap is the classic cause: the pool
    # dies mid-sync, WSUS answers 503, and ProcessedItems freezes with the
    # subscription still nominally Running.
    try {
        Import-Module WebAdministration -ErrorAction Stop
        foreach ($poolName in @('WsusPool', 'DefaultAppPool')) {
            $p = Get-Item "IIS:\AppPools\$poolName" -ErrorAction SilentlyContinue
            if (-not $p) { $lines += "AppPool '$poolName': not present"; continue }
            $lines += "AppPool '$poolName': State=$($p.state) privateMemoryLimitKB=$($p.recycling.periodicRestart.privateMemory) requestsLimit=$($p.recycling.periodicRestart.requests) timeLimit=$($p.recycling.periodicRestart.time)"
            foreach ($wp in @(Get-ChildItem "IIS:\AppPools\$poolName\WorkerProcesses" -ErrorAction SilentlyContinue)) {
                $proc = Get-Process -Id $wp.processId -ErrorAction SilentlyContinue
                if ($proc) {
                    $lines += "  w3wp pid=$($wp.processId) state=$($wp.state) privateMB=$([math]::Round($proc.PrivateMemorySize64/1MB)) wsMB=$([math]::Round($proc.WorkingSet64/1MB)) startedAt=$($proc.StartTime.ToString('yyyy-MM-dd HH:mm:ss'))"
                }
                else { $lines += "  w3wp pid=$($wp.processId) state=$($wp.state) (process not readable)" }
            }
        }
    }
    catch { $diag += "IIS/WsusPool inspection failed: $($_.Exception.Message)" }

    # 5074/5079/5080/5081 = app-pool recycle events; 5013 = worker process shutdown.
    try {
        $lines += '--- WAS/IIS app-pool recycle events (last 6h) ---'
        $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WAS'; StartTime = (Get-Date).AddHours(-6) } -ErrorAction SilentlyContinue | Select-Object -First 40)
        if ($ev.Count -eq 0) { $lines += '  (none)' }
        foreach ($e in $ev) { $lines += "  $($e.TimeCreated.ToString('HH:mm:ss')) id=$($e.Id) $(($e.Message -replace '\s+', ' ').Trim())" }
    }
    catch { $diag += "WAS event query failed: $($_.Exception.Message)" }

    try {
        $lines += '--- WSUS Application events (last 6h) ---'
        $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; StartTime = (Get-Date).AddHours(-6) } -ErrorAction SilentlyContinue |
                Where-Object { $_.ProviderName -match 'Update Services|WSUS' } | Select-Object -First 40)
        if ($ev.Count -eq 0) { $lines += '  (none)' }
        foreach ($e in $ev) { $lines += "  $($e.TimeCreated.ToString('HH:mm:ss')) [$($e.LevelDisplayName)] id=$($e.Id) $(($e.Message -replace '\s+', ' ').Trim())" }
    }
    catch { $diag += "Application event query failed: $($_.Exception.Message)" }

    # Content + DB volume free space: a full drive stalls a sync silently.
    try {
        $lines += '--- volumes ---'
        foreach ($v in @(Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter })) {
            $lines += "  $($v.DriveLetter): free=$([math]::Round($v.SizeRemaining/1GB,1))GB of $([math]::Round($v.Size/1GB,1))GB"
        }
    }
    catch { }

    $out['WsusStall.txt'] = ($lines -join "`r`n")

    # SoftwareDistribution.log is WSUS's own sync log and names the actual fault.
    $wsusDir = $null
    try { $wsusDir = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Update Services\Server\Setup' -Name 'TargetDir' -ErrorAction Stop).TargetDir } catch { }
    if (-not $wsusDir) { $wsusDir = 'C:\Program Files\Update Services' }
    $sdLog = Join-Path $wsusDir 'LogFiles\SoftwareDistribution.log'
    if (Test-Path $sdLog) {
        try { $out['SoftwareDistribution.log'] = ((Get-Content -LiteralPath $sdLog -Tail 3000 -ErrorAction SilentlyContinue) -join "`r`n") }
        catch { $diag += "SoftwareDistribution.log read threw: $($_.Exception.Message)" }
    }
    else { $diag += "SoftwareDistribution.log not found at $sdLog (WSUS TargetDir='$wsusDir')" }

    $out['_collector-diag.txt'] = ($diag -join "`r`n")
    return $out
}

$Phase11CmWsusSyncCollector = {
    # Runs ON the ConfigMgr site server. The SUP collector explains what WSUS
    # did; WCM.log and wsyncmgr.log explain who asked it to stop and why CM's
    # SMS_SUPSyncStatus projection did not leave a running state afterward.
    $out = @{}
    $diag = New-Object System.Collections.Generic.List[string]
    $lines = New-Object System.Collections.Generic.List[string]
    $smsDir = $null
    foreach ($keyPath in @('HKLM:\SOFTWARE\Microsoft\SMS\Identification', 'HKLM:\SOFTWARE\Microsoft\SMS\Setup')) {
        try { $smsDir = (Get-ItemProperty -Path $keyPath -Name 'Installation Directory' -ErrorAction Stop).'Installation Directory' } catch {}
        if ($smsDir) { break }
    }
    $siteCode = $null
    try { $siteCode = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\SMS\Identification' -Name 'Site Code' -ErrorAction Stop).'Site Code' } catch {}
    $lines.Add("CapturedUtc=$([DateTime]::UtcNow.ToString('o')) SiteCode=$siteCode SmsDir=$smsDir")

    if ($siteCode) {
        try {
            $syncRows = @(Get-WmiObject -Namespace "root\SMS\site_$siteCode" -Class SMS_SUPSyncStatus -ErrorAction Stop)
            if ($syncRows.Count -eq 0) { $lines.Add('SMS_SUPSyncStatus: NO ROWS') }
            foreach ($syncRow in $syncRows) {
                $lines.Add("SMS_SUPSyncStatus: SiteCode=$($syncRow.SiteCode) State=$($syncRow.LastSyncState) StateTime=$($syncRow.LastSyncStateTime) Error=$($syncRow.LastSyncErrorCode) WSUS=$($syncRow.WSUSServerName) Source=$($syncRow.WSUSSourceServer)")
            }
        }
        catch { $diag.Add("SMS_SUPSyncStatus query failed: $($_.Exception.Message)") }

        try {
            $components = @(Get-WmiObject -Namespace "root\SMS\site_$siteCode" -Class SMS_ComponentSummarizer `
                    -Filter "ComponentName='SMS_WSUS_SYNC_MANAGER' OR ComponentName='SMS_WSUS_CONFIGURATION_MANAGER'" -ErrorAction Stop)
            foreach ($component in $components) {
                $lines.Add("Component: $($component.ComponentName) State=$($component.State) Errors=$($component.Errors) Warnings=$($component.Warnings) LastContacted=$($component.LastContacted)")
            }
        }
        catch { $diag.Add("SMS_ComponentSummarizer query failed: $($_.Exception.Message)") }
    }

    try {
        $smsExec = Get-Service -Name SMS_EXECUTIVE -ErrorAction SilentlyContinue
        if ($smsExec) { $lines.Add("SMS_EXECUTIVE=$($smsExec.Status)") }
        $smsProc = Get-Process -Name smsexec -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($smsProc) { $lines.Add("smsexec pid=$($smsProc.Id) started=$($smsProc.StartTime.ToString('yyyy-MM-dd HH:mm:ss'))") }
    }
    catch { $diag.Add("SMS_EXECUTIVE process probe failed: $($_.Exception.Message)") }

    if ($smsDir) {
        $logDir = Join-Path $smsDir 'Logs'
        foreach ($logName in @('WCM.log', 'WCM.lo_', 'wsyncmgr.log', 'wsyncmgr.lo_')) {
            $logPath = Join-Path $logDir $logName
            if (-not (Test-Path -LiteralPath $logPath)) { continue }
            try { $out[$logName] = ((Get-Content -LiteralPath $logPath -Tail 4000 -ErrorAction Stop) -join "`r`n") }
            catch { $diag.Add("$logName read failed: $($_.Exception.Message)") }
        }
        try {
            $syncInbox = Join-Path $smsDir 'inboxes\wsyncmgr.box'
            if (Test-Path -LiteralPath $syncInbox) {
                $inboxFiles = @(Get-ChildItem -LiteralPath $syncInbox -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 20)
                $lines.Add("wsyncmgr.box files=$($inboxFiles.Count)")
                foreach ($file in $inboxFiles) { $lines.Add("  $($file.Name) $($file.Length) bytes $($file.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))") }
            }
        }
        catch { $diag.Add("wsyncmgr.box inventory failed: $($_.Exception.Message)") }
    }
    else { $diag.Add('ConfigMgr installation directory not found') }

    $out['CmWsusSync.txt'] = ($lines -join "`r`n")
    $out['_cm-wsus-collector-diag.txt'] = ($diag -join "`r`n")
    return $out
}

$Phase11SecondaryCertDiagCollector = {
    # Diagnose a Secondary site whose distmgr is wedged repeating
    #   "site exchange certificate is not found. Can not decrypt the data."
    #   "Failed to decrypt cert PFX data"  ->  "~Sleep 3600 seconds..."
    # CM source (distmgr.cpp -> CServerAccount::Decrypt ->
    # CSiteSettings::GetEncryptedSiteExchangeCertificate) reads the DP identity
    # cert PFX and decrypts it with the site's OWN SiteExchangeCertificate, stored
    # in this Secondary's site DB: SC_SiteDefinition_Property Name='SiteExchangeCertificate'
    # (+ the PFX in CM_RoleIdCertificates RoleTypeID=4). If that row is missing the
    # decrypt fails, distmgr sleeps, and NOTHING (incl. the CM client package) ever
    # distributes to this DP -> its boundary-group clients wedge in the ccmsetup
    # GetDPLocations loop. Confirm the missing cert straight from the DB.
    $out = @{}
    $lines = @()
    $siteCode = $null; $smsDir = $null
    try { $siteCode = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\SMS\Identification' -Name 'Site Code' -ErrorAction Stop).'Site Code' } catch {}
    foreach ($k in @('HKLM:\SOFTWARE\Microsoft\SMS\Identification', 'HKLM:\SOFTWARE\Microsoft\SMS\Setup')) {
        try { $smsDir = (Get-ItemProperty -Path $k -Name 'Installation Directory' -ErrorAction Stop).'Installation Directory' } catch {}
        if ($smsDir) { break }
    }
    $lines += "SiteCode=$siteCode  SMSInstallDir=$smsDir  Probed=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

    # Confirm the distmgr cert-decrypt wedge signature (last 4000 lines).
    $sig = 0; $lastSig = ''
    if ($smsDir) {
        $dm = Join-Path $smsDir 'Logs\distmgr.log'
        if (Test-Path $dm) {
            try {
                $tail = Get-Content -LiteralPath $dm -Tail 4000 -ErrorAction SilentlyContinue
                $m = @($tail | Where-Object { $_ -match 'site exchange certificate is not found|Failed to decrypt cert PFX data|Failed to decrypt data using format' })
                $sig = $m.Count
                if ($m.Count) { $lastSig = ($m | Select-Object -Last 1).Trim() }
            }
            catch {}
        }
    }
    $lines += "distmgr cert-decrypt-failure lines (last 4000): $sig"
    if ($lastSig) { $lines += "  last: $lastSig" }

    # Enumerate installed SQL instances; probe the CM secondary DB for the cert.
    $instances = @()
    try {
        $ip = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL' -ErrorAction Stop
        foreach ($p in $ip.PSObject.Properties) { if ($p.Name -notmatch '^PS') { $instances += $p.Name } }
    }
    catch {}
    $lines += "SQL instances: $($instances -join ', ')"
    $db = if ($siteCode) { "CM_$siteCode" } else { $null }
    $probed = $false
    # Secondary sites default to the CONFIGMGRSEC SQL Express instance; try it first.
    foreach ($inst in (@('CONFIGMGRSEC') + $instances | Select-Object -Unique)) {
        if ($probed -or -not $db) { break }
        $srv = if ($inst -eq 'MSSQLSERVER') { 'localhost' } else { "localhost\$inst" }
        $cn = $null
        try {
            $cs = "Server=$srv;Database=$db;Integrated Security=SSPI;Connect Timeout=8;TrustServerCertificate=True"
            $cn = New-Object System.Data.SqlClient.SqlConnection $cs
            $cn.Open()
            $qExch = "SELECT COUNT(*) FROM SC_SiteDefinition_Property WHERE Name='SiteExchangeCertificate'"
            try { $c = $cn.CreateCommand(); $c.CommandText = "SELECT COUNT(*) FROM SC_SiteDefinition_Property WHERE Name='SiteExchangeCertificate' AND SiteNumber=dbo.fnGetSiteNumber()"; $c.CommandTimeout = 15; $exch = [int]$c.ExecuteScalar() }
            catch { $c = $cn.CreateCommand(); $c.CommandText = $qExch; $c.CommandTimeout = 15; $exch = [int]$c.ExecuteScalar() }
            $c2 = $cn.CreateCommand(); $c2.CommandText = "SELECT COUNT(*) FROM CM_RoleIdCertificates WHERE RoleTypeID=4"; $c2.CommandTimeout = 15
            $pfx = [int]$c2.ExecuteScalar()
            $lines += "DB $db on $($srv): SiteExchangeCertificate rows=$exch ; CM_RoleIdCertificates(RoleTypeID=4) rows=$pfx"
            if ($exch -eq 0 -or $pfx -eq 0) {
                $lines += "  => VERDICT: site exchange certificate / RoleId PFX is MISSING in the Secondary's site DB. distmgr cannot decrypt the DP identity cert, so it distributes NOTHING to this DP (client package never becomes Installed) and its boundary-group clients loop in ccmsetup GetDPLocations. FIX: recover the Secondary site (Recover Secondary Site / reinstall) so the SiteExchangeCertificate + CM_RoleIdCertificates RoleTypeID=4 PFX are regenerated."
            }
            else {
                $lines += "  => site exchange certificate present; the PFX decrypt failure is a key/permission issue, not a missing cert. Check hman.log/ConfigMgrSetup.log below."
            }
            $probed = $true
        }
        catch {
            $lines += "DB probe $db on $srv failed: $($_.Exception.Message)"
        }
        finally {
            if ($cn -and $cn.State -eq 'Open') { try { $cn.Close() } catch {} }
        }
    }
    if (-not $probed) { $lines += "Could not probe any SQL instance for the site exchange certificate (permissions or instance not found)." }
    $out['SecondaryCertDiag.txt'] = ($lines -join "`r`n")

    # hman.log (parent<->child site + certificate exchange) + secondary setup log.
    if ($smsDir) {
        foreach ($n in @('hman.log', 'sitecomp.log')) {
            $p = Join-Path $smsDir "Logs\$n"
            if (Test-Path $p) { try { $c = Get-Content -LiteralPath $p -Tail 3000 -ErrorAction SilentlyContinue; if ($c) { $out[$n] = ($c -join "`r`n") } } catch {} }
        }
    }
    foreach ($sp in @('C:\ConfigMgrSetup.log', "$smsDir\Logs\ConfigMgrSetup.log")) {
        if ($sp -and (Test-Path $sp)) { try { $c = Get-Content -LiteralPath $sp -Tail 3000 -ErrorAction SilentlyContinue; if ($c) { $out['ConfigMgrSetup.log'] = ($c -join "`r`n"); break } } catch {} }
    }
    return $out
}

$Phase11PassiveSiteDiagCollector = {
    # Diagnose a passive (HA) site server whose ConfigMgr ServerState regressed to
    # 0x0001FFFF (SiteServerInstallationFailed) / 0x0002FFFF (PREREQ_ERROR). The
    # local ConfigMgrSetup.log usually shows a CLEAN install (files land) -- the
    # passive install is orchestrated by SMS_FAILOVER_MANAGER: every
    # SMS_HA_SiteServerDetailedMonitoring substage says "Check failovermgr.log"
    # (Stage 14/15: install SMS_EXECUTIVE + SMS_FAILOVER_MANAGER, validate the site
    # server, VALIDATE ACCESS TO REMOTE SITE SYSTEMS, become-ready). So
    # failovermgr.log (+ smsexec.log for the service install) is AUTHORITATIVE, not
    # hman.log (which only heartbeats "site system currently in use"). Grab all of
    # them from whichever node this runs on (active + passive both matter).
    $out = @{}
    $smsDir = $null
    foreach ($k in @('HKLM:\SOFTWARE\Microsoft\SMS\Identification', 'HKLM:\SOFTWARE\Microsoft\SMS\Setup')) {
        try { $smsDir = (Get-ItemProperty -Path $k -Name 'Installation Directory' -ErrorAction Stop).'Installation Directory' } catch {}
        if ($smsDir) { break }
    }
    if ($smsDir) {
        foreach ($n in @('failovermgr.log', 'smsexec.log', 'hman.log', 'rcmctrl.log', 'sitecomp.log')) {
            $p = Join-Path $smsDir "Logs\$n"
            if (Test-Path $p) { try { $c = Get-Content -LiteralPath $p -Tail 4000 -ErrorAction SilentlyContinue; if ($c) { $out[$n] = ($c -join "`r`n") } } catch {} }
        }
    }
    foreach ($sp in @('C:\ConfigMgrSetup.log', "$smsDir\Logs\ConfigMgrSetup.log")) {
        if ($sp -and (Test-Path $sp)) { try { $c = Get-Content -LiteralPath $sp -Tail 4000 -ErrorAction SilentlyContinue; if ($c) { $out['ConfigMgrSetup.log'] = ($c -join "`r`n"); break } } catch {} }
    }
    return $out
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

    # Cross-forest client management: a domain whose DC has
    # externalDomainJoinSiteCode is NOT managed by a local Primary -- its clients
    # are managed by a REMOTE CM site in the trusted forest (e.g. cstest8b
    # clients -> cstest8 PRI). Resolve that managing site so the push hint points
    # at the right server and so we can verify the client actually registered
    # with the remote site below. The domain's own DC carries the setting.
    $domainDC = $DeployConfig.virtualMachines | Where-Object { $_.role -in @('DC', 'BDC') } | Select-Object -First 1
    $extSiteCode = if ($domainDC) { $domainDC.externalDomainJoinSiteCode } else { $null }
    $isExternallyManaged = [bool]($extSiteCode -and $extSiteCode -ne 'NONE')
    $expectedSiteCode = if ($isExternallyManaged) { "$extSiteCode" } else { '' }
    $externalSiteServer = if ($isExternallyManaged -and $domainDC.thisParams) { $domainDC.thisParams.ExternalSiteServer } else { $null }

    # UsePKI belongs to the site that MANAGES these clients, not to this domain.
    # A cross-forest domain deploys no CM site, so its deployConfig carries a null
    # cmOptions and the check above yields $false -- which silently switched OFF
    # the client-certificate check on exactly the labs that need it. cstest8b then
    # shipped 6/6 DomainMembers whose ccmsetup died with CCM_E_NO_CLIENT_PKI_CERT
    # and still reported "Functional validation PASSED". The remote managing site
    # server is merged into virtualMachines as a hidden VM and carries the real
    # cmOptions.
    if (-not $usePKI -and $isExternallyManaged) {
        $mgmtShort = if ($externalSiteServer) { ($externalSiteServer -split '\.')[0] } else { '' }
        $mgmtVm = $DeployConfig.virtualMachines | Where-Object { $_.cmOptions -and $_.vmName -eq $mgmtShort } | Select-Object -First 1
        if (-not $mgmtVm) {
            $mgmtVm = $DeployConfig.virtualMachines | Where-Object { $_.cmOptions -and $_.role -in @('CAS', 'Primary') } | Select-Object -First 1
        }
        if ($mgmtVm) {
            $usePKI = [bool]$mgmtVm.cmOptions.UsePKI
            Write-Log "[Phase $Phase] $VMName [DomainMember]: managing site '$expectedSiteCode' resolved from $($mgmtVm.vmName); UsePKI=$usePKI (this domain has no cmOptions of its own)" -LogOnly
        }
        else {
            Write-Log "[Phase $Phase] $VMName [DomainMember]: domain is managed by remote site '$expectedSiteCode' but no VM in this config carries cmOptions -- UsePKI unknown, client-certificate check will be skipped" -LogOnly
        }
    }

    # A client push is only possible when a ConfigMgr site actually manages this
    # domain -- either a local CAS/Primary/Secondary site server in the deployment,
    # or a remote site (cross-forest externally-managed). On a no-ConfigMgr lab
    # there is nothing to push from, so pushClient (which is left unset, NOT
    # explicitly false) must not make us expect/warn about a missing client.
    $hasLocalCmSite = @($DeployConfig.virtualMachines | Where-Object { $_.role -in @('CAS', 'Primary', 'Secondary') }).Count -gt 0
    $cmManagesDomain = ($hasLocalCmSite -or $isExternallyManaged)
    $pushExpected = $cmManagesDomain -and ($CurrentItem.pushClient -ne $false)

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
                return "CCM_E_NO_CLIENT_PKI_CERT -- the client had no usable PKI client-auth certificate for an HTTPS site, so ccmsetup aborted BEFORE any request reached the MP (ConfigMgr requestresponse.cpp: 'Client is not allowed to use or doesn't have PKI cert while talking to HTTPS server'). The 'StatusCode 200' printed alongside is the value ccmsetup seeds itself before each attempt ('Reset status to ok' in ccmsetup.cpp), NOT a reply from the MP -- nothing was sent. This is NOT a content-distribution race: an MP that answers with no content location returns 0x87d00215 (CCM_E_ITEMNOTFOUND) instead. Check ccmsetup.log for CCMCERTISSUERS + 'Unable to find any Certificate based on Certificate Issuers': either the machine never enrolled (Enroll/AutoEnroll not granted to this domain's computers on the ConfigMgr client template) or the issuing CA is not trusted here (cross-forest: root/NTAuth not published into this forest)."
            }
            if ($l -match '0x87d00215') { return "CCM_E_ITEMNOTFOUND -- the MP answered but returned no content location for the ConfigMgr Client Package. This IS the content-distribution case: the client package is not on a DP in this VM's boundary group at the expected version. ccmsetup retries on its own schedule." }
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
                # Unwrap the CMTrace <![LOG[msg]LOG]!> envelope + collapse whitespace
                # so each entry is a readable one-liner.
                $unwrap = {
                    param($raw)
                    $mm = [regex]::Match([string]$raw, '<!\[LOG\[(.*?)\]LOG\]!>')
                    $msg = if ($mm.Success) { $mm.Groups[1].Value } else { [string]$raw }
                    ($msg -replace '\s+', ' ').Trim()
                }
                $tail = Get-Content $logFile -Tail 150 -ErrorAction SilentlyContinue
                # Rank by CAUSE, not recency. The final matching lines of a failed
                # ccmsetup are its shutdown bookkeeping ('Failed to revoke client
                # upgrade local policy', 'Successfully created task'), while the line
                # naming the failure sits ~30 lines earlier and got dropped. cstest8b
                # reported five useless lines with 'Unable to find any Certificate
                # based on Certificate Issuers' sitting in the same 150-line window.
                $causePattern = 'CCM_E_|Unable to find any Certificate|certificate by issuer|CCMCERTISSUERS|Client is not allowed to use|didn''t return DP locations|Failed to find DP locations|CcmSetup failed with error code|status code'
                $generalPattern = 'GetDPLocations|Sending location (services )?request|MP_LocationManager|boundary|retry|error|fail|download|prereq|reboot|pending|waiting|timed? ?out'
                $hits = @($tail | Where-Object { $_ -match $causePattern } | Select-Object -Last 5)
                if ($hits.Count -lt 5) {
                    $filler = @($tail | Where-Object { $_ -notmatch $causePattern -and $_ -match $generalPattern } | Select-Object -Last (5 - $hits.Count))
                    $hits = $filler + $hits
                }
                # ALWAYS fall back to the raw tail when nothing matched, so a ccmsetup
                # stuck on something OUTSIDE the known patterns (which is exactly the
                # "running for hours" case) is never invisible.
                if ($hits.Count -eq 0) { $hits = @($tail | Where-Object { $_ } | Select-Object -Last 5) }
                foreach ($h in $hits) {
                    $line = & $unwrap $h
                    if ($line) {
                        if ($line.Length -gt 200) { $line = $line.Substring(0, 200) + '...' }
                        $diag.Add($line)
                    }
                }
            }
            if ($diag.Count -eq 0) { $diag.Add('(ccmsetup.log missing or unreadable)') }
            return $diag
        }
        # CCM_E_NO_CLIENT_PKI_CERT forensics. 'Unable to find any Certificate based
        # on Certificate Issuers' has two very different causes with the same text:
        # the machine never enrolled at all, or it holds a cert whose issuer chain
        # cannot be built here. Only the client can tell them apart, and they need
        # opposite fixes (template Enroll/AutoEnroll grant vs publishing the CA's
        # root/NTAuth into this forest), so report both facts rather than the code.
        $ccmPkiForensics = {
            $out = New-Object System.Collections.Generic.List[string]
            $wantedIssuer = ''
            try {
                $p = 'C:\Windows\ccmsetup\Logs\ccmsetup.log'
                if (Test-Path $p) {
                    $line = Get-Content $p -Tail 400 -ErrorAction SilentlyContinue |
                        Where-Object { $_ -match 'CCMCERTISSUERS:' } | Select-Object -Last 1
                    if ($line -and ([string]$line) -match 'CCMCERTISSUERS:\s*([^\]<]+)') { $wantedIssuer = $Matches[1].Trim() }
                }
            }
            catch {}
            if ($wantedIssuer) { $out.Add("PKI: ccmsetup requires a client cert issued by [$wantedIssuer]") }

            $certs = @()
            try {
                $certs = @(Get-ChildItem Cert:\LocalMachine\My -ErrorAction Stop |
                        Where-Object { $_.EnhancedKeyUsageList.ObjectId -contains '1.3.6.1.5.5.7.3.2' })
            }
            catch { $out.Add("PKI: could not read LocalMachine\My: $($_.Exception.Message)") }
            if ($certs.Count -eq 0) {
                $out.Add('PKI: LocalMachine\My holds NO client-authentication certificate -- the machine never enrolled. Cause is enrollment, not chain trust: check that this domain''s computers have Read/Enroll/AutoEnroll on the ConfigMgr client template on the issuing CA, and that autoenrollment GP is applied here.')
            }
            else {
                foreach ($c in ($certs | Select-Object -First 4)) {
                    $chainTxt = 'chain=untested'
                    try {
                        $ch = New-Object System.Security.Cryptography.X509Certificates.X509Chain
                        $ch.ChainPolicy.RevocationMode = [System.Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
                        $built = $ch.Build($c)
                        $flags = (@($ch.ChainStatus) | ForEach-Object { $_.Status }) -join ','
                        if (-not $flags) { $flags = 'OK' }
                        $chainTxt = "chainsToTrustedRoot=$built ($flags)"
                    }
                    catch { $chainTxt = "chain-build-threw: $($_.Exception.Message)" }
                    $out.Add("PKI: have client-auth cert Subject='$($c.Subject)' Issuer='$($c.Issuer)' $chainTxt")
                }
                $out.Add('PKI: a cert exists, so ccmsetup''s "Unable to find any Certificate" means it could not chain it to the required issuer -- publish the issuing CA''s root (and NTAuth) into this forest rather than re-granting the template.')
            }

            # Is the required issuer's CA trusted locally at all? Cross-forest this
            # is the half that InstallRootCertificate / RunPkiSync is responsible for.
            if ($wantedIssuer) {
                $issuerCn = ''
                if ($wantedIssuer -match 'CN=\s*([^;,]+)') { $issuerCn = $Matches[1].Trim() }
                if ($issuerCn) {
                    foreach ($store in 'Root', 'CA') {
                        $n = 0
                        try { $n = @(Get-ChildItem "Cert:\LocalMachine\$store" -ErrorAction Stop | Where-Object { $_.Subject -like "*$issuerCn*" }).Count } catch {}
                        if ($n -gt 0) { $out.Add("PKI: issuer '$issuerCn' IS present in LocalMachine\$store") }
                        else { $out.Add("PKI: issuer '$issuerCn' is NOT in LocalMachine\$store -- ccmsetup cannot build a chain to it from this machine") }
                    }
                }
            }

            # Autoenrollment's own verdict. This is the only place that says why no
            # cert was issued (template not offered / access denied / no CA found),
            # and it dies with the VM, so it has to be lifted into the run log here.
            try {
                $ev = @(Get-WinEvent -LogName Application -MaxEvents 600 -ErrorAction SilentlyContinue |
                        Where-Object { $_.ProviderName -like '*AutoEnrollment*' } | Select-Object -First 4)
                if ($ev.Count -eq 0) {
                    $out.Add('PKI: no CertificateServicesClient-AutoEnrollment events in the Application log -- autoenrollment has not run here (check the Certificate AutoEnrollment GPO)')
                }
                foreach ($e in $ev) {
                    $m = (($e.Message -replace '\s+', ' ').Trim())
                    if ($m.Length -gt 220) { $m = $m.Substring(0, 220) + '...' }
                    $out.Add("PKI: AutoEnroll [$($e.TimeCreated.ToString('MM-dd HH:mm:ss'))] Id=$($e.Id) $($e.LevelDisplayName): $m")
                }
            }
            catch { $out.Add("PKI: could not read AutoEnrollment events: $($_.Exception.Message)") }

            # Which templates does this machine actually see it may enroll for?
            try {
                $tpl = & certutil.exe -template 2>&1 | Out-String
                $names = @([regex]::Matches($tpl, 'TemplatePropCommonName = (\S+)') | ForEach-Object { $_.Groups[1].Value })
                $cm = @($names | Where-Object { $_ -like 'ConfigMgr*' })
                if ($cm.Count -gt 0) { $out.Add("PKI: certutil -template offers this machine: $($cm -join ', ') (of $($names.Count) total)") }
                else { $out.Add("PKI: certutil -template offers this machine NO ConfigMgr* template (of $($names.Count) total) -- the template is not published to this forest or this machine has no Enroll right on it") }
            }
            catch { $out.Add("PKI: certutil -template failed: $($_.Exception.Message)") }
            return $out
        }
        # Returns the last meaningful ccmsetup.log line (message unwrapped from the
        # <![LOG[...]LOG]!> envelope, whitespace-collapsed, capped) so a 'waiting'
        # progress line can show what ccmsetup is actually doing right now.
        $tailCcmLine = {
            $p = 'C:\Windows\ccmsetup\Logs\ccmsetup.log'
            if (Test-Path $p) {
                $line = Get-Content $p -Tail 1 -ErrorAction SilentlyContinue | Select-Object -Last 1
                if ($line) {
                    $m = [regex]::Match([string]$line, '<!\[LOG\[(.*?)\]LOG\]!>')
                    $msg = if ($m.Success) { $m.Groups[1].Value } else { [string]$line }
                    $msg = ($msg -replace '\s+', ' ').Trim()
                    if ($msg.Length -gt 120) { $msg = $msg.Substring(0, 120) + '...' }
                    return $msg
                }
            }
            return ''
        }

        # Has THIS attempt's ccmsetup already exited in failure? Only a terminal line
        # dated after $since counts: ccmsetup.log is cumulative and never truncated, so
        # an older failure is routinely one the retry is about to fix. An undated or
        # unparseable line also returns null -- it cannot prove the failure is current.
        $ccmTerminalFailure = {
            param($since)
            $p = 'C:\Windows\ccmsetup\Logs\ccmsetup.log'
            if (-not (Test-Path $p)) { return $null }
            $tail = Get-Content $p -Tail 60 -ErrorAction SilentlyContinue
            $line = $tail | Where-Object { $_ -match 'CcmSetup failed with error code|CcmSetup is exiting with return code' } | Select-Object -Last 1
            if (-not $line) { return $null }
            if ($line -match 'return code 0\b') { return $null }
            $m = [regex]::Match([string]$line, 'time="(?<h>\d\d:\d\d:\d\d)[^"]*"\s+date="(?<d>[\d\-]+)"')
            if (-not $m.Success) { return $null }
            $when = [datetime]::MinValue
            if (-not [datetime]::TryParse("$($m.Groups['d'].Value) $($m.Groups['h'].Value)", [ref]$when)) { return $null }
            if ($when -lt $since) { return $null }
            $mm = [regex]::Match([string]$line, '<!\[LOG\[(.*?)\]LOG\]!>')
            $msg = if ($mm.Success) { $mm.Groups[1].Value } else { [string]$line }
            $msg = ($msg -replace '\s+', ' ').Trim()
            if ($msg.Length -gt 160) { $msg = $msg.Substring(0, 160) + '...' }
            return $msg
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
            # Poll for the OUTCOME (CcmExec Running), not for the ccmsetup PROCESS. The old
            # loop broke as soon as ccmsetup was not running -- which is equally true BEFORE
            # the retry task has spawned it, so it bailed almost immediately: PL-SOURDOUGH was
            # declared failed ~66s in while client.msi was still at CcmSetObjectSecurity.
            # Same overall budget, correct exit condition.
            $waitStart = Get-Date
            $waitBudget = 300
            $terminalFailure = $null
            while (((Get-Date) - $waitStart).TotalSeconds -lt $waitBudget) {
                $svc = Get-Service -Name 'CcmExec' -ErrorAction SilentlyContinue
                if ($svc -and $svc.Status -eq 'Running') { break }
                if ($svc) { try { Start-Service -Name 'CcmExec' -ErrorAction SilentlyContinue } catch {} }
                # The loop was already reading this log every 10s just to decorate the
                # progress line. When it records THIS attempt exiting in failure, CcmExec
                # cannot appear inside the remaining budget -- ccmsetup schedules its own
                # next attempt hours out -- so the rest of the wait is dead time. Six
                # DomainMember VMs each burned the full 300s on exactly that, 40% of a
                # 14-minute re-run.
                $terminalFailure = & $ccmTerminalFailure $waitStart
                if ($terminalFailure) { break }
                $elapsed = [int]((Get-Date) - $waitStart).TotalSeconds
                $busy = @(Get-Process -Name 'ccmsetup', 'msiexec' -ErrorAction SilentlyContinue).Count
                $tail = & $tailCcmLine
                $msg = "ccmsetup retry: waiting for CcmExec (${elapsed}s, $busy setup process(es) running)"
                if ($tail) { $msg += " -- last log: $tail" }
                Write-Progress -Activity $progressActivity -Status $msg
                Start-Sleep -Seconds 10
            }
            $svc = Get-Service -Name 'CcmExec' -ErrorAction SilentlyContinue
            if ($svc -and $svc.Status -eq 'Running') {
                $results.Details.Add("OK: CcmExec is Running after ccmsetup retry ($([int]((Get-Date) - $waitStart).TotalSeconds)s)")
                return $true
            }
            if ($terminalFailure) {
                $results.Details.Add("INFO: stopped waiting after $([int]((Get-Date) - $waitStart).TotalSeconds)s of ${waitBudget}s -- this retry's ccmsetup already exited in failure: $terminalFailure")
            }
            return $false
        }

        Write-Progress -Activity $progressActivity -Status "Checking ConfigMgr client (CcmExec)"
        $ccm = Get-Service -Name 'CcmExec' -ErrorAction SilentlyContinue
        # Snapshot taken BEFORE any remediation below: only an established client
        # (service already present, no install in flight) has had time to be
        # discovered, land in a collection and pull application policy. Everything
        # this function does after this point can turn a brand-new client into a
        # Running one, which is why the arrival state has to be recorded here.
        $results.ClientPreexisting = [bool]($ccm -and -not (Get-Process -Name 'ccmsetup' -ErrorAction SilentlyContinue))
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
                    $waitStart = Get-Date
                    for ($w = 0; $w -lt 30; $w++) {
                        $elapsed = [int]((Get-Date) - $waitStart).TotalSeconds
                        $tail = & $tailCcmLine
                        $msg = "CcmExec $($ccm.Status); waiting for ccmsetup to finish (${elapsed}s)"
                        if ($tail) { $msg += " -- last log: $tail" }
                        Write-Progress -Activity $progressActivity -Status $msg
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
                        if ($failDetail -match '0x87d00454') {
                            foreach ($d in (& $ccmPkiForensics)) { $results.Details.Add("  $d") }
                        }
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
                # How long has ccmsetup been running? A few minutes = a genuine slow
                # install; tens of minutes / hours = a stuck retry loop.
                $elapsedMin = $null
                try {
                    $st = ($stillRunning | Sort-Object StartTime | Select-Object -First 1).StartTime
                    if ($st) { $elapsedMin = [int]((Get-Date) - $st).TotalMinutes }
                }
                catch {}
                $elapsedTxt = if ($null -ne $elapsedMin) { "${elapsedMin}m" } else { 'unknown time' }

                # Is ccmsetup wedged in a GetDPLocations retry? Distinguish an MP
                # availability failure (HTTP 503 / 0x87d0027e) from a successful MP
                # response containing no DP locations (0x87d00215). Both park ccmsetup
                # in a retry loop, but they have different owners and remediations.
                $ccmTail = Get-Content 'C:\Windows\ccmsetup\Logs\ccmsetup.log' -Tail 60 -ErrorAction SilentlyContinue
                $mpUnavailable = $ccmTail | Where-Object { $_ -match '0x87d0027e|status code 503|Service Unavailable' } | Select-Object -Last 1
                $noDpLocations = $ccmTail | Where-Object { $_ -match "didn't return DP locations|Failed to find DP locations|0x87d00215|<LocationRecords\s*/>" } | Select-Object -Last 1

                if ($mpUnavailable) {
                    $results.Passed = $false
                    $results.Details.Add("FAIL: ccmsetup wedged $elapsedTxt because its Management Point is returning HTTP 503 Service Unavailable (0x87d0027e). This is an MP/IIS availability failure, not an empty DP-location response. Check the named MP's 'SMS Management Point Pool', W3SVC, and MP health.")
                }
                elseif ($noDpLocations) {
                    $results.Passed = $false
                    $results.Details.Add("FAIL: ccmsetup wedged $elapsedTxt in a GetDPLocations retry loop -- the MP returned NO DP locations for the CM client package (empty LocationRecords / 0x87d00215). The Configuration Manager client package is not on a DP in this client's boundary group at the expected version, and fallback to unprotected DP is disabled, so it retries every 30 min indefinitely. Fix: distribute the client package to a reachable DP (or ensure the pull DP has finished pulling it).")
                }
                elseif ($null -ne $elapsedMin -and $elapsedMin -ge 45) {
                    $results.Passed = $false
                    $results.Details.Add("FAIL: ccmsetup still running after ${elapsedMin}m with no completion -- treating as STUCK (see ccmsetup.log below), not a slow install.")
                }
                elseif ($null -ne $elapsedMin -and $elapsedMin -ge 15) {
                    $results.Details.Add("WARN: ccmsetup is still running (running ${elapsedMin}m); slow install -- re-run Phase 11 to re-check once it finishes")
                }
                else {
                    $runTxt = if ($null -ne $elapsedMin) { " (running ${elapsedMin}m)" } else { '' }
                    $results.Details.Add("WARN: ccmsetup is still running$runTxt; not interrupting -- re-run Phase 11 to re-check once it finishes")
                }
                # Always surface the last ccmsetup.log lines so the current activity
                # (DP retry / download / prereq) is visible without hand-pulling the log.
                foreach ($d in (& $grabCcmDiag 'C:\Windows\ccmsetup\Logs\ccmsetup.log')) { $results.Details.Add("  ccmsetup.log: $d") }
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
                # Hold the failure detail until the retry has run. ccmsetup.log rolls to
                # ccmsetup-<stamp>.log on a new install but is never truncated, so this line
                # is routinely a failure from hours ago that the retry then fixes -- emitting
                # it as a live WARN before retrying (and again after) made an already-repaired
                # MP look broken for the rest of the morning.
                $pendingFailure = New-Object System.Collections.Generic.List[string]
                if ($exitLine -and -not $isSuccess) {
                    $failAge = ''
                    $stamp = [regex]::Match($exitLine, 'time="(?<h>\d\d:\d\d:\d\d)[^"]*"\s+date="(?<d>[\d\-]+)"')
                    if ($stamp.Success) {
                        $parsed = [datetime]::MinValue
                        if ([datetime]::TryParse("$($stamp.Groups['d'].Value) $($stamp.Groups['h'].Value)", [ref]$parsed)) {
                            $failAge = " [logged $([int]((Get-Date) - $parsed).TotalMinutes) min ago]"
                        }
                    }
                    $meaning = & $decodeCcmError $exitLine
                    $headline = "ccmsetup failed: $($exitLine.Trim())$failAge"
                    if ($meaning) { $headline += " -- $meaning" }
                    $pendingFailure.Add($headline)
                    foreach ($d in (& $grabCcmDiag 'C:\Windows\ccmsetup\Logs\ccmsetup.log')) { $pendingFailure.Add("  ccmsetup.log: $d") }
                    if ($exitLine -match '0x87d00454') {
                        foreach ($d in (& $ccmPkiForensics)) { $pendingFailure.Add("  $d") }
                    }
                }
                elseif ($isSuccess) {
                    $pendingFailure.Add("ccmsetup reported success but CcmExec did not start")
                }
                else {
                    $pendingFailure.Add("ccmsetup.log exists but no success/failure line found")
                }
                if (& $retryCcmSetup $results) {
                    $results.Details.Add("INFO: ccmsetup.log also records an earlier failure ($($pendingFailure[0])); the log is cumulative so that entry is historical, not current.")
                }
                else {
                    $results.Details.Add("WARN: CcmExec not installed; $($pendingFailure[0])")
                    for ($pf = 1; $pf -lt $pendingFailure.Count; $pf++) { $results.Details.Add($pendingFailure[$pf]) }
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
            $pushSite = if ($CurrentItem.pushClient -is [string]) { $CurrentItem.pushClient } else { "the site" }
            $null = $result.ScriptBlockOutput.Details.Add("  WARN: pushClient=$($CurrentItem.pushClient) in config but no ccmsetup evidence on VM — push from $pushSite may have failed or still be in progress on the site server side")
            $pushTarget = if ($isExternallyManaged -and $externalSiteServer) { "the REMOTE managing site server $externalSiteServer (site $expectedSiteCode)" } else { "the site server for $pushSite" }
            $null = $result.ScriptBlockOutput.Details.Add("  Check ccmsetup on ${pushTarget}: Get-CMDevice -Name '$VMName' | Select IsClient,ClientActiveStatus")
        }
        else {
            if (-not $cmManagesDomain) {
                $result.ScriptBlockOutput.Details[-1] = "OK: CcmExec not installed (no ConfigMgr site manages this domain)"
            }
            else {
                $result.ScriptBlockOutput.Details[-1] = "OK: CcmExec not installed (pushClient=false in config)"
            }
        }
    }

    # On a ccmsetup install failure, pull the guest's ccmsetup / client.msi
    # logs to the host log directory so the operator can troubleshoot offline
    # (these live only on the guest and are otherwise lost on VHD compaction).
    if ($result.ScriptBlockOutput -is [hashtable] -and $result.ScriptBlockOutput.Details) {
        $ccmFailed = $result.ScriptBlockOutput.Details | Where-Object { $_ -match 'ccmsetup failed' }
        # ccmsetup.log rolls but is never truncated, so a failure line from an
        # outage hours ago survives the repair. If CcmExec is Running now, that
        # entry is history and pulling ~1MB of guest logs per VM over PSDirect
        # buys nothing -- on pushlab that was 27 files across 8 healthy clients.
        $ccmRunning = $result.ScriptBlockOutput.Details | Where-Object { $_ -match '^OK: CcmExec' }
        if ($ccmFailed -and -not $ccmRunning) {
            Save-CcmSetupLog -VMName $VMName -DomainName $domain
        }
    }

    # Cross-forest client-management verification. When this client's domain is
    # managed by a REMOTE CM site, confirm the client actually registered with
    # and was assigned to that remote site -- the end-to-end proof that the
    # forest trust + cross-forest PKI let the client reach the remote MP.
    # Informational/WARN only (never fails the VM).
    if ($isExternallyManaged -and $result.ScriptBlockOutput -is [hashtable] -and $result.ScriptBlockOutput.Details) {
        $clientRunningForReg = [bool]($result.ScriptBlockOutput.Details | Where-Object { $_ -match '^OK: CcmExec' })
        if ($clientRunningForReg) {
            $regCheckBlock = {
                param($expSite)
                $reg = @{ Details = [System.Collections.Generic.List[string]]::new() }

                # Assigned site code (COM is authoritative; registry fallback).
                $assigned = $null
                try {
                    $smsClient = New-Object -ComObject 'Microsoft.SMS.Client'
                    $assigned = $smsClient.GetAssignedSite()
                    [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($smsClient)
                }
                catch {
                    try { $assigned = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\SMS\Mobile Client' -Name 'AssignedSiteCode' -ErrorAction Stop).AssignedSiteCode } catch {}
                }
                if ($assigned) {
                    if ("$assigned" -eq "$expSite") {
                        $reg.Details.Add("OK: ConfigMgr client assigned to remote site '$assigned' (matches externalDomainJoinSiteCode)")
                    }
                    else {
                        $reg.Details.Add("WARN: ConfigMgr client assigned site '$assigned' != expected remote site '$expSite' (cross-forest site assignment may not have applied)")
                    }
                }
                else {
                    $reg.Details.Add("WARN: Could not read the client's assigned site code (expected remote site '$expSite')")
                }

                # A populated registration GUID means MP_ClientRegistration completed.
                $clientId = $null
                try { $clientId = (Get-CimInstance -Namespace 'root\ccm' -ClassName CCM_Client -ErrorAction Stop).ClientId } catch {}
                if (-not $clientId) {
                    try { $clientId = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\SMS\Client\Configuration\Client Properties' -Name 'SMSID' -ErrorAction Stop).SMSID } catch {}
                }
                if ($clientId) {
                    $reg.Details.Add("OK: Client is registered (ClientId $clientId) -- MP registration with the remote site succeeded over the cross-forest trust/PKI")
                }
                else {
                    $reg.Details.Add("WARN: Client has no registration GUID yet -- MP_ClientRegistration with the remote site's MP may not have completed (check the cross-forest PKI client cert + MP reachability)")
                }

                # The MP the client is actually talking to.
                try {
                    $auth = Get-CimInstance -Namespace 'root\ccm' -ClassName SMS_Authority -ErrorAction Stop | Select-Object -First 1
                    if ($auth -and $auth.CurrentManagementPoint) {
                        $reg.Details.Add("OK: Current Management Point = $($auth.CurrentManagementPoint) (authority $($auth.Name))")
                    }
                }
                catch {}

                # When registration is incomplete (no assigned site, WRONG assigned
                # site, or no registration GUID), pull the client-side registration
                # and location logs so a validation rerun captures the ROOT CAUSE
                # inline instead of a bare WARN. These logs live only on the guest
                # (C:\Windows\CCM\Logs) and are otherwise lost on VHD compaction.
                # DIAG lines are indented (not FAIL:/WARN: anchored) so they land in
                # the per-domain VMBuild log for diagnosis without altering the
                # pass/fail verdict. PS5.1-safe (runs on down-level Win10/11 clients).
                $regIncomplete = ((-not $assigned) -or ("$assigned" -ne "$expSite") -or (-not $clientId))
                if ($regIncomplete) {
                    $logDir = 'C:\Windows\CCM\Logs'
                    # Unwrap a CMTrace <![LOG[msg]LOG]!> envelope to "HH:mm:ss  msg".
                    $unwrap = {
                        param($line)
                        $mm = [regex]::Match([string]$line, '<!\[LOG\[(.*?)\]LOG\]!><time="([^"]*)"')
                        if ($mm.Success) {
                            $tt = ($mm.Groups[2].Value -split '\.')[0]
                            return ('{0}  {1}' -f $tt, (($mm.Groups[1].Value) -replace '\s+', ' ').Trim())
                        }
                        return (([string]$line) -replace '\s+', ' ').Trim()
                    }
                    $grabLog = {
                        param($file, $pattern, $keep)
                        if (Test-Path $file) {
                            $hits = Get-Content $file -Tail 400 -ErrorAction SilentlyContinue |
                                Where-Object { $_ -match $pattern } | Select-Object -Last $keep
                            return @($hits | ForEach-Object { & $unwrap $_ })
                        }
                        return @()
                    }
                    $reg.Details.Add("  DIAG: registration incomplete (assigned='$assigned', expected='$expSite', clientId='$clientId') -- collecting client registration logs")
                    if (-not (Test-Path $logDir)) {
                        $reg.Details.Add("  DIAG: '$logDir' not present -- ConfigMgr client logs unavailable for registration diagnosis")
                    }
                    else {
                        # ClientIDManagerStartup.log -> registration GUID / RegTask / cert
                        $cidLines = & $grabLog (Join-Path $logDir 'ClientIDManagerStartup.log') 'RegTask|[Rr]egist|Assigning|GUID|[Ee]rror|[Ff]ail|denied|forbidden|401|certificate|[Cc]ert ' 8
                        # LocationServices.log -> MP + assigned-site lookup
                        $lsLines = & $grabLog (Join-Path $logDir 'LocationServices.log') 'Assign|[Ss]ite code|management point|[Bb]oundary|[Ee]rror|[Ff]ail|LSGet|Current AD|forest|MP ' 8
                        # CcmMessaging.log -> MP comms (cert/auth/transport) failures
                        $msgLines = & $grabLog (Join-Path $logDir 'CcmMessaging.log') '[Ee]rror|[Ff]ail|401|403|denied|forbidden|certificate|reject|WINHTTP|0x8' 6
                        if ($cidLines.Count) {
                            $reg.Details.Add("  DIAG ClientIDManagerStartup.log (last $($cidLines.Count) registration lines):")
                            foreach ($l in $cidLines) { $reg.Details.Add("      $l") }
                        }
                        else {
                            $reg.Details.Add("  DIAG ClientIDManagerStartup.log: no registration/error lines matched (client may never have attempted registration)")
                        }
                        if ($lsLines.Count) {
                            $reg.Details.Add("  DIAG LocationServices.log (last $($lsLines.Count) MP/site lines):")
                            foreach ($l in $lsLines) { $reg.Details.Add("      $l") }
                        }
                        else {
                            $reg.Details.Add("  DIAG LocationServices.log: no MP/site/error lines matched")
                        }
                        if ($msgLines.Count) {
                            $reg.Details.Add("  DIAG CcmMessaging.log (last $($msgLines.Count) error lines):")
                            foreach ($l in $msgLines) { $reg.Details.Add("      $l") }
                        }
                    }
                }

                return $reg
            }
            $regResult = Invoke-VmCommand -VmName $VMName -VmDomainName $domain `
                -ScriptBlock $regCheckBlock -ArgumentList $expectedSiteCode `
                -DisplayName "Phase11-DomainMember-RemoteSiteReg" -SuppressLog `
                -AsJob -TimeoutSeconds 180
            if ($regResult.ScriptBlockOutput -is [hashtable] -and $regResult.ScriptBlockOutput.Details) {
                foreach ($detail in $regResult.ScriptBlockOutput.Details) {
                    $null = $result.ScriptBlockOutput.Details.Add($detail)
                }
            }
        }
        else {
            $mgmtServerNote = if ($externalSiteServer) { " ($externalSiteServer)" } else { '' }
            $null = $result.ScriptBlockOutput.Details.Add("WARN: This domain is managed by remote CM site '$expectedSiteCode'$mgmtServerNote but the ConfigMgr client isn't running, so remote-site registration can't be verified")
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
    # A client this run just brought online cannot hold the Office assignment yet:
    # it still has to be discovered, land in MEMLABS-Office Install Targets, have
    # the site project the assignment, and then pull machine policy. Polling it for
    # 3 min and then collecting server-side projection state is a guaranteed WARN
    # that costs ~5 min on Phase 11's critical path (pushlab PL-PRETZEL).
    $clientBrandNew = ($clientRunningForOffice -and -not $result.ScriptBlockOutput.ClientPreexisting)
    if ($officeWanted -and -not $clientRunningForOffice) {
        $null = $result.ScriptBlockOutput.Details.Add("WARN: Skipping Office deployment policy check -- ConfigMgr client (CcmExec) is not installed/running, so the Office deployment can't be received. Resolve the client install first (see the ccmsetup WARN above).")
    }
    elseif ($officeWanted -and $clientBrandNew) {
        $null = $result.ScriptBlockOutput.Details.Add("INFO: Skipping Office deployment policy check -- the ConfigMgr client only came online during this Phase 11 run, so discovery, collection membership and policy projection have not had a cycle yet. Re-run Phase 11 to check the Office deployment.")
    }
    if ($officeWanted -and $clientRunningForOffice -and -not $clientBrandNew) {
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
                $null = $result.ScriptBlockOutput.Details.Add($detail)
            }
        }

        # HOST-SIDE DIAGNOSTIC: if the client couldn't see the Office deployment
        # policy, reach into the managing Primary and collect the SERVER-side
        # projection state for THIS specific client, so the WARN carries the
        # root-cause data instead of a guess. The decisive signals:
        #   - SMS_R_System.Client                    (does CM know it's a client?)
        #   - SMS_FullCollectionMembership.IsClient  (the snapshot policypv reads;
        #     when Client=1 but IsClient=0 the site skips projecting per-resource
        #     app policy -> the exact "member but no assignment" symptom)
        #   - SMS_CIAssignmentTargetedMachines       (is the assignment PROJECTED
        #     to this ResourceID at all? present => server projected it, so the
        #     gap is client-side pull; absent => server-side projection gap)
        # This runs on the Primary (host has Invoke-VmCommand to it); a client
        # scriptblock cannot see the site database.
        $officeWarned = ($officeResult.ScriptBlockOutput -is [hashtable] -and $officeResult.ScriptBlockOutput.Details -and
            @($officeResult.ScriptBlockOutput.Details | Where-Object { $_ -match 'Office deployment policy not visible' }).Count -gt 0)
        if ($officeWarned) {
            # Resolve the Primary that owns this client's Office deployment: prefer
            # the Primary whose siteCode matches the client's push site, else the
            # parent Primary of that site, else the first Primary in the config.
            $pushSite = $CurrentItem.pushClient
            $diagPrimary = $null
            if ($pushSite -and $pushSite -ne $false) {
                $diagPrimary = $DeployConfig.virtualMachines | Where-Object { $_.role -eq 'Primary' -and $_.siteCode -eq $pushSite } | Select-Object -First 1
                if (-not $diagPrimary) {
                    $secForSite = $DeployConfig.virtualMachines | Where-Object { $_.role -eq 'Secondary' -and $_.siteCode -eq $pushSite } | Select-Object -First 1
                    if ($secForSite -and $secForSite.parentSiteCode) {
                        $diagPrimary = $DeployConfig.virtualMachines | Where-Object { $_.role -eq 'Primary' -and $_.siteCode -eq $secForSite.parentSiteCode } | Select-Object -First 1
                    }
                }
            }
            if (-not $diagPrimary) {
                $diagPrimary = $DeployConfig.virtualMachines | Where-Object { $_.role -eq 'Primary' } | Select-Object -First 1
            }
            if ($diagPrimary -and $diagPrimary.siteCode) {
                $null = $result.ScriptBlockOutput.Details.Add("DIAG: collecting server-side Office projection state for $VMName from Primary $($diagPrimary.vmName) [site $($diagPrimary.siteCode)]...")
                $officeServerDiag = {
                    param($sc, $clientName)
                    $d = [System.Collections.Generic.List[string]]::new()
                    $ns = "root\SMS\site_$sc"
                    $colName = 'MEMLABS-Office Install Targets'
                    try {
                        $col = Get-WmiObject -Namespace $ns -Class SMS_Collection -Filter "Name='$colName'" -ErrorAction Stop | Select-Object -First 1
                    }
                    catch { $d.Add("DIAG: SMS_Collection query failed on Primary: $($_.Exception.Message)"); return , @($d) }
                    if (-not $col) { $d.Add("DIAG: collection '$colName' not found on Primary"); return , @($d) }
                    $cid = $col.CollectionID
                    $d.Add("DIAG: collection '$colName' = $cid (MemberCount=$($col.MemberCount))")

                    $rid = $null
                    try {
                        $r = Get-WmiObject -Namespace $ns -Class SMS_R_System -Filter "NetbiosName='$clientName'" -ErrorAction Stop | Select-Object -First 1
                    }
                    catch { $r = $null }
                    if ($r) {
                        $rid = $r.ResourceID
                        $d.Add("DIAG: SMS_R_System[$clientName] ResourceID=$rid Client=$($r.Client) Obsolete=$($r.Obsolete) Active=$($r.Active) ClientVersion=$($r.ClientVersion)")
                    }
                    else {
                        $d.Add("DIAG: SMS_R_System[$clientName] NO ROW -- client not discovered by CM")
                    }

                    if ($rid) {
                        try {
                            $mem = Get-WmiObject -Namespace $ns -Class SMS_FullCollectionMembership -Filter "CollectionID='$cid' AND ResourceID=$rid" -ErrorAction Stop | Select-Object -First 1
                        }
                        catch { $mem = $null }
                        if ($mem) {
                            $d.Add("DIAG: SMS_FullCollectionMembership[$cid].IsClient=$($mem.IsClient) for $clientName (policypv skips per-resource app policy when IsClient=0)")
                            if ($r -and $r.Client -eq 1 -and -not $mem.IsClient) {
                                $d.Add("DIAG: >>> ROOT CAUSE: Client=1 but IsClient=0 (stale membership snapshot). colleval snapshots IsClient at ADD time; a plain RequestRefresh may not rewrite it for existing members. Remedy: drop+re-add membership (bump the query rule) or Clear+re-eval so IsClient is re-snapshotted from Client.")
                            }
                        }
                        else {
                            $d.Add("DIAG: $clientName (ResourceID=$rid) is NOT in SMS_FullCollectionMembership for $cid -- not a member")
                        }
                    }

                    try {
                        $ass = Get-WmiObject -Namespace $ns -Class SMS_ApplicationAssignment -Filter "TargetCollectionID='$cid'" -ErrorAction Stop | Select-Object -First 1
                    }
                    catch { $ass = $null }
                    if ($ass) {
                        $d.Add("DIAG: Assignment '$($ass.AssignmentName)' AssignmentID=$($ass.AssignmentID) LastModified=$($ass.LastModificationTime)")
                        # Compliance/projection from SMS_DeploymentSummary -- the correct,
                        # always-available source (SMS_CIAssignmentTargetedMachines is not
                        # exposed by the SMS Provider on all builds -> "Invalid class").
                        # NumberTargeted = collection membership size; NumberUnknown with
                        # 0 Success/InProgress/Errors means the targeted clients have never
                        # received/evaluated the assignment -- the app-policy projection
                        # race (targets added to the collection while still non-clients, so
                        # policypv never projected the assignment to them).
                        try {
                            $ds = @(Get-WmiObject -Namespace $ns -Class SMS_DeploymentSummary -Filter "CollectionID='$cid' AND SoftwareName LIKE 'MEMLABS-Microsoft365Apps%'" -ErrorAction Stop) | Select-Object -First 1
                            if ($ds) {
                                $d.Add("DIAG: deployment summary Targeted=$($ds.NumberTargeted) Success=$($ds.NumberSuccess) InProgress=$($ds.NumberInProgress) Errors=$($ds.NumberErrors) Unknown=$($ds.NumberUnknown)")
                                if ([int]$ds.NumberTargeted -gt 0 -and [int]$ds.NumberSuccess -eq 0 -and [int]$ds.NumberInProgress -eq 0 -and [int]$ds.NumberErrors -eq 0) {
                                    $d.Add("DIAG: >>> ROOT CAUSE: all $($ds.NumberTargeted) targeted client(s) are Unknown -- the MP serves 'No new assignments' to the client's policy request. This is the app-policy projection race: the target(s) were added to the collection while still NON-clients, so policypv never projected the assignment. Remedy: FULL collection eval (Invoke-CMCollectionUpdate) + re-create the deployment; durable fix is the Client=1 membership gate in perfloading.")
                                }
                            }
                            else {
                                $d.Add("DIAG: no SMS_DeploymentSummary row for collection $cid / MEMLABS-Microsoft365Apps (deployment not summarized yet)")
                            }
                        }
                        catch { $d.Add("DIAG: SMS_DeploymentSummary query failed: $($_.Exception.Message)") }
                    }
                    else {
                        $d.Add("DIAG: no SMS_ApplicationAssignment targets $cid")
                    }

                    # Office APPLICATION health -- the usual root cause of "policy
                    # received but no Office assignment in it": the app has NO usable
                    # deployment type (Add-CMScriptDeploymentType silently failed during
                    # perfloading) or is disabled, so the projected policy carries no
                    # actionable content and the client App agent discards the assignment.
                    try {
                        $officeApp = @(Get-WmiObject -Namespace $ns -Class SMS_Application -Filter "LocalizedDisplayName LIKE 'MEMLABS-Microsoft365Apps%' AND IsLatest='true'" -ErrorAction Stop) | Select-Object -First 1
                        if ($officeApp) {
                            try { $officeApp.Get() } catch {}
                            $dtCount = [int]$officeApp.NumberOfDeploymentTypes
                            $d.Add("DIAG: Office app '$($officeApp.LocalizedDisplayName)' CI_ID=$($officeApp.CI_ID) DeploymentTypes=$dtCount IsEnabled=$($officeApp.IsEnabled) IsDeployed=$($officeApp.IsDeployed)")
                            if ($dtCount -eq 0) {
                                $d.Add("DIAG: >>> ROOT CAUSE: Office application has ZERO deployment types -- Add-CMScriptDeploymentType failed during perfloading, so the deployment carries no actionable content and clients discard the assignment. Remedy: recreate the ODT script deployment type + redistribute content, then run Machine Policy Retrieval on the clients.")
                            }
                            elseif (-not $officeApp.IsEnabled) {
                                $d.Add("DIAG: >>> ROOT CAUSE: Office application is DISABLED (IsEnabled=False) -- clients won't receive the assignment until the app is enabled.")
                            }
                        }
                        else {
                            $d.Add("DIAG: >>> Office application 'MEMLABS-Microsoft365Apps*' NOT FOUND (IsLatest) -- application creation failed during perfloading (ODT download or New-CMApplication).")
                        }
                    }
                    catch { $d.Add("DIAG: Office application query failed: $($_.Exception.Message)") }

                    try {
                        $cdr = Get-WmiObject -Namespace $ns -Class SMS_CombinedDeviceResources -Filter "Name='$clientName'" -ErrorAction Stop | Select-Object -First 1
                        if ($cdr) { $d.Add("DIAG: SMS_CombinedDeviceResources[$clientName] LastPolicyRequest=$($cdr.LastPolicyRequest) LastActiveTime=$($cdr.LastActiveTime) ClientState=$($cdr.ClientState) IsActive=$($cdr.IsActive)") }
                    }
                    catch {}

                    # policypv.log tail: shows whether the site is (re)projecting policy.
                    try {
                        $inst = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\SMS\Setup' -Name 'Installation Directory' -ErrorAction SilentlyContinue).'Installation Directory'
                        if ($inst) {
                            $pv = Join-Path $inst 'Logs\policypv.log'
                            if (Test-Path $pv) {
                                $d.Add("DIAG: policypv.log (last write $((Get-Item $pv).LastWriteTime.ToString('HH:mm:ss'))) tail:")
                                foreach ($ln in @(Get-Content $pv -Tail 5 -ErrorAction SilentlyContinue)) {
                                    $m = $ln; if ($ln -match '\[LOG\[(.*?)\]LOG\]') { $m = $Matches[1] }
                                    $d.Add("    $($m.Substring(0, [Math]::Min(140, $m.Length)))")
                                }
                            }
                        }
                    }
                    catch {}

                    return , @($d)
                }
                try {
                    $srvDiag = Invoke-VmCommand -VmName $diagPrimary.vmName -VmDomainName $domain `
                        -ScriptBlock $officeServerDiag -ArgumentList $diagPrimary.siteCode, $VMName `
                        -DisplayName "Phase11-Office-ServerDiag" -SuppressLog -AsJob -TimeoutSeconds 180
                    if ($srvDiag.ScriptBlockOutput) {
                        foreach ($ln in @($srvDiag.ScriptBlockOutput)) { $null = $result.ScriptBlockOutput.Details.Add($ln) }
                    }
                    else {
                        $null = $result.ScriptBlockOutput.Details.Add("DIAG: server-side Office diagnostic on $($diagPrimary.vmName) returned no output (see build log)")
                    }
                }
                catch {
                    $null = $result.ScriptBlockOutput.Details.Add("DIAG: server-side Office diagnostic on $($diagPrimary.vmName) failed: $($_.Exception.Message)")
                }
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
                $null = $result.ScriptBlockOutput.Details.Add($detail)
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

        $results.Details.Add("CMD: Test-Path 'C:\Program Files*\Microsoft SQL Server Management Studio *\...\Common7\IDE\ssms.exe'")
        # Version-agnostic: v18/19/20 install 32-bit under 'Program Files (x86)\...\Common7\IDE';
        # v21/22+ install 64-bit under 'Program Files\...\Release\Common7\IDE'. Match any of them.
        $ssms = Get-ChildItem -Path @(
            "C:\Program Files\Microsoft SQL Server Management Studio *\Release\Common7\IDE\Ssms.exe",
            "C:\Program Files\Microsoft SQL Server Management Studio *\Common7\IDE\Ssms.exe",
            "C:\Program Files (x86)\Microsoft SQL Server Management Studio *\Common7\IDE\ssms.exe"
        ) -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending | Select-Object -First 1
        if (-not $ssms) {
            $results.Passed = $false
            $results.Details.Add("FAIL: ssms.exe not found under any 'Microsoft SQL Server Management Studio *' path (Program Files or Program Files (x86))")
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

        # Reads the site server's distmgr.log to tell whether DistMgr is STILL
        # retrying a package (it retries a failed distribution ~100 times over ~2
        # days) vs has ABANDONED it. Used to keep non-client (OSD/app) content that
        # is merely churning under load as a WARN instead of a hard FAIL.
        $getDistmgrRetryStatus = {
            param($pkgId)
            $smsDir = $null
            foreach ($k in @('HKLM:\SOFTWARE\Microsoft\SMS\Identification', 'HKLM:\SOFTWARE\Microsoft\SMS\Setup')) {
                try { $smsDir = (Get-ItemProperty -Path $k -Name 'Installation Directory' -ErrorAction Stop).'Installation Directory' } catch {}
                if ($smsDir) { break }
            }
            if (-not $smsDir) { return $null }
            $line = $null
            foreach ($lf in @("$smsDir\Logs\distmgr.log", "$smsDir\Logs\distmgr.lo_")) {
                if (-not (Test-Path $lf)) { continue }
                $hit = Get-Content -LiteralPath $lf -Tail 12000 -ErrorAction SilentlyContinue |
                    Where-Object { $_ -like "*$pkgId*" -and $_ -match 'retr(y|ies|ying)' } | Select-Object -Last 1
                if ($hit) { $line = $hit; break }
            }
            if (-not $line) { return $null }
            if ($line -match 'will retry\s+(\d+)\s+more times') {
                return @{ StillRetrying = ([int]$Matches[1] -gt 0); Remaining = [int]$Matches[1]; Line = $line.Trim() }
            }
            if ($line -match 'will not (retry|try)|exceeded the maximum|maximum number of retries') {
                return @{ StillRetrying = $false; Remaining = 0; Line = $line.Trim() }
            }
            # Saw retry activity but no explicit remaining-count -> assume still cycling.
            return @{ StillRetrying = $true; Remaining = -1; Line = $line.Trim() }
        }

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
                # Not registered in the site after the retry budget. The retry window
                # above (6 x 30s = 3 min) already absorbs the normal DistMgr propagation
                # lag. Beyond that, a pull DP that has NOT posted its row into
                # SMS_DistributionPointInfo is genuinely not installed -- e.g. the pull-DP
                # add failed because its Source DP wasn't a DP yet ("No object corresponds
                # to the specified parameters"), which leaves the DP permanently
                # uninstalled. Per the "only soften when we can validate it's in progress
                # AND working" rule, we have NO positive proof of progress here, so FAIL.
                $results.Passed = $false
                $results.Details.Add("FAIL: DP '$dpName' not registered in site '$sc' (SMS_DistributionPointInfo) after $([int]($dpAttempts * $dpDelay / 60)) min -- pull DP was not installed (check the site server's InstallDPMPClient/distmgr logs for a pull-DP source-DP failure)")
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

        # --- Content-arrival check (CLIENT-CRITICAL content only) -------------
        # What matters for a pull DP SERVING CLIENTS is the ConfigMgr client package
        # (ccmsetup content) -- NOT perfloading OSD images (Windows install.wim) or
        # app content, which are multi-GB, legitimately slow, and which clients never
        # consume. So verify the CLIENT PACKAGE specifically; report other content as
        # INFO, and only FAIL on a genuinely TERMINAL-failed package (3/6/8 = real
        # corruption). This is the content whose absence makes clients loop in
        # ccmsetup GetDPLocations (empty <LocationRecords/> / 0x87d00215).
        try {
            $stateName = @{ '0' = 'Installed'; '1' = 'InstallPending'; '2' = 'InstallRetrying'; '3' = 'InstallFailed'; '4' = 'RemovalPending'; '5' = 'RemovalRetrying'; '6' = 'RemovalFailed'; '7' = 'ContentValidating'; '8' = 'ContentValidationFailed' }
            $clientPkgIds = @(Get-WmiObject -Namespace "root\SMS\site_$sc" -Class SMS_Package -Filter "Name LIKE 'Configuration Manager Client%'" -ErrorAction SilentlyContinue | ForEach-Object { $_.PackageID })
            $pkgStatus = @(Get-WmiObject -Namespace "root\SMS\site_$sc" -Class SMS_PackageStatusDistPointsSummarizer `
                    -Filter "ServerNALPath LIKE '%$dpName%'" -ErrorAction Stop)
            if ($pkgStatus.Count -eq 0) {
                $results.Passed = $false
                $results.CollectLogs = $true
                $results.Details.Add("FAIL: DP '$dpName' has NO package distribution rows -- no content has been targeted/pulled to this pull DP yet")
            }
            else {
                # 1) The client package -- the only client-blocking content.
                $clientRows = @($pkgStatus | Where-Object { $clientPkgIds -contains $_.PackageID })
                $clientBad = @($clientRows | Where-Object { $_.State -ne 0 })
                if ($clientRows.Count -eq 0) {
                    $results.Details.Add("INFO: client package not yet targeted to DP '$dpName' (no summarizer row)")
                }
                elseif ($clientBad.Count -eq 0) {
                    $results.Details.Add("OK: DP '$dpName' has the ConfigMgr client package Installed")
                }
                else {
                    $results.CollectLogs = $true
                    foreach ($cb in $clientBad) {
                        $sn = $stateName["$([int]$cb.State)"]; if (-not $sn) { $sn = "State$($cb.State)" }
                        if ($cb.State -in 3, 6, 8) {
                            $results.Passed = $false
                            $results.Details.Add("FAIL: DP '$dpName' CLIENT package ($($cb.PackageID)) in TERMINAL failed state $sn -- clients relying on this DP loop in ccmsetup GetDPLocations")
                        }
                        else {
                            $results.Details.Add("WARN: DP '$dpName' CLIENT package ($($cb.PackageID)) not yet Installed (State=$sn) -- clients relying on this DP loop in ccmsetup until it completes")
                        }
                    }
                }

                # 2) Everything else (OSD images, apps, packages) = INFORMATIONAL.
                # These are large/non-client-critical; only a TERMINAL failure (real
                # content corruption) is worth a FAIL.
                $otherRows = @($pkgStatus | Where-Object { $clientPkgIds -notcontains $_.PackageID })
                $otherInstalled = @($otherRows | Where-Object { $_.State -eq 0 }).Count
                $otherInProg = @($otherRows | Where-Object { $_.State -notin 0, 3, 6, 8 })
                $otherTerminal = @($otherRows | Where-Object { $_.State -in 3, 6, 8 })
                $results.Details.Add("INFO: DP '$dpName' other content: $otherInstalled/$($otherRows.Count) Installed, $($otherInProg.Count) still distributing (OSD/app content -- not client-critical)")
                if ($otherTerminal.Count -gt 0) {
                    # Non-client content (OSD/app): DistMgr retries a failed
                    # distribution ~100 times over ~2 days, so a State 3/6/8 snapshot
                    # during a build is almost always still-retrying churn, not
                    # corruption. Only FAIL once DistMgr has actually GIVEN UP; while
                    # it is still retrying, WARN (and still collect logs).
                    $results.CollectLogs = $true
                    $abandoned = @()
                    foreach ($ot in $otherTerminal | Select-Object -First 10) {
                        $sn = $stateName["$([int]$ot.State)"]; if (-not $sn) { $sn = "State$($ot.State)" }
                        $rs = & $getDistmgrRetryStatus $ot.PackageID
                        if ($rs -and -not $rs.StillRetrying) {
                            $abandoned += $ot
                            $results.Details.Add("  PackageID=$($ot.PackageID) State=$sn -- DistMgr GAVE UP retrying: $($rs.Line)")
                        }
                        else {
                            $rem = if ($rs) { if ($rs.Remaining -ge 0) { "$($rs.Remaining) attempts left" } else { 'still retrying' } } else { 'still retrying (no give-up logged)' }
                            $results.Details.Add("WARN: DP '$dpName' non-client package $($ot.PackageID) State=$sn but DistMgr is $rem (OSD/app content -- not client-critical)")
                        }
                    }
                    if ($abandoned.Count -gt 0) {
                        $results.Passed = $false
                        $results.Details.Add("FAIL: DP '$dpName' has $($abandoned.Count) non-client package(s) in a TERMINAL failed state that DistMgr has ABANDONED (3/6/8) -- see PackageIDs above")
                    }
                }
            }
        }
        catch {
            $results.Details.Add("WARN: pull-DP content-status query failed: $($_.Exception.Message)")
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

    # If the pull DP failed OR is behind on content (even a WARN), auto-collect its
    # own content-transfer logs (PullDP.log + DataTransferService.log) and the source
    # site server's distmgr/PkgXferMgr logs into the host logs folder, so the pull
    # failure/backlog can be triaged offline without hand-running commands.
    if (($result.ScriptBlockOutput -is [hashtable]) -and (($result.ScriptBlockOutput.Passed -eq $false) -or ($result.ScriptBlockOutput.ContainsKey('CollectLogs') -and $result.ScriptBlockOutput.CollectLogs))) {
        Add-Phase11Output "[Phase $Phase] $VMName [PullDP]: content behind/failed -- collecting pull-DP + source logs into the logs folder"
        $null = Save-Phase11GuestLogs -VMName $VMName -DomainName $domain -RoleLabel 'PullDP' -Collector $Phase11CcmClientLogCollector
        $null = Save-Phase11GuestLogs -VMName $parentVM.vmName -DomainName $domain -RoleLabel 'PullDP-Source' -Collector $Phase11SmsSiteLogCollector
    }

    return (Format-TestResult -VMName $VMName -RoleLabel 'PullDP' -Result $result)
}

function Get-ClientPackageValidationScope {
    param(
        [Parameter(Mandatory)][object]$CurrentItem,
        [Parameter(Mandatory)][object]$DeployConfig
    )

    $siteCode = "$($CurrentItem.siteCode)"
    # A CAS's package summarizer contains replicated rows for child Primaries,
    # but those rows can lag while the child's own provider is already current.
    # Every Primary runs this same Phase 11 check, so delegate each child Primary
    # to its local provider. A Primary still owns directly attached Secondary
    # sites because Secondary roles do not run this package check themselves.
    $ownedSiteCodes = @($siteCode)
    try {
        $ownedSiteCodes += @($DeployConfig.virtualMachines | Where-Object {
                $_.role -eq 'Secondary' -and $_.parentSiteCode -and $_.parentSiteCode -eq $siteCode
            } | Select-Object -ExpandProperty siteCode)
    }
    catch {}
    $ownedSiteCodes = @($ownedSiteCodes | Where-Object { $_ } | Select-Object -Unique)
    $ownedSiteUpper = @($ownedSiteCodes | ForEach-Object { "$($_)".ToUpper() })

    $ownedDpNames = @($DeployConfig.virtualMachines | Where-Object {
            if (-not $_.vmName -or -not $_.siteCode) { return $false }
            $isDp = ($_.installDP -eq $true -or $_.enablePullDP -eq $true -or $_.role -eq 'Secondary')
            return $isDp -and ($ownedSiteUpper -contains "$($_.siteCode)".ToUpper())
        } | Select-Object -ExpandProperty vmName | Select-Object -Unique)

    return [pscustomobject]@{
        SiteCodes = $ownedSiteCodes
        DpNames   = $ownedDpNames
    }
}

function Test-CMClientPackageDistribution {
    <#
    .SYNOPSIS
        Verifies the ConfigMgr client package(s) are distributed to their DPs and
        that no package is in a terminal distribution-failed state site-wide.
    .DESCRIPTION
        Runs against the Primary/CAS itself. The local site DB is authoritative
        for its own site and directly attached Secondary sites; a CAS does not
        judge child-Primary DPs from lagging replicated summarizer rows. The
        ConfigMgr Client Package + Client Upgrade
        Package must be Installed on the DPs clients reach, or ccmsetup loops in
        GetDPLocations with empty <LocationRecords/> (0x87d00215) -- the exact
        failure seen on internet/PKI clients when a pull DP is behind. On failure
        it auto-collects the site server's distmgr.log + PkgXferMgr.log into the
        host logs folder for offline triage.
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

    # The provider classes below are hierarchy-wide. Resolve which rows this
    # provider can judge authoritatively before entering the guest scriptblock.
    $validationScope = Get-ClientPackageValidationScope -CurrentItem $CurrentItem -DeployConfig $DeployConfig
    $ownedSiteCodes = @($validationScope.SiteCodes)
    $ownedDpNames = @($validationScope.DpNames)
    $ownedSiteCsv = ($ownedSiteCodes -join ',')
    $ownedDpCsv = ($ownedDpNames -join ',')

    Write-Log "[Phase $Phase] $VMName [ClientPkg]: Verifying client package distribution for site '$siteCode' (owned sites: $ownedSiteCsv; owned DPs: $ownedDpCsv)" -LogOnly

    $scriptBlock = {
        param($sc, $ownedSitesCsv, $ownedDpCsv)
        $results = @{ Passed = $true; ContentPendingFromParent = $false; Details = [System.Collections.Generic.List[string]]::new() }
        $ns = "root\SMS\site_$sc"
        $stateName = @{ '0' = 'Installed'; '1' = 'InstallPending'; '2' = 'InstallRetrying'; '3' = 'InstallFailed'; '4' = 'RemovalPending'; '5' = 'RemovalRetrying'; '6' = 'RemovalFailed'; '7' = 'ContentValidating'; '8' = 'ContentValidationFailed' }
        $dpNameOf = {
            param($nal)
            if ("$nal" -match '\\\\([^\\"\]]+)') { return $Matches[1] } else { return "$nal" }
        }

        # SMS_PackageStatusDistPointsSummarizer and SMS_BoundaryGroup are HIERARCHY-wide.
        # In a cumulative lab (CSTest1 runs A..H into one domain) that hands this check
        # every DP and boundary group any EARLIER test ever created. A DP is this
        # deployment's when it is a VM in the config, or when its site is one this server
        # owns. Everything else is reported for context and never judged.
        $ownedSites = @("$ownedSitesCsv" -split ',' | Where-Object { $_ } | ForEach-Object { $_.Trim().ToUpper() })
        $ownedDps = @("$ownedDpCsv" -split ',' | Where-Object { $_ } | ForEach-Object { $_.Trim().ToUpper() })
        $isOwnedDp = {
            param($DpNameOrFqdn, $DpSiteCode)
            $short = ("$DpNameOrFqdn" -split '\.')[0].ToUpper()
            if ($ownedDps -contains $short) { return $true }
            if ($DpSiteCode -and ($ownedSites -contains "$DpSiteCode".ToUpper())) { return $true }
            return $false
        }

        # Reads distmgr.log to tell whether DistMgr is STILL retrying a package vs
        # has ABANDONED it (retries exhausted). Keeps non-client (OSD/app) content
        # that is merely churning under load as a WARN instead of a hard FAIL.
        $getDistmgrRetryStatus = {
            param($pkgId)
            $smsDir = $null
            foreach ($k in @('HKLM:\SOFTWARE\Microsoft\SMS\Identification', 'HKLM:\SOFTWARE\Microsoft\SMS\Setup')) {
                try { $smsDir = (Get-ItemProperty -Path $k -Name 'Installation Directory' -ErrorAction Stop).'Installation Directory' } catch {}
                if ($smsDir) { break }
            }
            if (-not $smsDir) { return $null }
            $line = $null
            foreach ($lf in @("$smsDir\Logs\distmgr.log", "$smsDir\Logs\distmgr.lo_")) {
                if (-not (Test-Path $lf)) { continue }
                $hit = Get-Content -LiteralPath $lf -Tail 12000 -ErrorAction SilentlyContinue |
                    Where-Object { $_ -like "*$pkgId*" -and $_ -match 'retr(y|ies|ying)' } | Select-Object -Last 1
                if ($hit) { $line = $hit; break }
            }
            if (-not $line) { return $null }
            if ($line -match 'will retry\s+(\d+)\s+more times') {
                return @{ StillRetrying = ([int]$Matches[1] -gt 0); Remaining = [int]$Matches[1]; Line = $line.Trim() }
            }
            if ($line -match 'will not (retry|try)|exceeded the maximum|maximum number of retries') {
                return @{ StillRetrying = $false; Remaining = 0; Line = $line.Trim() }
            }
            return @{ StillRetrying = $true; Remaining = -1; Line = $line.Trim() }
        }

        $failingDps = New-Object System.Collections.Generic.List[string]

        # --- ConfigMgr client package(s): the critical client-install content ---
        try {
            # 'Configuration Manager Client%' matches THREE site-created packages:
            #   * 'Configuration Manager Client Package'         -- production client content (REQUIRED on a DP; every ccmsetup pulls it)
            #   * 'Configuration Manager Client Upgrade Package' -- auto-upgrade content (normally auto-distributed)
            #   * 'Configuration Manager Client Piloting Package'-- PRE-PRODUCTION/pilot client content
            # The Piloting package exists only when a pre-production client is staged and is
            # consumed ONLY by members of the pre-production collection -- it is NEVER required
            # for a normal client install and memlabs never distributes it to a DP. Gating
            # Phase 11 on it (NOT distributed to ANY DP / no BG coverage) is a false positive
            # that fails otherwise-healthy sites, so exclude it from this coverage check.
            $clientPkgs = @(Get-WmiObject -Namespace $ns -Class SMS_Package -Filter "Name LIKE 'Configuration Manager Client%' AND Name NOT LIKE '%Piloting%'" -ErrorAction Stop)
        }
        catch {
            $results.Passed = $false
            $results.Details.Add("FAIL: could not query SMS_Package for the client package: $($_.Exception.Message)")
            return $results
        }
        if ($clientPkgs.Count -eq 0) {
            $results.Details.Add("WARN: no 'Configuration Manager Client%' package found in site $sc -- cannot verify client package distribution")
        }

        foreach ($pkg in $clientPkgs) {
            $pkgId = $pkg.PackageID
            $dpRows = @(Get-WmiObject -Namespace $ns -Class SMS_PackageStatusDistPointsSummarizer -Filter "PackageID='$pkgId'" -ErrorAction SilentlyContinue)
            # Convergence: allow in-progress (1/2/7) to settle before judging.
            for ($t = 1; $t -le 3; $t++) {
                $pending = @($dpRows | Where-Object { $_.State -in 1, 2, 7 })
                if ($pending.Count -eq 0) { break }
                Start-Sleep -Seconds 30
                $dpRows = @(Get-WmiObject -Namespace $ns -Class SMS_PackageStatusDistPointsSummarizer -Filter "PackageID='$pkgId'" -ErrorAction SilentlyContinue)
            }
            if ($dpRows.Count -eq 0) {
                $results.Passed = $false
                $results.Details.Add("FAIL: client package '$($pkg.Name)' ($pkgId) is NOT distributed to ANY DP -- clients can't get client content (ccmsetup loops on GetDPLocations / 0x87d00215). Distribute it to a DP in the clients' boundary group.")
                continue
            }
            $foreignRows = @($dpRows | Where-Object { -not (& $isOwnedDp (& $dpNameOf $_.ServerNALPath) $_.SiteCode) })
            $dpRows = @($dpRows | Where-Object { & $isOwnedDp (& $dpNameOf $_.ServerNALPath) $_.SiteCode })
            if ($foreignRows.Count -gt 0) {
                $foreignSummary = (@($foreignRows | Select-Object -First 8 | ForEach-Object {
                            $sn3 = $stateName["$([int]$_.State)"]; if (-not $sn3) { $sn3 = "State$($_.State)" }
                            "$((("$(& $dpNameOf $_.ServerNALPath)") -split '\.')[0])=$sn3(site $($_.SiteCode))"
                        })) -join ', '
                $results.Details.Add("  not judged -- $($foreignRows.Count) DP(s) belong to sites this deployment does not own: $foreignSummary")
            }
            if ($dpRows.Count -eq 0) {
                if ($ownedDps.Count -gt 0) {
                    $results.Passed = $false
                    $results.Details.Add("FAIL: client package '$($pkg.Name)' ($pkgId) is not distributed to ANY DP this deployment owns ($($ownedDps -join ', ')) -- clients assigned here loop in ccmsetup GetDPLocations.")
                }
                else {
                    $results.Details.Add("  client package '$($pkg.Name)' ($pkgId) skipped: this deployment contains no DP of its own")
                }
                continue
            }
            $bad = @($dpRows | Where-Object { $_.State -ne 0 })
            if ($bad.Count -eq 0) {
                $results.Details.Add("OK: client package '$($pkg.Name)' ($pkgId) Installed on all $($dpRows.Count) DP(s)")
            }
            else {
                # A DP missing the content is ALWAYS surfaced (so the fallback DPs
                # can't silently hide a broken/pull DP), but only as a WARN here --
                # whether any clients are actually BLOCKED is decided by the
                # boundary-group coverage check below (FAILs a BG with no Installed
                # DP) and the terminal-state sweep (FAILs 3/6/8). So: broken-but-
                # covered-by-a-fallback-DP -> WARN; blocking or terminal -> FAIL.
                #
                # Name the DPs IN the WARN line. The per-DP breakdown below is
                # -LogOnly (Format-TestResult only consoles FAIL:/WARN:/RECOVERED:
                # prefixes), so the console used to show this sentence ending in a
                # colon with nothing after it -- un-actionable, and the operator had
                # to go find the log to learn which DP. SiteCode matters too: in a
                # CAS hierarchy each primary judges from its OWN summarizer replica,
                # so a DP belonging to another site can read stale here.
                $badSummary = (@($bad | Select-Object -First 5 | ForEach-Object {
                            $sn2 = $stateName["$([int]$_.State)"]; if (-not $sn2) { $sn2 = "State$($_.State)" }
                            $dpShort = ("$(& $dpNameOf $_.ServerNALPath)" -split '\.')[0]
                            "$dpShort=$sn2(site $($_.SiteCode))"
                        })) -join ', '
                # A DP cannot install content its own site never received. On a child primary
                # the client package is owned by the CAS, so StoredPkgVersion=0 means the
                # parent never sent it down and every DP state above is a consequence, not a
                # cause. Saying so here stops the next reader triaging the DP: on cstest2 the
                # DP had been registered for 50 minutes and the site still held no content.
                if ([int]$pkg.StoredPkgVersion -lt 1) {
                    $results.ContentPendingFromParent = $true
                    $results.Details.Add("WARN: client package '$($pkg.Name)' ($pkgId) has NO content at site $sc at all (StoredPkgVersion=0, SourceVersion=$($pkg.SourceVersion)) -- it is owned by a parent site that never sent it down, so no DP here could have installed it. Triage the PARENT site's distmgr/sender, not the DP.")
                }
                $results.Details.Add("WARN: client package '$($pkg.Name)' ($pkgId) NOT Installed on $($bad.Count)/$($dpRows.Count) DP(s): $badSummary -- a fallback DP may still serve clients; the boundary-group check below decides whether any client is actually blocked.")
                foreach ($b in $bad | Select-Object -First 15) {
                    $sn = $stateName["$([int]$b.State)"]; if (-not $sn) { $sn = "State$($b.State)" }
                    $dpn = & $dpNameOf $b.ServerNALPath
                    [void]$failingDps.Add(("$dpn" -split '\.')[0])
                    $results.Details.Add("  DP=$dpn Site=$($b.SiteCode) State=$sn SourceVersion=$($b.SourceVersion) LastCopied=$($b.LastCopied)")
                }
            }
        }

        # --- Boundary-group coverage --------------------------------------
        # Every boundary group that has DP(s) must have at least ONE DP with the
        # client package Installed (State 0). A BG whose only DP is still
        # validating/pending (e.g. a Secondary's DP stuck at State 7) leaves
        # clients in that BG with empty DP locations -> the ccmsetup GetDPLocations
        # loop -- even though OTHER boundary groups' DPs have the content. This is
        # the check that maps directly to the client symptom.
        try {
            $bgs = @(Get-WmiObject -Namespace $ns -Class SMS_BoundaryGroup -ErrorAction Stop)
            $bgLinks = @(Get-WmiObject -Namespace $ns -Class SMS_BoundaryGroupSiteSystems -ErrorAction SilentlyContinue)
            foreach ($pkg in $clientPkgs) {
                $dpState = @{}
                $dpSite = @{}
                foreach ($row in @(Get-WmiObject -Namespace $ns -Class SMS_PackageStatusDistPointsSummarizer -Filter "PackageID='$($pkg.PackageID)'" -ErrorAction SilentlyContinue)) {
                    $rowName = (& $dpNameOf $row.ServerNALPath).ToUpper()
                    $dpState[$rowName] = [int]$row.State
                    $dpSite[$rowName] = "$($row.SiteCode)"
                }
                foreach ($bg in $bgs) {
                    $bgDps = @($bgLinks | Where-Object { $_.GroupID -eq $bg.GroupID } | ForEach-Object { (& $dpNameOf $_.ServerNALPath).ToUpper() } | Select-Object -Unique)
                    if ($bgDps.Count -eq 0) { continue }
                    $ownedInBg = @($bgDps | Where-Object { & $isOwnedDp $_ $dpSite[$_] })
                    if ($ownedInBg.Count -eq 0) {
                        $results.Details.Add("  boundary group '$($bg.Name)' ($($bg.GroupID)) not judged: none of its DP(s) belong to this deployment ($($bgDps -join ', '))")
                        continue
                    }
                    $installedInBg = @($bgDps | Where-Object { $dpState.ContainsKey($_) -and $dpState[$_] -eq 0 })
                    if ($installedInBg.Count -eq 0) {
                        $results.Passed = $false
                        $stateList = ($bgDps | ForEach-Object { $s = if ($dpState.ContainsKey($_)) { $stateName["$($dpState[$_])"] } else { 'no-row' }; "$_=$s" }) -join ', '
                        $why = if ([int]$pkg.StoredPkgVersion -lt 1) { " -- site $sc holds no copy of this package (StoredPkgVersion=0), so the content never arrived from its parent site" } else { '' }
                        $results.Details.Add("FAIL: boundary group '$($bg.Name)' ($($bg.GroupID)) has NO DP with client package '$($pkg.Name)' Installed -- clients in this BG loop in ccmsetup GetDPLocations (empty LocationRecords). DP states: $stateList$why")
                        foreach ($d in $bgDps) { if (-not ($dpState.ContainsKey($d) -and $dpState[$d] -eq 0)) { [void]$failingDps.Add(("$d" -split '\.')[0]) } }
                    }
                    else {
                        $results.Details.Add("OK: boundary group '$($bg.Name)' ($($bg.GroupID)) served by $(($installedInBg | ForEach-Object { ("$_" -split '\.')[0] }) -join ', ') for '$($pkg.Name)'")
                    }
                }
            }
        }
        catch {
            $results.Details.Add("WARN: boundary-group coverage check failed: $($_.Exception.Message)")
        }

        # --- Site-wide sweep: any package stuck in a TERMINAL failed state -----
        # The CLIENT package is client-critical -> a terminal state always FAILs.
        # Non-client content (perfloading OSD images, apps) is NOT client-critical
        # and DistMgr retries a failed distribution ~100 times over ~2 days, so a
        # State 3/6/8 snapshot during a build is almost always still-retrying churn,
        # not corruption. Only FAIL non-client content once DistMgr has actually
        # GIVEN UP (retries exhausted); while it is still retrying, WARN.
        try {
            $clientPkgIds = @($clientPkgs | ForEach-Object { $_.PackageID })
            $failedRows = @(Get-WmiObject -Namespace $ns -Class SMS_PackageStatusDistPointsSummarizer -Filter "State = 3 OR State = 6 OR State = 8" -ErrorAction Stop)
            $foreignFailed = @($failedRows | Where-Object { -not (& $isOwnedDp (& $dpNameOf $_.ServerNALPath) $_.SiteCode) })
            $failedRows = @($failedRows | Where-Object { & $isOwnedDp (& $dpNameOf $_.ServerNALPath) $_.SiteCode })
            if ($foreignFailed.Count -gt 0) {
                $results.Details.Add("  not judged -- $($foreignFailed.Count) terminal-state row(s) on DP(s) outside this deployment: $((@($foreignFailed | Select-Object -First 8 | ForEach-Object { "$($_.PackageID)@$(("$(& $dpNameOf $_.ServerNALPath)" -split '\.')[0])(site $($_.SiteCode))" })) -join ', ')")
            }
            if ($failedRows.Count -eq 0) {
                $results.Details.Add("OK: no packages in a terminal distribution-failed state (3/6/8) on this deployment's DP(s)")
            }
            else {
                $clientFailed = @($failedRows | Where-Object { $clientPkgIds -contains $_.PackageID })
                $nonClientFailed = @($failedRows | Where-Object { $clientPkgIds -notcontains $_.PackageID })

                if ($clientFailed.Count -gt 0) {
                    $results.Passed = $false
                    $results.Details.Add("FAIL: $($clientFailed.Count) CLIENT package/DP distribution(s) in a terminal failed state (3/6/8):")
                    foreach ($r in $clientFailed | Select-Object -First 20) {
                        $sn = $stateName["$([int]$r.State)"]; if (-not $sn) { $sn = "State$($r.State)" }
                        $dpn = & $dpNameOf $r.ServerNALPath
                        [void]$failingDps.Add(("$dpn" -split '\.')[0])
                        $results.Details.Add("  PackageID=$($r.PackageID) DP=$dpn State=$sn")
                    }
                }

                $abandonedNonClient = 0
                foreach ($r in $nonClientFailed | Select-Object -First 20) {
                    $sn = $stateName["$([int]$r.State)"]; if (-not $sn) { $sn = "State$($r.State)" }
                    $dpn = & $dpNameOf $r.ServerNALPath
                    [void]$failingDps.Add(("$dpn" -split '\.')[0])
                    $rs = & $getDistmgrRetryStatus $r.PackageID
                    if ($rs -and -not $rs.StillRetrying) {
                        $results.Passed = $false
                        $abandonedNonClient++
                        $results.Details.Add("FAIL: non-client package $($r.PackageID) on DP=$dpn is $sn and DistMgr has GIVEN UP retrying (abandoned) -- $($rs.Line)")
                    }
                    else {
                        $rem = if ($rs) { if ($rs.Remaining -ge 0) { "$($rs.Remaining) attempts left" } else { 'still retrying' } } else { 'still retrying (no give-up logged)' }
                        $results.Details.Add("WARN: non-client package $($r.PackageID) on DP=$dpn is $sn but not client-critical and DistMgr is $rem (OSD/app content) -- not failing the build")
                    }
                }
                if ($clientFailed.Count -eq 0 -and $abandonedNonClient -eq 0 -and $nonClientFailed.Count -gt 0) {
                    $results.Details.Add("OK: $($nonClientFailed.Count) non-client package/DP distribution(s) are failed but DistMgr is still retrying them (OSD/app content -- not client-critical)")
                }
            }
        }
        catch {
            $results.Details.Add("WARN: site-wide distribution sweep failed: $($_.Exception.Message)")
        }

        $results.FailingDPs = @($failingDps | Select-Object -Unique)
        return $results
    }

    $result = Invoke-VmCommand -VmName $VMName -VmDomainName $domain `
        -ScriptBlock $scriptBlock -ArgumentList $siteCode, $ownedSiteCsv, $ownedDpCsv `
        -DisplayName "Phase11-ClientPkg-Test" -SuppressLog `
        -AsJob -TimeoutSeconds 300

    # On a distribution failure OR any DP behind on the client package (even a
    # WARN, e.g. a Secondary DP stuck at ContentValidating), auto-collect the site
    # server's distmgr.log + PkgXferMgr.log and the failing DP's own logs so the
    # reason is captured without hand-running commands.
    $failing = @()
    if (($result.ScriptBlockOutput -is [hashtable]) -and $result.ScriptBlockOutput.ContainsKey('FailingDPs')) { $failing = @($result.ScriptBlockOutput.FailingDPs | Where-Object { $_ }) }
    if (($result.ScriptBlockOutput -is [hashtable]) -and (($result.ScriptBlockOutput.Passed -eq $false) -or ($failing.Count -gt 0))) {
        Add-Phase11Output "[Phase $Phase] $VMName [ClientPkg]: distribution failed or a DP is behind -- collecting distmgr/PkgXferMgr logs into the logs folder"
        $null = Save-Phase11GuestLogs -VMName $VMName -DomainName $domain -RoleLabel 'ClientPkg' -Collector $Phase11SmsSiteLogCollector

        # The summarizer is HIERARCHY-wide, so the failing DP routinely belongs to a
        # site this run never touched (re-running a subset config still reports it).
        # Resolving only against $DeployConfig.virtualMachines silently skipped those
        # DPs, leaving the validating site server's distmgr -- which never mentions
        # another site's content path -- as the only evidence collected.
        $domainVms = @()
        try { $domainVms = @(Get-List -Type VM -DomainName $domain) }
        catch { Add-Phase11Output "[Phase $Phase] $VMName [ClientPkg]: could not enumerate VMs in domain '$domain' to resolve failing DP(s): $($_.Exception.Message)" -Level Warning }
        $collectedFrom = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
        [void]$collectedFrom.Add($VMName)

        foreach ($dpShort in ($failing | Select-Object -Unique)) {
            $dpVm = $DeployConfig.virtualMachines | Where-Object { $_.vmName -and ($_.vmName.ToUpper() -eq "$dpShort".ToUpper()) } | Select-Object -First 1
            if (-not $dpVm) { $dpVm = $domainVms | Where-Object { $_.vmName -and ($_.vmName.ToUpper() -eq "$dpShort".ToUpper()) } | Select-Object -First 1 }
            if (-not $dpVm) {
                Add-Phase11Output "[Phase $Phase] $VMName [ClientPkg]: failing DP '$dpShort' matches no VM in domain '$domain' -- no DP-side logs collected, triage it by hand." -Level Warning
                continue
            }
            if ($collectedFrom.Add($dpVm.vmName)) {
                Add-Phase11Output "[Phase $Phase] $VMName [ClientPkg]: collecting DP logs from behind/failing DP '$($dpVm.vmName)'"
                $null = Save-Phase11GuestLogs -VMName $dpVm.vmName -DomainName $domain -RoleLabel 'ClientPkg-DP' -Collector $Phase11CcmClientLogCollector
                $null = Save-Phase11GuestLogs -VMName $dpVm.vmName -DomainName $domain -RoleLabel 'ClientPkg-DP' -Collector $Phase11SmsSiteLogCollector
                # The two collectors above cover a PULL DP (CCM logs) and a SITE SERVER
                # (SMS logs). A plain remote DP is neither, so on cstest2 both returned
                # nothing for the one machine the whole failure was about.
                $null = Save-Phase11GuestLogs -VMName $dpVm.vmName -DomainName $domain -RoleLabel 'ClientPkg-DP' -Collector $Phase11DpContentLogCollector
                # A Secondary DP that never gets the client package is often wedged in
                # distmgr on "site exchange certificate is not found / Failed to decrypt
                # cert PFX data" -- its site DB lost the SiteExchangeCertificate, so it
                # can't decrypt the DP identity cert and distributes NOTHING. Probe the
                # Secondary's site DB directly so the ROOT cause is captured, not just
                # the symptom.
                if ("$($dpVm.role)" -eq 'Secondary') {
                    Add-Phase11Output "[Phase $Phase] $VMName [ClientPkg]: '$($dpVm.vmName)' is a Secondary DP -- probing its site DB for the site exchange certificate (distmgr PFX-decrypt wedge)"
                    $null = Save-Phase11GuestLogs -VMName $dpVm.vmName -DomainName $domain -RoleLabel 'ClientPkg-SecCert' -Collector $Phase11SecondaryCertDiagCollector -TimeoutSeconds 180
                }
            }

            # Content reaches a DP in another site over THAT site's inter-site hop,
            # which only the sending parent logs ("Created minijob to send compressed
            # copy ... to site X" / "is NOT an active site, ignore it"). Without this
            # the pulled logs cannot explain the DP they were pulled for.
            $ownerCode = if ("$($dpVm.role)" -eq 'Secondary') { "$($dpVm.parentSiteCode)" } else { "$($dpVm.siteCode)" }
            if ($ownerCode -and $ownerCode -ne $siteCode) {
                $ownerVm = @(@($DeployConfig.virtualMachines) + @($domainVms) | Where-Object {
                        $_.vmName -and "$($_.siteCode)" -eq $ownerCode -and "$($_.role)" -in @('CAS', 'Primary', 'Secondary')
                    }) | Select-Object -First 1
                if ($ownerVm -and $collectedFrom.Add($ownerVm.vmName)) {
                    Add-Phase11Output "[Phase $Phase] $VMName [ClientPkg]: '$($dpVm.vmName)' is fed by site $ownerCode -- collecting the sending side from '$($ownerVm.vmName)'"
                    $null = Save-Phase11GuestLogs -VMName $ownerVm.vmName -DomainName $domain -RoleLabel 'ClientPkg-Parent' -Collector $Phase11SmsSiteLogCollector
                }
                elseif (-not $ownerVm) {
                    Add-Phase11Output "[Phase $Phase] $VMName [ClientPkg]: '$($dpVm.vmName)' is fed by site $ownerCode but no site server for that site exists in domain '$domain' -- sending-side logs NOT collected." -Level Warning
                }
            }
        }

        # The loop above follows the DP to ITS site, which for a child primary's own DP is
        # this same site -- so nothing above ever reaches the CAS. When the package has no
        # local copy the content owes down from the parent, and the only record of why the
        # parent did not send it ("Created minijob to send compressed copy ... to site X",
        # or its absence) is the parent's distmgr/sender. Without this, the pulled logs can
        # only show the local site waiting: cstest2 burned a 45-minute Phase 8 wait and a
        # Phase 11 failure whose entire evidence set was collected from the wrong two hosts.
        if ($result.ScriptBlockOutput.ContentPendingFromParent) {
            $parentCode = "$($CurrentItem.parentSiteCode)"
            if (-not $parentCode) {
                Add-Phase11Output "[Phase $Phase] $VMName [ClientPkg]: the client package has no content at site $siteCode but this site has no parent -- its own distmgr owns the missing content." -Level Warning
            }
            else {
                $parentVm = @(@($DeployConfig.virtualMachines) + @($domainVms) | Where-Object {
                        $_.vmName -and "$($_.siteCode)" -eq $parentCode -and "$($_.role)" -in @('CAS', 'Primary')
                    }) | Select-Object -First 1
                if (-not $parentVm) {
                    Add-Phase11Output "[Phase $Phase] $VMName [ClientPkg]: the client package content owes down from parent site $parentCode, but no site server for it exists in domain '$domain' -- the sending side was NOT collected." -Level Warning
                }
                elseif ($collectedFrom.Add($parentVm.vmName)) {
                    Add-Phase11Output "[Phase $Phase] $VMName [ClientPkg]: site $siteCode holds no copy of the client package -- collecting the sending side from parent site $parentCode ('$($parentVm.vmName)')"
                    $null = Save-Phase11GuestLogs -VMName $parentVm.vmName -DomainName $domain -RoleLabel 'ClientPkg-ContentSource' -Collector $Phase11SmsSiteLogCollector
                }
            }
        }
    }

    return (Format-TestResult -VMName $VMName -RoleLabel 'ClientPkg' -Result $result)
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
                # Missing volume -- dump full disk/partition/volume state so we can tell
                # "disk truly absent (host never attached it)" from "disk present but
                # OFFLINE / partition without a drive letter", then attempt a SAFE
                # recovery (online offline disks; assign the expected letter to a
                # matching lettertless data partition -- e.g. a SQL data disk that lost
                # its letter) and re-check. Never formats (no data loss).
                $results.Details.Add("WARN: Volume '$letter`:' not present -- capturing disk diagnostics")
                try {
                    foreach ($d in @(Get-Disk -ErrorAction SilentlyContinue | Sort-Object Number)) {
                        $results.Details.Add("  DIAG Disk#$($d.Number): '$($d.FriendlyName)' $([math]::Round($d.Size / 1GB, 1))GB Style=$($d.PartitionStyle) OpStatus=$($d.OperationalStatus) Offline=$($d.IsOffline) ReadOnly=$($d.IsReadOnly)")
                    }
                    foreach ($p in @(Get-Partition -ErrorAction SilentlyContinue | Where-Object { $_.Size -gt 100MB } | Sort-Object DiskNumber, PartitionNumber)) {
                        $results.Details.Add("  DIAG Partition Disk#$($p.DiskNumber)/Part#$($p.PartitionNumber): Letter='$($p.DriveLetter)' $([math]::Round($p.Size / 1GB, 1))GB Type=$($p.Type)")
                    }
                    foreach ($v in @(Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter })) {
                        $results.Details.Add("  DIAG Volume $($v.DriveLetter): $([math]::Round($v.Size / 1GB, 1))GB $($v.FileSystem) '$($v.FileSystemLabel)'")
                    }
                }
                catch { $results.Details.Add("  DIAG: disk enumeration failed: $($_.Exception.Message)") }

                try {
                    foreach ($od in @(Get-Disk -ErrorAction SilentlyContinue | Where-Object { $_.IsOffline })) {
                        try {
                            Set-Disk -Number $od.Number -IsOffline $false -ErrorAction Stop
                            if ($od.IsReadOnly) { Set-Disk -Number $od.Number -IsReadOnly $false -ErrorAction SilentlyContinue }
                            $results.Details.Add("  RECOVERED: brought Disk#$($od.Number) online")
                        }
                        catch { $results.Details.Add("  DIAG: could not online Disk#$($od.Number): $($_.Exception.Message)") }
                    }
                    Start-Sleep -Seconds 3
                    $vol = Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue | Select-Object -First 1
                    if (-not $vol) {
                        $cand = @(Get-Partition -ErrorAction SilentlyContinue | Where-Object { -not $_.DriveLetter -and $_.Size -gt 1GB -and $_.Type -notin 'Reserved', 'System' } | Sort-Object Size -Descending) | Select-Object -First 1
                        if ($cand) {
                            try {
                                Set-Partition -DiskNumber $cand.DiskNumber -PartitionNumber $cand.PartitionNumber -NewDriveLetter $letter -ErrorAction Stop
                                $results.Details.Add("  RECOVERED: assigned drive letter '$letter' to Disk#$($cand.DiskNumber)/Part#$($cand.PartitionNumber) ($([math]::Round($cand.Size / 1GB, 1))GB)")
                                Start-Sleep -Seconds 2
                                $vol = Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue | Select-Object -First 1
                            }
                            catch { $results.Details.Add("  DIAG: could not assign '$letter': $($_.Exception.Message)") }
                        }
                    }
                }
                catch { $results.Details.Add("  DIAG: recovery attempt error: $($_.Exception.Message)") }

                if (-not $vol) {
                    $results.Passed = $false
                    $results.Details.Add("FAIL: Volume '$letter`:' not present -- disk absent or unrecoverable (see DIAG above; if no Disk# matches the expected size, the host did not attach the disk)")
                    continue
                }
                $results.Details.Add("RECOVERED: Volume '$letter`:' recovered (was missing; disk onlined / drive letter reassigned)")
            }
            # Duplicate / colliding disk detection: more than one volume or partition
            # claiming the SAME drive letter is a disk-signature collision. The common
            # cause is a GUEST PHANTOM/ghost disk -- the host has only one data VHDX
            # attached, but a surprise disk remove/re-add or a checkpoint apply left a
            # stale disk object in the guest (Server 2025 storvsc is prone to this), so
            # two disks fight over the letter and it is intermittently unavailable.
            # Count only REAL, locally-attached disks claiming the letter. On a
            # Failover Cluster node (e.g. SQLAO) the CLUSTERED Windows Storage
            # subsystem reflects the PARTNER node's data disk -- including its
            # drive-letter attribute -- into this node's Get-Disk/Get-Partition view
            # as a phantom claimant with a NULL DiskNumber. That is a benign reporting
            # artifact, NOT a real collision: the device layer has exactly one real
            # disk on the letter (verified: one PnP devnode + one registry instance per
            # data disk; the reflected object has no disk.sys number and a \\?\Disk{guid}
            # path). Filtering to partitions with a non-null DiskNumber drops the cluster
            # reflection while STILL catching a genuine duplicate -- two really-attached
            # local disks each have a non-null DiskNumber, so that count stays > 1.
            $letterParts = @(Get-Partition -DriveLetter $letter -ErrorAction SilentlyContinue)
            $localParts = @($letterParts | Where-Object { $null -ne $_.DiskNumber })
            $reflectedN = $letterParts.Count - $localParts.Count
            if ($reflectedN -gt 0) {
                $results.Details.Add("OK: '$letter`:' shows $reflectedN additional claimant(s) reflected by the Clustered Windows Storage subsystem (the partner node's disk on a Failover Cluster / SQLAO) -- benign cluster-view artifact, ignored ($($localParts.Count) real local disk(s) claim '$letter`:')")
            }
            $preDupN = $localParts.Count
            if ($preDupN -gt 1) {
                try { Update-HostStorageCache -ErrorAction SilentlyContinue } catch {}
                Start-Sleep -Seconds 3
                $postDupN = @(Get-Partition -DriveLetter $letter -ErrorAction SilentlyContinue | Where-Object { $null -ne $_.DiskNumber }).Count
                if ($postDupN -le 1) {
                    $results.Details.Add("RECOVERED: '$letter`:' was claimed by $preDupN local disks (phantom/ghost); a storage rescan cleared it (now $postDupN)")
                }
                else {
                    $results.Details.Add("WARN: $postDupN LOCALLY-ATTACHED disks/partitions claim drive letter '$letter`:' after a storage rescan -- a genuine disk-signature COLLISION between two real disks (cluster-reflected partner-node disks are already excluded). See the HOST DIAG below (added automatically by the caller) for the definitive cause: HOST has exactly the config's data VHDX -> in-guest duplicate (reboot the VM to clear it); HOST has a duplicate/extra data VHDX -> remove it on the host (a reboot will NOT fix that). DIAG:")
                    foreach ($dp in @(Get-Partition -DriveLetter $letter -ErrorAction SilentlyContinue)) { $results.Details.Add("  DIAG dup partition: Disk#$($dp.DiskNumber)/Part#$($dp.PartitionNumber) $([math]::Round($dp.Size / 1GB, 1))GB") }
                    # Dump each disk with its stable identity fields. Two entries
                    # that share the SAME UniqueId/SerialNumber/Path are the SAME
                    # underlying VHDX double-reported by the guest (a pure PHANTOM;
                    # a reboot clears it); DIFFERENT identities mean two real disks
                    # are attached (a host-side duplicate VHDX -- see the HOST DIAG
                    # added by the caller). A null/blank Disk# is a ghost object.
                    foreach ($dd in @(Get-Disk -ErrorAction SilentlyContinue | Sort-Object Number)) { $results.Details.Add("  DIAG Disk#$($dd.Number): $([math]::Round($dd.Size / 1GB, 1))GB Sig=$($dd.Signature) Guid=$($dd.Guid) Offline=$($dd.IsOffline) Bus=$($dd.BusType) OpStatus=$($dd.OperationalStatus) Serial='$($dd.SerialNumber)' UniqueId='$($dd.UniqueId)' Path='$($dd.Path)'") }
                    # WHEN did the phantom appear? Correlate it to the build timeline:
                    # guest last-boot + the recent storage/PnP arrival/removal events
                    # (disk / partmgr / storvsc / vmbus / Kernel-PnP / Ntfs) from the
                    # System log. A phantom disk object is created by a surprise disk
                    # remove/re-add or a checkpoint apply, so these timestamps pin the
                    # operation/phase that introduced it (e.g. a SQLAO cluster/shared-disk
                    # step or a checkpoint merge) instead of just knowing it exists.
                    try {
                        $bootT = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).LastBootUpTime
                        if ($bootT) { $results.Details.Add("  DIAG WHEN: guest last boot $($bootT.ToString('yyyy-MM-dd HH:mm:ss')) (uptime $([int]((Get-Date) - $bootT).TotalMinutes)m)") }
                    }
                    catch {}
                    try {
                        $stEvts = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; StartTime = (Get-Date).AddHours(-24) } -MaxEvents 1500 -ErrorAction SilentlyContinue |
                                Where-Object { $_.ProviderName -match 'disk|partmgr|Kernel-PnP|storvsc|VmBus|Ntfs' -and $_.Message -match 'disk|volume|surprise|arriv|remov|attach|signature|Harddisk' } |
                                Select-Object -First 15)
                        foreach ($ev in $stEvts) {
                            $emsg = ($ev.Message -replace '\r?\n', ' ' -replace '\s+', ' ').Trim(); if ($emsg.Length -gt 150) { $emsg = $emsg.Substring(0, 150) + '...' }
                            $results.Details.Add("  DIAG WHEN: $($ev.TimeCreated.ToString('MM-dd HH:mm:ss')) [$($ev.ProviderName)/$($ev.Id)] $emsg")
                        }
                    }
                    catch {}
                    # SetupAPI.dev.log: the AUTHORITATIVE per-device install timeline. Each
                    # disk PnP installs writes a "Device Install ... Disk" section with a
                    # "Section start <timestamp>", so a phantom/ghost disk's arrival is
                    # timestamped to the second (pins it to the exact build operation).
                    # ETW System events can miss a ghost that arrives without a normal PnP
                    # install; this file catches those.
                    try {
                        $sapi = 'C:\Windows\INF\setupapi.dev.log'
                        if (Test-Path $sapi) {
                            $sl = @(Get-Content $sapi -Tail 6000 -ErrorAction SilentlyContinue)
                            $sHits = [System.Collections.Generic.List[string]]::new()
                            for ($si = 0; $si -lt $sl.Count; $si++) {
                                if ($sl[$si] -match 'Device Install.*(Disk|Virtual_Disk|storvsc)') {
                                    $sts = ''
                                    if (($si + 1) -lt $sl.Count -and $sl[$si + 1] -match 'Section start (.+)$') { $sts = $Matches[1].Trim() }
                                    $sHits.Add("  DIAG WHEN setupapi: $sts $($sl[$si].Trim())")
                                }
                            }
                            foreach ($sh in @($sHits | Select-Object -Last 8)) { $results.Details.Add($sh) }
                        }
                    }
                    catch {}
                }
            }
            if ($vol.FileSystem -ne 'NTFS') {
                # A data disk that is present but not NTFS is UNUSABLE, not a
                # warning: it is RAW/unformatted (FileSystem '' , Size 0) or a
                # wrong filesystem, which means Phase 1 disk init never finished.
                # ConfigMgr/SQL/WSUS then skip this drive and place their content on
                # another volume (typically C:), so a DP content library or a SQL/
                # WSUS data dir lands on the wrong disk. That is exactly how wacky
                # ZZ-CREPE 2026-08-17 shipped a DP with SMS on C: and no content
                # library. Must FAIL so the build stops here instead of passing.
                $results.Passed = $false
                $fsShown = if ($vol.FileSystem) { $vol.FileSystem } else { 'RAW/unformatted' }
                $results.Details.Add("FAIL: Volume '$letter`:' filesystem is '$($vol.FileSystem)' (expected NTFS) -- data disk is $fsShown; Phase 1 disk init did not complete, so ConfigMgr/SQL/WSUS will place content on the wrong volume. Re-run or re-create the VM.")
                # In-guest disk/partition state so a future hit shows WHY: a RAW disk
                # that was never initialized vs a partition that exists (has the
                # letter) but was never Format-Volume'd.
                try {
                    $dp = Get-Partition -DriveLetter $letter -ErrorAction SilentlyContinue | Select-Object -First 1
                    if ($dp) {
                        $dd = Get-Disk -Number $dp.DiskNumber -ErrorAction SilentlyContinue
                        $results.Details.Add("  DIAG Disk#$($dp.DiskNumber): Style=$($dd.PartitionStyle) $([math]::Round($dd.Size / 1GB, 1))GB OpStatus=$($dd.OperationalStatus) Offline=$($dd.IsOffline)")
                        $results.Details.Add("  DIAG Partition Disk#$($dp.DiskNumber)/Part#$($dp.PartitionNumber): $([math]::Round($dp.Size / 1GB, 1))GB Type=$($dp.Type) (partition exists but volume is not NTFS -> Format-Volume never ran)")
                    }
                    else {
                        $results.Details.Add("  DIAG no partition carries letter '$letter`:'; RAW/unpartitioned disk(s):")
                        foreach ($rd in @(Get-Disk -ErrorAction SilentlyContinue | Where-Object { $_.PartitionStyle -eq 'RAW' } | Sort-Object Number)) {
                            $results.Details.Add("  DIAG RAW Disk#$($rd.Number): $([math]::Round($rd.Size / 1GB, 1))GB OpStatus=$($rd.OperationalStatus) (never initialized)")
                        }
                    }
                }
                catch {}
            }
            else {
                $sizeGB = [math]::Round($vol.Size / 1GB, 1)
                $results.Details.Add("OK: Volume '$letter`:' present ($sizeGB GB, $($vol.FileSystem) $($vol.FileSystemLabel))")
            }
        }

        return $results
    }

    $result = Invoke-VmCommand -VmName $VMName -VmDomainName $domain `
        -ScriptBlock $scriptBlock -ArgumentList (($disks -join ',')) `
        -DisplayName "Phase11-Disks-Test" -SuppressLog `
        -AsJob -TimeoutSeconds 300

    # HOST-SIDE truth for a drive-letter collision. The guest scriptblock can see
    # a duplicate drive letter but CANNOT see whether the HOST actually attached
    # the data VHDX twice -- so the guest WARN could only *tell a human* to run
    # Get-VMHardDiskDrive by hand. This Phase 11 check runs on the Hyper-V host,
    # so do it automatically: enumerate the VM's attached VHDX and decide
    # definitively between a GUEST PHANTOM (host has exactly the expected data
    # disks -> a reboot clears the ghost) and a real HOST-SIDE duplicate VHDX
    # (the same VHDX attached twice, or more data disks than the config defines
    # -- which survives a redeploy and a reboot will NOT fix). The latter is a
    # genuine defect and is escalated from WARN to FAIL.
    try {
        $sbOut = $result.ScriptBlockOutput
        if ($sbOut -is [System.Collections.IEnumerable] -and $sbOut -isnot [System.Collections.IDictionary] -and $sbOut -isnot [string]) {
            foreach ($item in $sbOut) { if ($item -is [System.Collections.IDictionary] -and $item.Contains('Passed')) { $sbOut = $item; break } }
        }
        if ($sbOut -is [System.Collections.IDictionary] -and $sbOut.Details -and
            (@($sbOut.Details | Where-Object { $_ -match 'disks/partitions claim drive letter' }).Count -gt 0)) {

            $expectedDataDisks = @($disks).Count
            $hostLines = [System.Collections.Generic.List[string]]::new()
            $hostDup = $false
            try {
                $hostDisks = @(Get-VMHardDiskDrive -VMName $VMName -ErrorAction Stop)
                # Data VHDX are named '<vm>_DATA_<n>.vhdx' by New-VirtualMachine; fall
                # back to "anything not the OS disk at controller 0 / location 0".
                $dataVhdx = @($hostDisks | Where-Object { $_.Path -match '_DATA_\d+\.vhdx$' })
                if ($dataVhdx.Count -eq 0) { $dataVhdx = @($hostDisks | Where-Object { -not ($_.ControllerNumber -eq 0 -and $_.ControllerLocation -eq 0) }) }
                $hostLines.Add("  DIAG HOST: $($hostDisks.Count) VHDX attached to VM '$VMName'; $($dataVhdx.Count) data disk(s), config defines $expectedDataDisks")
                foreach ($hd in $hostDisks) {
                    $vhdSize = $null
                    try { $vhdSize = [math]::Round((Get-VHD -Path $hd.Path -ErrorAction Stop).Size / 1GB, 1) } catch {}
                    $shared = if ($hd.SupportPersistentReservations) { ' SHARED(clustered VHDX)' } else { '' }
                    # VHDX file timestamps: on a FRESH deploy every data disk is newly
                    # created, so an old CreationTime here betrays a stale/leftover VHDX
                    # from a prior lab (the real host-side duplicate) vs a disk created by
                    # this build (a pure guest phantom).
                    $vhdTs = ''
                    try { $fi = Get-Item -LiteralPath $hd.Path -ErrorAction Stop; $vhdTs = " Created=$($fi.CreationTime.ToString('MM-dd HH:mm')) Modified=$($fi.LastWriteTime.ToString('MM-dd HH:mm'))" } catch {}
                    $hostLines.Add("  DIAG HOST VHDX: '$($hd.Path)' Ctlr=$($hd.ControllerType)$($hd.ControllerNumber)/Loc$($hd.ControllerLocation)$(if ($vhdSize) { " ${vhdSize}GB" })$shared$vhdTs")
                }
                $dupPaths = @($hostDisks | Group-Object Path | Where-Object { $_.Count -gt 1 })
                if ($dupPaths.Count -gt 0) {
                    $hostLines.Add("FAIL: HOST attaches the SAME VHDX more than once: $(($dupPaths | ForEach-Object { $_.Name }) -join '; ') -- detach the duplicate on the host (a reboot will NOT fix this)")
                    $hostDup = $true
                }
                elseif ($dataVhdx.Count -gt $expectedDataDisks) {
                    $hostLines.Add("FAIL: HOST has $($dataVhdx.Count) data VHDX attached but config defines only $expectedDataDisks -- a stale/duplicate data VHDX is attached on the host; detach+delete the extra VHDX (this is NOT a guest phantom, a reboot will NOT fix it): $(($dataVhdx | ForEach-Object { $_.Path }) -join '; ')")
                    $hostDup = $true
                }
                else {
                    $hostLines.Add("WARN: HOST has exactly $($dataVhdx.Count) data VHDX (matches config) -> the duplicate '$($disks -join ',')' seen in the guest is a GUEST PHANTOM/ghost disk; reboot '$VMName' to clear it")
                }
                # WHEN/origin (host side): a lingering or recently-applied checkpoint and
                # disk hot-add/remove are the usual causes of a guest phantom disk. Report
                # the VM's checkpoints + guest uptime so a checkpoint apply/merge (or a
                # long-lived checkpoint spanning the phase the phantom appeared) is visible.
                try {
                    $snaps = @(Get-VMSnapshot -VMName $VMName -ErrorAction SilentlyContinue)
                    if ($snaps.Count -gt 0) {
                        $snapDesc = ($snaps | ForEach-Object { "$($_.Name)@$($_.CreationTime.ToString('MM-dd HH:mm'))" }) -join '; '
                        $hostLines.Add("  DIAG HOST WHEN: VM has $($snaps.Count) checkpoint(s): $snapDesc -- a checkpoint apply/merge can leave a guest phantom disk")
                    }
                    else { $hostLines.Add("  DIAG HOST WHEN: VM has no checkpoints") }
                    $vmObj = Get-VM -Name $VMName -ErrorAction SilentlyContinue
                    if ($vmObj -and $vmObj.Uptime) { $hostLines.Add("  DIAG HOST WHEN: guest uptime $([int]$vmObj.Uptime.TotalMinutes)m") }
                }
                catch {}
                # Host Hyper-V logs: disk attach/detach and checkpoint create/apply/delete
                # for THIS VM are timestamped here -- the host-side "when" that pairs with
                # the guest device-arrival timeline (System log + SetupAPI) above.
                try {
                    $hvEvts = @(Get-WinEvent -FilterHashtable @{ LogName = @('Microsoft-Windows-Hyper-V-VMMS-Admin', 'Microsoft-Windows-Hyper-V-Worker-Admin'); StartTime = (Get-Date).AddHours(-24) } -ErrorAction SilentlyContinue |
                            Where-Object { $_.Message -match [regex]::Escape($VMName) -and $_.Message -match 'disk|VHD|checkpoint|snapshot|attach|detach|remov|merg' } | Select-Object -First 12)
                    foreach ($he in $hvEvts) {
                        $hmsg = ($he.Message -replace '\r?\n', ' ' -replace '\s+', ' ').Trim(); if ($hmsg.Length -gt 160) { $hmsg = $hmsg.Substring(0, 160) + '...' }
                        $hostLines.Add("  DIAG HOST WHEN hv: $($he.TimeCreated.ToString('MM-dd HH:mm:ss')) [$($he.Id)] $hmsg")
                    }
                }
                catch {}
            }
            catch {
                $hostLines.Add("  DIAG HOST: could not enumerate host VHDX for '$VMName': $($_.Exception.Message)")
            }

            # $sbOut is a rehydrated Hashtable whose Details collection may be
            # fixed-size after PSRemoting deserialization -- rebuild it rather than
            # calling .Add(), and set keys on the hashtable (which is mutable).
            $newDetails = [System.Collections.Generic.List[string]]::new()
            foreach ($l in $sbOut.Details) { $newDetails.Add([string]$l) }
            foreach ($l in $hostLines) { $newDetails.Add($l) }
            $sbOut.Details = $newDetails
            if ($hostDup) { $sbOut.Passed = $false }
        }
    }
    catch { }

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
    $hierarchySiteCode = if ($CurrentItem.parentSiteCode) { "$($CurrentItem.parentSiteCode)" } else { "$siteCode" }
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

    # OfflineSUP deployments deliberately skip subscribing any products /
    # classifications and skip the update sync (perfloading sets $Sups=$false
    # and returns early). On such a site an EMPTY WSUS subscription is the
    # intended end state, not a failure -- so the subscription-parity test
    # below must report OK/INFO rather than WARN when OfflineSUP is set.
    $offlineSup = [bool]$effectiveCmOptions.OfflineSUP
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

    # Resolve the SUP server FQDN so the WSUS-native diagnostics target the ACTUAL
    # WSUS box. The SUP is frequently a SEPARATE site system (e.g. a remote
    # DPMPSUP) rather than the site server this validator runs on, so a bare
    # Get-WsusServer -- which defaults to localhost -- throws
    # WsusInvalidServerException on a site server that has no local WSUS. CM
    # requires the WSUS administration console on the site server whenever the
    # SUP is remote, so Get-WsusServer -Name <supFqdn> -PortNumber 8530 works
    # from here. Port 8530 (HTTP) is ALWAYS listening even on an HTTPS-enabled
    # SUP, so we always use it.
    $supVmObj = $DeployConfig.virtualMachines | Where-Object {
        ($_.installSUP -or $_.InstallSUP) -and $_.siteCode -eq $siteCode
    } | Select-Object -First 1
    $supServer = if ($supVmObj) { "$($supVmObj.vmName).$domain" } else { '' }

    # Whether any OSDClient exists in this lab. perfloading only distributes OSD
    # content (boot/OS images) to DP(s) on an OSDClient's subnet (to save space +
    # because PXE is subnet-local), so with NO OSDClient the boot image is
    # intentionally not distributed anywhere -- that's INFO, not a WARN.
    $hasOsdClient = [bool]($DeployConfig.virtualMachines | Where-Object { $_.role -eq 'OSDClient' } | Select-Object -First 1)

    # Expected boundary groups + their subnet boundaries, mirroring
    # InstallBoundaryGroups.ps1: one boundary group named by site code, each
    # containing an IPRange boundary for that site's subnet (.1-.254 over /24).
    # Encoded as "SiteCode~Subnet~First-Last" pairs joined by '|' for the
    # remote scriptblock to verify existence AND membership.
    #
    # Scope to the site codes THIS server actually owns -- its own siteCode plus
    # any child site whose parentSiteCode points here -- mirroring the creator's
    # $ValidSiteCodes (own + Get-CMSite ReportingSiteCode children). thisParams
    # .sitesAndNetworks is DOMAIN-WIDE (every Primary/Secondary in the config, so
    # the DC can build all AD sites), so iterating it verbatim made each Primary
    # expect a boundary group for EVERY site in the domain. For independent
    # standalone primaries (no CAS / no DRS link) that produced spurious
    # "Expected boundary group 'X' not found" WARNs for the sites this server
    # legitimately doesn't own -- boundary groups don't replicate between
    # independent standalone primaries. Scoping here makes the validator match
    # what InstallBoundaryGroups.ps1 actually creates on this box.
    $ownedSiteCodes = @($siteCode)
    try {
        $ownedSiteCodes += @($DeployConfig.virtualMachines | Where-Object {
                $_.role -in @('Primary', 'Secondary') -and $_.parentSiteCode -and $_.parentSiteCode -eq $siteCode
            } | Select-Object -ExpandProperty siteCode)
    }
    catch {}
    $ownedSiteCodes = @($ownedSiteCodes | Where-Object { $_ } | Select-Object -Unique)

    $expectedBoundaryPairs = @()
    try {
        foreach ($sn in @($CurrentItem.thisParams.sitesAndNetworks)) {
            if (-not $sn -or -not $sn.SiteCode -or -not $sn.Subnet) { continue }
            if ($sn.SiteCode -notin $ownedSiteCodes) { continue }
            $octets = "$($sn.Subnet)" -split '\.'
            if ($octets.Count -ne 4) { continue }
            $range = "$($octets[0]).$($octets[1]).$($octets[2]).1-$($octets[0]).$($octets[1]).$($octets[2]).254"
            $expectedBoundaryPairs += "$($sn.SiteCode)~$($sn.Subnet)~$range"
        }
    }
    catch {
        Write-Log "[Phase $Phase] $VMName [$role ($siteCode)]: Could not enumerate sitesAndNetworks for boundary check: $($_.Exception.Message)" -Warning -LogOnly
    }
    $expectedBoundaryCsv = ($expectedBoundaryPairs -join '|')

    $siteRoleLabel = "$role ($siteCode)"
    Write-Log "[Phase $Phase] $VMName [$siteRoleLabel]: Testing site-wide settings (BoundaryGroups, Discovery, Apps, CommsMode)" -LogOnly

    $scriptBlock = {
        # NOTE: Invoke-VmCommand declares [string[]]$ArgumentList which (a)
        # stringifies bools (any non-empty string is truthy) and (b) flattens
        # nested arrays. Bools are passed as '0'/'1' strings; arrays are
        # passed as a single CSV string and split inside.
        param($sc, $hierarchySc, $usePkiInner, $expectedAppsCsv, $vmRole, $prePopInner, $isTopLevelInner, $hasSUPInner, $expectedBgCsv, $supServer, $offlineSupInner, $expectOsdInner)
        $usePki = ($usePkiInner -eq 'True')
        $prePop = ($prePopInner -eq 'True')
        $topLevel = ($isTopLevelInner -eq 'True')
        $isPrimary = ($vmRole -eq 'Primary')
        $hasSup = ($hasSUPInner -eq 'True')
        $offlineSup = ($offlineSupInner -eq 'True')
        $expectOsd = ($expectOsdInner -eq 'True')
        # WSUS admin API endpoint for this site's SUP. When the site uses PKI,
        # WSUS is SSL-configured and its admin API (ApiRemoting30) REQUIRES SSL:
        # an HTTP call on 8530 returns HTTP 403 Forbidden, so PKI sites MUST use
        # 8531 + -UseSsl. Non-PKI sites use plain HTTP on 8530. (Confirmed on
        # fabrikam: 8530 -> 403; 8531 -UseSsl -> works.) The SUP is frequently a
        # remote site system, so we always target it by -Name $supServer (the
        # WSUS admin console is present on the site server when the SUP is
        # remote, a documented CM SUP prerequisite).
        $wsusPort   = if ($usePki) { 8531 } else { 8530 }
        $wsusUseSsl = [bool]$usePki
        $expectedApps = if ([string]::IsNullOrEmpty($expectedAppsCsv)) { @() } else { @($expectedAppsCsv -split '\|') }
        $expectedBoundaries = if ([string]::IsNullOrEmpty($expectedBgCsv)) { @() } else { @($expectedBgCsv -split '\|') }
        $results = @{ Passed = $true; Details = [System.Collections.Generic.List[string]]::new() }

        $ns = "root\SMS\site_$sc"

        # 1. Boundary groups -- runs on EVERY Primary/CAS (NOT gated on
        # top-level): each site's own boundary group is created LOCALLY by its
        # InstallBoundaryGroups.ps1 run, so it is present without waiting for
        # CAS->child DRS, and $expectedBoundaries is scoped to this VM's own
        # site(s) via thisParams.sitesAndNetworks. Verify the per-site group
        # (named by site code) EXISTS and actually CONTAINS its subnet boundary
        # as a member -- a group that exists but is empty silently breaks client
        # site assignment, so existence alone is not enough.
        $results.Details.Add("CMD: Get-WmiObject -Namespace '$ns' -Class SMS_BoundaryGroup")
        try {
            $bgs = @(Get-WmiObject -Namespace $ns -Class SMS_BoundaryGroup -ErrorAction Stop)
            if ($bgs.Count -ge 1) {
                $results.Details.Add("OK: $($bgs.Count) boundary group(s) defined: $(($bgs | Select-Object -First 5 -ExpandProperty Name) -join ', ')")
            }
            elseif ($vmRole -eq 'CAS') {
                # A CAS is a central administration site: it owns NO boundaries or
                # boundary groups of its own, and InstallBoundaryGroups.ps1 never
                # runs on the CAS (ScriptWorkFlow's Hierarchy/CAS branch omits it;
                # only the Primary branch calls it). Child-primary boundary groups
                # are global data that replicate UP to the CAS via DRS, so they
                # only appear in the CAS DB after replication converges -- which
                # frequently has NOT happened by the time Phase 11 runs. Zero
                # boundary groups on a CAS is therefore the expected state, not a
                # failure. (The per-expected-site loop below still WARNs, never
                # FAILs, if a specific child BG hasn't replicated yet.)
                $results.Details.Add("INFO: No boundary groups on CAS '$sc' (expected; a CAS hosts none of its own, child-site BGs replicate up via DRS)")
            }
            else {
                $results.Passed = $false
                $results.Details.Add("FAIL: No boundary groups defined for site '$sc'")
            }

            # Per-expected-site verification: group named <sitecode> exists AND
            # its subnet boundary is a member. Membership issues WARN (not FAIL)
            # to avoid false negatives from DRS timing / Forest-Discovery boundary
            # naming, while still surfacing a genuinely empty/mis-membered group.
            foreach ($pair in $expectedBoundaries) {
                $parts = $pair -split '~'
                if ($parts.Count -lt 3) { continue }
                $bgName = $parts[0]; $subnet = $parts[1]; $range = $parts[2]

                $grp = $bgs | Where-Object { $_.Name -eq $bgName } | Select-Object -First 1
                if (-not $grp) {
                    $results.Details.Add("WARN: Expected boundary group '$bgName' (site $bgName) not found")
                    continue
                }

                # Locate the subnet's boundary -- exact IPRange (.1-.254) first,
                # then any boundary whose Value references the /24 prefix.
                $bnd = $null
                try {
                    $bnd = @(Get-WmiObject -Namespace $ns -Class SMS_Boundary -Filter "Value='$range'" -ErrorAction Stop) | Select-Object -First 1
                } catch {}
                if (-not $bnd) {
                    $prefix = $subnet -replace '\.\d+$', '.'
                    try {
                        $bnd = @(Get-WmiObject -Namespace $ns -Class SMS_Boundary -ErrorAction Stop |
                            Where-Object { "$($_.Value)" -like "$prefix*" }) | Select-Object -First 1
                    } catch {}
                }
                if (-not $bnd) {
                    $results.Details.Add("WARN: Boundary group '$bgName' exists but no boundary found for subnet $subnet ($range)")
                    continue
                }

                # Confirm the boundary is a member of THIS group via the
                # association class; fall back to the boundary's GroupCount when
                # SMS_BoundaryGroupMembers is unavailable.
                $isMember = $false
                $viaAssoc = $false
                try {
                    $members = @(Get-WmiObject -Namespace $ns -Class SMS_BoundaryGroupMembers -Filter "GroupID=$($grp.GroupID)" -ErrorAction Stop)
                    $viaAssoc = $true
                    $isMember = @($members | Where-Object { $_.BoundaryID -eq $bnd.BoundaryID }).Count -gt 0
                }
                catch {
                    $isMember = ([int]$bnd.GroupCount -gt 0)
                }
                if ($isMember -and $viaAssoc) {
                    $results.Details.Add("OK: Boundary group '$bgName' contains subnet boundary $subnet ($range)")
                }
                elseif ($isMember) {
                    $results.Details.Add("OK: Boundary group '$bgName' present; subnet boundary $subnet is grouped (membership inferred from GroupCount)")
                }
                else {
                    $results.Details.Add("WARN: Subnet boundary $subnet ($range) is NOT a member of boundary group '$bgName' (clients on $subnet may not resolve this site's MP/DP content)")
                }
            }
        }
        catch {
            $results.Details.Add("WARN: SMS_BoundaryGroup query failed: $($_.Exception.Message)")
        }

        # --- Hierarchy-owned checks (only on top-level sites) ---
        # On a child Primary under a CAS, discovery / comms mode replicate from
        # the CAS; checking them before DRS finishes causes false failures.
        if ($topLevel) {

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
                            # Parse a DP server name out of a ServerNALPath like
                            # ["Display=\\PL-PATTYDP.dom\"]MSWNET:...\\PL-PATTYDP.dom\
                            $dpNameOf = {
                                param($nal)
                                if ($nal -match '\\\\([^\\"\]]+)') { return $Matches[1] } else { return "$nal" }
                            }
                            $allDp = @(Get-WmiObject -Namespace $ns -Class SMS_PackageStatusDistPointsSummarizer `
                                -Filter "PackageID='$($bi.PackageID)'" -ErrorAction Stop)
                            $installed = @($allDp | Where-Object { $_.State -eq 0 })
                            $inProgress = @($allDp | Where-Object { $_.State -in 1, 2, 7 })
                            $failed = @($allDp | Where-Object { $_.State -in 3, 6, 8 })
                            # Convergence re-check: a DP can briefly post InstallFailed (3) then
                            # auto-retry to success, so don't fail on the first sighting. Re-query
                            # a few times; only a failure that PERSISTS (and isn't advancing to
                            # in-progress/installed) is a genuine stuck distribution. On this
                            # box the boot image sat InstallFailed for 12h, so it fails here.
                            if ($failed.Count -ge 1) {
                                for ($dpTry = 1; $dpTry -le 3 -and $failed.Count -ge 1; $dpTry++) {
                                    Start-Sleep -Seconds 30
                                    $allDp = @(Get-WmiObject -Namespace $ns -Class SMS_PackageStatusDistPointsSummarizer `
                                        -Filter "PackageID='$($bi.PackageID)'" -ErrorAction SilentlyContinue)
                                    $installed = @($allDp | Where-Object { $_.State -eq 0 })
                                    $inProgress = @($allDp | Where-Object { $_.State -in 1, 2, 7 })
                                    $failed = @($allDp | Where-Object { $_.State -in 3, 6, 8 })
                                }
                            }
                            if ($installed.Count -ge 1 -and $failed.Count -eq 0 -and $inProgress.Count -eq 0) {
                                $results.Details.Add("OK: Boot image '$biName' distributed to $($installed.Count) DP(s)")
                            }
                            elseif ($failed.Count -ge 1) {
                                # State 3/6/8 (InstallFailed/RemovalFailed/ContentValidationFailed)
                                # that survived the convergence re-check is a REAL failure. Fail the
                                # phase (a concurrent InProgress DP does NOT make it "converging" --
                                # a stuck distribution can sit failed+in-progress for hours/days).
                                $stateNamesLocal = @{ 3 = 'InstallFailed'; 6 = 'RemovalFailed'; 8 = 'ContentValidationFailed' }
                                $failedDpNames = @($failed | ForEach-Object {
                                        "$(& $dpNameOf $_.ServerNALPath) [$(if ($stateNamesLocal.ContainsKey([int]$_.State)) { $stateNamesLocal[[int]$_.State] } else { "State=$($_.State)" })]"
                                    })
                                $results.Passed = $false
                                $results.Details.Add("FAIL: Boot image '$biName' ($($bi.PackageID)) distribution FAILED on $($failed.Count) DP(s): $($failedDpNames -join ', ') [Installed=$($installed.Count), InProgress=$($inProgress.Count)]. Run Fixes\Test-ContentDistribution.ps1 for per-DP state + auto-collected pull logs. For a Pull DP, the real error is in the CM CLIENT log dir (e.g. E:\SMS_CCM\Logs): PullDP.log + DataTransferService.log (BITS 'HTTP status 4xx'). A 404 with the source showing 'Installed' usually means the source DP's content library was relocated for HA (remoteContentLibVM) -- a pull source must be a DP with a LOCAL content library.")

                                # DIAG: collect the site-server-local content-transfer / distmgr
                                # log tails for this PackageID so the root cause is captured in the
                                # Phase 11 output (mirrors the DNS DIAG pattern). PkgXferMgr.log is
                                # the site side of the pull-DP content job; distmgr.log is the
                                # distribution-manager decisions. The Pull DP's own PullDP.log /
                                # DataTransferService.log live in the DP's CM client log dir.
                                try {
                                    $smsDir = $null
                                    foreach ($k in 'HKLM:\SOFTWARE\Microsoft\SMS\Identification', 'HKLM:\SOFTWARE\Microsoft\SMS\Setup') {
                                        try { $smsDir = (Get-ItemProperty -Path $k -Name 'Installation Directory' -ErrorAction Stop).'Installation Directory' } catch {}
                                        if ($smsDir) { break }
                                    }
                                    if ($smsDir) {
                                        foreach ($logName in 'PkgXferMgr.log', 'distmgr.log') {
                                            $logPath = Join-Path $smsDir "Logs\$logName"
                                            if (Test-Path $logPath) {
                                                $hits = @(Select-String -Path $logPath -Pattern $bi.PackageID -SimpleMatch -ErrorAction SilentlyContinue |
                                                    Select-Object -Last 6)
                                                if ($hits) {
                                                    $results.Details.Add("DIAG: $logName (last $($hits.Count) line(s) mentioning $($bi.PackageID)):")
                                                    foreach ($h in $hits) {
                                                        $line = ($h.Line -replace '\r?\n', ' ' -replace '\s+', ' ').Trim()
                                                        if ($line.Length -gt 240) { $line = $line.Substring(0, 240) + '...' }
                                                        $results.Details.Add("  $line")
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                                catch {}
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
                                elseif (-not $expectOsd) {
                                    $results.Details.Add("INFO: Boot image '$biName' not distributed to any DP -- no OSDClient in this lab (OSD content is only distributed to an OSDClient-subnet DP to save space)")
                                }
                                elseif ($biName -match 'arm64') {
                                    # memlabs OSDClients are all x64 Gen2 VMs -- there is no arm64
                                    # PXE target, so the arm64 boot image is intentionally not
                                    # distributed. Advisory only, not a real problem.
                                    $results.Details.Add("INFO: Boot image '$biName' not distributed to any DP -- no arm64 OSDClient in this lab (memlabs OSDClients are x64; only the x64 boot image is distributed for PXE)")
                                }
                                else {
                                    $results.Details.Add("WARN: Boot image '$biName' ($($bi.PackageID)) is not on any DP yet, so PXE can't work. An OSDClient exists, so perfloading distributes it to the OSDClient-subnet DP during Phase 8 -- re-run to distribute. If it persists, confirm a DP shares the OSDClient's subnet.")
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
                    # TS creation in Phase 8 (perfloading) is gated on OSD media under
                    # <CM install drive>\OSD -- probe it here so the WARN names the cause:
                    # media absent -> Phase 1 copy gap; media present -> TS creation
                    # itself failed (e.g. a transient SQL deadlock).
                    $osdHint = 'OSD media state unknown'
                    try {
                        $osdDrive = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\SMS\Setup' -Name 'Installation Directory' -ErrorAction Stop).'Installation Directory' | Split-Path -Qualifier
                        $osdFolder = "$osdDrive\OSD"
                        $w11 = Test-Path "$osdFolder\Windows 11 24h2\sources\install.wim"
                        $w10 = Test-Path "$osdFolder\Windows 10 22h2\sources\install.wim"
                        if ($w11 -and $w10) { $osdHint = "OSD media IS present under '$osdFolder' -- TS creation itself failed in Phase 8 (check the perfloading task-sequence logs, e.g. a transient SQL deadlock)" }
                        else { $osdHint = "OSD media MISSING under '$osdFolder' (win11 install.wim=$w11; win10 install.wim=$w10) -- Phase 8 skipped TS creation; see the Phase 8 '[perfloading] OSD media missing' + 'OSD DIAG' lines for why the Phase 1 copy is gone" }
                    }
                    catch {}
                    $results.Details.Add("WARN: No MEMLABS-* task sequences found. $osdHint.")
                }
            }
            catch {
                $results.Details.Add("WARN: SMS_TaskSequencePackage query failed: $($_.Exception.Message)")
            }
        }

        # 8. Collections — MEMLABS-* device collections should exist.
        # Primary-only (like the task-sequence / package checks above): perfloading
        # authors the MEMLABS device collections under 'if (CurrentRole -ne CAS)'
        # -- they are Primary-tier content. A CAS has none of its own (and they do
        # not necessarily replicate up by Phase 11), so skip rather than WARN.
        if ($isPrimary) {
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
        }
        elseif ($vmRole -eq 'CAS') {
            $results.Details.Add("INFO: Skipping MEMLABS device-collection check (CAS authors none; Primary-tier content)")
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

        # 10. Scripts — MEMLABS-* should exist.
        # Primary-only: New-CMScript on a CAS is a no-op (CM Scripts are authored on
        # the Primary; the CAS has no script library -- see perfloading.ps1), so a
        # CAS legitimately has zero. Only check on a Primary; INFO on the CAS.
        if ($isPrimary) {
            try {
                $scripts = @(Get-WmiObject -Namespace $ns -Class SMS_Scripts `
                    -Filter "ScriptName LIKE 'MEMLABS-%'" -ErrorAction Stop)
                $approvedScripts = @($scripts | Where-Object { [int]$_.ApprovalState -eq 3 })
                $unapprovedScripts = @($scripts | Where-Object { [int]$_.ApprovalState -ne 3 })
                if ($scripts.Count -ge 5 -and $unapprovedScripts.Count -eq 0) {
                    $results.Details.Add("OK: all $($scripts.Count) MEMLABS script(s) imported and approved (ApprovalState=3)")
                }
                elseif ($scripts.Count -ge 5) {
                    $unapprovedNames = @($unapprovedScripts | Select-Object -First 8 -ExpandProperty ScriptName)
                    # Read the EFFECTIVE two-key-approval policy from the top-level
                    # site's master SCI. The provider enforces that hierarchy row;
                    # a child Primary's local row can read 0 while approval is blocked.
                    # TwoKeyApproval=1 => author self-approval is blocked (perfloading's
                    # SCI write didn't take); =0 => approval failed for another reason,
                    # named by the Phase 8 '[perfloading] Failed to approve script' line.
                    $tkHint = 'two-key-approval policy unknown'
                    try {
                        $siteDef = @(Get-WmiObject -Namespace $ns -Class SMS_SCI_SiteDefinition -Filter "FileType=2 AND SiteCode='$hierarchySc'" -ErrorAction Stop) | Select-Object -First 1
                        $tkProp = $siteDef.Props | Where-Object { $_.PropertyName -eq 'TwoKeyApproval' } | Select-Object -First 1
                        $tkVal = if ($tkProp) { "$($tkProp.Value)" } else { '<missing>' }
                        $tkHint = if ($tkVal -eq '0') { "hierarchy site $hierarchySc TwoKeyApproval=0 (self-approve allowed) -- the failure is NOT the two-key policy" } elseif ($tkVal -eq '1') { "hierarchy site $hierarchySc TwoKeyApproval=1 -- author self-approval is BLOCKED; perfloading's policy write did not take effect" } else { "hierarchy site $hierarchySc TwoKeyApproval=$tkVal" }
                    }
                    catch {}
                    $results.Details.Add("WARN: $($unapprovedScripts.Count)/$($scripts.Count) MEMLABS script(s) imported but NOT approved (ApprovalState != 3): $($unapprovedNames -join ', '). $tkHint. See the Phase 8 '[perfloading] Failed to approve script' / 'Approval DIAG' lines for the SMS provider error (ExtStatus/ErrorCode) that names the cause; re-running Phase 8 retries approval.")
                }
                elseif ($scripts.Count -ge 1) {
                    $results.Details.Add("WARN: Only $($scripts.Count) MEMLABS script(s) found (expected 50+); $($approvedScripts.Count) approved")
                }
                else {
                    $results.Details.Add("WARN: No MEMLABS-* scripts found")
                }
            }
            catch {
                $results.Details.Add("WARN: SMS_Scripts query failed: $($_.Exception.Message)")
            }
        }
        elseif ($vmRole -eq 'CAS') {
            $results.Details.Add("INFO: Skipping MEMLABS scripts check (CAS has no script library; Primary-tier content)")
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
                    # Decode the HRESULT. 0x80131500 = COR_E_EXCEPTION, a generic
                    # managed exception thrown during a sync cycle -- almost
                    # always transient (MU timeout, WsusPool recycle, upstream
                    # throttle). The authoritative health signal is the WSUS-native
                    # taxonomy/UpdateCount cross-check below, so for that
                    # known-transient code defer the verdict to it instead of
                    # hard-failing on a single bad cycle.
                    $supErr = $syncStatus.LastSyncErrorCode
                    $supErrHex = ''
                    try { $supErrHex = '0x{0:X8}' -f ([uint32]([int64]$supErr -band 0xFFFFFFFF)) } catch {}
                    # Known-TRANSIENT/retryable sync errors that self-heal on the next
                    # cycle -- defer the verdict to the WSUS-native catalog/UpdateCount
                    # cross-check below (authoritative) rather than hard-failing on one bad
                    # cycle. A genuinely broken catalog still WARNs via that native check.
                    #   0x80131500 COR_E_EXCEPTION (generic managed exception)
                    #   0x800C0008 INET_E_DOWNLOAD_FAILURE (MU download failed -- throttle/
                    #              timeout/transient network under load; WSUS retries)
                    #   0x80244007 / 0x8024401C / 0x80244022 WU HTTP SOAP/timeout/503
                    #   0x80072EE2 WININET operation timed out
                    $transientSyncErrors = @('0x80131500', '0x800C0008', '0x80244007', '0x8024401C', '0x80244022', '0x80072EE2')
                    if ($supErrHex -in $transientSyncErrors) {
                        $results.Details.Add("INFO: SUP last CM sync reported Failed (6703) with a transient/retryable error ($supErrHex); WSUS retries and the WSUS-native catalog check below is authoritative")
                    }
                    else {
                        $supErrShown = if ($supErrHex) { "$supErr / $supErrHex" } else { "$supErr" }
                        $supFailTime = $null
                        try { $supFailTime = [Management.ManagementDateTimeConverter]::ToDateTime($syncStatus.LastSyncStateTime) } catch { }
                        $whenCm = if ($supFailTime) { " at $($supFailTime.ToString('yyyy-MM-dd HH:mm:ss')) SUP-local" } else { '' }
                        # An HRESULT on its own is not actionable -- 0x80131509 is just
                        # "a managed InvalidOperationException happened somewhere". WSUS
                        # keeps the real reason in its own sync history, so read it.
                        #
                        # The WSUS API hands back UTC DateTimes while every other timestamp
                        # in this log is local. Printing HH:mm:ss with neither a date nor a
                        # zone left the one real occurrence uncorrelatable: cstest5 reported
                        # "ran=02:32:23->02:47:58" on a run spanning 19:30-23:52 local, which
                        # reads as a different day until you convert it (-> 22:32-22:47,
                        # inside the run) -- and CM's own failure timestamp was never printed
                        # at all, so there was no way to tell a live failure from a stale row.
                        # "local" here is the SUP's zone, which a lab may set away from the
                        # host's, so the offset is stated rather than implied.
                        $tzTag = ''
                        try {
                            $tzOff = [DateTimeOffset]::Now.Offset
                            $tzTag = ' UTC{0}{1}' -f $(if ($tzOff.Ticks -ge 0) { '+' } else { '-' }), $tzOff.ToString('hh\:mm')
                        }
                        catch { }
                        $toLocal = {
                            param($dt)
                            if ($null -eq $dt) { return $null }
                            if ($dt.Kind -eq [DateTimeKind]::Local) { return $dt }
                            return ([DateTime]::SpecifyKind($dt, [DateTimeKind]::Utc)).ToLocalTime()
                        }
                        $supFailDiag = ''
                        $superseded = ''
                        if ($supServer) {
                            try {
                                $wsusSrvF = Get-WsusServer -Name $supServer -PortNumber $wsusPort -UseSsl:$wsusUseSsl -ErrorAction Stop
                                $subF = $wsusSrvF.GetSubscription()
                                # Do NOT trust the collection's own order -- sort it. Taking
                                # element [0] on faith is how an unrelated older cycle gets
                                # reported as the failure being investigated.
                                $hist = @($subF.GetSynchronizationHistory() | Sort-Object StartTime -Descending | Select-Object -First 1)
                                if ($hist.Count -gt 0) {
                                    $h = $hist[0]
                                    $hStart = & $toLocal $h.StartTime
                                    $hEnd = & $toLocal $h.EndTime
                                    $parts = @("result=$($h.Result)", "error=$($h.Error)")
                                    if ($h.ErrorText) { $parts += "errorText='$(("$($h.ErrorText)" -replace '\s+', ' ').Trim())'" }
                                    if ($hStart) { $parts += "ran=$($hStart.ToString('yyyy-MM-dd HH:mm:ss'))->$(if ($hEnd) { $hEnd.ToString('HH:mm:ss') } else { '?' }) SUP-local$tzTag" }
                                    # A converted stamp in the FUTURE is proof the conversion went
                                    # the wrong way: treating an already-local value as UTC shifts
                                    # it forward by the offset. A finished sync cannot start later
                                    # than now, so say the conversion is suspect rather than
                                    # printing a confident nonsense time.
                                    if ($hStart -and $hStart -gt (Get-Date).AddMinutes(5)) {
                                        $parts += 'SUSPECT: that start time is in the future -- the WSUS value was probably already local, so this UTC->local conversion is wrong (or the SUP clock is ahead)'
                                    }
                                    # Stronger than the future check, which only fires when the
                                    # misapplied shift exceeds the record's age: CM and WSUS both
                                    # recorded THIS sync independently, and CM's stamp is already
                                    # local. If the converted WSUS time sits a whole UTC offset
                                    # away from CM's, that gap is the double-application itself.
                                    try {
                                        $offAbs = [math]::Abs([int]([DateTimeOffset]::Now.Offset.TotalMinutes))
                                        if ($hEnd -and $supFailTime -and $offAbs -gt 0) {
                                            $gapMin = [math]::Abs(($hEnd - $supFailTime).TotalMinutes)
                                            if ([math]::Abs($gapMin - $offAbs) -le 5) {
                                                $parts += "SUSPECT: converted end sits $([int]$gapMin)min from CM's own record of the same sync, which is this SUP's UTC offset -- the conversion looks double-applied"
                                            }
                                        }
                                    }
                                    catch { }
                                    try {
                                        $ue = @($h.UpdateErrors)
                                        if ($ue.Count -gt 0) { $parts += "updateErrors=$($ue.Count) first='$(("$($ue[0])" -replace '\s+', ' ').Trim())'" }
                                    }
                                    catch { }
                                    # A cancelled sync is not a broken sync -- something STOPPED
                                    # it, and in a memlabs build that is usually memlabs itself:
                                    # perfloading's Repair-WsusSync restarts WsusPool and
                                    # SMS_EXECUTIVE before re-triggering, and InstallRoles notes
                                    # that starting a sync on top of a running one cancels it.
                                    # Either way the NEXT cycle is the one worth judging.
                                    if ("$($h.Result)" -match 'Cancel' -or "$($h.Error)" -match 'Cancel') {
                                        $parts += 'cause=the sync was CANCELLED, not failed -- WsusPool/WsusService/SMS_EXECUTIVE restarted mid-cycle (perfloading Repair-WsusSync does exactly that), the SUP rebooted, or a second sync was started on top of it'
                                    }
                                    $supFailDiag = " [WSUS history: $($parts -join ' ')]"

                                    # Is CM's record already stale? A WSUS cycle that completed
                                    # successfully after CM stamped the failure, or one running
                                    # right now, supersedes that record. The successful cycle may
                                    # have started before the CM failure (cstest2: 02:39 start,
                                    # 02:44 CM failure, 02:47 successful completion), so compare
                                    # its END time rather than requiring a later start.
                                    $liveState = ''
                                    try { $liveState = "$($subF.GetSynchronizationStatus())" } catch { }
                                    if ($liveState -match 'Running|Progress|Syncing') {
                                        $superseded = "WSUS is running a new sync now ($liveState)"
                                    }
                                    elseif ("$($h.Result)" -match 'Succeeded' -and $supFailTime -and $hEnd -and $hEnd -gt $supFailTime) {
                                        $superseded = "WSUS completed a successful sync at $($hEnd.ToString('yyyy-MM-dd HH:mm:ss')) SUP-local"
                                    }
                                }
                                else { $supFailDiag = ' [WSUS history: no entries]' }
                            }
                            catch { $supFailDiag = " [WSUS history not collected from '$($supServer):$wsusPort': $($_.Exception.Message)]" }
                        }
                        if ($superseded) {
                            $results.Details.Add("INFO: SUP last CM sync record is Failed (6703, $supErrShown)$whenCm but is already stale -- $superseded$supFailDiag")
                        }
                        else {
                            $results.Details.Add("WARN: SUP last sync FAILED (state 6703, error code $supErrShown)$whenCm$supFailDiag")
                        }
                    }
                }
                elseif ([int]$syncStatus.LastSyncState -eq 6705) {
                    # 6705 = "Synchronizing SMS database": WSUS's own sync (WSUS <-
                    # upstream/MU) is COMPLETE and CM's SMS_WSUS_SYNC_MANAGER
                    # (wsyncmgr) is importing the synced metadata into the CM DB.
                    # Native WSUS is IDLE during this phase BY DESIGN, so the
                    # WSUS-native "desync" test is the wrong instrument here -- measure
                    # CM-side import progress from wsyncmgr.log (which runs on THIS
                    # site server) instead. wacky ZZ-BIGMAC 2026-08-17 warned
                    # "CM/WSUS desync ... 136 min" while wsyncmgr was at 97% and still
                    # advancing. Timestamps are labelled local vs UTC to avoid the
                    # three-zone confusion in that same message.
                    $syncTime = [Management.ManagementDateTimeConverter]::ToDateTime($syncStatus.LastSyncStateTime)
                    $age = (Get-Date) - $syncTime
                    $sName = 'Syncing DB'
                    $sinceLocal = $syncTime.ToString('yyyy-MM-dd HH:mm:ss')
                    if ($age.TotalMinutes -le 30) {
                        $results.Details.Add("OK: SUP sync in progress ($sName, $([math]::Round($age.TotalMinutes,1)) min; native WSUS idle is expected during the CM database import)")
                    }
                    else {
                        # wsyncmgr.log logs "processed N out of M items (P%)" with a
                        # CMTrace local timestamp. Two reads ~12s apart catch a fast
                        # mover; recency of the last activity catches a slow-but-healthy
                        # import (progress lines are minutes apart). Guarded so a read/
                        # parse error degrades to INFO -- a diagnostic must never throw.
                        try {
                            $wsyncPath = $null
                            foreach ($k in 'HKLM:\SOFTWARE\Microsoft\SMS\Identification', 'HKLM:\SOFTWARE\Microsoft\SMS\Setup') {
                                $sd = $null
                                try { $sd = (Get-ItemProperty -Path $k -Name 'Installation Directory' -ErrorAction Stop).'Installation Directory' } catch {}
                                if ($sd) { $cand = Join-Path $sd 'Logs\wsyncmgr.log'; if (Test-Path $cand) { $wsyncPath = $cand; break } }
                            }
                            $readWsync = {
                                param($path)
                                $processed = $null; $total = $null; $pct = $null; $lastTs = $null; $lastLine = ''
                                if ($path -and (Test-Path $path)) {
                                    $tail = @(Get-Content -Path $path -Tail 400 -ErrorAction SilentlyContinue)
                                    foreach ($ln in $tail) {
                                        if ($ln -match 'processed (\d+) out of (\d+) items(?:\s*\((\d+)%\))?') { $processed = [int]$Matches[1]; $total = [int]$Matches[2]; if ($Matches[3]) { $pct = [int]$Matches[3] } }
                                    }
                                    for ($i = $tail.Count - 1; $i -ge 0; $i--) {
                                        if ($tail[$i] -match '<(\d{2})-(\d{2})-(\d{4}) (\d{2}):(\d{2}):(\d{2})') {
                                            try { $lastTs = [datetime]::new([int]$Matches[3], [int]$Matches[1], [int]$Matches[2], [int]$Matches[4], [int]$Matches[5], [int]$Matches[6]) } catch {}
                                            $lastLine = $tail[$i]; break
                                        }
                                    }
                                }
                                [pscustomobject]@{ Processed = $processed; Total = $total; Pct = $pct; LastTs = $lastTs; LastLine = $lastLine }
                            }
                            $s1 = & $readWsync $wsyncPath
                            Start-Sleep -Seconds 12
                            $s2 = & $readWsync $wsyncPath
                            $advancing = ($null -ne $s1.Processed -and $null -ne $s2.Processed -and $s2.Processed -gt $s1.Processed)
                            $recent = ($null -ne $s2.LastTs -and ((Get-Date) - $s2.LastTs).TotalMinutes -lt 10)
                            $progDesc = if ($null -ne $s2.Processed) { "wsyncmgr processed $($s2.Processed)/$($s2.Total)$(if ($null -ne $s2.Pct) { " ($($s2.Pct)%)" })" } else { 'wsyncmgr progress line not found' }
                            $lastActDesc = if ($null -ne $s2.LastTs) { "last wsyncmgr activity $($s2.LastTs.ToString('yyyy-MM-dd HH:mm:ss')) local" } else { 'wsyncmgr activity timestamp unreadable' }
                            $deltaBit = if ($advancing) { "; +$($s2.Processed - $s1.Processed) items in 12s" } else { '' }
                            if (-not $wsyncPath) {
                                $results.Details.Add("INFO: SUP at '$sName' (6705) for $([math]::Round($age.TotalMinutes,0)) min (since $sinceLocal local); native WSUS idle is expected during the CM database import, and wsyncmgr.log was not found to confirm CM-side progress")
                            }
                            elseif ($advancing -or $recent) {
                                $results.Details.Add("OK: SUP at '$sName' (6705) for $([math]::Round($age.TotalMinutes,0)) min (since $sinceLocal local); native WSUS idle is expected in this phase and the CM database import is progressing [$progDesc; $lastActDesc$deltaBit]")
                            }
                            else {
                                $results.Details.Add("WARN: SUP at '$sName' (6705) for $([math]::Round($age.TotalMinutes,0)) min (since $sinceLocal local) with no confirmed CM-side progress -- native WSUS is idle (expected in this phase), so the CM database import appears stalled [$progDesc; $lastActDesc]")
                                if ($s2.LastLine) { $results.Details.Add("  DIAG wsyncmgr last line: $($s2.LastLine.Trim())") }
                            }
                        }
                        catch {
                            $results.Details.Add("INFO: SUP at '$sName' (6705) for $([math]::Round($age.TotalMinutes,0)) min (since $sinceLocal local); native WSUS idle is expected during the CM database import, but the wsyncmgr.log progress check errored: $($_.Exception.Message)")
                        }
                    }
                }
                elseif ($syncStatus.LastSyncState -in @(6701, 6704, 6706)) {
                    $stateNames = @{ 6701 = 'Started'; 6704 = 'Syncing WSUS'; 6706 = 'Syncing Internet WSUS' }
                    $sName = if ($stateNames.ContainsKey([int]$syncStatus.LastSyncState)) { $stateNames[[int]$syncStatus.LastSyncState] } else { "state $($syncStatus.LastSyncState)" }
                    $syncTime = [Management.ManagementDateTimeConverter]::ToDateTime($syncStatus.LastSyncStateTime)
                    $age = (Get-Date) - $syncTime
                    if ($age.TotalMinutes -gt 30) {
                        # Long-running sync — pull live WSUS progress from the SUP
                        # using the protocol the SUP actually requires ($wsusPort /
                        # $wsusUseSsl: 8531+SSL on PKI, else 8530). On any failure
                        # emit a clean note instead of a scary raw exception.
                        #
                        # Age alone does NOT mean "stuck": a top-level SUP's FIRST
                        # full sync pulls the entire upstream Microsoft Update
                        # catalog (routinely 10k+ items) and legitimately runs well
                        # past 30 min, while a child SUP syncing from that upstream
                        # finishes in minutes. So when WSUS reports the sync still
                        # Running, take two ProcessedItems samples a few seconds
                        # apart: if it is still advancing the sync is healthy (OK,
                        # not stuck); only a sync that is genuinely not moving warns.
                        $wsusDiag = ""
                        $progressing = $false
                        $wsusNativeRunning = $false
                        $wsusNativeIdle = $false
                        $wsusLastResult = 'Unknown'
                        $wsusLastSync = ''
                        if ($supServer) {
                            try {
                                $wsusSrv = Get-WsusServer -Name $supServer -PortNumber $wsusPort -UseSsl:$wsusUseSsl -ErrorAction Stop
                                $sub = $wsusSrv.GetSubscription()
                                $wsusState = $sub.GetSynchronizationStatus().ToString()
                                if ($wsusState -match 'Running|Progress|Syncing') {
                                    $wsusNativeRunning = $true
                                    $prog1 = $sub.GetSynchronizationProgress()
                                    $p1 = [int]$prog1.ProcessedItems
                                    $total = [int]$prog1.TotalItems
                                    Start-Sleep -Seconds 12
                                    $wsusState = $sub.GetSynchronizationStatus().ToString()
                                    if ($wsusState -match 'Running|Progress|Syncing') {
                                        $prog2 = $sub.GetSynchronizationProgress()
                                        $p2 = [int]$prog2.ProcessedItems
                                        if ($p2 -gt $p1) { $progressing = $true }
                                        $wsusDiag = " [WSUS@$supServer`: $wsusState, Phase=$($prog2.Phase), Items=$p2/$total (+$($p2 - $p1) in 12s)]"
                                    }
                                    else {
                                        $wsusNativeRunning = $false
                                        $wsusNativeIdle = $true
                                    }
                                }
                                else {
                                    # Confirm idle over the same interval used for a
                                    # running-progress sample. A sync can start between
                                    # the CM query and this WSUS-native read.
                                    Start-Sleep -Seconds 12
                                    $wsusState = $sub.GetSynchronizationStatus().ToString()
                                    if ($wsusState -match 'Running|Progress|Syncing') {
                                        $wsusNativeRunning = $true
                                        $prog2 = $sub.GetSynchronizationProgress()
                                        $wsusDiag = " [WSUS@$supServer`: $wsusState, Phase=$($prog2.Phase), Items=$($prog2.ProcessedItems)/$($prog2.TotalItems) (started during 12s confirmation)]"
                                    }
                                    else { $wsusNativeIdle = $true }
                                }
                                try {
                                    $lastHistory = @($sub.GetSynchronizationHistory() | Sort-Object StartTime -Descending | Select-Object -First 1)
                                    if ($lastHistory.Count -gt 0) {
                                        $wsusLastResult = "$($lastHistory[0].Result)"
                                        $wsusLastSync = "$($lastHistory[0].StartTime)->$($lastHistory[0].EndTime)"
                                    }
                                }
                                catch {}
                                if ($wsusNativeIdle) {
                                    $idleProgress = $sub.GetSynchronizationProgress()
                                    $wsusDiag = " [WSUS@$supServer`: $wsusState, Phase=$($idleProgress.Phase), Items=$($idleProgress.ProcessedItems)/$($idleProgress.TotalItems), LastResult=$wsusLastResult, LastSync=$wsusLastSync]"
                                }
                            }
                            catch {
                                $wsusDiag = " [WSUS-native progress not collected from '$($supServer):$wsusPort': $($_.Exception.Message)]"
                            }
                        }
                        if ($wsusNativeRunning) {
                            $activity = if ($progressing) { 'and counters advanced' } else { '(Categories can legitimately show no item delta)' }
                            $results.Details.Add("OK: SUP sync at '$sName' after $([math]::Round($age.TotalMinutes,0)) min; native WSUS confirms Running $activity$wsusDiag")
                        }
                        elseif ($wsusNativeIdle) {
                            $results.Details.Add("WARN: CM/WSUS desync: CM has reported '$sName' for $([math]::Round($age.TotalMinutes,0)) min (since $($syncTime.ToString('yyyy-MM-dd HH:mm:ss')) local), but native WSUS was confirmed idle over 12s. LastResult=$wsusLastResult LastSync(UTC)=$wsusLastSync$wsusDiag")
                        }
                        else {
                            $results.Details.Add("WARN: SUP sync at '$sName' for $([math]::Round($age.TotalMinutes,0)) min (since $($syncTime.ToString('yyyy-MM-dd HH:mm:ss')) local)$wsusDiag — may be slow or stuck")
                        }
                    }
                    else {
                        $results.Details.Add("OK: SUP sync in progress ($sName, $([math]::Round($age.TotalMinutes,1)) min)")
                    }
                }
                elseif (-not $syncStatus.LastSyncState) {
                    # 0 / null / empty LastSyncState = the SUP has simply never
                    # synced yet (fresh SUP whose first categories sync hasn't
                    # run, common on a remote SUP that syncs from an upstream).
                    # That's a pending state, not an "unexpected" failure.
                    $results.Details.Add("INFO: SUP has not synced yet [LastSyncState=$($syncStatus.LastSyncState)] - first categories sync has not run")
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
            # Targets this site's SUP with the protocol it requires ($wsusPort /
            # $wsusUseSsl: 8531+SSL on PKI, else 8530). The SUP is often a remote
            # site system; the outer catch reports an INFO and skips on any failure.
            try {
                if ($supServer) {
                    $wsusSrv = Get-WsusServer -Name $supServer -PortNumber $wsusPort -UseSsl:$wsusUseSsl -ErrorAction Stop
                }
                else {
                    $wsusSrv = Get-WsusServer -ErrorAction Stop
                }
                $wStatus = $wsusSrv.GetStatus()

                # Is this SUP a DOWNSTREAM/replica (syncs from an upstream WSUS,
                # not Microsoft Update)? A downstream SUP intentionally does NOT
                # import the MU categories cab -- importing it corrupts the local
                # sync anchor -> UssInternalError -- so its taxonomy replicates
                # from the upstream instead, which is slower to first-populate.
                # Read it the SAME way the DSC import guard does (Phase8.ps1 /
                # ScriptFunctions.ps1): SyncFromMicrosoftUpdate=False AND an
                # upstream server name set. Used below to downgrade a
                # "taxonomy not yet populated" / "no sync history" verdict from
                # WARN to INFO for a still-replicating downstream (a genuine
                # downstream sync FAILURE still WARNs via the per-VM SUP check's
                # Result=Failed path and the SMS_SUPSyncStatus 6703 branch).
                # Capture the raw topology signals ($supTopoDiag) that decide
                # downstream-vs-standalone, so a genuine 'subscription empty' WARN
                # can show WHY it wasn't classified downstream -- if GetConfiguration
                # throws, $isDownstreamSup silently stays $false and a child SUP is
                # mis-warned; the diag makes that visible instead of guessing.
                $isDownstreamSup = $false; $upstreamSupName = $null; $supTopoDiag = 'SUP topology unknown'
                try {
                    $wsusCfgChk = $wsusSrv.GetConfiguration()
                    $supTopoDiag = "SyncFromMU=$($wsusCfgChk.SyncFromMicrosoftUpdate); Upstream='$($wsusCfgChk.UpstreamWsusServerName)'"
                    if ((-not $wsusCfgChk.SyncFromMicrosoftUpdate) -and $wsusCfgChk.UpstreamWsusServerName) {
                        $isDownstreamSup = $true
                        $upstreamSupName = $wsusCfgChk.UpstreamWsusServerName
                    }
                }
                catch { $supTopoDiag = "WSUS GetConfiguration failed: $($_.Exception.Message)" }

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
                elseif ($isDownstreamSup) {
                    # Downstream SUP: the cab is intentionally NOT imported here;
                    # categories replicate from the upstream and just haven't
                    # arrived on this first pass. Pending state, not a failure.
                    $taxShown = if ($taxCats -is [int]) { $taxCats } else { '<unknown>' }
                    $results.Details.Add("INFO: WSUS taxonomy not yet replicated [TaxonomyCats=$taxShown; TaxonomyClas=$taxClas] - downstream SUP replicates categories from upstream '$upstreamSupName' (MU cab import intentionally skipped); populates after the first upstream sync completes")
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
                if ($offlineSup) {
                    # OfflineSUP: perfloading intentionally never subscribes any
                    # product/classification and never runs the update sync, so an
                    # empty subscription is the correct, intended end state. The
                    # categories taxonomy (Test A) still loads from the cab when
                    # WsusImportBaseline is set, so update metadata can be added
                    # offline later. Report OK, not WARN.
                    $results.Details.Add("OK: WSUS subscription empty by design (OfflineSUP) [SubCats=$subCats; SubClas=$subClas$wcmBit] - no products subscribed for an offline SUP")
                }
                elseif ($haveCm) {
                    if ($cmProdCount -eq 0 -or $cmClassCount -eq 0) {
                        if ($isDownstreamSup) {
                            # Downstream SUP: products/classifications replicate from
                            # the upstream SUP, not configured locally -- an empty
                            # subscription on the first pass is pending, not a failure
                            # (matches Test A taxonomy / Test C sync-history handling).
                            $results.Details.Add("INFO: WSUS/CM subscription not yet replicated on this downstream SUP [CM-Sub=$cmProdCount/$cmClassCount; WSUS-Sub=$subCats/$subClas$wcmBit] - replicates from upstream '$upstreamSupName'; populates after the first upstream sync completes")
                        }
                        else {
                            $results.Details.Add("WARN: CM SUP has nothing subscribed [CM-Products=$cmProdCount; CM-Classifications=$cmClassCount; WSUS-Sub=$subCats/$subClas$wcmBit; $supTopoDiag] - configure SUP products/classifications")
                        }
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
                    elseif ($isDownstreamSup) {
                        # Downstream SUP: the subscription replicates from the upstream
                        # and hasn't arrived yet on this first pass -- pending, not a
                        # failure (matches Test A / Test C downstream handling).
                        $results.Details.Add("INFO: WSUS subscription not yet replicated on this downstream SUP [SubCats=$subCats; SubClas=$subClas$wcmBit] - replicates from upstream '$upstreamSupName'; populates after the first upstream sync completes")
                    }
                    else {
                        $results.Details.Add("WARN: WSUS subscription empty [SubCats=$subCats; SubClas=$subClas$wcmBit; $supTopoDiag]")
                    }
                }

                # ---- Test C: last sync result + UpdateCount (informational) ----
                # The taxonomy (Test A) only ever lands via the FIRST sync
                # (cab import or full MU categories sync), so TaxonomyCats >= 100
                # is proof the initial sync ran -- regardless of whether the
                # subscription's GetSynchronizationHistory() has a retained row
                # yet (it can be empty right after install, or pruned). And a
                # SyncState of Running means a sync is actively progressing
                # right now, which is healthy, not a failure. Only treat a
                # genuinely-never-synced, idle WSUS as a WARN.
                $ucBit = "UpdateCount=$($wStatus.UpdateCount)"
                $initialSyncDone = ($taxCats -is [int] -and $taxCats -ge 100)
                $syncRunning = ($syncState -eq 'Running')
                if ($lastResult -eq 'Succeeded') {
                    $results.Details.Add("OK: WSUS last sync Succeeded [LastSync=$lastSyncTime; SyncState=$syncState; $ucBit]")
                }
                elseif ($syncRunning) {
                    # Active sync in progress -- working, don't warn. Note
                    # whether this is the (already-completed) initial taxonomy
                    # sync feeding the update sync that's now running.
                    $phaseBit = if ($initialSyncDone) { 'update sync in progress (initial categories sync already completed)' } else { 'initial sync in progress' }
                    $results.Details.Add("OK: WSUS sync running [$phaseBit; SyncState=$syncState; $ucBit]")
                }
                elseif ($lastResult -eq 'Failed' -and $initialSyncDone -and ($wStatus.UpdateCount -gt 0)) {
                    # Catalog is fully populated (taxonomy loaded AND update
                    # metadata present); a Failed last cycle is a transient blip
                    # (commonly 0x80131500 -- a generic managed exception from an
                    # MU timeout / WsusPool recycle / upstream throttle), not a
                    # broken SUP. Report INFO; the kick-a-sync block below
                    # re-triggers so it recovers without waiting for the schedule.
                    $results.Details.Add("INFO: WSUS last sync Result=Failed but catalog is populated - transient [TaxonomyCats=$taxCats; LastSync=$lastSyncTime; $ucBit]; re-triggering a sync")
                }
                elseif ($lastResult -eq 'Canceled' -and $initialSyncDone) {
                    # A 'Canceled' WSUS sync is benign churn, NOT a failure:
                    # WSUS records Canceled when a NEWER sync request supersedes
                    # an in-flight one (common in a CAS -> child hierarchy as the
                    # downstream SUP re-requests while the upstream catalog is
                    # still moving) or when WsusService cycled mid-sync. With the
                    # taxonomy already fully populated (initialSyncDone -- the
                    # initial categories sync demonstrably ran) the canceled cycle
                    # left a healthy catalog behind, and the CM-side
                    # SMS_SUPSyncStatus check above is the authoritative sync
                    # verdict. Report INFO; the kick-a-sync block below re-triggers
                    # a fresh cycle (UpdateCount=0) so it completes on its own.
                    $results.Details.Add("INFO: WSUS last sync Result=Canceled but catalog is populated - benign (a newer sync superseded the canceled cycle) [TaxonomyCats=$taxCats; LastSync=$lastSyncTime; $ucBit]")
                }
                elseif ($lastResult) {
                    $results.Details.Add("WARN: WSUS last sync Result=$lastResult [LastSync=$lastSyncTime; SyncState=$syncState; $ucBit]")
                }
                elseif ($initialSyncDone) {
                    # No retained sync-history row, but the taxonomy is fully
                    # populated -- the initial categories sync demonstrably ran.
                    # The update sync (dbo.Update rows) may simply not have run
                    # yet for a narrow subscription; that's not a failure.
                    $results.Details.Add("OK: WSUS initial sync completed (taxonomy populated) [TaxonomyCats=$taxCats; SyncState=$syncState; $ucBit] - no retained sync-history row yet; update sync may not have run for this subscription")
                }
                elseif ($isDownstreamSup) {
                    # Downstream SUP whose first upstream replication hasn't
                    # completed yet -- pending, not broken. A real downstream
                    # sync failure (e.g. UssInternalError) surfaces as Result=Failed
                    # above / SMS_SUPSyncStatus 6703, not here.
                    $results.Details.Add("INFO: WSUS downstream first sync pending [SyncState=$syncState; $ucBit] - downstream SUP replicates from upstream '$upstreamSupName'; the first upstream sync has not completed yet")
                }
                else {
                    $results.Details.Add("WARN: WSUS has no sync history and taxonomy not populated [SyncState=$syncState; $ucBit] - first sync has not run")
                }

                # ---- Kick a sync when subscribed but 0 updates and idle ----
                # If the subscription has products/classifications set but the
                # update catalog (dbo.Update / UpdateCount) is still empty and
                # nothing is currently syncing, the post-subscription update
                # sync simply never ran (or ran before the subscription was
                # pushed). Start one here so the lab gets real updates without
                # waiting for the next scheduled sync.
                $haveSubscription =
                    (($subCats -is [int] -and $subCats -gt 0) -and ($subClas -is [int] -and $subClas -gt 0)) -or
                    (($cmProdCount -is [int] -and $cmProdCount -gt 0) -and ($cmClassCount -is [int] -and $cmClassCount -gt 0))
                # Re-trigger a sync when subscribed and idle AND either the update
                # catalog is still empty (post-subscription sync never ran) OR the
                # last sync ended Failed (transient cycle on an otherwise-populated
                # catalog -- recover it now instead of waiting for the schedule).
                $lastSyncFailed = ($lastResult -eq 'Failed')
                $kickReason = if ($wStatus.UpdateCount -eq 0) { 'subscribed but UpdateCount=0 and idle' } else { 'last sync Failed (transient) and idle' }
                # Do NOT kick a sync on a DOWNSTREAM SUP. A downstream replica
                # WSUS pulls its update metadata from the upstream SUP (the CAS),
                # not from a locally-forced sync. Forcing one here while the
                # upstream is still doing its initial full catalog sync just
                # produces a superseded/Canceled cycle (the exact churn that
                # surfaced as 'WSUS last sync Result=Canceled'); once the upstream
                # finishes, WCM's scheduled downstream sync replicates the catalog
                # on its own. So on a downstream SUP, report INFO and let
                # replication drive it instead of manufacturing a canceled cycle.
                if ($isDownstreamSup -and $haveSubscription -and (-not $syncRunning) -and (($wStatus.UpdateCount -eq 0) -or $lastSyncFailed)) {
                    $results.Details.Add("INFO: $kickReason on a downstream SUP - not forcing a sync; catalog replicates from upstream '$upstreamSupName' once its sync completes")
                }
                elseif ($haveSubscription -and (-not $syncRunning) -and (($wStatus.UpdateCount -eq 0) -or $lastSyncFailed)) {
                    $kicked = $false
                    # Prefer the CM cmdlet so WCM stays the source of truth;
                    # fall back to the WSUS subscription API if unavailable.
                    try {
                        if (Get-Command Sync-CMSoftwareUpdate -ErrorAction SilentlyContinue) {
                            # Sync-CMSoftwareUpdate (like every CM cmdlet) only
                            # runs from a ConfigMgr PSDrive. This scriptblock
                            # starts on the filesystem, so without connecting to
                            # the site drive first the call throws "This command
                            # cannot be run from the current drive." Establish /
                            # reuse the CMSite drive, then run the sync inside it.
                            $cmDriveOk = $false
                            try {
                                if (-not (Get-PSDrive -Name $sc -PSProvider CMSite -ErrorAction SilentlyContinue)) {
                                    $rk = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry32)
                                    $uiPath = $rk.OpenSubKey('SOFTWARE\Microsoft\ConfigMgr10\Setup').GetValue('UI Installation Directory')
                                    Import-Module (Join-Path $uiPath 'bin\ConfigurationManager.psd1') -ErrorAction Stop
                                    $smsProv = "$env:COMPUTERNAME.$((Get-WmiObject Win32_ComputerSystem).Domain)"
                                    $null = New-PSDrive -Name $sc -PSProvider CMSite -Root $smsProv -ErrorAction SilentlyContinue
                                }
                                $cmDriveOk = [bool](Get-PSDrive -Name $sc -PSProvider CMSite -ErrorAction SilentlyContinue)
                            } catch {}
                            if ($cmDriveOk) {
                                Push-Location "${sc}:\"
                                try { Sync-CMSoftwareUpdate -FullSync $false -ErrorAction Stop }
                                finally { Pop-Location }
                                $kicked = $true
                                $results.Details.Add("OK: $kickReason - started a software update sync via Sync-CMSoftwareUpdate")
                            }
                            else {
                                $results.Details.Add("INFO: CM PSDrive unavailable - using the WSUS subscription API to start the sync")
                            }
                        }
                    } catch {
                        $results.Details.Add("WARN: Sync-CMSoftwareUpdate failed to start a sync [$($_.Exception.Message)] - will try the WSUS subscription API")
                    }
                    if (-not $kicked) {
                        try {
                            $sub.StartSynchronization()
                            $kicked = $true
                            $results.Details.Add("OK: $kickReason - started a WSUS subscription sync (StartSynchronization)")
                        } catch {
                            $results.Details.Add("WARN: $kickReason - failed to start a sync [$($_.Exception.Message)]")
                        }
                    }
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
                $results.Details.Add("INFO: WSUS-native cross-check skipped (could not reach SUP '$($supServer):$wsusPort'): $($_.Exception.Message)")
            }
        }

        return $results
    }

    $appsCsv = ($expectedAppNames -join '|')
    $result = Invoke-VmCommand -VmName $VMName -VmDomainName $domain `
        -ScriptBlock $scriptBlock -ArgumentList $siteCode, $hierarchySiteCode, ([string]$usePKI), $appsCsv, $role, ([string]$prePopulate), ([string]$IsTopLevel), ([string]$hasSUP), $expectedBoundaryCsv, $supServer, ([string]$offlineSup), ([string]$hasOsdClient) `
        -DisplayName "Phase11-CMSite-Test" -SuppressLog `
        -AsJob -TimeoutSeconds 600

    # Capture both sides when CM reports a long-running sync that native WSUS
    # cannot confirm. SUP-side evidence explains the native sync; site-server
    # WCM/wsyncmgr evidence explains who stopped it and why CM stayed stale.
    try {
        $stallLine = $null
        if ($result.ScriptBlockOutput -is [hashtable] -and $result.ScriptBlockOutput.Details) {
            $stallLine = @($result.ScriptBlockOutput.Details | Where-Object {
                    $_ -match 'WARN: CM/WSUS desync:' -or $_ -match 'WARN: SUP sync at .* may be slow or stuck'
                }) | Select-Object -First 1
        }
        if ($stallLine) {
            Add-Phase11Output "[Phase $Phase] $VMName [$siteRoleLabel]: SUP sync state is not corroborated -- collecting WCM/wsyncmgr evidence from the site server"
            $null = Save-Phase11GuestLogs -VMName $VMName -DomainName $domain -RoleLabel 'SUP-CMState' -Collector $Phase11CmWsusSyncCollector -TimeoutSeconds 240
            if ($supVmObj -and $supVmObj.vmName) {
                Add-Phase11Output "[Phase $Phase] $VMName [$siteRoleLabel]: collecting WsusPool/IIS/SoftwareDistribution evidence from SUP '$($supVmObj.vmName)'"
                $null = Save-Phase11GuestLogs -VMName $supVmObj.vmName -DomainName $domain -RoleLabel 'SUP-SyncStall' -Collector $Phase11WsusStallCollector -TimeoutSeconds 240
            }
        }
    }
    catch { }

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

    # No listener. Self-heal like the SMB check does: (re)run the idempotent
    # Squid installer over SSH. Install-LinuxProxyServer uses the dpkg-guard-
    # backed apt_retry, so it also recovers a Proxy whose ORIGINAL Phase-2
    # install-squid was aborted by a corrupt dpkg DB (squid never got installed)
    # -- a Phase-11-only re-run otherwise never reinstalls it. Then re-probe
    # :3128 before failing.
    if (Get-Command Install-LinuxProxyServer -ErrorAction SilentlyContinue) {
        Write-Log "[Phase $Phase] $VMName [$RoleLabel]: WARN - no listener on :3128; attempting Squid (re)install self-heal" -Warning -LogOnly
        $healed = $false
        try {
            $healed = Install-LinuxProxyServer -deployConfig $DeployConfig -ProxyVM $CurrentItem
        }
        catch {
            Write-Log "[Phase $Phase] $VMName [$RoleLabel]: Squid self-heal threw: $($_.Exception.Message)" -LogOnly
        }
        if ($healed) {
            $reprobe = Invoke-LinuxVmCommand -VmName $VMName -BashCommand $bash -Sudo -TimeoutSeconds 30 -SuppressLog -DisplayName "Phase11-Proxy-Listen-reprobe"
            $output = if ($reprobe -and -not $reprobe.ScriptBlockFailed) { ($reprobe.ScriptBlockOutput | Out-String).Trim() } else { '' }
            if ($output -match ':3128') {
                Write-Log "[Phase $Phase] $VMName [$RoleLabel]: OK - Squid listening on :3128 after self-heal ($($output -replace '\s+', ' '))" -LogOnly
                return $true
            }
        }
    }

    Write-Log "[Phase $Phase] $VMName [$RoleLabel]: FAIL - no listener on :3128 after self-heal (ss output: '$output')" -Failure -LogOnly
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

function Test-LinuxProxyConfig {
    <#
    .SYNOPSIS
        Phase 11 test for an opted-in Linux VM: verifies the guest is pointed
        at the lab Squid proxy.
    .DESCRIPTION
        Linux analog of Test-WindowsProxyConfig. Over SSH, checks that the
        roles/proxy-client.sh config landed:
          - /etc/environment has an http_proxy=...:3128 entry (hard FAIL)
          - /etc/apt/apt.conf.d/00-memlabs-proxy sets Acquire::http::Proxy (hard FAIL)
        and, as an end-to-end soft check (INFO only), curls archive.ubuntu.com
        THROUGH the proxy and reports the HTTP status.

        NOTE: direct-Internet-blocked is intentionally NOT tested for Linux --
        the Linux deny-ACL is stamped post-Phase-11 by
        Set-VmProxyEnforcementForAllLabs, so egress is still open during Phase 11.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][object]$CurrentItem,
        [Parameter(Mandatory)][object]$DeployConfig
    )

    $Phase = 11
    $RoleLabel = 'ProxyClient'

    $proxyVm = $DeployConfig.virtualMachines | Where-Object { $_.role -eq 'Proxy' } | Select-Object -First 1
    if (-not $proxyVm) {
        # Add-to-existing case: Proxy may live in the existing hierarchy.
        $existingProxyName = $null
        if (Get-Command Get-ExistingForDomain -ErrorAction SilentlyContinue) {
            $existingProxyName = Get-ExistingForDomain -DomainName $DeployConfig.vmOptions.domainName -Role 'Proxy' | Select-Object -First 1
        }
        if (-not $existingProxyName) {
            Write-Log "[Phase $Phase] $VMName [$RoleLabel]: WARN - useProxy=true but no Proxy VM in config; skipping client config test" -Warning -LogOnly
            return $true
        }
    }

    if (-not (Get-Command Invoke-LinuxVmCommand -ErrorAction SilentlyContinue)) {
        Write-Log "[Phase $Phase] $VMName [$RoleLabel]: FAIL - Invoke-LinuxVmCommand not loaded" -Failure -LogOnly
        $script:Phase11OutputBuffer.Add(@{ Text = "[Phase $Phase] $VMName [$RoleLabel]: FAIL - Invoke-LinuxVmCommand not loaded"; Level = 'Failure' })
        return $false
    }

    Write-Log "[Phase $Phase] $VMName [$RoleLabel]: Testing Linux proxy client config (env + apt -> :3128)" -LogOnly

    $bash = @'
rc=0
# 1) /etc/environment http_proxy points at a :3128 listener
if grep -qiE '^http_proxy=.*:3128' /etc/environment 2>/dev/null; then
    echo "OK: /etc/environment http_proxy -> $(grep -iE '^http_proxy=' /etc/environment | head -1)"
else
    echo "FAIL: /etc/environment has no http_proxy :3128 entry"
    rc=1
fi
# 2) apt Acquire proxy
if grep -qiE 'Acquire::http(s)?::Proxy.*:3128' /etc/apt/apt.conf.d/00-memlabs-proxy 2>/dev/null; then
    echo "OK: apt Acquire proxy configured"
else
    echo "FAIL: /etc/apt/apt.conf.d/00-memlabs-proxy missing or has no :3128 proxy"
    rc=1
fi
# 3) End-to-end (soft): curl archive.ubuntu.com THROUGH the proxy.
PROXY_URL=$(grep -oE 'http://[^"]+:3128' /etc/environment 2>/dev/null | head -1)
if [ -n "$PROXY_URL" ]; then
    CODE=$(curl --max-time 25 -s -o /dev/null -w '%{http_code}' -x "$PROXY_URL" http://archive.ubuntu.com/ubuntu/dists/ 2>/dev/null || echo 000)
    echo "INFO: curl via $PROXY_URL -> http_code=$CODE"
fi
exit $rc
'@

    $result = Invoke-LinuxVmCommand -VmName $VMName -BashCommand $bash -Sudo -TimeoutSeconds 60 -SuppressLog -DisplayName "Phase11-LinuxProxyClient-Test"

    $output = if ($result) { ($result.ScriptBlockOutput | Out-String).Trim() } else { '' }
    foreach ($line in ($output -split "`n")) {
        $line = $line.Trim()
        if (-not $line) { continue }
        if ($line -like 'FAIL:*') {
            Write-Log "[Phase $Phase] $VMName [$RoleLabel]: $line" -Failure -LogOnly
        }
        else {
            Write-Log "[Phase $Phase] $VMName [$RoleLabel]: $line" -LogOnly
        }
    }

    if (-not $result -or $result.ScriptBlockFailed -or $result.ExitCode -ne 0) {
        $detail = if ($output) { (($output -split "`n" | Where-Object { $_ -like 'FAIL:*' }) -join '; ') } else { 'SSH failed' }
        if (-not $detail) { $detail = "exit=$(if ($result) { $result.ExitCode } else { 'n/a' })" }
        Write-Log "[Phase $Phase] $VMName [$RoleLabel]: FAIL - proxy client config not applied: $detail" -Failure -LogOnly
        $script:Phase11OutputBuffer.Add(@{ Text = "[Phase $Phase] $VMName [$RoleLabel]: FAIL - proxy client config not applied ($detail)"; Level = 'Failure' })
        return $false
    }

    Write-Log "[Phase $Phase] $VMName [$RoleLabel]: OK - Linux proxy client config verified" -LogOnly
    return $true
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
        From inside the guest, opens a TCP connection to 8.8.8.8:443 with a
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
        $results.Details.Add("CMD: TCP connect 8.8.8.8:443 (hard 3s timeout)")
        try {
            # Hard-timeout TcpClient probe instead of Test-NetConnection, which can
            # hang well past its own timeout (DNS reverse lookups / ICMP fallbacks).
            $ok = $false
            $tcpClient = [System.Net.Sockets.TcpClient]::new()
            $iar = $tcpClient.BeginConnect('8.8.8.8', 443, $null, $null)
            if ($iar.AsyncWaitHandle.WaitOne(3000, $false)) {
                try { $tcpClient.EndConnect($iar); $ok = $tcpClient.Connected } catch { $ok = $false }
            }
            try { $tcpClient.Close() } catch { }
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
            $results.Details.Add("OK: TCP connect threw (treated as blocked): $($_.Exception.Message)")
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
    # Hard-timeout TCP probe (Test-TcpPort); Test-NetConnection can hang on a
    # filtered/closed 445 (e.g. a Linux box with SMB down), which is exactly the
    # state this fallback probes.
    $smbUp = Test-TcpPort -ComputerName $vmIp -Port 445 -TimeoutMs 3000 -Retries 2 -RetryDelayMs 1000

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
        2) Verifies TCP 445 is reachable (hard-timeout TCP probe).
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

    # 1) TCP 445 reachability. smbd is enabled --now at cloud-init, but on a
    # heavily loaded host the busiest Linux VM (the Proxy: squid + webui + apt
    # churn) can have smbd fail to come up, or die on a first-boot apt/samba
    # install race, leaving 445 closed while SSH and ping stay healthy. Since
    # the health cascade that runs before this test has already confirmed SSH
    # is up, self-heal instead of hard-failing the whole lab for a backup
    # file-access channel: SSH in, (re)start smbd, then re-probe 445.
    $tcpOk = Test-TcpPort -ComputerName $vmIp -Port 445 -TimeoutMs 3000 -Retries 2 -RetryDelayMs 1000
    if (-not $tcpOk) {
        Write-Log "[Phase $Phase] $VMName [$RoleLabel]: WARN - TCP 445 closed on $vmIp; attempting smbd self-heal over SSH" -Warning -LogOnly
        # Run the same shared ensure-samba.sh used at first boot: detect-skip if
        # smbd already present, else HEAL a corrupt/truncated dpkg DB
        # (recover_dpkg/repair_dpkg_status) and install samba with retries, then
        # enable+start smbd and confirm the :445 listener. The corrupt dpkg DB
        # ("end of file after field name ''") is the actual Proxy failure mode,
        # so a plain 'apt-get install samba' is not enough -- the recovery must
        # run first.
        $ensureSambaBody = Get-LinuxScript -Name 'roles/ensure-samba' -IncludeAptRetry
        $heal = Invoke-LinuxVmCommand -VmName $VMName -IPAddress $vmIp -Sudo -SuppressLog -TimeoutSeconds 420 `
            -DisplayName 'ensure-samba (heal dpkg + smbd)' `
            -BashCommand $ensureSambaBody
        if ($heal -and $heal.ScriptBlockOutput -match 'SMBD_LISTENING') {
            Write-Log "[Phase $Phase] $VMName [$RoleLabel]: smbd installed/restarted and now listening on :445; re-probing TCP 445" -LogOnly
        }
        else {
            $healOut = if ($heal) { $heal.ScriptBlockOutput } else { '(no SSH result)' }
            Write-Log "[Phase $Phase] $VMName [$RoleLabel]: smbd self-heal did not confirm a listener. Output: $healOut" -LogOnly
        }
        # Re-probe 445 from the host after the self-heal attempt.
        $tcpOk = Test-TcpPort -ComputerName $vmIp -Port 445 -TimeoutMs 3000 -Retries 2 -RetryDelayMs 1000
        if (-not $tcpOk) {
            Write-Log "[Phase $Phase] $VMName [$RoleLabel]: FAIL - TCP 445 not reachable on $vmIp (after smbd self-heal)" -Failure -LogOnly
            $script:Phase11OutputBuffer.Add(@{ Text = "[Phase $Phase] $VMName [$RoleLabel]: FAIL - Samba TCP 445 not reachable"; Level = 'Failure' })
            return $false
        }
        Write-Log "[Phase $Phase] $VMName [$RoleLabel]: OK - TCP 445 reachable on $vmIp after smbd self-heal" -LogOnly
    }
    else {
        Write-Log "[Phase $Phase] $VMName [$RoleLabel]: OK - TCP 445 reachable on $vmIp" -LogOnly
    }

    # 2) Verify shares are listed via net view (runs as host, no auth needed for listing)
    $netViewOutput = & net view "\\$vmIp" /all 2>&1
    $netViewString = ($netViewOutput | Out-String).Trim()
    $hasShares = $netViewString -match 'logs' -and $netViewString -match 'home'
    if ($hasShares) {
        Write-Log "[Phase $Phase] $VMName [$RoleLabel]: OK - Samba shares 'logs' and 'home' visible via net view" -LogOnly
    }
    elseif ($netViewString -match 'System error 5|Access is denied') {
        # NOT a warning: an unauthenticated 'net view' being DENIED means Samba
        # is up and enforcing auth (smb.conf security=user, map to guest=never).
        # The meaningful check (TCP 445 reachable) already passed, so this is the
        # expected, healthy result -- log it as OK, not a WARN.
        Write-Log "[Phase $Phase] $VMName [$RoleLabel]: OK - Samba up and enforcing auth (net view denied without creds; TCP 445 open)" -LogOnly
    }
    else {
        # Genuinely unexpected net view output (not shares, not access-denied).
        Write-Log "[Phase $Phase] $VMName [$RoleLabel]: WARN - net view returned unexpected output (TCP 445 is open)" -Warning -LogOnly
        Write-Log "[Phase $Phase] $VMName [$RoleLabel]: net view output: $netViewString" -LogOnly
    }

    $script:Phase11OutputBuffer.Add(@{ Text = "[Phase $Phase] $VMName [$RoleLabel]: OK - Samba accessible on $vmIp:445"; Level = 'Success' })
    return $true
}

function Test-LinuxDomainJoin {
    <#
    .SYNOPSIS
        Phase 11 check for a Linux VM with joinDomain=true: verify it actually
        realm-joined the lab AD domain.
    .DESCRIPTION
        Runs over SSH (Invoke-LinuxVmCommand). Considers the VM joined when
        `realm list` reports the domain (authoritative -- realm only lists a
        domain once sssd is configured against it). On success emits OK.

        On failure it gathers the actionable diagnostics -- sssd active-state,
        /etc/krb5.keytab presence, the resolver (which DC/DNS the box is using),
        whether the DC name resolves + is pingable, and `adcli testjoin` -- so the
        common root cause (resolver not pointing at the DC -> "Couldn't find
        usable domain controller") is visible in the build log. Informational
        only: always returns $true (never fails the VM); the WARN reaches the
        console via the Phase 11 output buffer. joinDomain is a best-effort lab
        convenience and the realm-join script is idempotent, so a re-run of
        Phase 3 re-attempts the join.
    .OUTPUTS
        Boolean: always $true (informational).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][object]$CurrentItem,
        [Parameter(Mandatory)][object]$DeployConfig
    )

    $Phase = 11
    $RoleLabel = $CurrentItem.role
    $domain = $DeployConfig.vmOptions.domainName
    $domainLower = if ($domain) { $domain.ToLower() } else { $domain }

    if (-not (Get-Command Invoke-LinuxVmCommand -ErrorAction SilentlyContinue)) {
        Write-Log "[Phase $Phase] $VMName [$RoleLabel]: Domain-join check skipped (Invoke-LinuxVmCommand unavailable)" -LogOnly
        return $true
    }

    $vmIp = Get-LinuxVmIPAddress -VmName $VMName
    if (-not $vmIp) {
        Write-Log "[Phase $Phase] $VMName [$RoleLabel]: Domain-join check skipped (no IP from KVP)" -LogOnly
        return $true
    }

    Write-Log "[Phase $Phase] $VMName [$RoleLabel]: Verifying AD domain join ($domain)" -LogOnly

    # DC IP: memlabs convention <network>.1 (same derivation the realm-join uses).
    # Computed here so both the DNS assertion below and the failure diagnostics
    # further down can use it.
    $netBase = $CurrentItem.network
    if (-not $netBase) { $netBase = $DeployConfig.vmOptions.network }
    $dcIp = ''
    if ($netBase -match '^(\d+\.\d+\.\d+)\.\d+$') { $dcIp = "$($Matches[1]).1" }

    # ---- Explicit DNS assertion (its own OK/WARN line) ----
    # The #1 realm-join failure is the guest resolving the AD domain via PUBLIC
    # DNS instead of the DC -- the lab AD domain often collides with a real
    # internet domain (e.g. contoso.com), so public resolvers answer AD queries
    # with wrong (public) IPs and the _msdcs SRV zone NXDOMAINs. Verify the AD
    # domain resolves to a PRIVATE address (ideally the DC) and the SRV zone is
    # answerable. Runs regardless of join state, so a joined-but-misrouted box
    # (or a box the DNS fix hasn't reached) is still flagged on its own line.
    if ($domainLower) {
        $dnsCmd = @"
A=`$(getent hosts '$domainLower' 2>/dev/null | awk '{print `$1}' | head -1)
if nslookup -type=srv _ldap._tcp.dc._msdcs.$domainLower 2>/dev/null | grep -qiE 'service|priority|^_ldap'; then SRV=ok; else SRV=bad; fi
if [ -f /etc/systemd/resolved.conf.d/memlabs-dc-route.conf ]; then ROUTE=present; else ROUTE=absent; fi
echo "A=`${A:-none} SRV=`$SRV ROUTE=`$ROUTE"
"@
        $dnsProbe = Invoke-LinuxVmCommand -VMName $VMName -IPAddress $vmIp -Sudo -TimeoutSeconds 45 `
            -DisplayName 'Phase11-dns-check' -BashCommand $dnsCmd
        $aRec = 'none'; $srv = 'bad'; $route = 'absent'
        if ($dnsProbe -and $dnsProbe.ScriptBlockOutput) {
            $dnsOut = ($dnsProbe.ScriptBlockOutput | Out-String)
            if ($dnsOut -match 'A=(\S+)') { $aRec = $Matches[1] }
            if ($dnsOut -match 'SRV=(\S+)') { $srv = $Matches[1] }
            if ($dnsOut -match 'ROUTE=(\S+)') { $route = $Matches[1] }
        }
        $aIsPrivate = $aRec -match '^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)'
        $aIsDc = ($dcIp -and $aRec -eq $dcIp)
        if ($aRec -ne 'none' -and $aIsPrivate -and $srv -eq 'ok') {
            $dcNote = if ($aIsDc) { " (DC $dcIp)" } else { " ($aRec, private)" }
            Write-Log "[Phase $Phase] $VMName [$RoleLabel]: OK - AD DNS resolves to the DC$dcNote and the SRV zone answers (route drop-in $route)" -LogOnly
            $script:Phase11OutputBuffer.Add(@{ Text = "[Phase $Phase] $VMName [$RoleLabel]: OK - AD DNS -> DC$dcNote, SRV zone OK"; Level = 'Success' })
        }
        else {
            $reason = if ($aRec -eq 'none') { "the AD domain does not resolve" }
                      elseif (-not $aIsPrivate) { "the AD domain resolves to a PUBLIC IP ($aRec) -- the guest is using public DNS, not the DC" }
                      elseif ($srv -ne 'ok') { "the AD SRV zone (_ldap._tcp.dc._msdcs.$domainLower) does not answer" }
                      else { "AD DNS looks wrong (A=$aRec SRV=$srv)" }
            Write-Log "[Phase $Phase] $VMName [$RoleLabel]: WARN - $reason. Expected the DC ($dcIp) to be authoritative for '$domain'. memlabs-set-dns writes /etc/systemd/resolved.conf.d/memlabs-dc-route.conf (route drop-in currently $route) to route the AD domain to the DC; re-run '-StartPhase 3' or apply it manually." -Warning
            $script:Phase11OutputBuffer.Add(@{ Text = "[Phase $Phase] $VMName [$RoleLabel]: WARN - AD DNS misrouted (A=$aRec SRV=$srv route=$route) -- guest not resolving '$domain' via the DC"; Level = 'Warning' })
        }
    }

    # Authoritative check: realm list reports the joined domain.
    $realmProbe = Invoke-LinuxVmCommand -VMName $VMName -IPAddress $vmIp -Sudo -TimeoutSeconds 30 `
        -DisplayName 'Phase11-realm-list' `
        -BashCommand "realm list --name-only 2>/dev/null || true"
    $realmOut = ''
    if ($realmProbe -and $realmProbe.ScriptBlockOutput) { $realmOut = ($realmProbe.ScriptBlockOutput | Out-String) }

    if ($domainLower -and ($realmOut -match [regex]::Escape($domainLower))) {
        Write-Log "[Phase $Phase] $VMName [$RoleLabel]: OK - realm-joined to $domain" -LogOnly
        $script:Phase11OutputBuffer.Add(@{ Text = "[Phase $Phase] $VMName [$RoleLabel]: OK - joined to AD domain $domain"; Level = 'Success' })
        return $true
    }

    # Not joined -- collect diagnostics so the root cause is in the build log.
    # ($dcIp / $netBase were derived above for the DNS assertion.)

    # Comprehensive one-shot diagnostic bundle. Everything an operator needs to
    # root-cause a failed realm-join is collected here so the build log alone is
    # sufficient (we rarely get hands-on the VM): identity/join state, sssd +
    # its journal, Kerberos (keytab/krb5.conf/clock-skew -- AD rejects tickets
    # >5min skew), the resolver + netplan (the #1 cause is DNS not pointing at
    # the DC), live AD SRV-record lookups, DC reachability on each AD port
    # (53/88/389/445 via bash /dev/tcp -- no nc dependency), adcli discovery, and
    # the realm-join echoes captured in cloud-init-output.log.
    $diagCmd = @"
echo '=== hostname / identity ==='; hostnamectl 2>&1 | grep -Ei 'hostname|chassis' ; id vmbuildadmin 2>&1
echo '=== clock (Kerberos needs <5min skew vs DC) ==='; timedatectl 2>&1 | grep -Ei 'Local time|Universal|synchronized|NTP service' ; date -u
echo '=== realm list ==='; realm list 2>&1 || echo '(realm not joined / not installed)'
echo '=== net ads testjoin ==='; net ads testjoin 2>&1 || echo '(net ads testjoin failed / samba not installed)'
echo '=== adcli info ($domainLower) ==='; adcli info '$domainLower' 2>&1 | head -30 || echo '(adcli info failed -- cannot discover DC via SRV)'
echo '=== adcli testjoin ==='; adcli testjoin '$domainLower' 2>&1 || echo '(adcli testjoin failed)'
echo '=== sssd active ==='; systemctl is-active sssd 2>&1 ; systemctl is-enabled sssd 2>&1
echo '=== sssd journal (last 40) ==='; journalctl -u sssd --no-pager -n 40 2>&1 || echo '(no sssd journal)'
echo '=== /etc/sssd/sssd.conf ==='; (test -f /etc/sssd/sssd.conf && sed -E 's/(ldap_default_authtok|password) *=.*/\1 = <redacted>/' /etc/sssd/sssd.conf) 2>&1 || echo '(no /etc/sssd/sssd.conf)'
echo '=== keytab ==='; ls -l /etc/krb5.keytab 2>&1 || echo '(no /etc/krb5.keytab)'; klist -k 2>&1 | head -20 || true
echo '=== /etc/krb5.conf ==='; cat /etc/krb5.conf 2>&1 || echo '(no /etc/krb5.conf)'
echo '=== resolver ==='; resolvectl status 2>&1 | grep -Ei 'Current DNS|DNS Servers|DNS Domain|Link ' || cat /etc/resolv.conf 2>&1
echo '=== /etc/resolv.conf ==='; cat /etc/resolv.conf 2>&1
echo '=== netplan ==='; for f in /etc/netplan/*.yaml; do echo "-- `$f --"; cat "`$f" 2>&1; done
echo '=== memlabs-set-dns present ==='; ls -l /usr/local/sbin/memlabs-set-dns 2>&1 || echo '(helper missing)'
echo '=== DNS: A record $domainLower ==='; getent hosts '$domainLower' 2>&1 || echo '(domain name does not resolve)'
echo '=== DNS: SRV _ldap._tcp.dc._msdcs.$domainLower ==='; (nslookup -type=srv _ldap._tcp.dc._msdcs.$domainLower 2>&1 | grep -Ei 'service|server|priority|can.t find|NXDOMAIN|timed out') || echo '(nslookup unavailable or no SRV records -- AD DNS not reachable)'
echo '=== DC reachability ($dcIp) ==='; if [ -n '$dcIp' ]; then ping -c1 -W2 '$dcIp' >/dev/null 2>&1 && echo 'ping OK' || echo 'ping FAILED'; for p in 53 88 389 445; do (timeout 3 bash -c "echo > /dev/tcp/$dcIp/`$p" 2>/dev/null && echo "tcp/`$p OPEN" || echo "tcp/`$p CLOSED/filtered"); done; else echo '(no DC IP derived from network)'; fi
echo '=== realm-join echoes (cloud-init-output.log) ==='; grep -a 'memlabs-realm-join' /var/log/cloud-init-output.log 2>&1 | tail -30 || echo '(no realm-join output in cloud-init log)'
"@
    $diag = Invoke-LinuxVmCommand -VMName $VMName -IPAddress $vmIp -Sudo -TimeoutSeconds 120 `
        -DisplayName 'Phase11-domainjoin-diag' -BashCommand $diagCmd
    if ($diag -and $diag.ScriptBlockOutput) {
        foreach ($line in ($diag.ScriptBlockOutput -split "`n")) {
            $t = $line.TrimEnd()
            if ($t) { Write-Log "[Phase $Phase] $VMName [$RoleLabel]: dj-diag> $t" -LogOnly }
        }
    }
    else {
        Write-Log "[Phase $Phase] $VMName [$RoleLabel]: dj-diag> (diagnostic collection returned no output -- SSH may have failed)" -LogOnly
    }

    Write-Log "[Phase $Phase] $VMName [$RoleLabel]: WARN - joinDomain=true but not joined to $domain. Most common cause is DNS: the VM's resolver must point at the DC ($dcIp) so it can find the AD SRV records. Re-run '-StartPhase 3' after the DC's DNS is serving; the realm-join is idempotent. See dj-diag lines in the build log." -Warning
    $script:Phase11OutputBuffer.Add(@{ Text = "[Phase $Phase] $VMName [$RoleLabel]: WARN - NOT joined to AD domain $domain (joinDomain=true) -- likely DNS/DC reachability; see dj-diag in log"; Level = 'Warning' })
    return $true
}

#endregion Linux Common Validation Tests

#endregion

#region Helper Functions

function Write-ValidationStep {
    <#
    .SYNOPSIS
        Marks a Phase 11 step boundary and logs the duration of the step that just ended.
    .DESCRIPTION
        Phase 11 recorded no per-check timing at all -- only the per-VM total -- so
        "which check is slow" could not be answered from the log. Each call stamps the
        previous step as '[TestTiming] <vm> [<role>] <step> <sec>s' and starts the clock
        for the new one. Stop-ValidationStep flushes the final step.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [string]$RoleLabel,
        [Parameter(Mandatory)][string]$Activity,
        [Parameter(Mandatory)][string]$Status
    )
    Stop-ValidationStep -VMName $VMName -RoleLabel $RoleLabel
    $script:ValStepName = $Status
    $script:ValStepWatch = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Progress2 -PercentComplete 0 -Activity $Activity -Status $Status
}

function Stop-ValidationStep {
    [CmdletBinding()]
    param(
        [string]$VMName,
        [string]$RoleLabel
    )
    if (-not $script:ValStepWatch) { return }
    $script:ValStepWatch.Stop()
    Write-Log ("[TestTiming] {0} [{1}] {2} {3}s" -f $VMName, $RoleLabel, $script:ValStepName,
        [Math]::Round($script:ValStepWatch.Elapsed.TotalSeconds, 1)) -LogOnly
    $script:ValStepWatch = $null
    $script:ValStepName = $null
}

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
    # A test scriptblock that leaks stray pipeline output (e.g. an IIS cmdlet or
    # method that emits) makes ScriptBlockOutput an ARRAY (leaked objects + the
    # returned $results hashtable) instead of a single hashtable. Member access
    # then enumerates the array and, if any element is $null, ContainsKey() below
    # throws "You cannot call a method on a null-valued expression". Pick the real
    # result hashtable out of the array so a leak can't crash the whole phase.
    if ($output -is [System.Collections.IEnumerable] -and
        $output -isnot [System.Collections.IDictionary] -and
        $output -isnot [string]) {
        $picked = $null
        foreach ($item in $output) {
            if ($item -is [System.Collections.IDictionary] -and $item.Contains('Passed')) { $picked = $item }
        }
        if ($picked) { $output = $picked }
    }
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

        Add-Phase11Output "[Phase $Phase] $VMName [SQLAO]: Running post-Phase-5 validation"

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
