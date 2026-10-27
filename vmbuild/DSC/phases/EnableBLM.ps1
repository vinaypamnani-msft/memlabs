#EnableBLM.ps1
param(
    [string]$ConfigFilePath,
    [string]$LogPath
)

$Tag = "[EnableBLM]"

if (-not $ConfigFilePath) {
    $ConfigFilePath = "C:\staging\DSC\deployConfig.json"
}

# Read config json
$deployConfig = Get-Content $ConfigFilePath | ConvertFrom-Json

# Resolve this VM and its cmOptions so multi-hierarchy deploys (CAS hierarchy
# alongside a separate standalone Primary with differing EnableBLM) pick the
# correct hierarchy's flag.
$ThisMachineName = if ($deployConfig.parameters.ThisMachineName) { $deployConfig.parameters.ThisMachineName } else { $env:COMPUTERNAME }
$ThisVM = $deployConfig.virtualMachines | Where-Object { $_.vmName -eq $ThisMachineName }
$cmo = if ($ThisVM -and $ThisVM.cmOptions) { $ThisVM.cmOptions } else { $deployConfig.cmOptions }

# Determine if BLM should run: either cmOptions.EnableBLM is set, or VMs have BitLocker=true
$blmEnabled = $cmo.EnableBLM
$blmVMs = @($deployConfig.virtualMachines | Where-Object { $_.BitLocker -eq $true })
if (-not $blmEnabled -and $blmVMs.Count -eq 0) {
    Write-DscStatus "$Tag EnableBLM is not set and no VMs have BitLocker=true. Skipping."
    return
}
if (-not $blmEnabled -and $blmVMs.Count -gt 0) {
    Write-DscStatus "$Tag cmOptions.EnableBLM not set, but $($blmVMs.Count) VM(s) have BitLocker=true (existing domain BLM). Proceeding with collection membership."
}

# Connect to the CM site (imports module, sets up PS drive, sets location)
Write-DscStatus "$Tag Connecting to CM site..."
. $PSScriptRoot\Connect-CMSite.ps1 -Tag $Tag

$DomainFullName = $deployConfig.parameters.domainName

Write-DscStatus "$Tag Configuring BitLocker Management (Domain: $DomainFullName)"

# Enable the BLM Recovery Service web app on all MPs in the site.
# Mechanism (verified from cmmain source):
#   1. Set SC_SiteDefinition_Property.EnableMBAMRecoveryService = 1 (via SMS_SCI_SiteDefinition WMI)
#   2. Site Component Manager pushes HKLM:\SOFTWARE\Microsoft\SMS\MP\EnableMBAMRecoveryService=1 to each MP
#   3. MP control runs bin\x64\MBAMRecoveryServiceInstaller.ps1 which creates IIS app 'SMS_MP_MBAM'
#      under Default Web Site with app pool 'SMS MP MBAM Pool'.
# Without this, the Console cannot query recovery keys (the web app is the read-back endpoint).
# Idempotent: no-op if Value already == 1; SCM won't re-push to MPs unless the value changes.
try {
    $siteCode = Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Microsoft\SMS\Identification' -Name 'Site Code' -ErrorAction Stop
    $wmiNs    = "root\sms\site_$siteCode"
    $siteDefLazy = Get-WmiObject -Namespace $wmiNs -Class SMS_SCI_SiteDefinition -Filter "SiteCode='$siteCode'" -ErrorAction Stop
    if ($siteDefLazy) {
        $siteDef  = [wmi]"$($siteDefLazy.__PATH)"
        $existing = $siteDef.Props | Where-Object PropertyName -eq 'EnableMBAMRecoveryService'
        if ($existing -and $existing.Value -eq 1) {
            Write-DscStatus "$Tag Recovery Service site property already enabled (no-op)."
        }
        else {
            if ($existing) {
                $existing.Value  = 1
                $existing.Value1 = ''
                $existing.Value2 = ''
            }
            else {
                $cls = [wmiclass]"\\.\$($wmiNs):SMS_EmbeddedProperty"
                $new = $cls.CreateInstance()
                $new.PropertyName = 'EnableMBAMRecoveryService'
                $new.Value  = 1
                $new.Value1 = ''
                $new.Value2 = ''
                $siteDef.Props = @($siteDef.Props) + $new
            }
            $siteDef.Put() | Out-Null
            Write-DscStatus "$Tag Set EnableMBAMRecoveryService=1 on site $siteCode. SCM will push to MPs (~1-5 min)."
            try {
                Restart-Service -Name SMS_SITE_COMPONENT_MANAGER -Force -ErrorAction Stop
                Write-DscStatus "$Tag Restarted SMS_SITE_COMPONENT_MANAGER to accelerate MP push."
            } catch {
                Write-DscStatus "$Tag SCM restart failed (will pick up on next cycle): $($_.Exception.Message)"
            }
        }
    }
    else {
        Write-DscStatus "$Tag WARNING: SMS_SCI_SiteDefinition not found for site $siteCode -- skipping recovery service enable."
    }
}
catch {
    Write-DscStatus "$Tag WARNING: Failed to enable BLM Recovery Service site property: $($_.Exception.Message)"
}

# Create collection for BitLocker clients (direct membership only, no OU query)
$blmCollectionName = "MEMLABS-BitLocker Clients"
Write-DscStatus "$Tag Checking if collection '$blmCollectionName' exists..."
$existingCollection = Get-CMDeviceCollection -Name $blmCollectionName -ErrorAction SilentlyContinue
if (-not $existingCollection) {
    Write-DscStatus "$Tag Collection not found, creating '$blmCollectionName'..."
    $blmSchedule = New-CMSchedule -RecurInterval Days -RecurCount 1
    New-CMDeviceCollection -Name $blmCollectionName -LimitingCollectionId SMS00001 -RefreshSchedule $blmSchedule -RefreshType Periodic | Out-Null
    Write-DscStatus "$Tag Created collection: $blmCollectionName"
}
else {
    Write-DscStatus "$Tag Collection '$blmCollectionName' already exists (ID: $($existingCollection.CollectionID))"
}

# Get collection object for later use
Write-DscStatus "$Tag Retrieving collection object for '$blmCollectionName'..."
$blmCollection = Get-CMDeviceCollection -Name $blmCollectionName -ErrorAction SilentlyContinue
if ($blmCollection) {
    Write-DscStatus "$Tag Got collection object (ID: $($blmCollection.CollectionID), MemberCount: $($blmCollection.MemberCount))"
}
else {
    Write-DscStatus "$Tag WARNING: Get-CMDeviceCollection returned null for '$blmCollectionName'"
}

