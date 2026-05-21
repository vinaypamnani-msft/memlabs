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
    Write-DscStatus "$Tag EnableBLM is not set. Skipping."
    return
}

# Connect to the CM site (imports module, sets up PS drive, sets location)
. $PSScriptRoot\Connect-CMSite.ps1 -Tag $Tag

$DomainFullName = $deployConfig.parameters.domainName
$DN = 'DC=' + $DomainFullName.Replace('.', ',DC=')

Write-DscStatus "$Tag Configuring BitLocker Management"

# Create collection targeting the BLM OU
$blmCollectionName = "MEMLABS-BitLocker Clients"
if (-not (Get-CMDeviceCollection -Name $blmCollectionName -ErrorAction SilentlyContinue)) {
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

# Add direct membership rules for BitLocker VMs (immediate targeting without waiting for OU query)
$blmCollection = Get-CMDeviceCollection -Name $blmCollectionName -ErrorAction SilentlyContinue
if ($blmCollection) {
    $blmVMs = @($deployConfig.virtualMachines | Where-Object { $_.BitLocker -eq $true })
    foreach ($blmVM in $blmVMs) {
        $vmResourceName = "$($deployConfig.vmOptions.prefix)$($blmVM.vmName)"
        $cmDevice = Get-CMDevice -Name $vmResourceName -ErrorAction SilentlyContinue
        if ($cmDevice) {
            $existingRule = Get-CMDeviceCollectionDirectMembershipRule -CollectionId $blmCollection.CollectionID -ResourceId $cmDevice.ResourceID -ErrorAction SilentlyContinue
            if (-not $existingRule) {
                Add-CMDeviceCollectionDirectMembershipRule -CollectionId $blmCollection.CollectionID -ResourceId $cmDevice.ResourceID
                Write-DscStatus "$Tag Added $vmResourceName to $blmCollectionName"
            }
        }
    }
}

# Build BitLocker policy objects for drive encryption
$blmPolicies = @()
# Setup tab: XTS-AES 256 encryption for OS and Fixed drives (Windows 10+)
$blmPolicies += New-CMBLEncryptionMethodWithXts -PolicyState Enabled -OSDriveEncryptionMethod AesXts256 -FixedDriveEncryptionMethod AesXts256
# OS Drive tab: Require encryption with TPM-only protector
$blmPolicies += New-CMBMSOSDEncryptionPolicy -PolicyState Enabled -Protector TpmOnly
# OS Drive tab: Enforce OS drive encryption immediately
$blmPolicies += New-CMUseOsEnforcePolicy -PolicyState Enabled -GracePeriodDays 0
# Fixed Drive tab: Require encryption with auto-unlock
$blmPolicies += New-CMBMSFDVEncryptionPolicy -PolicyState Enabled -AutoUnlock Require
# Fixed Drive tab: Enforce fixed drive encryption immediately
$blmPolicies += New-CMUseFddEnforcePolicy -PolicyState Enabled -GracePeriodDays 0
# Client Management tab: Check compliance every 90 minutes, escrow recovery password and package
$blmPolicies += New-CMBMSClientConfigureCheckIntervalPolicy -PolicyState Enabled -ClientWakeupFrequencyMinutes 90 -KeyRecoveryOption PasswordAndPackage

# Create or update BitLocker management policy
$blmPolicyName = "MEMLABS-BitLocker Policy"
$blmPolicy = Get-CMBlmSetting -Name $blmPolicyName -ErrorAction SilentlyContinue
if (-not $blmPolicy) {
    $blmPolicy = New-CMBlmSetting -Name $blmPolicyName -Description "MEMLABS auto created BitLocker management policy" -Policies $blmPolicies
    Write-DscStatus "$Tag Created BitLocker policy: $blmPolicyName"
}
else {
    Write-DscStatus "$Tag BitLocker policy already exists, skipping creation"
}

# Ensure policy is deployed to the collection (idempotent)
if ($blmPolicy -and $blmCollection) {
    $existingDeployment = Get-CMSettingDeployment -CMSetting $blmPolicy -ErrorAction SilentlyContinue |
        Where-Object { $_.CollectionId -eq $blmCollection.CollectionID }
    if (-not $existingDeployment) {
        New-CMSettingDeployment -CMSetting $blmPolicy -CollectionId $blmCollection.CollectionID -ErrorAction SilentlyContinue
        Write-DscStatus "$Tag Deployed BitLocker policy to $blmCollectionName"
    }
    else {
        Write-DscStatus "$Tag BitLocker policy already deployed to $blmCollectionName"
    }
}

Write-DscStatus "$Tag BitLocker Management configuration complete"
