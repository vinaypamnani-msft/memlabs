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
            Add-CMDeviceCollectionQueryMembershipRule -CollectionId $blmCollection.CollectionID -RuleName $ruleName -QueryExpression $query
            Write-DscStatus "$Tag Added query rule '$ruleName' to $blmCollectionName"
        }
        else {
            Write-DscStatus "$Tag Query rule '$ruleName' already exists in $blmCollectionName"
        }
    }

    # Force collection membership evaluation and verify members appear
    Invoke-CMCollectionUpdate -CollectionId $blmCollection.CollectionID
    Write-DscStatus "$Tag Triggered collection evaluation for $blmCollectionName"

    # Wait for evaluation to complete - members must be visible for deployment to work
    # Query rules will match once the device is discovered (any ResourceID)
    $evalRetries = 12
    $evalDelay = 10
    for ($i = 1; $i -le $evalRetries; $i++) {
        Start-Sleep -Seconds $evalDelay
        $members = @(Get-CMCollectionMember -CollectionId $blmCollection.CollectionID -ErrorAction SilentlyContinue)
        $expectedNames = @($blmVMs | ForEach-Object { $_.vmName })
        $found = @($members | Where-Object { $_.Name -in $expectedNames })
        if ($found.Count -ge $expectedNames.Count) {
            Write-DscStatus "$Tag Collection evaluation complete: $($members.Count) total member(s), $($found.Count)/$($expectedNames.Count) expected BLM clients visible"
            break
        }
        if ($i -lt $evalRetries) {
            Write-DscStatus "$Tag Waiting for collection evaluation ($i/$evalRetries): $($found.Count)/$($expectedNames.Count) expected BLM clients visible..."
            Invoke-CMCollectionUpdate -CollectionId $blmCollection.CollectionID
        }
        else {
            $missing = $expectedNames | Where-Object { $_ -notin $members.Name }
            Write-DscStatus "$Tag WARNING: After $($evalRetries * $evalDelay)s, missing members: $($missing -join ', '). They will appear once discovered by the site."
        }
    }
}

