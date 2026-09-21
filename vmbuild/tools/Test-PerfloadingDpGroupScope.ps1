<#
.SYNOPSIS
    Verifies that perfloading only auto-adds DPs to All MEMLABS DPs.

.DESCRIPTION
    Extracts the production ownership selector and checks explicit DPs, pull
    DPs, and implicit secondary-site DPs. External DPs and CMGs remain manual
    group members.

    Run under both PowerShell 7 and Windows PowerShell 5.1.
#>
[CmdletBinding()]
param (
    [string] $RootPath
)

if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }

$script:Failures = 0

function Assert-Equal {
    param ($Expected, $Actual, [string] $What)

    $passed = "$Expected" -eq "$Actual"
    if (-not $passed) { $script:Failures++ }
    $status = if ($passed) { 'PASS' } else { 'FAIL' }
    Write-Host ('{0}  {1}' -f $status, $What)
    if (-not $passed) {
        Write-Host "      expected: $Expected"
        Write-Host "      actual:   $Actual"
    }
}

function Import-TestFunction {
    param ([string] $Path, [string] $Name)

    $errors = $null
    $tokens = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    $parseErrors = @($errors | Where-Object { $null -ne $_ })
    if ($parseErrors.Count -ne 0) { throw "$Path has $($parseErrors.Count) parse error(s)" }
    $definition = @($ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($definition.Count -ne 1) { throw "Expected one $Name definition, found $($definition.Count)" }
    return [scriptblock]::Create($definition[0].Extent.Text)
}

$perfloadingPath = Join-Path $RootPath 'DSC\phases\perfloading.ps1'
. (Import-TestFunction -Path $perfloadingPath -Name 'Get-MemLabsManagedDistributionPointNames')
. (Import-TestFunction -Path $perfloadingPath -Name 'Test-MemLabsDistributionPointGroupMember')
. (Import-TestFunction -Path $perfloadingPath -Name 'Sync-MemLabsDistributionPointGroupMembership')
. (Import-TestFunction -Path $perfloadingPath -Name 'Test-MemLabsContentDistributionTarget')
. (Import-TestFunction -Path $perfloadingPath -Name 'Sync-MemLabsContentDistribution')

Write-Host "engine : $($PSVersionTable.PSVersion)"

$virtualMachines = @(
    [pscustomobject]@{ vmName = 'PRIMARY1'; role = 'Primary'; siteCode = 'PRI'; installDP = $true; enablePullDP = $false; hidden = $false },
    [pscustomobject]@{ vmName = 'PULLDP1'; role = 'SiteSystem'; siteCode = 'PRI'; installDP = $false; enablePullDP = $true; hidden = $false },
    [pscustomobject]@{ vmName = 'SECONDARY1'; role = 'Secondary'; siteCode = 'SEC'; parentSiteCode = 'PRI'; installDP = $false; enablePullDP = $false; hidden = $false },
    [pscustomobject]@{ vmName = 'EXISTINGDP1'; role = 'SiteSystem'; siteCode = 'PRI'; installDP = $true; enablePullDP = $false; hidden = $true; domain = 'memlabs.test' },
    [pscustomobject]@{ vmName = 'OTHERPRIMARY'; role = 'Primary'; siteCode = 'OTH'; installDP = $true; enablePullDP = $false; hidden = $false },
    [pscustomobject]@{ vmName = 'OTHERPULL'; role = 'SiteSystem'; siteCode = 'OTH'; installDP = $false; enablePullDP = $true; hidden = $false },
    [pscustomobject]@{ vmName = 'FOREIGNDP'; role = 'SiteSystem'; siteCode = 'PRI'; domain = 'foreign.test'; installDP = $true; enablePullDP = $false; hidden = $false },
    [pscustomobject]@{ vmName = 'FOREIGNPULL'; role = 'SiteSystem'; siteCode = 'PRI'; domain = 'foreign.test'; installDP = $false; enablePullDP = $true; hidden = $false },
    [pscustomobject]@{ vmName = 'FOREIGNSECONDARY'; role = 'Secondary'; siteCode = 'FSE'; parentSiteCode = 'PRI'; domain = 'foreign.test'; installDP = $false; enablePullDP = $false; hidden = $false },
    [pscustomobject]@{ vmName = 'EXTERNALDP'; role = 'SiteSystem'; siteCode = 'PRI'; installDP = $false; enablePullDP = $false; hidden = $false },
    [pscustomobject]@{ vmName = 'EXTERNALCMG'; role = 'CMG'; siteCode = 'PRI'; installDP = $false; enablePullDP = $false; hidden = $false }
)

$managedNames = @(Get-MemLabsManagedDistributionPointNames -VirtualMachines $virtualMachines -DefaultDomainName 'memlabs.test' -PrimarySiteCode PRI | Sort-Object)
Assert-Equal 'EXISTINGDP1.memlabs.test,PRIMARY1.memlabs.test,PULLDP1.memlabs.test,SECONDARY1.memlabs.test' ($managedNames -join ',') 'only exact MemLabs-managed DP FQDNs are selected'
Assert-Equal $true ($managedNames -contains 'PULLDP1.memlabs.test') 'pull-only DP is selected'
Assert-Equal $false ($managedNames -contains 'EXTERNALDP.memlabs.test') 'external DP is not auto-added'
Assert-Equal $false ($managedNames -contains 'EXTERNALCMG.memlabs.test') 'CMG is not auto-added'
Assert-Equal $false ($managedNames -contains 'OTHERPRIMARY.memlabs.test') 'another Primary site is not auto-added'
Assert-Equal $false ($managedNames -contains 'OTHERPULL.memlabs.test') 'pull DP from another Primary site is not auto-added'
Assert-Equal $false ($managedNames -contains 'FOREIGNDP.foreign.test') 'foreign-domain DP with a colliding site code is excluded'
Assert-Equal $false ($managedNames -contains 'FOREIGNPULL.foreign.test') 'foreign-domain pull DP with a colliding site code is excluded'
Assert-Equal $false ($managedNames -contains 'FOREIGNSECONDARY.foreign.test') 'foreign-domain Secondary under the local Primary is excluded'
Assert-Equal $false ($managedNames -contains 'PRIMARY1.external.test') 'same short name in another domain is not selected'
$projectedScopes = @(
    [pscustomobject]@{ PrimarySiteCode = 'PRI'; DistributionPointNames = @('LEGACYPRI', 'EXISTINGDP1.memlabs.test') },
    [pscustomobject]@{ PrimarySiteCode = 'OTH'; DistributionPointNames = @('OTHERDP.memlabs.test') }
)
$managedNamesWithProjection = @(Get-MemLabsManagedDistributionPointNames -VirtualMachines $virtualMachines -DefaultDomainName 'memlabs.test' -PrimarySiteCode PRI -AdditionalDistributionPointScopes $projectedScopes | Sort-Object)
Assert-Equal $true ($managedNamesWithProjection -contains 'LEGACYPRI.memlabs.test') 'host-projected Primary fallback is included and domain-qualified'
Assert-Equal 1 @($managedNamesWithProjection | Where-Object { $_ -eq 'EXISTINGDP1.memlabs.test' }).Count 'host-projected DP names are deduplicated with declared roles'
Assert-Equal $false ($managedNamesWithProjection -contains 'OTHERDP.memlabs.test') 'host projection from another Primary site is excluded'

$existingMembers = @{ 'PRIMARY1.EXTERNAL.TEST' = $true }
Assert-Equal $false (Test-MemLabsDistributionPointGroupMember -MemberKeys $existingMembers -DistributionPointName 'PRIMARY1.memlabs.test') 'external member with same short name does not suppress managed DP add'
Assert-Equal $true (Test-MemLabsDistributionPointGroupMember -MemberKeys $existingMembers -DistributionPointName 'primary1.external.test') 'membership comparison is exact and case-insensitive'

$script:MemberReadCount = 0
$script:CoverageMode = 'Delayed'
$script:Statuses = New-Object System.Collections.Generic.List[object]
$script:ContentPackages = @()
$script:GroupPackages = @()
$script:GroupPackageReadCount = 0
$script:GroupPackagesAfterRead = 0
$script:LiveDpReadCount = 0
$script:LiveDpMode = 'Present'
$script:GroupMembers = New-Object System.Collections.Generic.List[string]
$script:PendingGroupMembers = New-Object System.Collections.Generic.List[string]
$script:MemberProjectionAfterRead = 0
$script:AddReadCount = 0
$script:AddFailureAttempts = 0
function Get-CMDistributionPoint {
    param ([switch] $AllSite, $ErrorAction)

    $script:LiveDpReadCount++
    if ($script:LiveDpMode -eq 'Missing') { return @() }
    if ($script:LiveDpMode -eq 'Delayed' -and $script:LiveDpReadCount -eq 1) { return @() }
    if ($script:LiveDpMode -eq 'Unrelated') { return [pscustomobject]@{ NetworkOSPath = '\\EXTERNAL.memlabs.test' } }
    return [pscustomobject]@{ NetworkOSPath = '\\PRIMARY1.memlabs.test' }
}
function Get-WmiObject {
    param ([string] $Namespace, [string] $Class, [string] $Filter, [string] $ErrorAction)

    if ($Class -eq 'SMS_DistributionPointGroup') { return [pscustomobject]@{ GroupID = 'G1' } }
    if ($Class -eq 'SMS_CIContentPackage') { return $script:ContentPackages }
    if ($Class -eq 'SMS_DPGroupPackages') {
        $script:GroupPackageReadCount++
        if ($script:GroupPackageReadCount -le $script:GroupPackagesAfterRead) { return @() }
        return $script:GroupPackages
    }
    if ($Class -ne 'SMS_DPGroupMembers') { return }
    $script:MemberReadCount++
    if ($script:PendingGroupMembers.Count -gt 0 -and $script:MemberReadCount -gt $script:MemberProjectionAfterRead) {
        foreach ($pendingMember in @($script:PendingGroupMembers)) {
            if (-not $script:GroupMembers.Contains($pendingMember)) { [void]$script:GroupMembers.Add($pendingMember) }
        }
        $script:PendingGroupMembers.Clear()
    }
    @($script:GroupMembers | ForEach-Object { [pscustomobject]@{ DPNALPath = "[`"Display=\\$_`"]MSWNET:[`"SMS_SITE=ABC`"]\\$_\" } })
}
function Add-CMDistributionPointToGroup {
    param ([string] $DistributionPointGroupName, [string] $DistributionPointName, $ErrorAction)

    $script:AddReadCount++
    if ($script:AddReadCount -le $script:AddFailureAttempts) { throw 'simulated transient add failure' }
    if (-not $script:GroupMembers.Contains($DistributionPointName) -and -not $script:PendingGroupMembers.Contains($DistributionPointName)) {
        [void]$script:PendingGroupMembers.Add($DistributionPointName)
    }
}
function Write-DscStatus {
    param ([Parameter(Position = 0)][string] $Message, [switch] $Failure)

    $script:Statuses.Add([pscustomobject]@{ Message = $Message; Failure = [bool]$Failure })
}
function Start-Sleep { param ([int] $Seconds) }

[void]$script:GroupMembers.Add('PRIMARY1.external.test')
$script:MemberProjectionAfterRead = 2
$coverage = Sync-MemLabsDistributionPointGroupMembership -SiteCode ABC -GroupName 'All MEMLABS DPs' -ExpectedDistributionPointNames @('PRIMARY1.memlabs.test') -StatusTag '[test]' -Attempts 2 -RetrySeconds 0
Assert-Equal $true $coverage 'membership verification waits for the exact managed FQDN'
Assert-Equal $true ($script:MemberReadCount -ge 3) 'membership verification retries delayed provider state'
Assert-Equal 1 $script:AddReadCount 'missing managed DP is added once while provider projection catches up'

$script:MemberReadCount = 0
$script:AddReadCount = 0
$script:AddFailureAttempts = 1
$script:MemberProjectionAfterRead = 0
$script:GroupMembers.Clear()
[void]$script:GroupMembers.Add('PRIMARY1.external.test')
$script:PendingGroupMembers.Clear()
$script:Statuses.Clear()
$coverage = Sync-MemLabsDistributionPointGroupMembership -SiteCode ABC -GroupName 'All MEMLABS DPs' -ExpectedDistributionPointNames @('PRIMARY1.memlabs.test') -StatusTag '[test]' -Attempts 1 -RetrySeconds 0
Assert-Equal $false $coverage 'external member cannot mask a missing managed DP'
Assert-Equal 1 @($script:Statuses | Where-Object Failure).Count 'unverified membership records a phase failure'

$script:LiveDpMode = 'Unrelated'
$script:LiveDpReadCount = 0
$script:Statuses.Clear()
$coverage = Sync-MemLabsDistributionPointGroupMembership -SiteCode ABC -GroupName 'All MEMLABS DPs' -ExpectedDistributionPointNames @() -StatusTag '[test]' -Attempts 1 -RetrySeconds 0
Assert-Equal $false $coverage 'unrelated group membership cannot satisfy an empty managed-DP expectation'
Assert-Equal 1 @($script:Statuses | Where-Object Failure).Count 'empty managed-DP expectation records a phase failure'

$script:LiveDpMode = 'Missing'
$script:LiveDpReadCount = 0
$script:GroupMembers.Clear()
[void]$script:GroupMembers.Add('PRIMARY1.memlabs.test')
$script:Statuses.Clear()
$coverage = Sync-MemLabsDistributionPointGroupMembership -SiteCode ABC -GroupName 'All MEMLABS DPs' -ExpectedDistributionPointNames @('PRIMARY1.memlabs.test') -StatusTag '[test]' -Attempts 1 -RetrySeconds 0
Assert-Equal $false $coverage 'stale group membership cannot mask a missing live managed DP'
Assert-Equal 1 @($script:Statuses | Where-Object { $_.Failure -and $_.Message -match 'not registered as live DP' }).Count 'missing live managed DP is reported in the phase failure'

$script:LiveDpMode = 'Delayed'
$script:LiveDpReadCount = 0
$script:MemberReadCount = 0
$script:AddReadCount = 0
$script:AddFailureAttempts = 0
$script:MemberProjectionAfterRead = 0
$script:GroupMembers.Clear()
[void]$script:GroupMembers.Add('PRIMARY1.external.test')
$script:PendingGroupMembers.Clear()
$script:Statuses.Clear()
$coverage = Sync-MemLabsDistributionPointGroupMembership -SiteCode ABC -GroupName 'All MEMLABS DPs' -ExpectedDistributionPointNames @('PRIMARY1.memlabs.test') -StatusTag '[test]' -Attempts 2 -RetrySeconds 0
Assert-Equal $true $coverage 'membership verification retries delayed live DP registration'
Assert-Equal 2 $script:LiveDpReadCount 'live DP projection is refreshed on each coverage attempt'
Assert-Equal 1 $script:AddReadCount 'DP appearing on the second attempt is reconciled into the group'

$script:LiveDpMode = 'Present'
$script:LiveDpReadCount = 0
$script:MemberReadCount = 0
$script:AddReadCount = 0
$script:AddFailureAttempts = 1
$script:MemberProjectionAfterRead = 0
$script:GroupMembers.Clear()
$script:PendingGroupMembers.Clear()
$script:Statuses.Clear()
$coverage = Sync-MemLabsDistributionPointGroupMembership -SiteCode ABC -GroupName 'All MEMLABS DPs' -ExpectedDistributionPointNames @('PRIMARY1.memlabs.test') -StatusTag '[test]' -Attempts 2 -RetrySeconds 0
Assert-Equal $true $coverage 'membership reconciliation retries a transient add failure'
Assert-Equal 2 $script:AddReadCount 'transient add failure is retried rather than observed repeatedly'

$script:DistributionRequests = New-Object System.Collections.Generic.List[string]
$script:RemovalRequests = New-Object System.Collections.Generic.List[string]
$script:FailDistribution = $false
$script:DistributionFailureMessage = 'distribution failed'
$script:Applications = @{}
$script:Packages = @{}
$script:DeploymentPackages = @{}
function Start-CMContentDistribution {
    param ($ApplicationName, $PackageName, $DeploymentPackageName, $DistributionPointGroupName, $ErrorAction)

    if ($script:FailDistribution) { throw $script:DistributionFailureMessage }
    $contentName = @($ApplicationName, $PackageName, $DeploymentPackageName | Where-Object { $_ })[0]
    $script:DistributionRequests.Add("$contentName->$DistributionPointGroupName")
}
function Remove-CMContentDistribution {
    param ($ApplicationName, $PackageName, $DeploymentPackageName, $DistributionPointGroupName, [switch] $Force, $ErrorAction)

    $contentName = @($ApplicationName, $PackageName, $DeploymentPackageName | Where-Object { $_ })[0]
    $script:RemovalRequests.Add("$contentName->$DistributionPointGroupName")
}
function Get-CMApplication {
    param ($Name, [switch] $Fast, $ErrorAction)

    return $script:Applications[$Name]
}
function Get-CMPackage {
    param ($Name, [switch] $Fast, $ErrorAction)

    return $script:Packages[$Name]
}
function Get-CMSoftwareUpdateDeploymentPackage {
    param ($Name, $ErrorAction)

    return $script:DeploymentPackages[$Name]
}

$script:DeploymentPackages['MEMLABS-W10-11-CU-pkg'] = [pscustomobject]@{ PackageID = 'ABCUPD01' }
$script:GroupPackages = @([pscustomobject]@{ PkgID = 'ABCUPD01' })
$synced = Sync-MemLabsContentDistribution -ContentType DeploymentPackage -ContentName 'MEMLABS-W10-11-CU-pkg' -DistributionPointGroupName 'All MEMLABS DPs' -LegacyDistributionPointGroupName 'ALL DPS' -MigrateLegacy $true -StatusTag '[test]' -SiteCode ABC
Assert-Equal $true $synced 'existing update package targets the new group'
Assert-Equal 'MEMLABS-W10-11-CU-pkg->All MEMLABS DPs' ($script:DistributionRequests -join ',') 'new targeting precedes migration'
Assert-Equal 'MEMLABS-W10-11-CU-pkg->ALL DPS' ($script:RemovalRequests -join ',') 'legacy update-package targeting is removed'

$script:FailDistribution = $true
$script:RemovalRequests.Clear()
$synced = Sync-MemLabsContentDistribution -ContentType Application -ContentName 'MEMLABS-App' -DistributionPointGroupName 'All MEMLABS DPs' -LegacyDistributionPointGroupName 'ALL DPS' -MigrateLegacy $true -StatusTag '[test]' -SiteCode ABC
Assert-Equal $false $synced 'failed new targeting reports failure'
Assert-Equal 0 $script:RemovalRequests.Count 'failed new targeting retains legacy content'

$script:Applications['MEMLABS-App'] = [pscustomobject]@{ CI_ID = 42 }
$script:ContentPackages = @([pscustomobject]@{ PackageID = 'ABC00001' })
$script:GroupPackages = @([pscustomobject]@{ PkgID = 'ABC00001' })
$script:DistributionFailureMessage = 'No content destination was found.'
$script:Statuses.Clear()
$synced = Sync-MemLabsContentDistribution -ContentType Application -ContentName 'MEMLABS-App' -DistributionPointGroupName 'All MEMLABS DPs' -LegacyDistributionPointGroupName 'ALL DPS' -MigrateLegacy $false -StatusTag '[test]' -SiteCode ABC
Assert-Equal $true $synced 'ambiguous no-destination error is accepted after target verification'
Assert-Equal 1 @($script:Statuses | Where-Object { $_.Message -match 'already targeted' -and -not $_.Failure }).Count 'verified existing target is reported without a failure'

$script:Packages['MEMLABS-Package'] = [pscustomobject]@{ PackageID = 'ABC00002' }
$script:GroupPackages = @([pscustomobject]@{ PkgID = 'ABC00002' })
$script:Statuses.Clear()
$synced = Sync-MemLabsContentDistribution -ContentType Package -ContentName 'MEMLABS-Package' -DistributionPointGroupName 'All MEMLABS DPs' -LegacyDistributionPointGroupName 'ALL DPS' -MigrateLegacy $false -StatusTag '[test]' -SiteCode ABC
Assert-Equal $true $synced 'package no-destination error is accepted after target verification'
Assert-Equal 1 @($script:Statuses | Where-Object { $_.Message -match "Package 'MEMLABS-Package' is already targeted" -and -not $_.Failure }).Count 'verified existing package target is reported without a failure'

$script:FailDistribution = $false
$script:GroupPackageReadCount = 0
$script:GroupPackagesAfterRead = 1
$script:Statuses.Clear()
$synced = Sync-MemLabsContentDistribution -ContentType Package -ContentName 'MEMLABS-Package' -DistributionPointGroupName 'All MEMLABS DPs' -LegacyDistributionPointGroupName 'ALL DPS' -MigrateLegacy $false -StatusTag '[test]' -SiteCode ABC
Assert-Equal $true $synced 'successful distribution waits for delayed target projection'
Assert-Equal 2 $script:GroupPackageReadCount 'target postcondition retries until the provider projects the assignment'

$script:FailDistribution = $true
$script:GroupPackagesAfterRead = 0
$script:GroupPackages = @()
$script:Statuses.Clear()
$synced = Sync-MemLabsContentDistribution -ContentType Application -ContentName 'MEMLABS-App' -DistributionPointGroupName 'All MEMLABS DPs' -LegacyDistributionPointGroupName 'ALL DPS' -MigrateLegacy $false -StatusTag '[test]' -SiteCode ABC
Assert-Equal $false $synced 'no-destination error remains fatal when the target is absent'
Assert-Equal 1 @($script:Statuses | Where-Object Failure).Count 'absent target records a phase failure'

$source = Get-Content -LiteralPath $perfloadingPath -Raw
Assert-Equal $true $source.Contains('$DPGroupName = "All MEMLABS DPs"') 'production group name reflects MemLabs ownership'
Assert-Equal $true $source.Contains('Distribution points created and managed by MEMLABS') 'production group description reflects MemLabs ownership'
Assert-Equal $true $source.Contains('$allDistributionPoints = @(Get-CMDistributionPoint -AllSite -ErrorAction Stop)') 'production refreshes live DPs during membership reconciliation'
Assert-Equal $true $source.Contains('-AdditionalDistributionPointScopes $deployConfig.phase8ManagedDistributionPointScopes') 'production consumes per-Primary add-to-existing DP ownership'
Assert-Equal $true $source.Contains('Sync-MemLabsDistributionPointGroupMembership -SiteCode $SiteCode') 'production reconciles and verifies group membership in one retry loop'
Assert-Equal $true $source.Contains('-ExpectedDistributionPointNames $managedDpNames') 'production requires every site-scoped config-owned DP, including missing live rows'
Assert-Equal $true $source.Contains('external DP(s)/CMG(s) are left unchanged') 'production preserves manual external membership'
Assert-Equal $false $source.Contains('-DistributionPointGroupName "ALL DPS"') 'content calls do not target the legacy group name'
$distributionOffset = $source.IndexOf('Sync-MemLabsContentDistribution -ContentType Application -ContentName $appname')
$deploymentOffset = $source.IndexOf('New-CMApplicationDeployment -ApplicationName "$appname"')
Assert-Equal $true ($distributionOffset -ge 0 -and $distributionOffset -lt $deploymentOffset) 'application content is targeted before its collection deployment is created'
$packageDistributionOffset = $source.IndexOf('Sync-MemLabsContentDistribution -ContentType Package -ContentName $pkgName')
$packageDeploymentOffset = $source.IndexOf('New-CMPackageDeployment -StandardProgram -PackageId $Package.PackageID')
Assert-Equal $true ($packageDistributionOffset -ge 0 -and $packageDistributionOffset -lt $packageDeploymentOffset) 'package content is targeted before its collection deployment is created'

if ($script:Failures -gt 0) {
    Write-Host "$script:Failures check(s) failed."
    exit 1
}

Write-Host 'All perfloading DP-group scope checks passed.'