# Add query membership rules for BitLocker VMs (by name - resilient to ResourceID changes)
if ($blmCollection) {
    Write-DscStatus "$Tag Found $($blmVMs.Count) VM(s) with BitLocker=true in deployConfig"

    foreach ($blmVM in $blmVMs) {
        $vmResourceName = $blmVM.vmName
        $ruleName = "BLM-$vmResourceName"
        $existingRule = Get-CMDeviceCollectionQueryMembershipRule -CollectionId $blmCollection.CollectionID -RuleName $ruleName -ErrorAction SilentlyContinue
        if (-not $existingRule) {
            $query = "SELECT * FROM SMS_R_System WHERE Name = '$vmResourceName'"
            try {
                Add-CMDeviceCollectionQueryMembershipRule -CollectionId $blmCollection.CollectionID -RuleName $ruleName -QueryExpression $query -ErrorAction Stop
                Write-DscStatus "$Tag Added query rule '$ruleName' to $blmCollectionName"
            }
            catch {
                Write-DscStatus "$Tag WARNING: Failed to add query rule '$ruleName': $($_.Exception.Message)"
            }
        }
        else {
            Write-DscStatus "$Tag Query rule '$ruleName' already exists in $blmCollectionName"
        }
    }

    # Force collection membership evaluation and verify members appear
    # Trigger AD System Discovery first — devices must exist in CM before
    # query rules can match them. PushClients may have already done this,
    # but DDR processing can lag.
    try { Invoke-CMSystemDiscovery } catch {}
    try { Invoke-CMCollectionUpdate -CollectionId $blmCollection.CollectionID -ErrorAction Stop } catch {
        Write-DscStatus "$Tag WARNING: Invoke-CMCollectionUpdate failed: $($_.Exception.Message)"
    }
    Write-DscStatus "$Tag Triggered AD system discovery + collection evaluation for $blmCollectionName"

    # Wait for evaluation to complete - members must be visible for deployment to work
    # Query rules will match once the device is discovered (any ResourceID)
    $evalRetries = 12
    $evalDelay = 10
    for ($i = 1; $i -le $evalRetries; $i++) {
        Start-Sleep -Seconds $evalDelay
        # Get-CMCollectionMember queries SMS_CM_RES_COLL_<ID> which maps to a SQL
        # view that ConfigMgr creates asynchronously after New-CMDeviceCollection.
        # Until the view exists, the SMS Provider throws a terminating WMI error
        # ("Invalid object name '_RES_COLL_xxx'") that -ErrorAction cannot suppress.
        # Catch it and treat as 0 members -- the view will appear on a later attempt.
        try {
            $members = @(Get-CMCollectionMember -CollectionId $blmCollection.CollectionID -ErrorAction Stop)
        }
        catch {
            Write-DscStatus "$Tag Collection member query failed (attempt $i/$evalRetries, view may not exist yet): $($_.Exception.Message)"
            $members = @()
        }
        $expectedNames = @($blmVMs | ForEach-Object { $_.vmName })
        $found = @($members | Where-Object { $_.Name -in $expectedNames })
        if ($found.Count -ge $expectedNames.Count) {
            Write-DscStatus "$Tag Collection evaluation complete: $($members.Count) total member(s), $($found.Count)/$($expectedNames.Count) expected BLM clients visible"
            break
        }
        if ($i -lt $evalRetries) {
            Write-DscStatus "$Tag Waiting for collection evaluation ($i/$evalRetries): $($found.Count)/$($expectedNames.Count) expected BLM clients visible..."
            try { Invoke-CMCollectionUpdate -CollectionId $blmCollection.CollectionID -ErrorAction Stop } catch {
                Write-DscStatus "$Tag WARNING: Invoke-CMCollectionUpdate retry failed: $($_.Exception.Message)"
            }
        }
        else {
            $missing = $expectedNames | Where-Object { $_ -notin $members.Name }
            Write-DscStatus "$Tag WARNING: After $($evalRetries * $evalDelay)s, missing members: $($missing -join ', '). They will appear once discovered by the site."
        }
    }
}