# Build BitLocker policy objects for drive encryption (only when cmOptions.EnableBLM is set)
if ($blmEnabled) {
    # Ensure SQL encryption certificate exists (required for BLM recovery key escrow)
    # Reference: https://learn.microsoft.com/en-us/mem/configmgr/protect/deploy-use/bitlocker/encrypt-recovery-data
    $cmDbName = "CM_$SiteCode"
    Write-DscStatus "$Tag Ensuring SQL encryption certificate exists for database '$cmDbName'..."
    try {
        Push-Location $env:SystemDrive
        $cm_svc_file = "C:\Staging\DSC\cm_svc.txt"
        $masterKeyPass = if (Test-Path $cm_svc_file) { (Get-Content $cm_svc_file).Trim() } else { 'oMm$Bl!2024x' }
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
        Invoke-Sqlcmd -Query $sqlCertQuery -ServerInstance "." -TrustServerCertificate -ErrorAction Stop
        Write-DscStatus "$Tag SQL encryption certificate ensured for $cmDbName"
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
        Write-DscStatus "$Tag Policy not found, creating '$blmPolicyName' with $($blmPolicies.Count) sub-policies..."
        try {
            $blmPolicy = New-CMBlmSetting -Name $blmPolicyName -Description "MEMLABS auto created BitLocker management policy" -Policies $blmPolicies -ErrorAction Stop
            Write-DscStatus "$Tag Created BitLocker policy: $blmPolicyName"
        }
        catch {
            Write-DscStatus "$Tag ERROR: New-CMBlmSetting failed: $($_.Exception.Message)"
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
        $result = @{ Installed=$false; AppOk=$false; PoolOk=$false; Reg=$false; ConnStr=$null; Details=@() }
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
                    $result.Details += "WARN: physical path missing on disk"
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
        $result.Installed = ($result.AppOk -and $result.Reg)
        return $result
    }

    $blmGroup       = 'BLM Helpdesk Users'
    $netbios        = ($DomainFullName -split '\.')[0]
    $qualifiedGroup = "$netbios\$blmGroup"
    $sqlServerFqdn  = "$env:COMPUTERNAME.$DomainFullName"
    $cmDbName       = "CM_$SiteCode"

    Write-DscStatus "$Tag === Helpdesk Portal: starting (Server=$sqlServerFqdn Db=$cmDbName Group=$qualifiedGroup Domain=$DomainFullName) ==="

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

            # ---- IIS + ASP.NET 4.5 prereqs ------------------------------------
            Write-DscStatus "$Tag Verifying IIS / ASP.NET 4.5 features..."
            try {
                $needed = @('Web-Server','Web-Asp-Net45','Web-Mgmt-Console')
                $missing = @()
                foreach ($f in $needed) {
                    $feat = Get-WindowsFeature -Name $f -ErrorAction SilentlyContinue
                    if (-not $feat) { Write-DscStatus "$Tag   feature '$f' not recognized on this OS" ; continue }
                    if ($feat.Installed) {
                        Write-DscStatus "$Tag   $f : installed"
                    } else {
                        Write-DscStatus "$Tag   $f : MISSING - will install"
                        $missing += $f
                    }
                }
                if ($missing.Count -gt 0) {
                    $iisResult = Install-WindowsFeature -Name $missing -ErrorAction Stop
                    Write-DscStatus "$Tag   Install-WindowsFeature: Success=$($iisResult.Success) RestartNeeded=$($iisResult.RestartNeeded)"
                    if ($iisResult.RestartNeeded -eq 'Yes') {
                        Write-DscStatus "$Tag WARNING: IIS install requested reboot; continuing anyway. May fail until reboot."
                    }
                }
                $defaultSite = Get-Website -Name 'Default Web Site' -ErrorAction SilentlyContinue
                if (-not $defaultSite) {
                    throw "'Default Web Site' is missing in IIS after feature install."
                }
                Write-DscStatus "$Tag   'Default Web Site' state=$($defaultSite.State) bindings=$($defaultSite.bindings.Collection.bindingInformation -join ',')"
            } catch {
                Write-DscStatus "$Tag WARNING: IIS prereq step failed: $($_.Exception.Message)"
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
                $stamp     = Get-Date -Format yyyyMMdd_HHmmss
                $logDir    = if (Test-Path 'C:\staging\DSC') { 'C:\staging\DSC' } else { $env:TEMP }
                $logFile   = Join-Path $logDir "MBAMWebSiteInstaller_$stamp.log"
                $errFile   = "$logFile.err"

                $installerArgs = @(
                    '-NoProfile','-NonInteractive','-ExecutionPolicy','RemoteSigned'
                    '-File',"`"$installer`""
                    '-SqlServerName',$sqlServerFqdn        # MUST be FQDN -- installer hardcodes
                    '-SqlDatabaseName',$cmDbName            # Encrypt=True;TrustServerCertificate=False,
                    '-SiteInstall','HelpDesk'               # so NetBIOS triggers SPN mismatch
                    '-HelpdeskUsersGroupName',"`"$qualifiedGroup`""
                    '-HelpdeskAdminsGroupName',"`"$qualifiedGroup`""
                    '-DomainName',$DomainFullName
                )
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
                            $req = [System.Net.HttpWebRequest]::Create("https://$sqlServerFqdn/HelpDesk/")
                            $req.Timeout = 15000
                            $req.AllowAutoRedirect = $false
                            $req.UseDefaultCredentials = $true
                            $resp = $req.GetResponse()
                            Write-DscStatus "$Tag Smoke test: HTTP $([int]$resp.StatusCode) from https://$sqlServerFqdn/HelpDesk/"
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

                        Write-DscStatus "$Tag SUCCESS: BLM Helpdesk Portal ready at https://$sqlServerFqdn/HelpDesk (sign in as member of $qualifiedGroup)"
                    }
                    else {
                        Write-DscStatus "$Tag WARNING: Installer ran but post-install health check FAILED. See $logFile and $errFile for details."
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
