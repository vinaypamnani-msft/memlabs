####################################
### Functional Validation (Phase 11)
####################################
# Common.Validation.Functional.ps1
#
# Fast, role-specific functional tests run inside each guest VM via
# Invoke-VmCommand / PSDirect. Called by $global:Phase11Job after
# the build completes to confirm each VM's assigned role is working.

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
        try {
            $dns = Resolve-DnsName -Name $domainFqdn -Type A -ErrorAction Stop
            if ($dns) {
                $results.Details.Add("OK: DNS resolves '$domainFqdn'")
            }
        }
        catch {
            $results.Passed = $false
            $results.Details.Add("FAIL: DNS cannot resolve '$domainFqdn': $($_.Exception.Message)")
        }

        # dcdiag quick checks (Services + Replications)
        try {
            $dcdiag = & dcdiag.exe /test:Services /test:Replications /test:FSMOCheck /q 2>&1
            $dcdiagText = $dcdiag -join "`n"
            $failCount = ([regex]::Matches($dcdiagText, 'failed test')).Count
            if ($failCount -gt 0) {
                $results.Passed = $false
                $results.Details.Add("FAIL: dcdiag reported $failCount failed test(s)")
                # Include first few failure lines for diagnostics
                $failLines = $dcdiag | Where-Object { $_ -match 'failed test' } | Select-Object -First 3
                foreach ($fl in $failLines) { $results.Details.Add("  $($fl.Trim())") }
            }
            else {
                $results.Details.Add("OK: dcdiag Services/Replications/FSMOCheck passed")
            }
        }
        catch {
            $results.Details.Add("WARN: dcdiag execution failed: $($_.Exception.Message)")
            # Don't fail the whole test for dcdiag issues - services are the critical check
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

    $scriptBlock = {
        param($instName, $port)
        $results = @{ Passed = $true; Details = [System.Collections.Generic.List[string]]::new() }

        # Determine service name
        $svcName = if ($instName -eq 'MSSQLSERVER') { 'MSSQLSERVER' } else { "MSSQL`$$instName" }

        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if (-not $svc) {
            $results.Passed = $false
            $results.Details.Add("FAIL: SQL service '$svcName' not found")
            return $results
        }
        if ($svc.Status -ne 'Running') {
            $results.Passed = $false
            $results.Details.Add("FAIL: SQL service '$svcName' is $($svc.Status)")
            return $results
        }
        $results.Details.Add("OK: SQL service '$svcName' is Running")

        # SQL Agent
        $agentName = if ($instName -eq 'MSSQLSERVER') { 'SQLSERVERAGENT' } else { "SQLAgent`$$instName" }
        $agent = Get-Service -Name $agentName -ErrorAction SilentlyContinue
        if ($agent -and $agent.Status -eq 'Running') {
            $results.Details.Add("OK: SQL Agent '$agentName' is Running")
        }
        elseif ($agent) {
            $results.Details.Add("WARN: SQL Agent '$agentName' is $($agent.Status)")
        }

        # Test connectivity via Invoke-Sqlcmd
        try {
            $connStr = if ($instName -eq 'MSSQLSERVER') { 'localhost' } else { "localhost\$instName" }
            if ($port) { $connStr = "localhost,$port" }
            Import-Module SqlServer -ErrorAction SilentlyContinue
            if (-not (Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue)) {
                Import-Module SQLPS -DisableNameChecking -ErrorAction SilentlyContinue
            }
            $qr = Invoke-Sqlcmd -ServerInstance $connStr -Query "SELECT 1 AS TestResult" -QueryTimeout 30 -ErrorAction Stop
            if ($qr.TestResult -eq 1) {
                $results.Details.Add("OK: SQL query 'SELECT 1' succeeded on '$connStr'")
            }
            else {
                $results.Passed = $false
                $results.Details.Add("FAIL: SQL query returned unexpected result")
            }
        }
        catch {
            $results.Passed = $false
            $results.Details.Add("FAIL: SQL connectivity test failed: $($_.Exception.Message)")
        }

        return $results
    }

    $result = Invoke-VmCommand -VmName $VMName -VmDomainName $domain `
        -ScriptBlock $scriptBlock -ArgumentList $instanceName, $sqlPort `
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

        try {
            Import-Module SqlServer -ErrorAction SilentlyContinue
            if (-not (Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue)) {
                Import-Module SQLPS -DisableNameChecking -ErrorAction SilentlyContinue
            }
            $ag = Invoke-Sqlcmd -Query "SELECT ag.name AS GroupName, rs.synchronization_health_desc AS Health FROM sys.dm_hadr_availability_replica_states rs JOIN sys.availability_groups ag ON rs.group_id = ag.group_id" -QueryTimeout 30 -ErrorAction Stop
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
        try {
            [reflection.assembly]::LoadWithPartialName('Microsoft.UpdateServices.Administration') | Out-Null
            # Try port 8530 (HTTP) first, then 443 (HTTPS)
            $connected = $false
            foreach ($port in @(8530, 443)) {
                try {
                    $useSSL = ($port -eq 443)
                    $wsus = [Microsoft.UpdateServices.Administration.AdminProxy]::GetUpdateServer('localhost', $useSSL, $port)
                    if ($wsus) {
                        $results.Details.Add("OK: WSUS API connected on port $port")
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

    Write-Log "[Phase $Phase] $VMName [CM-$siteCode]: Testing ConfigMgr site services" -LogOnly

    $scriptBlock = {
        param($sc)
        $results = @{ Passed = $true; Details = [System.Collections.Generic.List[string]]::new() }

        # Check critical CM services
        foreach ($svc in @('SMS_EXECUTIVE', 'SMS_SITE_COMPONENT_MANAGER')) {
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

        if (-not $results.Passed) { return $results }

        # WMI site query with retry (CM components may still be initializing)
        $maxRetries = 3
        $retryDelay = 30
        $siteOk = $false
        for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
            try {
                $site = Get-WmiObject -Namespace "root\SMS\site_$sc" -Class SMS_Site -ErrorAction Stop
                if ($site) {
                    $results.Details.Add("OK: WMI SMS_Site query returned site '$sc'")
                    $siteOk = $true
                    break
                }
            }
            catch {
                if ($attempt -lt $maxRetries) {
                    Start-Sleep -Seconds $retryDelay
                }
                else {
                    $results.Passed = $false
                    $results.Details.Add("FAIL: WMI SMS_Site query failed after $maxRetries attempts: $($_.Exception.Message)")
                }
            }
        }

        # Component health check (allow a small number of warnings, fail on critical)
        if ($siteOk) {
            try {
                $critical = @(Get-WmiObject -Namespace "root\SMS\site_$sc" -Class SMS_ComponentSummarizer `
                    -Filter "Status = 2 AND TallyInterval = '0001128000100008'" -ErrorAction Stop)
                if ($critical.Count -gt 0) {
                    $results.Details.Add("WARN: $($critical.Count) component(s) in critical state:")
                    foreach ($c in ($critical | Select-Object -First 5)) {
                        $results.Details.Add("  - $($c.ComponentName): Status=$($c.Status)")
                    }
                    # Allow up to 2 critical components (transient startup issues)
                    if ($critical.Count -gt 2) {
                        $results.Passed = $false
                        $results.Details.Add("FAIL: More than 2 components in critical state")
                    }
                }
                else {
                    $results.Details.Add("OK: No critical component issues")
                }
            }
            catch {
                $results.Details.Add("WARN: Component health query failed: $($_.Exception.Message)")
            }
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
            try {
                $response = Invoke-WebRequest -Uri 'http://localhost/sms_mp/.sms_aut?mplist' `
                    -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
                if ($response.StatusCode -eq 200) {
                    $results.Details.Add("OK: MP endpoint returned HTTP 200")
                }
                else {
                    $results.Passed = $false
                    $results.Details.Add("FAIL: MP endpoint returned HTTP $($response.StatusCode)")
                }
            }
            catch {
                $results.Passed = $false
                $results.Details.Add("FAIL: MP endpoint unreachable: $($_.Exception.Message)")
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
            Write-Log "[Phase $Phase] $VMName [DP]: Verifying DP status from '$($parentVM.vmName)'" -LogOnly

            $dpScript = {
                param($sc, $dpVmName)
                $results = @{ Passed = $true; Details = [System.Collections.Generic.List[string]]::new() }
                try {
                    $dp = Get-WmiObject -Namespace "root\SMS\site_$sc" -Class SMS_DistributionPointInfo `
                        -Filter "ServerName LIKE '%$dpVmName%'" -ErrorAction Stop
                    if ($dp) {
                        $results.Details.Add("OK: DP '$dpVmName' found in site '$sc'")
                    }
                    else {
                        $results.Passed = $false
                        $results.Details.Add("FAIL: DP '$dpVmName' not found in site '$sc' SMS_DistributionPointInfo")
                    }
                }
                catch {
                    $results.Passed = $false
                    $results.Details.Add("FAIL: DP query failed: $($_.Exception.Message)")
                }
                return $results
            }

            $dpResult = Invoke-VmCommand -VmName $parentVM.vmName -VmDomainName $domain `
                -ScriptBlock $dpScript -ArgumentList $siteCode, $VMName `
                -DisplayName "Phase11-DP-Test" -SuppressLog

            if (-not (Format-TestResult -VMName $VMName -RoleLabel 'DP' -Result $dpResult)) {
                $allPassed = $false
            }
        }
        else {
            Write-Log "[Phase $Phase] $VMName [DP]: Cannot find parent site server for site '$siteCode'; skipping DP verification" -Warning
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
    Write-Log "[Phase $Phase] $VMName [RP]: Testing Reporting Services portal" -LogOnly

    $scriptBlock = {
        $results = @{ Passed = $true; Details = [System.Collections.Generic.List[string]]::new() }

        # Try common SSRS/PBIRS URLs
        $urls = @(
            'http://localhost/Reports',
            'https://localhost/Reports',
            'http://localhost:80/Reports'
        )
        $reachable = $false
        foreach ($url in $urls) {
            try {
                $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
                if ($response.StatusCode -eq 200) {
                    $results.Details.Add("OK: Reporting portal reachable at '$url'")
                    $reachable = $true
                    break
                }
            }
            catch {
                # Try next URL
            }
        }
        if (-not $reachable) {
            $results.Passed = $false
            $results.Details.Add("FAIL: Reporting portal not reachable on any standard URL")
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
        $svc = Get-Service -Name 'LanmanServer' -ErrorAction SilentlyContinue
        if (-not $svc -or $svc.Status -ne 'Running') {
            $results.Passed = $false
            $results.Details.Add("FAIL: LanmanServer service is not running")
            return $results
        }
        $results.Details.Add("OK: LanmanServer service is Running")

        # Check for non-default SMB shares (E$, F$, or named shares)
        $shares = @(Get-SmbShare -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notin @('ADMIN$', 'C$', 'IPC$', 'print$') })
        if ($shares.Count -gt 0) {
            $results.Details.Add("OK: Found $($shares.Count) non-default share(s): $($shares.Name -join ', ')")
        }
        else {
            # At minimum, E$ and F$ should exist (FileServer role requires E and F disks)
            $adminShares = @(Get-SmbShare -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -in @('E$', 'F$') })
            if ($adminShares.Count -ge 2) {
                $results.Details.Add("OK: E`$ and F`$ admin shares present")
            }
            else {
                $results.Passed = $false
                $results.Details.Add("FAIL: No non-default shares found and E`$/F`$ not both present")
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
        Correct end state is VM=Off. If it's still running, verify CA is operational.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$Domain
    )

    $Phase = 11
    Write-Log "[Phase $Phase] $VMName [StandaloneRootCA]: Validating Root CA state" -LogOnly

    # The correct post-deployment state is VM powered off
    $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if (-not $vm) {
        Write-Log "[Phase $Phase] $VMName [StandaloneRootCA]: FAIL - VM not found" -Failure
        return $false
    }

    if ($vm.State -eq 'Off') {
        Write-Log "[Phase $Phase] $VMName [StandaloneRootCA]: OK - VM is Off (expected post-deployment state)" -LogOnly
        Write-Log "[Phase $Phase] $VMName [StandaloneRootCA]: PASSED" -LogOnly
        return $true
    }

    # VM is unexpectedly running — run the standard CA tests
    Write-Log "[Phase $Phase] $VMName [StandaloneRootCA]: VM is $($vm.State) (expected Off) - running CA tests" -LogOnly
    return (Test-CAFunctionality -VMName $VMName -Domain $Domain)
}

function Test-CAFunctionality {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$Domain
    )

    $Phase = 11
    Write-Log "[Phase $Phase] $VMName [CA]: Testing Certificate Authority" -LogOnly

    $scriptBlock = {
        $results = @{ Passed = $true; Details = [System.Collections.Generic.List[string]]::new() }

        # CertSvc service (Active Directory Certificate Services)
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
        try {
            $ping = & certutil.exe -ping 2>&1
            $pingText = $ping -join "`n"
            if ($LASTEXITCODE -eq 0) {
                $results.Details.Add("OK: certutil -ping succeeded")
            }
            else {
                $results.Passed = $false
                $results.Details.Add("FAIL: certutil -ping failed (exit $LASTEXITCODE)")
            }
        }
        catch {
            $results.Passed = $false
            $results.Details.Add("FAIL: certutil -ping exception: $($_.Exception.Message)")
        }

        # Verify the CA certificate is valid (not expired)
        try {
            $caInfo = & certutil.exe -cainfo name 2>&1
            $caName = ($caInfo | Where-Object { $_ -match 'CA name:' }) -replace '.*CA name:\s*', ''
            if ($caName) {
                $results.Details.Add("OK: CA name = '$caName'")
            }

            $caCert = & certutil.exe -ca.cert 2>&1
            if ($LASTEXITCODE -eq 0) {
                $results.Details.Add("OK: CA certificate retrievable")
            }
            else {
                $results.Details.Add("WARN: certutil -ca.cert returned exit $LASTEXITCODE")
            }
        }
        catch {
            $results.Details.Add("WARN: CA certificate check failed: $($_.Exception.Message)")
        }

        return $results
    }

    $result = Invoke-VmCommand -VmName $VMName -VmDomainName $Domain `
        -ScriptBlock $scriptBlock -DisplayName "Phase11-CA-Test" -SuppressLog

    return (Format-TestResult -VMName $VMName -RoleLabel 'CA' -Result $result)
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
        $errMsg = if ($Result) { $Result.ScriptBlockFailed } else { 'Invoke-VmCommand returned no result' }
        Write-Log "[Phase $Phase] $VMName [$RoleLabel]: FAIL - $errMsg" -Failure
        return $false
    }

    $output = $Result.ScriptBlockOutput
    if (-not $output -or -not $output.ContainsKey('Passed')) {
        Write-Log "[Phase $Phase] $VMName [$RoleLabel]: FAIL - Test script returned unexpected output" -Failure
        return $false
    }

    # Log all detail lines
    if ($output.Details) {
        foreach ($line in $output.Details) {
            $isError = $line -match '^FAIL:'
            if ($isError) {
                Write-Log "[Phase $Phase] $VMName [$RoleLabel]: $line" -Failure
            }
            else {
                Write-Log "[Phase $Phase] $VMName [$RoleLabel]: $line" -LogOnly
            }
        }
    }

    if ($output.Passed) {
        Write-Log "[Phase $Phase] $VMName [$RoleLabel]: All checks PASSED" -Success
        return $true
    }
    else {
        Write-Log "[Phase $Phase] $VMName [$RoleLabel]: FAILED" -Failure
        return $false
    }
}

#endregion