# Build BitLocker policy objects for drive encryption (only when cmOptions.EnableBLM is set)
if ($blmEnabled) {
    # Resolve SQL server instance (may be remote SQL or SQLAO listener).
    # Follows the same pattern as InstallAndUpdateSCCM.ps1 for consistency.
    $sqlServerName = $env:COMPUTERNAME
    $sqlInstanceName = $ThisVM.sqlInstanceName
    $sqlPort = if ($ThisVM.sqlPort) { $ThisVM.sqlPort } else { 1433 }

    if ($ThisVM.remoteSQLVM) {
        $SQLVM = $deployConfig.virtualMachines | Where-Object { $_.vmName -eq $ThisVM.remoteSQLVM }
        $sqlServerName = $ThisVM.remoteSQLVM
        $sqlInstanceName = $SQLVM.sqlInstanceName
        $sqlPort = if ($SQLVM.sqlPort) { $SQLVM.sqlPort } else { 1433 }
        if ($SQLVM.AlwaysOnListenerName) {
            $sqlServerName = $SQLVM.AlwaysOnListenerName
            $sqlPort = $SQLVM.thisParams.SQLAO.SQLAOPort
        }
    }

    # Invoke-Sqlcmd -ServerInstance format: "server\instance,port" or "server,port"
    $sqlConnStr = $sqlServerName
    if ($sqlInstanceName -and $sqlInstanceName -ne 'MSSQLSERVER') {
        $sqlConnStr = "$sqlServerName\$sqlInstanceName"
    }
    if ($sqlPort -and $sqlPort -ne 1433) {
        $sqlConnStr = "$sqlConnStr,$sqlPort"
    }
    # FQDN version for the Helpdesk installer (-SqlServerName must be FQDN)
    $sqlServerFqdnBase = "$($sqlServerName.Split('\')[0]).$DomainFullName"
    $sqlInstanceFqdn = $sqlServerFqdnBase
    if ($sqlInstanceName -and $sqlInstanceName -ne 'MSSQLSERVER') {
        $sqlInstanceFqdn = "$sqlServerFqdnBase\$sqlInstanceName"
    }
    Write-DscStatus "$Tag SQL resolved: ConnStr=$sqlConnStr FQDN=$sqlInstanceFqdn Port=$sqlPort"

    # Ensure SQL encryption certificate exists (required for BLM recovery key escrow)
    # Reference: https://learn.microsoft.com/en-us/mem/configmgr/protect/deploy-use/bitlocker/encrypt-recovery-data
    $cmDbName = "CM_$SiteCode"
    Write-DscStatus "$Tag Ensuring SQL encryption certificate exists for database '$cmDbName'..."
    try {
        Push-Location $env:SystemDrive
        $cm_svc_file = "C:\Staging\DSC\cm_svc.txt"
        if (-not (Test-Path $cm_svc_file)) {
            throw "SQL service account password file '$cm_svc_file' not found. Cannot create database master key without it."
        }
        $masterKeyPass = (Get-Content $cm_svc_file).Trim()
        if ([string]::IsNullOrWhiteSpace($masterKeyPass)) {
            throw "SQL service account password file '$cm_svc_file' is empty. Cannot create database master key."
        }
        $sqlCertQuery = @"
USE [$cmDbName];
IF NOT EXISTS (SELECT name FROM sys.symmetric_keys WHERE name = '##MS_DatabaseMasterKey##')
BEGIN
    CREATE MASTER KEY ENCRYPTION BY PASSWORD = '$masterKeyPass'
END

IF NOT EXISTS (SELECT name FROM sys.certificates WHERE name = 'BitLockerManagement_CERT')
BEGIN
    CREATE CERTIFICATE BitLockerManagement_CERT AUTHORIZATION RecoveryAndHardwareCore
    WITH SUBJECT = 'BitLocker Management',
    EXPIRY_DATE = '20391022';

    GRANT CONTROL ON CERTIFICATE ::BitLockerManagement_CERT TO RecoveryAndHardwareRead;
    GRANT CONTROL ON CERTIFICATE ::BitLockerManagement_CERT TO RecoveryAndHardwareWrite;
END
ELSE
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM sys.certificates c
        JOIN sys.database_principals p ON c.principal_id = p.principal_id
        WHERE c.name = 'BitLockerManagement_CERT' AND p.name = 'RecoveryAndHardwareCore')
    BEGIN
        ALTER AUTHORIZATION ON CERTIFICATE ::BitLockerManagement_CERT TO RecoveryAndHardwareCore;
    END

    GRANT CONTROL ON CERTIFICATE ::BitLockerManagement_CERT TO RecoveryAndHardwareRead;
    GRANT CONTROL ON CERTIFICATE ::BitLockerManagement_CERT TO RecoveryAndHardwareWrite;
END
"@
        Invoke-Sqlcmd -Query $sqlCertQuery -ServerInstance $sqlConnStr -TrustServerCertificate -ErrorAction Stop
        Write-DscStatus "$Tag SQL encryption certificate ensured for $cmDbName on $sqlConnStr"
    }
    catch {
        Write-DscStatus "$Tag WARNING: SQL cert creation failed: $($_.Exception.Message)"
    }
    finally {
        Pop-Location
    }

    Write-DscStatus "$Tag Building BitLocker policy objects..."
    $blmPolicies = @()
    $blmPolicies += New-CMBLEncryptionMethodWithXts -PolicyState Enabled -OSDriveEncryptionMethod AesXts256 -FixedDriveEncryptionMethod AesXts256
    $blmPolicies += New-CMBMSOSDEncryptionPolicy -PolicyState Enabled -Protector TpmOnly
    $blmPolicies += New-CMUseOsEnforcePolicy -PolicyState Enabled -GracePeriodDays 0
    $blmPolicies += New-CMBMSFDVEncryptionPolicy -PolicyState Enabled -AutoUnlock Require
    $blmPolicies += New-CMUseFddEnforcePolicy -PolicyState Enabled -GracePeriodDays 0
    $blmPolicies += New-CMBMSClientConfigureCheckIntervalPolicy -PolicyState Enabled -ClientWakeupFrequencyMinutes 5 -KeyRecoveryOption PasswordAndPackage
    Write-DscStatus "$Tag Built $($blmPolicies.Count) policy objects (XtsAes256, TpmOnly, OsEnforce0d, FdvAutoUnlock, FddEnforce0d, ClientCheck5m)"

    # Create BitLocker management policy (skip if already exists)
    $blmPolicyName = "MEMLABS-BitLocker Policy"
    Write-DscStatus "$Tag Checking if BitLocker policy '$blmPolicyName' exists..."
    $blmPolicy = Get-CMBlmSetting -Name $blmPolicyName -ErrorAction SilentlyContinue
    if (-not $blmPolicy) {
        # New-CMBlmSetting can throw a bare System.Management.ManagementException
        # immediately after EnableMBAMRecoveryService is set, because the SMS
        # Provider connection was established before the feature was enabled and
        # hasn't picked up the BLM policy classes yet. Retry with a short backoff,
        # logging full exception details and the exact command line on each failure.
        $blmCmd = "New-CMBlmSetting -Name '$blmPolicyName' -Description 'MEMLABS auto created BitLocker management policy' -Policies <$($blmPolicies.Count) policy objects: XtsAes256, TpmOnly, OsEnforce0d, FdvAutoUnlock, FddEnforce0d, ClientCheck5m> -ErrorAction Stop"
        $blmMaxRetries = 5
        $blmRetryDelay = 30
        for ($blmAttempt = 1; $blmAttempt -le $blmMaxRetries; $blmAttempt++) {
            Write-DscStatus "$Tag Policy not found, creating '$blmPolicyName' with $($blmPolicies.Count) sub-policies (attempt $blmAttempt/$blmMaxRetries)..."
            try {
                $blmPolicy = New-CMBlmSetting -Name $blmPolicyName -Description "MEMLABS auto created BitLocker management policy" -Policies $blmPolicies -ErrorAction Stop
                Write-DscStatus "$Tag Created BitLocker policy: $blmPolicyName"
                break
            }
            catch {
                $ex = $_.Exception
                $exType = $ex.GetType().FullName
                $exMsg = $ex.Message
                # Surface inner exception (the ManagementException usually wraps the real provider error here)
                $innerMsg = ""
                $inner = $ex.InnerException
                $innerDepth = 0
                while ($inner -and $innerDepth -lt 5) {
                    $innerMsg += " | inner[$($inner.GetType().FullName)]: $($inner.Message)"
                    $inner = $inner.InnerException
                    $innerDepth++
                }
                # WMI/SMS Provider errors carry an ErrorCode on the ManagementException
                $wmiCode = ""
                try { if ($ex.ErrorCode) { $wmiCode = " ErrorCode=$($ex.ErrorCode)" } } catch {}
                $catInfo = ""
                try { if ($_.CategoryInfo) { $catInfo = " Category=$($_.CategoryInfo.Category)/$($_.CategoryInfo.Reason)" } } catch {}
                $fqeid = ""
                try { if ($_.FullyQualifiedErrorId) { $fqeid = " FQEID=$($_.FullyQualifiedErrorId)" } } catch {}
                $scriptPos = ""
                try { if ($_.InvocationInfo -and $_.InvocationInfo.PositionMessage) { $scriptPos = ($_.InvocationInfo.PositionMessage -replace "\r?\n", " ").Trim() } } catch {}

                Write-DscStatus "$Tag ERROR: New-CMBlmSetting failed (attempt $blmAttempt/$blmMaxRetries)"
                Write-DscStatus "$Tag   Command : $blmCmd"
                Write-DscStatus "$Tag   Type    : $exType$wmiCode$catInfo$fqeid"
                Write-DscStatus "$Tag   Message : $exMsg$innerMsg"
                if ($scriptPos) { Write-DscStatus "$Tag   At      : $scriptPos" }

                if ($blmAttempt -lt $blmMaxRetries) {
                    Write-DscStatus "$Tag   Retrying in $blmRetryDelay s (refreshing SMS Provider connection)..."
                    Start-Sleep -Seconds $blmRetryDelay
                    # Re-check in case a prior attempt actually created the policy despite throwing
                    $blmPolicy = Get-CMBlmSetting -Name $blmPolicyName -ErrorAction SilentlyContinue
                    if ($blmPolicy) {
                        Write-DscStatus "$Tag Policy '$blmPolicyName' now present after attempt $blmAttempt; continuing."
                        break
                    }
                }
                else {
                    Write-DscStatus "$Tag ERROR: New-CMBlmSetting failed after $blmMaxRetries attempts. Policy not created."
                }
            }
        }
    }
    else {
        Write-DscStatus "$Tag BitLocker policy '$blmPolicyName' already exists, skipping creation"
    }

    # Ensure policy is deployed to the collection
    Write-DscStatus "$Tag Checking deployment state (blmPolicy=$([bool]$blmPolicy), blmCollection=$([bool]$blmCollection))..."
    if ($blmPolicy -and $blmCollection) {
        $existingDeployment = Get-CMSettingDeployment -CMSetting $blmPolicy -ErrorAction SilentlyContinue |
            Where-Object { $_.CollectionId -eq $blmCollection.CollectionID }
        if (-not $existingDeployment) {
            Write-DscStatus "$Tag No existing deployment found, deploying policy to '$blmCollectionName' (ID: $($blmCollection.CollectionID))..."
            try {
                New-CMSettingDeployment -CMSetting $blmPolicy -CollectionId $blmCollection.CollectionID -ErrorAction Stop
                Write-DscStatus "$Tag Deployed BitLocker policy to $blmCollectionName"
            }
            catch {
                Write-DscStatus "$Tag ERROR: New-CMSettingDeployment failed: $($_.Exception.Message)"
            }
        }
        else {
            Write-DscStatus "$Tag BitLocker policy already deployed to $blmCollectionName (DeploymentID: $($existingDeployment.CI_ID))"
        }
    }
    else {
        if (-not $blmPolicy) { Write-DscStatus "$Tag WARNING: BitLocker policy object is null, cannot create deployment" }
        if (-not $blmCollection) { Write-DscStatus "$Tag WARNING: Collection '$blmCollectionName' not found, cannot create deployment" }
    }
}
else {
    Write-DscStatus "$Tag Skipping policy creation/deployment (cmOptions.EnableBLM not set; policy should already exist from original build)"
}

