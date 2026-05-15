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
            $testsPassed = Test-DCFunctionality -VMName $VMName -Domain $domain
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
        default {
            # Roles like DomainMember, WorkgroupMember, InternetClient, etc.
            # have no role-specific functionality to test. If we get here
            # the phase dispatch filter missed one - pass by default.
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

    # Verify maintenance scheduled tasks are present (confirms Phase 10 ran correctly)
    if ($testsPassed -and $role -notin @('OSDClient', 'Linux', 'AADClient', 'StandaloneRootCA')) {
        $testsPassed = Test-MaintenanceTasks -VMName $VMName -Domain $domain
    }

    return $testsPassed
}

#region Role-Specific Test Functions

function Test-DCFunctionality {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$Domain
    )

    $Phase = 11
    Write-Log "[Phase $Phase] $VMName [DC]: Testing AD DS, DNS, and Netlogon services" -LogOnly

    $scriptBlock = {
        param($domainFqdn)
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

        return $results
    }

    $result = Invoke-VmCommand -VmName $VMName -VmDomainName $Domain `
        -ScriptBlock $scriptBlock -ArgumentList $Domain `
        -DisplayName "Phase11-DC-Test" -SuppressLog

    return (Format-TestResult -VMName $VMName -RoleLabel 'DC' -Result $result)
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

    return (Format-TestResult -VMName $VMName -RoleLabel "CM-$siteCode" -Result $result)
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

            # Check SMS_MP IIS virtual directory exists via WebAdministration
            try {
                Import-Module WebAdministration -ErrorAction Stop
                $mpApp = Get-WebApplication -Site 'Default Web Site' -Name 'SMS_MP' -ErrorAction SilentlyContinue
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

                # DP registration in WMI can lag behind the actual install.
                # Retry for up to ~2 minutes.
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
                    $results.Passed = $false
                    $results.Details.Add("FAIL: DP '$dpVmName' not found in site '$sc' after $maxAttempts attempts")
                }
                return $results
            }

            $dpResult = Invoke-VmCommand -VmName $parentVM.vmName -VmDomainName $domain `
                -ScriptBlock $dpScript -ArgumentList $siteCode, $VMName, "$VMName.$domain" `
                -DisplayName "Phase11-DP-Test" -SuppressLog

            if (-not (Format-TestResult -VMName $VMName -RoleLabel 'DP' -Result $dpResult)) {
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
            }
            elseif ($svc.Status -ne 'Running') {
                $results.Passed = $false
                $results.Details.Add("FAIL: Service 'WsusService' is $($svc.Status)")
            }
            else {
                $results.Details.Add("OK: Service 'WsusService' is Running")
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

        # Check SQL Server Reporting Services service
        $results.Details.Add("CMD: Get-Service -Name 'SQLServerReportingServices' or 'ReportServer'")
        $svc = Get-Service -Name 'SQLServerReportingServices' -ErrorAction SilentlyContinue
        if (-not $svc) {
            $svc = Get-Service -Name 'ReportServer' -ErrorAction SilentlyContinue
        }
        if (-not $svc) {
            $results.Passed = $false
            $results.Details.Add("FAIL: Neither 'SQLServerReportingServices' nor 'ReportServer' service found")
            $results.Details.Add("  Available services matching 'Report*' or 'SQLSR*': $(( Get-Service -Name 'Report*','SQLSR*' -EA SilentlyContinue | ForEach-Object { $_.Name } ) -join ', ')")
            return $results
        }
        if ($svc.Status -ne 'Running') {
            $results.Passed = $false
            $results.Details.Add("FAIL: Reporting service '$($svc.Name)' is $($svc.Status)")
            return $results
        }
        $results.Details.Add("OK: Reporting service '$($svc.Name)' is Running")

        # Try common SSRS/PBIRS portal URLs
        $urls = @(
            'http://localhost/Reports',
            'http://localhost:80/Reports',
            'https://localhost/Reports'
        )
        $results.Details.Add("CMD: Invoke-WebRequest (trying: $($urls -join ', '))")
        $reachable = $false
        $lastErr = ''
        foreach ($url in $urls) {
            try {
                $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
                if ($response.StatusCode -eq 200) {
                    $results.Details.Add("OK: Reporting portal reachable at '$url'")
                    $reachable = $true
                    break
                }
            }
            catch {
                $lastErr = $_.Exception.Message
            }
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

        $requiredTasks = @('Disable-IEESC', 'EnableLogMachine')
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
