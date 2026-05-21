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

if (-not $deployConfig.cmOptions.EnableBLM) {
    Write-DscStatus "$Tag EnableBLM is not set in cmOptions. Skipping."
    return
}

# Connect to the CM site (imports module, sets up PS drive, sets location)
Write-DscStatus "$Tag Connecting to CM site..."
. $PSScriptRoot\Connect-CMSite.ps1 -Tag $Tag

$DomainFullName = $deployConfig.parameters.domainName
$DN = 'DC=' + $DomainFullName.Replace('.', ',DC=')

Write-DscStatus "$Tag Configuring BitLocker Management (Domain: $DomainFullName)"

# Create collection targeting the BLM OU
$blmCollectionName = "MEMLABS-BitLocker Clients"
Write-DscStatus "$Tag Checking if collection '$blmCollectionName' exists..."
$existingCollection = Get-CMDeviceCollection -Name $blmCollectionName -ErrorAction SilentlyContinue
if (-not $existingCollection) {
    Write-DscStatus "$Tag Collection not found, creating '$blmCollectionName'..."
    $blmSchedule = New-CMSchedule -RecurInterval Days -RecurCount 1
    New-CMDeviceCollection -Name $blmCollectionName -LimitingCollectionId SMS00001 -RefreshSchedule $blmSchedule -RefreshType Periodic | Out-Null
    $blmQuery = @"
SELECT SMS_R_SYSTEM.ResourceID, SMS_R_SYSTEM.ResourceType, SMS_R_SYSTEM.Name
FROM SMS_R_System
WHERE SMS_R_System.SystemOUName = "$DomainFullName/MEMLABS-BitLockerClients"
"@
    Add-CMDeviceCollectionQueryMembershipRule -CollectionName $blmCollectionName -QueryExpression $blmQuery -RuleName "BLM OU Members"
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

# Add direct membership rules for BitLocker VMs (immediate targeting without waiting for OU query)
if ($blmCollection) {
    $blmVMs = @($deployConfig.virtualMachines | Where-Object { $_.BitLocker -eq $true })
    Write-DscStatus "$Tag Found $($blmVMs.Count) VM(s) with BitLocker=true in deployConfig"
    foreach ($blmVM in $blmVMs) {
        $vmResourceName = "$($deployConfig.vmOptions.prefix)$($blmVM.vmName)"
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

# Build BitLocker policy objects for drive encryption
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
    $blmPolicy = New-CMBlmSetting -Name $blmPolicyName -Description "MEMLABS auto created BitLocker management policy" -Policies $blmPolicies
    if ($blmPolicy) {
        Write-DscStatus "$Tag Created BitLocker policy: $blmPolicyName"
    }
    else {
        Write-DscStatus "$Tag ERROR: New-CMBlmSetting returned null for '$blmPolicyName'"
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

Write-DscStatus "$Tag BitLocker Management configuration complete"