# Install the BLM Helpdesk Portal web app on this Primary site server.
# The ConfigMgr Console has NO built-in recovery-key UI -- the Helpdesk Portal
# (/HelpDesk on the site server) is Microsoft's only first-party tool for
# looking up BitLocker recovery keys from the CM database.
#
# This block is built for a 4-hour deployment: every step is logged, every
# external call is wrapped in try/catch, and it is FULLY idempotent. If a
# prior install is already healthy we do nothing -- we never re-run the
# MBAMWebSiteInstaller against a working install (it tears down and rebuilds
# the SQL grants + IIS app on every run, which is risky).
if ($blmEnabled) {

    function Test-BlmPortalHealth {
        # Returns hashtable: @{ Installed=$bool; AppOk=$bool; PoolOk=$bool; Reg=$bool; ConnStr=$str; Details=$str }
        $result = @{ Installed=$false; AppOk=$false; SspOk=$false; PoolOk=$false; Reg=$false; ConnStr=$null; Details=@() }
        try {
            Import-Module WebAdministration -ErrorAction Stop
        } catch {
            $result.Details += "WebAdministration module load failed: $($_.Exception.Message)"
            return $result
        }
        try {
            $app = Get-WebApplication -Site 'Default Web Site' -Name 'HelpDesk' -ErrorAction SilentlyContinue
            if ($app) {
                $result.AppOk = $true
                $result.Details += "IIS app /HelpDesk -> $($app.PhysicalPath)"
                if ($app.PhysicalPath -and -not (Test-Path $app.PhysicalPath)) {
                    $result.Details += "WARN: HelpDesk physical path missing on disk"
                    $result.AppOk = $false
                }
                $poolName = $app.applicationPool
                if ($poolName) {
                    $pool = Get-Item "IIS:\AppPools\$poolName" -ErrorAction SilentlyContinue
                    if ($pool) {
                        $result.Details += "AppPool '$poolName' state=$($pool.State)"
                        $result.PoolOk = $true
                    } else {
                        $result.Details += "WARN: AppPool '$poolName' not found"
                    }
                }
            } else {
                $result.Details += "IIS app /HelpDesk not present"
            }
            $ssp = Get-WebApplication -Site 'Default Web Site' -Name 'SelfService' -ErrorAction SilentlyContinue
            if ($ssp) {
                $result.SspOk = $true
                $result.Details += "IIS app /SelfService -> $($ssp.PhysicalPath)"
            } else {
                $result.Details += "IIS app /SelfService not present"
            }
        } catch {
            $result.Details += "IIS probe failed: $($_.Exception.Message)"
        }
        try {
            $webKey = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\MBAM Server\Web' -ErrorAction SilentlyContinue
            if ($webKey -and $webKey.RecoveryDBConnectionString) {
                $result.Reg = $true
                $result.ConnStr = $webKey.RecoveryDBConnectionString
                $result.Details += "Registry conn string present"
            } else {
                $result.Details += "Registry MBAM Server\Web missing or empty"
            }
        } catch {
            $result.Details += "Registry probe failed: $($_.Exception.Message)"
        }
        $result.Installed = ($result.AppOk -and $result.SspOk -and $result.Reg)
        return $result
    }

    $blmGroup       = 'BLM Helpdesk Users'
    # Authoritative NetBIOS domain name -- deployConfig.vmOptions.domainNetBiosName is the
    # single source of truth (it is what Phase 2 actually created the domain with via the
    # ADDomain resource's DomainNetBiosName). NEVER derive it from the FQDN: in a disjoint
    # namespace the NetBIOS name differs from the DNS first label (e.g. DNS
    # 'wacky.sandwich.lab' with NetBIOS 'TACO'). If the field is somehow absent, fall back to
    # AD's authoritative Get-ADDomain.NetBIOSName (we run on the domain-joined primary), NOT
    # the DNS label. Used BOTH for the pre-qualified group names AND -- critically -- for the
    # installer's -DomainName parameter, which the MBAM installer feeds VERBATIM into
    # Get-DomainMachineName as "{DomainName}\{COMPUTERNAME}$" to CREATE LOGIN the site-server
    # machine account on (possibly remote) SQL. That name MUST be the NetBIOS domain (SQL's
    # LookupAccountName rejects the DNS-suffix form 'contoso.dns.suffix\HOST$' with 'Windows
    # NT user or group ... not found'). See the -DomainName pass-through below.
    $netbios        = $deployConfig.vmOptions.domainNetBiosName
    if ([string]::IsNullOrWhiteSpace($netbios)) {
        try { $netbios = (Get-ADDomain -ErrorAction Stop).NetBIOSName } catch { }
    }
    $qualifiedGroup = "$netbios\$blmGroup"
    $localServerFqdn = "$env:COMPUTERNAME.$DomainFullName"
    $cmDbName       = "CM_$SiteCode"

    Write-DscStatus "$Tag === Helpdesk Portal: starting (Server=$localServerFqdn SqlServer=$sqlInstanceFqdn Db=$cmDbName Group=$qualifiedGroup Domain=$DomainFullName) ==="

    # ---- Pre-flight: is it already installed and healthy? -----------------
    try {
        $health = Test-BlmPortalHealth
        foreach ($d in $health.Details) { Write-DscStatus "$Tag   probe: $d" }

        if ($health.Installed) {
            # If conn string points somewhere unexpected, warn but DO NOT reinstall
            # (someone may have intentionally pointed it at a different DB).
            if ($health.ConnStr -and ($health.ConnStr -notlike "*$cmDbName*")) {
                Write-DscStatus "$Tag WARNING: existing portal connection string does not reference '$cmDbName'. Leaving as-is to avoid clobbering customization. ConnStr=$($health.ConnStr)"
            }
            # Make sure the app pool is running (cheap, safe).
            try {
                $app = Get-WebApplication -Site 'Default Web Site' -Name 'HelpDesk' -ErrorAction Stop
                $poolName = $app.applicationPool
                $pool = Get-Item "IIS:\AppPools\$poolName" -ErrorAction Stop
                if ($pool.State -ne 'Started') {
                    Write-DscStatus "$Tag App pool '$poolName' is $($pool.State); starting..."
                    Start-WebAppPool -Name $poolName -ErrorAction Stop
                    Write-DscStatus "$Tag App pool '$poolName' started."
                }
            } catch {
                Write-DscStatus "$Tag WARNING: could not verify/start app pool: $($_.Exception.Message)"
            }
            Write-DscStatus "$Tag Helpdesk Portal already installed and healthy. Skipping installer (idempotent no-op)."
        }
        else {
            # ---- AD group via ADSI (no RSAT required) -------------------------
            Write-DscStatus "$Tag Ensuring AD group '$blmGroup' exists (via ADSI)..."
            $groupReady = $false
            try {
                $root = [ADSI]"LDAP://RootDSE"
                $domainDn = $root.defaultNamingContext.ToString()
                Write-DscStatus "$Tag   domainDn=$domainDn"

                $finder = New-Object DirectoryServices.DirectorySearcher
                $finder.Filter = "(&(objectClass=group)(sAMAccountName=$blmGroup))"
                $found = $finder.FindOne()

                if (-not $found) {
                    Write-DscStatus "$Tag   group not found; creating in CN=Users,$domainDn"
                    try {
                        $usersOu = [ADSI]"LDAP://CN=Users,$domainDn"
                        $newGrp  = $usersOu.Create('group', "CN=$blmGroup")
                        $newGrp.Put('sAMAccountName', $blmGroup)
                        $newGrp.Put('groupType', -2147483646)  # Global Security
                        $newGrp.Put('description', 'BitLocker Management Helpdesk Users (recovery key lookup)')
                        $newGrp.SetInfo()
                        Write-DscStatus "$Tag   created '$blmGroup'; waiting for AD propagation..."
                    } catch {
                        Write-DscStatus "$Tag WARNING: New-ADGroup (ADSI) failed: $($_.Exception.Message)"
                    }
                    # Re-find with retry (DC replication / cache)
                    for ($i = 1; $i -le 6; $i++) {
                        Start-Sleep -Seconds 5
                        $finder2 = New-Object DirectoryServices.DirectorySearcher
                        $finder2.Filter = "(&(objectClass=group)(sAMAccountName=$blmGroup))"
                        $found = $finder2.FindOne()
                        if ($found) { Write-DscStatus "$Tag   group visible after $($i*5)s"; break }
                        Write-DscStatus "$Tag   waiting for group to be visible ($i/6)..."
                    }
                } else {
                    Write-DscStatus "$Tag   group already exists: $($found.Properties['distinguishedName'][0])"
                }

                if ($found) {
                    $groupReady = $true
                    # Add Domain Admins as a member if missing
                    try {
                        $daFinder = New-Object DirectoryServices.DirectorySearcher
                        $daFinder.Filter = "(&(objectClass=group)(sAMAccountName=Domain Admins))"
                        $daFound = $daFinder.FindOne()
                        if ($daFound) {
                            $grpObj = $found.GetDirectoryEntry()
                            $daDn   = $daFound.Properties['distinguishedName'][0]
                            $currentMembers = @($grpObj.member)
                            if ($currentMembers -contains $daDn) {
                                Write-DscStatus "$Tag   Domain Admins already a member."
                            } else {
                                $grpObj.Add("LDAP://$daDn")
                                Write-DscStatus "$Tag   added Domain Admins -> '$blmGroup'."
                            }
                        } else {
                            Write-DscStatus "$Tag WARNING: Domain Admins group not found via ADSI."
                        }
                    } catch {
                        Write-DscStatus "$Tag WARNING: failed to add Domain Admins to '$blmGroup': $($_.Exception.Message)"
                    }
                } else {
                    Write-DscStatus "$Tag WARNING: group '$blmGroup' still not visible after retries. Portal install will proceed; create group manually if portal sign-in fails."
                }
            } catch {
                Write-DscStatus "$Tag WARNING: AD group setup failed: $($_.Exception.Message)"
            }

            # ---- IIS + ASP.NET 4.5 prereqs (install-if-missing) ---------------
            # Web-Server / Web-Asp-Net45 / Web-Mgmt-Console are normally
            # installed by InstallFeatureForSCCM (TemplateHelpDSC) under the
            # "Site Server" role during Phase 2/3, but that has been observed
            # to leave Web-Asp-Net45 off on some site servers (logged here as
            # 'missing IIS prereq features: Web-Asp-Net45'). The MBAM Helpdesk /
            # Self-Service web apps cannot be created without ASP.NET 4.5, so
            # rather than only verifying, install any missing feature in-place
            # before running the installer. Install-WindowsFeature pulls in the
            # ASP.NET 4.5 dependency chain (Web-Net-Ext45, Web-ISAPI-Ext/Filter,
            # NET-Framework-45-ASPNET) automatically.
            Write-DscStatus "$Tag Verifying IIS / ASP.NET 4.5 features..."
            try {
                $needed  = @('Web-Server','Web-Asp-Net45','Web-Windows-Auth','Web-Mgmt-Console')
                $missing = @()
                foreach ($f in $needed) {
                    $feat = Get-WindowsFeature -Name $f -ErrorAction SilentlyContinue
                    if (-not $feat -or -not $feat.Installed) { $missing += $f }
                }
                if ($missing.Count -gt 0) {
                    Write-DscStatus "$Tag Installing missing IIS prereq features: $($missing -join ', ')..."
                    $stillMissing = @()
                    foreach ($f in $missing) {
                        try {
                            $r = Install-WindowsFeature -Name $f -IncludeManagementTools -ErrorAction Stop
                            Write-DscStatus "$Tag   installed '$f' (ExitCode=$($r.ExitCode), RestartNeeded=$($r.RestartNeeded))"
                        } catch {
                            Write-DscStatus "$Tag   WARNING: failed to install '$f': $($_.Exception.Message)"
                        }
                        $chk = Get-WindowsFeature -Name $f -ErrorAction SilentlyContinue
                        if (-not $chk -or -not $chk.Installed) { $stillMissing += $f }
                    }
                    if ($stillMissing.Count -gt 0) {
                        Write-DscStatus "$Tag ERROR: IIS prereq features still missing after install attempt: $($stillMissing -join ', '). Portal install will likely fail."
                    } else {
                        Write-DscStatus "$Tag   IIS prereqs now satisfied (installed: $($missing -join ', '))"
                    }
                } else {
                    $defaultSite = Get-Website -Name 'Default Web Site' -ErrorAction SilentlyContinue
                    if (-not $defaultSite) {
                        Write-DscStatus "$Tag ERROR: 'Default Web Site' is missing in IIS."
                    } else {
                        Write-DscStatus "$Tag   IIS prereqs OK; 'Default Web Site' state=$($defaultSite.State)"
                    }
                }
            } catch {
                Write-DscStatus "$Tag WARNING: IIS prereq check failed: $($_.Exception.Message)"
            }

            # ---- Locate and sanity-check the installer ------------------------
            $cmInstallDir = $null
            try {
                $cmInstallDir = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\SMS\Setup' -ErrorAction Stop).'Installation Directory'
            } catch {
                Write-DscStatus "$Tag ERROR: cannot read SMS Setup registry: $($_.Exception.Message)"
            }
            $installer = if ($cmInstallDir) { Join-Path $cmInstallDir 'bin\x64\MBAMWebSiteInstaller.ps1' } else { $null }
            Write-DscStatus "$Tag CM install dir: $cmInstallDir"
            Write-DscStatus "$Tag Installer path : $installer"

            $installerOk = $false
            if ($installer -and (Test-Path $installer)) {
                try {
                    $fi = Get-Item $installer -ErrorAction Stop
                    Write-DscStatus "$Tag Installer size=$($fi.Length) lastWrite=$($fi.LastWriteTime)"
                    if ($fi.Length -lt 1024) {
                        Write-DscStatus "$Tag WARNING: installer file is suspiciously small ($($fi.Length) bytes)"
                    }
                    # Quick content sanity check (param name we depend on)
                    $head = Get-Content $installer -TotalCount 200 -ErrorAction Stop
                    if (($head -join "`n") -match 'HelpdeskUsersGroupName') {
                        $installerOk = $true
                    } else {
                        Write-DscStatus "$Tag WARNING: installer does not appear to declare -HelpdeskUsersGroupName; aborting to avoid corruption."
                    }
                } catch {
                    Write-DscStatus "$Tag WARNING: installer sanity check failed: $($_.Exception.Message)"
                }
            } else {
                Write-DscStatus "$Tag WARNING: MBAMWebSiteInstaller.ps1 not found; skipping portal install."
            }

            # ---- Run the installer --------------------------------------------
            if ($installerOk) {
                # Pre-flight: the MBAM installer calls [System.Net.Dns]::GetHostByName($env:computerName)
                # at line 139 to resolve the local FQDN. If DNS suffix search list is missing or
                # the VM's A record isn't registered yet, this fails with "No such host is known"
                # and cascades into "Failure acquiring SQL identity certificate". Fix by ensuring
                # the primary DNS suffix is set and the hostname resolves.
                try {
                    $null = [System.Net.Dns]::GetHostByName($env:COMPUTERNAME)
                    Write-DscStatus "$Tag Pre-flight: DNS hostname resolution OK ($env:COMPUTERNAME)"
                }
                catch {
                    Write-DscStatus "$Tag Pre-flight: DNS hostname resolution FAILED for '$env:COMPUTERNAME': $($_.Exception.Message)"
                    # Ensure DNS suffix search list includes our domain
                    try {
                        $currentSuffix = (Get-DnsClient | Where-Object { $_.InterfaceAlias -notmatch 'Loopback' } | Select-Object -First 1).ConnectionSpecificSuffix
                        if (-not $currentSuffix) {
                            Write-DscStatus "$Tag Pre-flight: No DNS suffix on primary adapter. Setting to '$DomainFullName'..."
                            Get-DnsClient | Where-Object { $_.InterfaceAlias -notmatch 'Loopback' } | Set-DnsClient -ConnectionSpecificSuffix $DomainFullName -ErrorAction Stop
                            Register-DnsClient -ErrorAction SilentlyContinue
                            Start-Sleep -Seconds 5
                        }
                        # Retry resolution
                        $resolved = [System.Net.Dns]::GetHostByName($env:COMPUTERNAME)
                        Write-DscStatus "$Tag Pre-flight: DNS resolved after suffix fix -> $($resolved.HostName)"
                    }
                    catch {
                        Write-DscStatus "$Tag Pre-flight: DNS still failing after suffix fix: $($_.Exception.Message). MBAM installer will likely fail."
                    }
                }

                # ---- SQL Server Identification Certificate pre-flight ----------
                # Verified against ConfigMgr source
                # (src/SiteServer/mp/MBAM/MBAMWebSiteInstaller.ps1): the
                # installer's Get-CertificateFromSqlServer does NOT query SQL --
                # it reads Cert:\LocalMachine\My ON THE SQL BOX for an X509 cert
                # whose FriendlyName is 'ConfigMgr SQL Server Identification
                # Certificate' with a currently-valid NotBefore/NotAfter window,
                # exports its public blob and imports it into
                # LocalMachine\TrustedPeople so the portal can validate SQL's
                # 'Encrypt=True;TrustServerCertificate=False' connection. If that
                # cert is absent / expired / future-dated, Install-MBAMWebSites
                # writes 'Failure acquring SQL identity certificate' and rolls
                # the whole install back (the exact failure observed). CM site
                # setup provisions this cert and serializes it under
                # HKLM\SOFTWARE\Microsoft\SMS\SQL Server
                # (EncodedCertificateThumbprint / SerializedEncodedCertificate);
                # on a fresh deploy it can lag the portal install, so wait for it
                # (and recover a thumbprint-matched cert that lost its friendly
                # name) before launching.
                $certFriendly = 'ConfigMgr SQL Server Identification Certificate'
                $sqlHostShort = $sqlServerName.Split('\')[0]
                $isLocalSql   = ($sqlHostShort -eq $env:COMPUTERNAME) -or ($sqlServerFqdnBase -eq $localServerFqdn)
                $certProbe = {
                    param($friendly)
                    $now = Get-Date
                    $all = @(Get-ChildItem -Path Cert:\LocalMachine\My -ErrorAction SilentlyContinue)
                    $named = @($all | Where-Object { $_.FriendlyName -eq $friendly })
                    $valid = @($named | Where-Object { $_.NotBefore -lt $now -and $_.NotAfter -gt $now })
                    $regThumb = $null
                    try { $regThumb = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\SMS\SQL Server' -Name 'EncodedCertificateThumbprint' -ErrorAction Stop).EncodedCertificateThumbprint } catch {}
                    $recovered = $false
                    # Recover the common edge case: CM's registry names a cert by
                    # thumbprint that is present + date-valid in My but lost the
                    # friendly name the installer filters on. Setting FriendlyName
                    # on a cert obtained from an opened X509Store persists it.
                    if ($valid.Count -eq 0 -and $regThumb) {
                        try {
                            $store = New-Object System.Security.Cryptography.X509Certificates.X509Store('My','LocalMachine')
                            $store.Open('ReadWrite')
                            $byThumb = $store.Certificates | Where-Object { $_.Thumbprint -eq $regThumb -and $_.NotBefore -lt $now -and $_.NotAfter -gt $now } | Select-Object -First 1
                            if ($byThumb -and $byThumb.FriendlyName -ne $friendly) {
                                $byThumb.FriendlyName = $friendly
                                $recovered = $true
                            }
                            $store.Close()
                        } catch {}
                        if ($recovered) {
                            $all   = @(Get-ChildItem -Path Cert:\LocalMachine\My -ErrorAction SilentlyContinue)
                            $named = @($all | Where-Object { $_.FriendlyName -eq $friendly })
                            $valid = @($named | Where-Object { $_.NotBefore -lt $now -and $_.NotAfter -gt $now })
                        }
                    }
                    [pscustomobject]@{
                        ValidCount = $valid.Count
                        RegThumb   = $regThumb
                        Recovered  = $recovered
                        Inventory  = @($named | ForEach-Object { "FN='$($_.FriendlyName)' TP=$($_.Thumbprint) NB=$($_.NotBefore.ToString('s')) NA=$($_.NotAfter.ToString('s'))" })
                    }
                }

                # ---- Full SQL-identity-cert diagnostics (one-shot) -------------
                # We never get the user's environment, so on any failure dump
                # EVERYTHING needed to root-cause the missing/expired/removed cert
                # straight into the build log:
                #   1. Every CANDIDATE cert in LocalMachine\My + \TrustedPeople on
                #      the SQL box -- VALID *and* EXPIRED/NOT-YET-VALID -- matched
                #      by friendly name, Server-Auth EKU (1.3.6.1.5.5.7.3.1), or a
                #      subject containing the SQL host, with full dates/EKU/privkey.
                #   2. The CM registry serialization on the SITE SERVER
                #      (HKLM\SOFTWARE\Microsoft\SMS\SQL Server:
                #      EncodedCertificateThumbprint / SerializedEncodedCertificate).
                #   3. The CM_RoleIdCertificates DB row(s) (FriendlyName / Subject /
                #      UsageOID / ExpirationDate / Thumbprint + blob sizes) -- this is
                #      CM's own record of the cert, so an in-DB thumbprint that is
                #      absent from the store proves a post-install removal, while no
                #      row at all proves setup never created it.
                $serverAuthOid = '1.3.6.1.5.5.7.3.1'
                $certStoreDiag = {
                    param($friendly, $sqlHost, $sauthOid)
                    $now = Get-Date
                    $out = New-Object System.Collections.Generic.List[string]
                    foreach ($storeName in 'My','TrustedPeople') {
                        $certs = @(Get-ChildItem -Path "Cert:\LocalMachine\$storeName" -ErrorAction SilentlyContinue)
                        $cand  = @($certs | Where-Object {
                            ($_.FriendlyName -eq $friendly) -or
                            (@($_.EnhancedKeyUsageList | Where-Object { $_.ObjectId -eq $sauthOid }).Count -gt 0) -or
                            ($_.Subject -and $sqlHost -and ($_.Subject -like "*$sqlHost*"))
                        })
                        $out.Add("STORE LocalMachine\$storeName : $($certs.Count) total cert(s), $($cand.Count) candidate(s)")
                        foreach ($c in $cand) {
                            $state = 'VALID'
                            if ($c.NotBefore -gt $now) { $state = 'NOT-YET-VALID' }
                            elseif ($c.NotAfter -lt $now) { $state = 'EXPIRED' }
                            $ekus = @($c.EnhancedKeyUsageList | ForEach-Object { $_.ObjectId }) -join ','
                            if (-not $ekus) { $ekus = '<none>' }
                            $out.Add(("  [{0}] TP={1} FN='{2}' Subj='{3}' NB={4} NA={5} PrivKey={6} EKU={7}" -f `
                                $state, $c.Thumbprint, $c.FriendlyName, $c.Subject, `
                                $c.NotBefore.ToString('s'), $c.NotAfter.ToString('s'), $c.HasPrivateKey, $ekus))
                        }
                    }
                    return $out
                }
                $certDiagEmitted = $false
                $emitCertDiagnostics = {
                    Write-DscStatus "$Tag === SQL identity cert diagnostics (one-shot; we have no access to the user's env) ==="
                    # 1) cert store on the SQL box (valid AND invalid candidates)
                    try {
                        if ($isLocalSql) { $lines = & $certStoreDiag $certFriendly $sqlHostShort $serverAuthOid }
                        else { $lines = Invoke-Command -ComputerName $sqlServerFqdnBase -ScriptBlock $certStoreDiag -ArgumentList $certFriendly, $sqlHostShort, $serverAuthOid -ErrorAction Stop }
                        foreach ($l in $lines) { Write-DscStatus "$Tag   $l" }
                    } catch { Write-DscStatus "$Tag   cert store dump failed on ${sqlHostShort}: $($_.Exception.Message)" }
                    # 2) CM registry serialization on the SITE SERVER (always local)
                    try {
                        $rk = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\SMS\SQL Server' -ErrorAction Stop
                        $encThumb  = $rk.EncodedCertificateThumbprint
                        $serEncLen = 0; if ($rk.SerializedEncodedCertificate) { $serEncLen = ([string]$rk.SerializedEncodedCertificate).Length }
                        $serSSBLen = 0; if ($rk.SerializedCertificate)        { $serSSBLen = ([string]$rk.SerializedCertificate).Length }
                        Write-DscStatus "$Tag   REGISTRY HKLM\SOFTWARE\Microsoft\SMS\SQL Server: EncodedCertificateThumbprint=$encThumb SerializedEncodedCertificate(len=$serEncLen) SerializedCertificate/SSB(len=$serSSBLen)"
                        if ($rk.SerializedEncodedCertificate) {
                            $pv = ([string]$rk.SerializedEncodedCertificate); if ($pv.Length -gt 80) { $pv = $pv.Substring(0,80) + '...' }
                            Write-DscStatus "$Tag     SerializedEncodedCertificate preview: $pv"
                        }
                    } catch { Write-DscStatus "$Tag   registry read failed: $($_.Exception.Message)" }
                    # 3) CM_RoleIdCertificates DB row(s) -- CM's own record of the cert
                    try {
                        $q = "SELECT RoleTypeID, FriendlyName, SubjectName, UsageOID, ExpirationDate, CONVERT(varchar(max), CONVERT(varbinary(max), Thumbprint)) AS ThumbStr, DATALENGTH(SerializedCertificate) AS SerLen, DATALENGTH(EncodedCertificate) AS EncLen FROM CM_RoleIdCertificates"
                        $rows = @(Invoke-Sqlcmd -ServerInstance $sqlConnStr -Database $cmDbName -TrustServerCertificate -Query $q -ErrorAction Stop)
                        Write-DscStatus "$Tag   DB CM_RoleIdCertificates ($cmDbName): $($rows.Count) row(s)"
                        foreach ($r in $rows) {
                            $ts = ''; if ($r.ThumbStr) { $ts = ([string]$r.ThumbStr).Trim() }
                            Write-DscStatus ("{0}     RoleTypeID={1} FN='{2}' Subj='{3}' OID={4} Exp={5} Thumb={6} SerLen={7} EncLen={8}" -f `
                                $Tag, $r.RoleTypeID, $r.FriendlyName, $r.SubjectName, $r.UsageOID, $r.ExpirationDate, $ts, $r.SerLen, $r.EncLen)
                        }
                    } catch { Write-DscStatus "$Tag   DB CM_RoleIdCertificates query failed: $($_.Exception.Message)" }
                    Write-DscStatus "$Tag === end SQL identity cert diagnostics ==="
                }
                Write-DscStatus "$Tag SQL identity cert pre-flight (target=$sqlHostShort local=$isLocalSql)..."
                $certOk = $false
                $certWaitMax = 20   # 20 x 15s = up to 5 min
                for ($ci = 1; $ci -le $certWaitMax; $ci++) {
                    $probe = $null
                    try {
                        if ($isLocalSql) {
                            $probe = & $certProbe $certFriendly
                        } else {
                            $probe = Invoke-Command -ComputerName $sqlServerFqdnBase -ScriptBlock $certProbe -ArgumentList $certFriendly -ErrorAction Stop
                        }
                    } catch {
                        Write-DscStatus "$Tag   cert probe error (attempt $ci/$certWaitMax): $($_.Exception.Message)"
                    }
                    if ($probe) {
                        if ($probe.Recovered) { Write-DscStatus "$Tag   recovered SQL identity cert friendly name on thumbprint $($probe.RegThumb)" }
                        if ($probe.ValidCount -ge 1) {
                            Write-DscStatus "$Tag   SQL identity cert present and valid on $sqlHostShort (count=$($probe.ValidCount))"
                            $certOk = $true
                            break
                        }
                        if ($ci -eq 1 -or $ci -eq $certWaitMax -or ($ci % 4) -eq 0) {
                            $inv = '<none>'
                            if ($probe.Inventory.Count -gt 0) { $inv = $probe.Inventory -join ' ; ' }
                            Write-DscStatus "$Tag   waiting for SQL identity cert (attempt $ci/$certWaitMax): valid=0 regThumb=$($probe.RegThumb) named=[$inv]"
                        }
                    }
                    if ($ci -lt $certWaitMax) { Start-Sleep -Seconds 15 }
                }
                if (-not $certOk) {
                    Write-DscStatus "$Tag WARNING: 'ConfigMgr SQL Server Identification Certificate' not valid in LocalMachine\My on $sqlHostShort after wait. MBAMWebSiteInstaller will fail at 'acquring SQL identity certificate' (CM site setup normally provisions this cert; HKLM\SOFTWARE\Microsoft\SMS\SQL Server\EncodedCertificateThumbprint). Proceeding so full diagnostics are captured."
                    & $emitCertDiagnostics
                    $certDiagEmitted = $true
                }

                $stamp     = Get-Date -Format yyyyMMdd_HHmmss
                $logDir    = if (Test-Path 'C:\staging\DSC') { 'C:\staging\DSC' } else { $env:TEMP }
                $logFile   = Join-Path $logDir "MBAMWebSiteInstaller_$stamp.log"
                $errFile   = "$logFile.err"

                $installerArgs = @(
                    '-NoProfile','-NonInteractive','-ExecutionPolicy','RemoteSigned'
                    '-File',"`"$installer`""
                    '-SqlServerName',$sqlServerFqdnBase     # FQDN of the SQL host only (no instance)
                    '-SqlDatabaseName',$cmDbName
                    '-SiteInstall','Both'
                    '-HelpdeskUsersGroupName',"`"$qualifiedGroup`""
                    '-HelpdeskAdminsGroupName',"`"$qualifiedGroup`""
                    # MUST be the NetBIOS domain name, NOT the FQDN. The installer's
                    # Get-DomainMachineName builds the SQL login as
                    # "{0}\{1}$" -f $DomainName, $env:COMPUTERNAME and (on the REMOTE-SQL path
                    # only -- local SQL uses NETWORK SERVICE) runs CREATE LOGIN for it on the
                    # SQL box. Passing the FQDN produced 'pushlab.sandwich.lab\PL-MELT$', which
                    # SQL's LookupAccountName cannot resolve -> 'Windows NT user or group ... not
                    # found' -> Set-MachineUserOnSql fails -> whole portal install rolls back
                    # (the observed PL-MELT BLM failure). The installer's own error text says to
                    # pass the NetBIOS name here. -DomainName is used for nothing else (the
                    # Helpdesk groups are passed pre-qualified above).
                    '-DomainName',$netbios
                )
                # Named instance: pass -SqlInstanceName separately and ensure
                # SQL Browser is running on the SQL host (required for instance
                # discovery when the MBAM installer connects without a port number)
                if ($sqlInstanceName -and $sqlInstanceName -ne 'MSSQLSERVER') {
                    $installerArgs += '-SqlInstanceName'; $installerArgs += $sqlInstanceName
                    $sqlHostName = $sqlServerName.Split('\')[0]
                    try {
                        $browserStatus = Invoke-Command -ComputerName "$sqlHostName.$DomainFullName" -ScriptBlock {
                            $svc = Get-Service -Name SQLBrowser -ErrorAction SilentlyContinue
                            if (-not $svc) { return 'NotFound' }
                            if ($svc.Status -ne 'Running') {
                                Set-Service -Name SQLBrowser -StartupType Automatic -ErrorAction SilentlyContinue
                                Start-Service -Name SQLBrowser -ErrorAction Stop
                                return 'Started'
                            }
                            return 'Running'
                        } -ErrorAction Stop
                        Write-DscStatus "$Tag SQL Browser on ${sqlHostName}: $browserStatus"
                    } catch {
                        Write-DscStatus "$Tag WARNING: Could not verify SQL Browser on ${sqlHostName}: $($_.Exception.Message)"
                    }
                }
                Write-DscStatus "$Tag Launching installer; log=$logFile"
                Write-DscStatus "$Tag   args: $($installerArgs -join ' ')"

                $proc = $null
                try {
                    $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $installerArgs `
                        -NoNewWindow -Wait -PassThru `
                        -RedirectStandardOutput $logFile -RedirectStandardError $errFile -ErrorAction Stop
                } catch {
                    Write-DscStatus "$Tag ERROR: failed to launch installer: $($_.Exception.Message)"
                }

                if ($proc) {
                    Write-DscStatus "$Tag Installer exit code: $($proc.ExitCode)"
                    if (Test-Path $logFile) {
                        $stdoutTail = (Get-Content $logFile -Tail 20 -ErrorAction SilentlyContinue) -join ' | '
                        Write-DscStatus "$Tag   stdout tail: $stdoutTail"
                    }
                    if ((Test-Path $errFile) -and ((Get-Item $errFile).Length -gt 0)) {
                        $stderrTail = (Get-Content $errFile -Tail 10 -ErrorAction SilentlyContinue) -join ' | '
                        Write-DscStatus "$Tag   stderr tail: $stderrTail"
                    }

                    # ---- Verification (regardless of exit code, check actual state) ----
                    $post = Test-BlmPortalHealth
                    foreach ($d in $post.Details) { Write-DscStatus "$Tag   verify: $d" }

                    if ($post.Installed) {
                        # Make sure the app pool is running
                        try {
                            $app = Get-WebApplication -Site 'Default Web Site' -Name 'HelpDesk' -ErrorAction Stop
                            $poolName = $app.applicationPool
                            $pool = Get-Item "IIS:\AppPools\$poolName" -ErrorAction Stop
                            if ($pool.State -ne 'Started') {
                                Write-DscStatus "$Tag Starting app pool '$poolName'..."
                                Start-WebAppPool -Name $poolName -ErrorAction Stop
                            }
                        } catch {
                            Write-DscStatus "$Tag WARNING: post-install pool check failed: $($_.Exception.Message)"
                        }

                        # Smoke-test the URL (401/403 are also fine -- means IIS is serving)
                        try {
                            $req = [System.Net.HttpWebRequest]::Create("https://$localServerFqdn/HelpDesk/")
                            $req.Timeout = 15000
                            $req.AllowAutoRedirect = $false
                            $req.UseDefaultCredentials = $true
                            $resp = $req.GetResponse()
                            Write-DscStatus "$Tag Smoke test: HTTP $([int]$resp.StatusCode) from https://$localServerFqdn/HelpDesk/"
                            $resp.Close()
                        } catch [System.Net.WebException] {
                            $code = $null
                            if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
                            if ($code -in 401,403,302) {
                                Write-DscStatus "$Tag Smoke test: HTTP $code (expected -- portal requires auth). Portal is serving."
                            } else {
                                Write-DscStatus "$Tag WARNING: Smoke test failed: $($_.Exception.Message)"
                            }
                        } catch {
                            Write-DscStatus "$Tag WARNING: Smoke test exception: $($_.Exception.Message)"
                        }

                        Write-DscStatus "$Tag SUCCESS: BLM portals ready at https://$localServerFqdn/HelpDesk and https://$localServerFqdn/SelfService (sign in as member of $qualifiedGroup)"
                    }
                    else {
                        # One-shot diagnostics: the installer log lives only on
                        # this VM and we rarely get a second chance to collect
                        # it, so pump the FULL installer log/err + the #1 root
                        # cause (SQL identity cert state) + IIS feature state into
                        # the build log (which is retrieved) before giving up.
                        Write-DscStatus "$Tag WARNING: Installer ran but post-install health check FAILED. Capturing full diagnostics (one-shot)."
                        try {
                            if (Test-Path $logFile) {
                                $full = @(Get-Content $logFile -ErrorAction SilentlyContinue | Where-Object { $_ -notmatch 'to Extraction Queue' })
                                if ($full.Count -gt 250) { $full = $full[-250..-1] }
                                Write-DscStatus "$Tag   --- MBAMWebSiteInstaller.log (signal lines, Extraction-Queue noise filtered) ---"
                                foreach ($ln in $full) { if (-not [string]::IsNullOrWhiteSpace($ln)) { Write-DscStatus "$Tag   LOG| $($ln.TrimEnd())" } }
                            }
                        } catch { Write-DscStatus "$Tag   (could not read installer log: $($_.Exception.Message))" }
                        try {
                            if ((Test-Path $errFile) -and ((Get-Item $errFile).Length -gt 0)) {
                                $fullErr = @(Get-Content $errFile -ErrorAction SilentlyContinue)
                                Write-DscStatus "$Tag   --- MBAMWebSiteInstaller.err ($($fullErr.Count) lines) ---"
                                foreach ($ln in $fullErr) { if (-not [string]::IsNullOrWhiteSpace($ln)) { Write-DscStatus "$Tag   ERR| $($ln.TrimEnd())" } }
                            }
                        } catch {}
                        if (-not $certDiagEmitted) { & $emitCertDiagnostics; $certDiagEmitted = $true }
                        try {
                            $feats = @('Web-Server','Web-Asp-Net45','Web-Net-Ext45','Web-Windows-Auth','Web-ISAPI-Ext','Web-ISAPI-Filter','Web-Mgmt-Console') | ForEach-Object {
                                $f = Get-WindowsFeature -Name $_ -ErrorAction SilentlyContinue
                                $st = 'missing'; if ($f -and $f.Installed) { $st = 'installed' }
                                "$_=$st"
                            }
                            Write-DscStatus "$Tag   DIAG IIS features: $($feats -join ' ')"
                            $dws = Get-Website -Name 'Default Web Site' -ErrorAction SilentlyContinue
                            if ($dws) { Write-DscStatus "$Tag   DIAG Default Web Site state=$($dws.State)" } else { Write-DscStatus "$Tag   DIAG Default Web Site: MISSING" }
                        } catch {}
                        Write-DscStatus "$Tag   (installer log on VM: $logFile / $errFile)"
                    }
                }
            }
        }
    }
    catch {
        # Belt-and-suspenders: never let this section fail the phase.
        Write-DscStatus "$Tag WARNING: unhandled exception in Helpdesk Portal block: $($_.Exception.Message)"
    }

    Write-DscStatus "$Tag === Helpdesk Portal: done ==="
}

Write-DscStatus "$Tag BitLocker Management configuration complete"
