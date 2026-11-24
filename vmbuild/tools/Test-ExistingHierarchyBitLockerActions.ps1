#requires -Version 5.1
[CmdletBinding()]
param([switch]$GuestOnly)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'common\Common.ExistingHierarchy.BitLocker.ps1')
$script:Assertions = 0
function Assert-True {
    param([bool]$Condition, [string]$Message)
    $script:Assertions++
    if (-not $Condition) { throw $Message }
}
function Get-MemLabsRequestedDeploymentVMs { param($DeployConfig); $DeployConfig.virtualMachines | Where-Object { -not $_.hidden } }
function Resolve-MemLabsDeploymentPrimary {
    param($DeployConfig, $SiteCode)
    $owner = @($DeployConfig.virtualMachines | Where-Object { $_.role -eq 'Primary' -and $_.siteCode -eq $SiteCode })
    if ($owner.Count -ne 1) { throw 'Fixture owner is not unique.' }
    return $owner[0]
}
function Test-MemLabsContextOnlyVM { param($VM); return $VM.hidden -eq $true }
$config = [pscustomobject]@{
    virtualMachines = @(
        [pscustomobject]@{ vmName = 'PRI1'; role = 'Primary'; siteCode = 'P01'; hidden = $true },
        [pscustomobject]@{ vmName = 'PRI2'; role = 'Primary'; siteCode = 'P02'; hidden = $true },
        [pscustomobject]@{ vmName = 'NEW1'; BitLocker = $true; pushClient = 'P01' },
        [pscustomobject]@{ vmName = 'NEW2'; BitLocker = $true; pushClient = 'P02' },
        [pscustomobject]@{ vmName = 'BROKEN-EXISTING'; BitLocker = $true; pushClient = 'P01'; hidden = $true }
    )
}
$plan = @(Get-MemLabsExistingBitLockerActions -DeployConfig $config)
Assert-True ($plan.Count -eq 2) 'BitLocker planning lost site-owner isolation.'
foreach ($action in $plan) {
    Assert-True ($action.TargetVMNames.Count -eq 1 -and $action.TargetVMNames[0] -in @('NEW1', 'NEW2')) `
        'An unrelated existing BitLocker device entered the enrollment plan.'
}
$handler = ($plan | Where-Object SiteCode -EQ P01).Handler
foreach ($mode in @('Ready', 'AlreadyEnrolled', 'MissingRecovery', 'MissingCollection', 'MissingPolicy', 'MissingDeployment', 'ConflictingRule', 'ProviderError')) {
    & {
        param($Mode, $Handler)
        $script:Mode = $Mode
        $script:Rules = [Collections.Generic.List[object]]::new()
        $script:Evaluations = 0
        function Get-WmiObject {
            param($Namespace, $Class, $Filter, $ErrorAction)
            if ($script:Mode -eq 'ProviderError') { throw 'Deliberate provider failure.' }
            $enabled = if ($script:Mode -eq 'MissingRecovery') { 0 } else { 1 }
            return [pscustomobject]@{ Props = @([pscustomobject]@{ PropertyName = 'EnableMBAMRecoveryService'; Value = $enabled }) }
        }
        function Get-CMDeviceCollection {
            param($Name, $ErrorAction)
            if ($script:Mode -ne 'MissingCollection') { return [pscustomobject]@{ CollectionID = 'P0100001' } }
        }
        function Get-CMBlmSetting {
            param($Name, $ErrorAction)
            if ($script:Mode -ne 'MissingPolicy') { return [pscustomobject]@{ Name = $Name } }
        }
        function Get-CMSettingDeployment {
            param($CMSetting, $ErrorAction)
            if ($script:Mode -ne 'MissingDeployment') { return [pscustomobject]@{ CollectionID = 'P0100001' } }
        }
        function Get-CMDeviceCollectionQueryMembershipRule {
            param($CollectionId, $RuleName, $ErrorAction)
            [pscustomobject]@{ RuleName = 'BLM-BROKEN-EXISTING'; QueryExpression = 'Deliberately invalid unrelated rule' }
            if ($script:Mode -eq 'AlreadyEnrolled') {
                return [pscustomobject]@{ RuleName = 'BLM-NEW1'; QueryExpression = "SELECT * FROM SMS_R_System WHERE Name = 'NEW1'" }
            }
            if ($script:Mode -eq 'ConflictingRule') { return [pscustomobject]@{ RuleName = 'BLM-NEW1'; QueryExpression = 'SELECT * FROM SMS_R_System' } }
        }
        function Add-CMDeviceCollectionQueryMembershipRule {
            param($CollectionId, $RuleName, $QueryExpression, $ErrorAction)
            $script:Rules.Add([pscustomobject]@{ Collection = $CollectionId; Name = $RuleName; Query = $QueryExpression })
        }
        function Invoke-CMCollectionUpdate { param($CollectionId, $ErrorAction); $script:Evaluations++ }
        function Restart-Service { throw 'Existing BitLocker services must not be repaired.' }
        function New-CMBlmSetting { throw 'Existing BitLocker policies must not be rebuilt.' }
        function New-CMSettingDeployment { throw 'Existing BitLocker deployment must not be repaired.' }
        function Invoke-CMSystemDiscovery { throw 'Discovery must not be triggered.' }
        function Invoke-Sqlcmd { throw 'Existing BitLocker SQL objects must not be repaired.' }
        $failure = ''
        $receipt = $null
        try { $receipt = & $Handler ([pscustomobject]@{ SiteCode = 'P01'; TargetVMNames = @('NEW1') }) }
        catch { $failure = $_.Exception.Message }
        if ($Mode -eq 'Ready') {
            Assert-True (-not $failure -and $receipt.Status -eq 'Submitted' -and
                $script:Rules.Count -eq 1 -and $script:Rules[0].Name -eq 'BLM-NEW1' -and
                $script:Rules[0].Query -eq "SELECT * FROM SMS_R_System WHERE Name = 'NEW1'" -and
                $script:Evaluations -eq 1) 'BitLocker enrollment changed more than the requested new-client membership.'
        }
        elseif ($Mode -eq 'AlreadyEnrolled') {
            Assert-True (-not $failure -and $receipt.Status -eq 'Submitted' -and
                $script:Rules.Count -eq 0 -and $script:Evaluations -eq 0) 'An already-enrolled client caused unnecessary policy work.'
        }
        else {
            Assert-True ($failure -and $script:Rules.Count -eq 0 -and $script:Evaluations -eq 0) `
                "Existing BitLocker prerequisite '$Mode' was repaired or ignored."
        }
    } $mode $handler
}
Write-Host "PASS -- $script:Assertions scoped BitLocker assertions on PowerShell $($PSVersionTable.PSVersion)."
