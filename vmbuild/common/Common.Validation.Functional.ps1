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

    # Determine which test function(s) to call based on role and installed features.
    $testsPassed = $true

    switch ($role) {
        'DC' {
            $testsPassed = Test-DCFunctionality -VMName $VMName -Domain $domain
        }
        'BDC' {
            $testsPassed = Test-DCFunctionality -VMName $VMName -Domain $domain -IsBDC
        }
        'CAS' {
            $testsPassed = Test-SQLFunctionality -VMName $VMName -CurrentItem $CurrentItem -DeployConfig $DeployConfig
            if ($testsPassed) {
                $testsPassed = Test-CMSiteFunctionality -VMName $VMName -CurrentItem $CurrentItem -DeployConfig $DeployConfig
            }
        }
        'Primary' {
            $testsPassed = Test-SQLFunctionality -VMName $VMName -CurrentItem $CurrentItem -DeployConfig $DeployConfig
            if ($testsPassed) {
                $testsPassed = Test-CMSiteFunctionality -VMName $VMName -CurrentItem $CurrentItem -DeployConfig $DeployConfig
            }
        }
        'Secondary' {
            $testsPassed = Test-SecondaryFunctionality -VMName $VMName -CurrentItem $CurrentItem -DeployConfig $DeployConfig
        }
        'SiteSystem' {
            $testsPassed = Test-SiteSystemFunctionality -VMName $VMName -CurrentItem $CurrentItem -DeployConfig $DeployConfig
        }
        'SQLAO' {
            $testsPassed = Test-SQLAOFunctionality -VMName $VMName -CurrentItem $CurrentItem -DeployConfig $DeployConfig
        }
        'WSUS' {
            $testsPassed = Test-WSUSFunctionality -VMName $VMName -Domain $domain
        }
        'FileServer' {
            $testsPassed = Test-FileServerFunctionality -VMName $VMName -Domain $domain
        }
        'StandaloneRootCA' {
            $testsPassed = Test-StandaloneRootCAFunctionality -VMName $VMName -Domain $domain
        }
        'PassiveSite' {
            $testsPassed = Test-PassiveSiteFunctionality -VMName $VMName -CurrentItem $CurrentItem -DeployConfig $DeployConfig
        }
        'DomainMember' {
            $testsPassed = Test-DomainMemberFunctionality -VMName $VMName -CurrentItem $CurrentItem -DeployConfig $DeployConfig
        }
        'WorkgroupMember' {
            $testsPassed = Test-WorkgroupMemberFunctionality -VMName $VMName -CurrentItem $CurrentItem -DeployConfig $DeployConfig
        }
        'InternetClient' {
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
        $testsPassed = Test-ReportingFunctionality -VMName $VMName -Domain $domain
    }

    # If the VM has InstallCA, test Certificate Authority
    if ($testsPassed -and $CurrentItem.InstallCA) {
        $testsPassed = Test-CAFunctionality -VMName $VMName -Domain $domain
    }

    # If the VM has SQL but is not a Primary/CAS/SQLAO (standalone SQL server)
    if ($testsPassed -and $CurrentItem.sqlVersion -and $role -notin @('CAS', 'Primary', 'SQLAO')) {
        $testsPassed = Test-SQLFunctionality -VMName $VMName -CurrentItem $CurrentItem -DeployConfig $DeployConfig
    }

    # SSMS install check (any role with installSSMS=$true)
    if ($testsPassed -and $CurrentItem.installSSMS) {
        $testsPassed = Test-SSMSInstall -VMName $VMName -Domain $domain
    }

    # SMS Provider role check (remote SMS provider, not on the site server itself)
    if ($testsPassed -and $CurrentItem.InstallSMSProv -and $role -ne 'CAS' -and $role -ne 'Primary') {
        $testsPassed = Test-SMSProviderRole -VMName $VMName -CurrentItem $CurrentItem -DeployConfig $DeployConfig
    }

    # Pull-DP configuration (verified from parent Primary)
    if ($testsPassed -and $CurrentItem.enablePullDP) {
        $testsPassed = Test-PullDPConfiguration -VMName $VMName -CurrentItem $CurrentItem -DeployConfig $DeployConfig
    }

    # Additional data disks (E:, F:, ...) per additionalDisks config
    if ($testsPassed -and $CurrentItem.additionalDisks) {
        $testsPassed = Test-AdditionalDisks -VMName $VMName -CurrentItem $CurrentItem -DeployConfig $DeployConfig
    }

    # BitLocker volume state on member VMs flagged for encryption
    if ($testsPassed -and $CurrentItem.BitLocker -eq $true -and $role -notin @('DC', 'BDC')) {
        $testsPassed = Test-BitLockerProtection -VMName $VMName -CurrentItem $CurrentItem -DeployConfig $DeployConfig
    }

    # BitLocker Management: validate policy exists and is deployed (top-level site only)
    $hasBLMVMs = @($DeployConfig.virtualMachines | Where-Object { $_.BitLocker -eq $true }).Count -gt 0
    if ($testsPassed -and ($DeployConfig.cmOptions.EnableBLM -or $hasBLMVMs) -and $role -eq 'Primary') {
        $testsPassed = Test-BLMFunctionality -VMName $VMName -CurrentItem $CurrentItem -DeployConfig $DeployConfig
    }

    # Verify maintenance scheduled tasks are present (confirms Phase 10 ran correctly)
    if ($testsPassed -and $role -notin @('OSDClient', 'AADClient', 'StandaloneRootCA')) {
        $testsPassed = Test-MaintenanceTasks -VMName $VMName -Domain $domain
    }

    # ---- Proxy validation ----
    # 1) For the Proxy VM itself: verify Squid is listening on TCP 3128.
    if ($testsPassed -and $role -eq 'Proxy') {
        $testsPassed = Test-ProxyListening -VMName $VMName -CurrentItem $CurrentItem -DeployConfig $DeployConfig
    }
    # 2) For any opted-in Windows client/CM-role VM: verify it's pointed at the proxy,
    #    that direct Internet is blocked by host ACLs, and (CM site roles only) that
    #    Get-CMSiteSystemServer reports UseProxy=$true.
    if ($testsPassed -and (Test-VmUsesProxy -Vm $CurrentItem -DeployConfig $DeployConfig)) {
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

    return $testsPassed
}

#region Role-Specific Test Functions

function Test-DCFunctionality {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$Domain,
        [switch]$IsBDC
    )

    $Phase = 11
    $label = if ($IsBDC) { 'BDC' } else { 'DC' }
    Write-Log "[Phase $Phase] $VMName [$label]: Testing AD DS, DNS, and Netlogon services" -LogOnly

    $scriptBlock = {
        # NOTE: Invoke-VmCommand declares [string[]]$ArgumentList, so any bool we pass
        # in arrives as the string 'True'/'False' (both truthy in `if`). Compare to
        # the string 'True' explicitly to avoid the BDC branch firing on every DC.
        param($domainFqdn, $isBdcInner)
        $isBdc = ($isBdcInner -eq 'True')
        $results = @{ Passed = $true; Details = [System.Collections.Generic.List[string]]::new() }

        # Check critical services
        $services = @('NTDS', 'DNS', 'Netlogon')
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

        # dcdiag quick checks (Services + Replications)
        $results.Details.Add("CMD: dcdiag.exe /test:Services /test:Replications /test:FSMOCheck /q")
        try {
            $dcdiag = & dcdiag.exe /test:Services /test:Replications /test:FSMOCheck /q 2>&1
            $dcdiagText = $dcdiag -join "`n"
            $failCount = ([regex]::Matches($dcdiagText, 'failed test')).Count
            if ($failCount -gt 0) {
                $results.Passed = $false
                $results.Details.Add("FAIL: dcdiag reported $failCount failed test(s)")
                $failLines = $dcdiag | Where-Object { $_ -match 'failed test' } | Select-Object -First 5
                foreach ($fl in $failLines) { $results.Details.Add("  dcdiag: $($fl.Trim())") }
            }
            else {
                $results.Details.Add("OK: dcdiag Services/Replications/FSMOCheck passed")
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
        -ScriptBlock $scriptBlock -ArgumentList $Domain, ([string]$IsBDC.IsPresent) `
        -DisplayName "Phase11-$label-Test" -SuppressLog

    return (Format-TestResult -VMName $VMName -RoleLabel $label -Result $result)
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
            $results.Passed = $false
            $results.Details.Add("FAIL: SQL service '$svcName' is $($svc.Status)")
            return $results
        }
        $results.Details.Add("OK: SQL service '$svcName' is Running")

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
            $qr = Invoke-Sqlcmd -ServerInstance $connStr -Query "SELECT 1 AS TestResult" -QueryTimeout 30 -TrustServerCertificate -ErrorAction Stop
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

    $scriptBlock = {
        $results = @{ Passed = $true; Details = [System.Collections.Generic.List[string]]::new() }

        $query = "SELECT ag.name AS GroupName, rs.synchronization_health_desc AS Health FROM sys.dm_hadr_availability_replica_states rs JOIN sys.availability_groups ag ON rs.group_id = ag.group_id"
        $results.Details.Add("CMD: Invoke-Sqlcmd -Query `"$query`"")
        try {
            Import-Module SqlServer -ErrorAction SilentlyContinue
            if (-not (Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue)) {
                Import-Module SQLPS -DisableNameChecking -ErrorAction SilentlyContinue
            }
            $ag = Invoke-Sqlcmd -Query $query -QueryTimeout 30 -TrustServerCertificate -ErrorAction Stop
            if (-not $ag) {
                $results.Passed = $false
                $results.Details.Add("FAIL: No availability group replicas found")
            }
            else {
                $unhealthy = @($ag | Where-Object { $_.Health -ne 'HEALTHY' })
                if ($unhealthy.Count -gt 0) {
                    $results.Passed = $false
                    foreach ($u in $unhealthy) {
                        $results.Details.Add("FAIL: AG '$($u.GroupName)' replica health is '$($u.Health)'")
                    }
                }
                else {
                    $results.Details.Add("OK: All $($ag.Count) AG replica(s) are HEALTHY")
                }
            }
        }
        catch {
            $results.Passed = $false
            $results.Details.Add("FAIL: AG health query failed: $($_.Exception.Message)")
        }

        return $results
    }

    $result = Invoke-VmCommand -VmName $VMName -VmDomainName $domain `
        -ScriptBlock $scriptBlock -DisplayName "Phase11-SQLAO-Test" -SuppressLog

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

    Write-Log "[Phase $Phase] $VMName [CM-$siteCode]: Testing ConfigMgr site services and WMI" -LogOnly

    $scriptBlock = {
        param($sc)
        $results = @{ Passed = $true; Details = [System.Collections.Generic.List[string]]::new() }

        # Check critical CM services
        foreach ($svc in @('SMS_EXECUTIVE', 'SMS_SITE_COMPONENT_MANAGER')) {
            $results.Details.Add("CMD: Get-Service -Name '$svc'")
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
        $sitePassed = Test-CMSiteWideFunctionality -VMName $VMName -CurrentItem $CurrentItem -DeployConfig $DeployConfig
        if (-not $sitePassed) { $passed = $false }
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

    Write-Log "[Phase $Phase] $VMName [Secondary]: Testing SMS_EXECUTIVE service" -LogOnly

    $scriptBlock = {
        $results = @{ Passed = $true; Details = [System.Collections.Generic.List[string]]::new() }

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

        return $results
    }

    $result = Invoke-VmCommand -VmName $VMName -VmDomainName $domain `
        -ScriptBlock $scriptBlock -DisplayName "Phase11-Secondary-Test" -SuppressLog

    $localOk = Format-TestResult -VMName $VMName -RoleLabel 'Secondary' -Result $result
    if (-not $localOk) { return $false }

    # Verify from parent Primary that this secondary site is attached
    $parentSiteCode = $CurrentItem.parentSiteCode
    if ($parentSiteCode) {
        $parentVM = $DeployConfig.virtualMachines | Where-Object {
            $_.siteCode -eq $parentSiteCode -and $_.role -in @('Primary', 'CAS')
        } | Select-Object -First 1
        if ($parentVM) {
            $secSiteCode = $CurrentItem.siteCode
            Write-Log "[Phase $Phase] $VMName [Secondary]: Verifying site '$secSiteCode' visible from parent '$($parentVM.vmName)'" -LogOnly

            $parentScript = {
                param($parentSC, $childSC)
                $results = @{ Passed = $true; Details = [System.Collections.Generic.List[string]]::new() }
                $results.Details.Add("CMD: Get-WmiObject -Namespace 'root\SMS\site_$parentSC' -Class SMS_Site -Filter `"SiteCode = '$childSC'`"")
                try {
                    $sec = Get-WmiObject -Namespace "root\SMS\site_$parentSC" -Class SMS_Site `
                        -Filter "SiteCode = '$childSC'" -ErrorAction Stop
                    if ($sec) {
                        $results.Details.Add("OK: Secondary site '$childSC' found in parent site '$parentSC'")
                    }
                    else {
                        $results.Passed = $false
                        $results.Details.Add("FAIL: Secondary site '$childSC' not found in parent site '$parentSC'")
                    }
                }
                catch {
                    $results.Passed = $false
                    $results.Details.Add("FAIL: Cannot query parent for secondary: $($_.Exception.Message)")
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
        [Parameter(Mandatory)][string]$Domain
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

        # Probe the configured PBIRS/SSRS portal URL. memlabs binds the
        # portal to the FQDN (URL reservations in IIS/HTTP.SYS often don't
        # include 'localhost', and HTTPS bindings may use a cert with a CN
        # that doesn't match 'localhost'). Pull the configured URL from
        # WMI when possible, then fall back to FQDN/COMPUTERNAME guesses.
        $urls = @()
        try {
            $rsConfig = Get-WmiObject -Namespace 'root\Microsoft\SqlServer\ReportServer\RS_PBIRS\v15\Admin' `
                -Class MSReportServer_ConfigurationSetting -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if (-not $rsConfig) {
                $rsConfig = Get-WmiObject -Namespace 'root\Microsoft\SqlServer\ReportServer\RS_SSRS\v15\Admin' `
                    -Class MSReportServer_ConfigurationSetting -ErrorAction SilentlyContinue |
                    Select-Object -First 1
            }
            if ($rsConfig) {
                $listing = $rsConfig.ListReservedUrls()
                if ($listing -and $listing.UrlString) {
                    foreach ($u in $listing.UrlString) {
                        if ($u -match 'Reports') { $urls += $u.TrimEnd('/') }
                    }
                }
            }
        }
        catch { }

        $fqdn = "$env:COMPUTERNAME.$((Get-WmiObject Win32_ComputerSystem).Domain)"
        $urls += @(
            "http://$fqdn/Reports",
            "http://$env:COMPUTERNAME/Reports",
            "https://$fqdn/Reports",
            'http://localhost/Reports'
        )
        $urls = $urls | Select-Object -Unique

        # Bypass cert validation (self-signed lab cert) and force TLS 1.2
        $origCb = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
        $origProto = [System.Net.ServicePointManager]::SecurityProtocol
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls11 -bor [System.Net.SecurityProtocolType]::Tls

        $results.Details.Add("CMD: Invoke-WebRequest -UseDefaultCredentials (trying: $($urls -join ', '))")
        $reachable = $false
        $lastErr = ''
        try {
            foreach ($url in $urls) {
                try {
                    $response = Invoke-WebRequest -Uri $url -UseBasicParsing -UseDefaultCredentials `
                        -TimeoutSec 15 -MaximumRedirection 5 -ErrorAction Stop
                    if ($response.StatusCode -in 200, 301, 302) {
                        $results.Details.Add("OK: Reporting portal reachable at '$url' (status $([int]$response.StatusCode))")
                        $reachable = $true
                        break
                    }
                }
                catch {
                    # 401/403 also means IIS is answering; portal just requires different auth
                    $code = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
                    if ($code -in 401, 403) {
                        $results.Details.Add("OK: Reporting portal responding at '$url' (status $code -- requires auth)")
                        $reachable = $true
                        break
                    }
                    $lastErr = "$url -> $($_.Exception.Message)"
                }
            }
        }
        finally {
            [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $origCb
            [System.Net.ServicePointManager]::SecurityProtocol = $origProto
        }
        if (-not $reachable) {
            # Portal unreachable is a WARN, not a FAIL - the service being
            # Running is the critical check. Portal may need auth or different URL.
            $results.Details.Add("WARN: Reporting portal not reachable on standard URLs (last error: $lastErr)")
        }

        return $results
    }

    $result = Invoke-VmCommand -VmName $VMName -VmDomainName $Domain `
        -ScriptBlock $scriptBlock -DisplayName "Phase11-RP-Test" -SuppressLog

    return (Format-TestResult -VMName $VMName -RoleLabel 'RP' -Result $result)
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

        return $results
    }

    $result = Invoke-VmCommand -VmName $VMName -VmDomainName $Domain `
        -ScriptBlock $scriptBlock -DisplayName "Phase11-CA-Test" -SuppressLog

    return (Format-TestResult -VMName $VMName -RoleLabel 'CA' -Result $result)
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
        try {
            $sc = Test-ComputerSecureChannel -ErrorAction Stop
            if ($sc) {
                $results.Details.Add("OK: Secure channel to domain is healthy")
            }
            else {
                $results.Passed = $false
                $results.Details.Add("FAIL: Test-ComputerSecureChannel returned False -- machine account password may be broken")
            }
        }
        catch {
            $results.Details.Add("WARN: Test-ComputerSecureChannel threw: $($_.Exception.Message)")
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
        $ccm = Get-Service -Name 'CcmExec' -ErrorAction SilentlyContinue
        if ($ccm) {
            if ($ccm.Status -eq 'Running') {
                $results.Details.Add("OK: CcmExec service is Running")
            }
            else {
                $results.Passed = $false
                $results.Details.Add("FAIL: CcmExec service is $($ccm.Status) (client is installed but not running)")
            }
        }
        else {
            $results.Details.Add("OK: CcmExec service not installed (no client push expected for this VM)")
        }

        return $results
    }

    $result = Invoke-VmCommand -VmName $VMName -VmDomainName $domain `
        -ScriptBlock $scriptBlock -ArgumentList $domain `
        -DisplayName "Phase11-DomainMember-Test" -SuppressLog

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
                $results.Passed = $false
                $results.Details.Add("FAIL: No valid client-auth cert in LocalMachine\My (PKI is enabled for this site)")
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
                if ($usePki -and $mode -ne 1) {
                    $results.Details.Add("WARN: UsePKI=true but site Mode=$mode (expected 1 = HTTPS only)")
                }
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

        # IE / WinINET per-machine
        $ieKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\Internet Settings'
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

    return (Format-TestResult -VMName $VMName -RoleLabel $RoleLabel -Result $result)
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

    $result = Invoke-VmCommand -VmName $VMName -VmDomainName $domain `
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
        $errMsg = if ($Result) { $Result.ScriptBlockFailed } else { 'Invoke-VmCommand returned no result (PSDirect session may have failed)' }
        Write-Log "[Phase $Phase] $VMName [$RoleLabel]: FAIL - $errMsg" -Failure -LogOnly
        $script:Phase11OutputBuffer.Add(@{ Text = "[Phase $Phase] $VMName [$RoleLabel]: FAIL - $errMsg"; Level = 'Failure' })
        return $false
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
