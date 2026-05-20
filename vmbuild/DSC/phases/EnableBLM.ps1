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

# Create BitLocker management policy
$blmPolicyName = "MEMLABS-BitLocker Policy"
$blmPolicy = Get-CMBlmSetting -Name $blmPolicyName -ErrorAction SilentlyContinue
if (-not $blmPolicy) {
    $blmPolicy = New-CMBlmSetting -Name $blmPolicyName -Description "MEMLABS auto created BitLocker management policy"

    # Configure OS drive encryption settings
    Set-CMBlmPlannedFailureAction -InputObject $blmPolicy -LockWorkstation
    Set-CMBlmSetting -InputObject $blmPolicy -OsDrive -Encrypt -EncryptionMethod XtsAes256 -MinimumPinLength 6
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
