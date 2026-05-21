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

# Determine if BLM should run: either cmOptions.EnableBLM is set, or VMs have BitLocker=true
$blmEnabled = $deployConfig.cmOptions.EnableBLM
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

# Add direct membership rules for BitLocker VMs
if ($blmCollection) {
    Write-DscStatus "$Tag Found $($blmVMs.Count) VM(s) with BitLocker=true in deployConfig"
    foreach ($blmVM in $blmVMs) {
        $vmResourceName = $blmVM.vmName
        $cmDevice = Get-CMDevice -Name $vmResourceName -ErrorAction SilentlyContinue
        if ($cmDevice) {
            $existingRule = Get-CMDeviceCollectionDirectMembershipRule -CollectionId $blmCollection.CollectionID -ResourceId $cmDevice.ResourceID -ErrorAction SilentlyContinue
            if (-not $existingRule) {
                Add-CMDeviceCollectionDirectMembershipRule -CollectionId $blmCollection.CollectionID -ResourceId $cmDevice.ResourceID
                Write-DscStatus "$Tag Added $vmResourceName (ResourceID: $($cmDevice.ResourceID)) to $blmCollectionName"
            }
            else {
                Write-DscStatus "$Tag $vmResourceName already a direct member of $blmCollectionName"
            }
        }
        else {
            Write-DscStatus "$Tag Device '$vmResourceName' not found in ConfigMgr, skipping direct membership"
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
    EXPIRY_DATE = '20391022'

    GRANT CONTROL ON CERTIFICATE ::BitLockerManagement_CERT TO RecoveryAndHardwareRead
    GRANT CONTROL ON CERTIFICATE ::BitLockerManagement_CERT TO RecoveryAndHardwareWrite
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
    $blmPolicies += New-CMBMSClientConfigureCheckIntervalPolicy -PolicyState Enabled -ClientWakeupFrequencyMinutes 90 -KeyRecoveryOption PasswordAndPackage
    Write-DscStatus "$Tag Built $($blmPolicies.Count) policy objects (XtsAes256, TpmOnly, OsEnforce0d, FdvAutoUnlock, FddEnforce0d, ClientCheck90m)"

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
            New-CMSettingDeployment -CMSetting $blmPolicy -CollectionId $blmCollection.CollectionID -ErrorAction SilentlyContinue
            Write-DscStatus "$Tag Deployed BitLocker policy to $blmCollectionName"
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

Write-DscStatus "$Tag BitLocker Management configuration complete"
