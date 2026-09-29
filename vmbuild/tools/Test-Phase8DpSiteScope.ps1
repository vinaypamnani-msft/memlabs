<#
.SYNOPSIS
    Verifies exact ConfigMgr DP-group resolution, membership, and content targeting.
#>
[CmdletBinding()]
param (
    [string] $RootPath
)

$ErrorActionPreference = 'Stop'
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

function Assert-Throws {
    param ([scriptblock] $Action, [string] $MessagePattern, [string] $What)

    $caught = $null
    try { & $Action } catch { $caught = $_ }
    $passed = $caught -and $caught.Exception.Message -like $MessagePattern
    if (-not $passed) { $script:Failures++ }
    Write-Host ('{0}  {1}' -f $(if ($passed) { 'PASS' } else { 'FAIL' }), $What)
    if (-not $passed) {
        $actual = if ($caught) { $caught.Exception.Message } else { '<no exception>' }
        Write-Host "      expected: $MessagePattern"
        Write-Host "      actual:   $actual"
    }
}

function Import-TestFunction {
    param ([string] $Path, [string] $Name)

    $errors = $null
    $tokens = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    $parseErrors = @($errors | Where-Object { $null -ne $_ })
    if ($parseErrors.Count -ne 0) { throw "$Path has $($parseErrors.Count) parse error(s)" }
    $definitions = @($ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($definitions.Count -ne 1) { throw "Expected one $Name definition, found $($definitions.Count)" }
    [scriptblock]::Create($definitions[0].Extent.Text)
}

$perfloadingPath = Join-Path $RootPath 'DSC\phases\perfloading.ps1'
$configPath = Join-Path $RootPath 'common\Common.Config.ps1'
. (Import-TestFunction -Path $perfloadingPath -Name 'Get-MemLabsManagedDistributionPointNames')
. (Import-TestFunction -Path $perfloadingPath -Name 'Get-MemLabsServerFromNalPath')
. (Import-TestFunction -Path $perfloadingPath -Name 'Test-MemLabsDistributionPointGroupMember')
. (Import-TestFunction -Path $perfloadingPath -Name 'Get-MemLabsDistributionPointGroup')
. (Import-TestFunction -Path $perfloadingPath -Name 'Test-MemLabsShouldManageDistributionPointGroup')
. (Import-TestFunction -Path $perfloadingPath -Name 'Sync-MemLabsDistributionPointGroupMembership')
. (Import-TestFunction -Path $perfloadingPath -Name 'Get-MemLabsContentPackageIds')
. (Import-TestFunction -Path $perfloadingPath -Name 'Invoke-MemLabsDistributionPointGroupPackageMethod')
. (Import-TestFunction -Path $perfloadingPath -Name 'Test-MemLabsContentDistributionTarget')
. (Import-TestFunction -Path $perfloadingPath -Name 'Sync-MemLabsContentDistribution')
. (Import-TestFunction -Path $configPath -Name 'Add-Phase8DistributionPointMetadata')

Write-Host "engine : $($PSVersionTable.PSVersion)"

$virtualMachines = @(
    [pscustomobject]@{ vmName = 'PRIMARY1'; role = 'Primary'; siteCode = 'PRI'; installDP = $true; enablePullDP = $false },
    [pscustomobject]@{ vmName = 'PULLDP1'; role = 'SiteSystem'; siteCode = 'PRI'; installDP = $false; enablePullDP = $true },
    [pscustomobject]@{ vmName = 'SECONDARY1'; role = 'Secondary'; siteCode = 'SEC'; parentSiteCode = 'PRI'; installDP = $false; enablePullDP = $false },
    [pscustomobject]@{ vmName = 'OTHERDP'; role = 'SiteSystem'; siteCode = 'OTH'; installDP = $true; enablePullDP = $false },
    [pscustomobject]@{ vmName = 'FOREIGNDP'; role = 'SiteSystem'; siteCode = 'PRI'; domain = 'foreign.test'; installDP = $true; enablePullDP = $false }
)
$projectedScopes = @(
    [pscustomobject]@{ PrimarySiteCode = 'PRI'; DistributionPointNames = @('EXISTINGPRI') },
    [pscustomobject]@{ PrimarySiteCode = 'OTH'; DistributionPointNames = @('EXISTINGOTH') }
)
$managedNames = @(Get-MemLabsManagedDistributionPointNames -VirtualMachines $virtualMachines -DefaultDomainName 'memlabs.test' -PrimarySiteCode PRI -AdditionalDistributionPointScopes $projectedScopes | Sort-Object)
Assert-Equal 'EXISTINGPRI.memlabs.test,PRIMARY1.memlabs.test,PULLDP1.memlabs.test,SECONDARY1.memlabs.test' ($managedNames -join ',') 'only the requested Primary hierarchy is selected'
Assert-Equal $false ($managedNames -contains 'OTHERDP.memlabs.test') 'another Primary site is excluded'
Assert-Equal $false ($managedNames -contains 'FOREIGNDP.foreign.test') 'another domain is excluded'
Assert-Equal $false (Test-MemLabsShouldManageDistributionPointGroup -CurrentRole CAS -ManagedDistributionPointNames @()) 'CAS without managed DPs skips competing empty-group creation'
Assert-Equal $true (Test-MemLabsShouldManageDistributionPointGroup -CurrentRole Primary -ManagedDistributionPointNames @()) 'Primary owns group reconciliation'
Assert-Equal $true (Test-MemLabsShouldManageDistributionPointGroup -CurrentRole CAS -ManagedDistributionPointNames @('CASDP.memlabs.test')) 'CAS with a managed DP owns group reconciliation'

$script:Groups = @()
$script:MembersByGroup = @{}
$script:GroupPackagesById = @{}
$script:ContentPackages = @()
$script:Applications = @{}
$script:AddedGroupIds = New-Object System.Collections.Generic.List[string]
$script:GroupMethodRequests = New-Object System.Collections.Generic.List[string]
$script:DistributionRequests = New-Object System.Collections.Generic.List[string]
$script:Statuses = New-Object System.Collections.Generic.List[object]
$script:LiveDpMode = 'Present'

function Get-WmiObject {
    param ([string] $Namespace, [string] $Class, [string] $Filter, $ErrorAction)

    switch ($Class) {
        'SMS_DistributionPointGroup' {
            if ($Filter -match "^GroupID='([^']+)'$") {
                return @($script:Groups | Where-Object { "$($_.GroupID)" -eq $Matches[1] })
            }
            if ($Filter -match "^Name='([^']+)'$") {
                return @($script:Groups | Where-Object { "$($_.Name)" -eq $Matches[1] })
            }
            return @($script:Groups)
        }
        'SMS_DPGroupMembers' {
            if ($Filter -notmatch "^GroupID='([^']+)'$") { return @() }
            return @($script:MembersByGroup[$Matches[1]] | ForEach-Object {
                    [pscustomobject]@{ DPNALPath = "[`"Display=\\$_`"]MSWNET:[`"SMS_SITE=ABC`"]\\$_\" }
                })
        }
        'SMS_CIContentPackage' { return @($script:ContentPackages) }
        'SMS_DPGroupPackages' {
            if ($Filter -notmatch "^GroupID='([^']+)'$") { return @() }
            return @($script:GroupPackagesById[$Matches[1]])
        }
    }
}

function Get-CMDistributionPoint {
    param ([switch] $AllSite, $ErrorAction)

    if ($script:LiveDpMode -eq 'Missing') { return @() }
    [pscustomobject]@{ NetworkOSPath = '\\PRIMARY1.memlabs.test' }
}

function Add-CMDistributionPointToGroup {
    param ([string] $DistributionPointGroupId, [string] $DistributionPointName, $ErrorAction)

    $script:AddedGroupIds.Add($DistributionPointGroupId)
    $members = @($script:MembersByGroup[$DistributionPointGroupId])
    if ($members -notcontains $DistributionPointName) { $members += $DistributionPointName }
    $script:MembersByGroup[$DistributionPointGroupId] = @($members)
    [pscustomobject]@{ GroupID = $DistributionPointGroupId }
}

function Get-CMApplication {
    param ([string] $Name, [switch] $Fast, $ErrorAction)
    $script:Applications[$Name]
}

function Get-CMPackage {
    param ([string] $Name, [switch] $Fast, $ErrorAction)
}

function Get-CMSoftwareUpdateDeploymentPackage {
    param ([string] $Name, $ErrorAction)
}

function Invoke-WmiMethod {
    param ($InputObject, [string] $Name, [object[]] $ArgumentList, $ErrorAction)

    if ($ArgumentList.Count -ne 1 -or $ArgumentList[0] -isnot [string[]]) {
        throw 'DP-group package method requires one string-array argument'
    }
    $packageIds = @($ArgumentList[0] | Where-Object { $_ })
    $script:GroupMethodRequests.Add("${Name}:$($InputObject.GroupID):$($packageIds -join ',')")
    if ($Name -eq 'AddPackages') {
        $script:GroupPackagesById["$($InputObject.GroupID)"] = @($packageIds | ForEach-Object { [pscustomobject]@{ PkgID = "$_" } })
    }
    [pscustomobject]@{ ReturnValue = 0 }
}

function Start-CMContentDistribution {
    param ($ApplicationName, $PackageId, $PackageName, $DeploymentPackageName, $DistributionPointGroupName, $ErrorAction)

    $contentName = @($ApplicationName, $PackageId, $PackageName, $DeploymentPackageName | Where-Object { $_ })[0]
    $script:DistributionRequests.Add("$contentName->$DistributionPointGroupName")
}

function Write-DscStatus {
    param ([Parameter(Position = 0)][string] $Message, [switch] $Failure, [switch] $Warning)
    $script:Statuses.Add([pscustomobject]@{ Message = $Message; Failure = [bool]$Failure; Warning = [bool]$Warning })
}

function Write-Log {
    param ([Parameter(Position = 0)][string] $Message, [switch] $LogOnly)
}

function Start-Sleep { param ([int] $Seconds) }

$script:Groups = @(
    [pscustomobject]@{ Name = 'ALL DPS'; GroupID = 'CAS-GROUP'; SourceSite = 'CAS' },
    [pscustomobject]@{ Name = 'ALL DPS'; GroupID = 'PRI-GROUP'; SourceSite = 'PRI' }
)
$resolution = Get-MemLabsDistributionPointGroup -SiteCode PRI -GroupName 'ALL DPS'
Assert-Equal 'PRI-GROUP' $resolution.Group.GroupID 'same-name resolution selects the local SourceSite row'
Assert-Equal 2 $resolution.MatchCount 'same-name resolution reports ambiguity'
$resolution = Get-MemLabsDistributionPointGroup -SiteCode PRI -GroupName 'ALL DPS' -GroupId 'CAS-GROUP'
Assert-Equal 'CAS-GROUP' $resolution.Group.GroupID 'explicit GroupID pins the requested row'

$script:Groups = @([pscustomobject]@{ Name = 'ALL DPS'; GroupID = 'SOLE-GROUP'; SourceSite = 'CAS' })
$resolution = Get-MemLabsDistributionPointGroup -SiteCode PRI -GroupName 'ALL DPS'
Assert-Equal 'SOLE-GROUP' $resolution.Group.GroupID 'a sole non-local row is selected'

$script:Groups = @(
    [pscustomobject]@{ Name = 'ALL DPS'; GroupID = 'CAS-1'; SourceSite = 'CAS' },
    [pscustomobject]@{ Name = 'ALL DPS'; GroupID = 'CAS-2'; SourceSite = 'CAS' }
)
Assert-Throws { Get-MemLabsDistributionPointGroup -SiteCode PRI -GroupName 'ALL DPS' } '*none is owned by site PRI*' 'ambiguous non-local rows fail closed'

$script:Groups = @(
    [pscustomobject]@{ Name = 'ALL DPS'; GroupID = 'CAS-GROUP'; SourceSite = 'CAS' },
    [pscustomobject]@{ Name = 'ALL DPS'; GroupID = 'PRI-GROUP'; SourceSite = 'PRI' }
)
$script:MembersByGroup = @{ 'CAS-GROUP' = @(); 'PRI-GROUP' = @() }
$script:AddedGroupIds.Clear()
$script:Statuses.Clear()
$coverageResults = @(Sync-MemLabsDistributionPointGroupMembership -SiteCode PRI -GroupName 'ALL DPS' -DistributionPointGroupId 'PRI-GROUP' -ExpectedDistributionPointNames @('PRIMARY1.memlabs.test') -StatusTag '[test]' -Attempts 1 -RetrySeconds 0)
Assert-Equal 1 $coverageResults.Count 'membership helper emits only its Boolean result'
Assert-Equal $true $coverageResults[0] 'exact local group membership is reconciled'
Assert-Equal 'PRI-GROUP' ($script:AddedGroupIds -join ',') 'membership add pins the local GroupID'
Assert-Equal 0 @($script:MembersByGroup['CAS-GROUP']).Count 'same-name CAS group is not mutated'

$script:LiveDpMode = 'Missing'
$script:MembersByGroup['PRI-GROUP'] = @('PRIMARY1.memlabs.test')
$script:Statuses.Clear()
$coverage = Sync-MemLabsDistributionPointGroupMembership -SiteCode PRI -GroupName 'ALL DPS' -DistributionPointGroupId 'PRI-GROUP' -ExpectedDistributionPointNames @('PRIMARY1.memlabs.test') -StatusTag '[test]' -Attempts 1 -RetrySeconds 0
Assert-Equal $false $coverage 'stale membership cannot hide a missing live DP'
Assert-Equal 1 @($script:Statuses | Where-Object { $_.Failure -and $_.Message -match 'not registered as live DP' }).Count 'missing live DP records a phase failure'

$script:LiveDpMode = 'Present'
$script:MembersByGroup['PRI-GROUP'] = @('PRIMARY1.memlabs.test')
$script:Applications['MEMLABS-App'] = [pscustomobject]@{ CI_ID = 42 }
$script:ContentPackages = @([pscustomobject]@{ PackageID = 'PRI00001' })
$script:GroupPackagesById = @{ 'CAS-GROUP' = @(); 'PRI-GROUP' = @() }
$script:GroupMethodRequests.Clear()
$script:DistributionRequests.Clear()
$synced = Sync-MemLabsContentDistribution -ContentType Application -ContentName 'MEMLABS-App' -DistributionPointGroupName 'ALL DPS' -DistributionPointGroupId 'PRI-GROUP' -StatusTag '[test]' -SiteCode PRI
Assert-Equal $true $synced 'duplicate-name application targeting succeeds by exact group'
Assert-Equal 'AddPackages:PRI-GROUP:PRI00001' ($script:GroupMethodRequests -join ',') 'duplicate-name targeting uses exact AddPackages'
Assert-Equal 0 $script:DistributionRequests.Count 'ambiguous group name is never passed to Start-CMContentDistribution'

$script:GroupMethodRequests.Clear()
Invoke-MemLabsDistributionPointGroupPackageMethod -Group $script:Groups[1] -MethodName RemovePackages -PackageIds @('PRI00001')
Assert-Equal 'RemovePackages:PRI-GROUP:PRI00001' ($script:GroupMethodRequests -join ',') 'duplicate-name removal supports exact RemovePackages'

$perfloadingText = Get-Content -LiteralPath $perfloadingPath -Raw
Assert-Equal $false ($perfloadingText -match '-DistributionPointGroupName\s+["'']ALL DPS["'']') 'production content calls never hardcode the ambiguous ALL DPS name'
Assert-Equal $true $perfloadingText.Contains("skipping empty CAS group creation") 'production skips CAS group creation when the CAS owns no managed DPs'
Assert-Equal $true $perfloadingText.Contains("OSD content is not distributed by the ambiguous group name") 'production suppresses ambiguous OSD name distribution'

$config = [pscustomobject]@{
    vmOptions = [pscustomobject]@{ domainName = 'memlabs.test' }
    virtualMachines = @(
        [pscustomobject]@{ vmName = 'PRIMARY1'; role = 'Primary'; siteCode = 'PRI'; hidden = $true },
        [pscustomobject]@{ vmName = 'NEWDP'; role = 'SiteSystem'; siteCode = 'PRI'; installDP = $true },
        [pscustomobject]@{ vmName = 'OTHERPRIMARY'; role = 'Primary'; siteCode = 'OTH' },
        [pscustomobject]@{ vmName = 'OTHERDP'; role = 'SiteSystem'; siteCode = 'OTH'; installDP = $true }
    )
}
$existingVMs = @(
    [pscustomobject]@{ vmName = 'EXISTINGDP'; role = 'SiteSystem'; siteCode = 'PRI'; domain = 'memlabs.test'; installDP = $true }
)
Add-Phase8DistributionPointMetadata -Config $config -ExistingVMs $existingVMs -InventoryRefreshVerified $true
$primaryScope = @($config.phase8ManagedDistributionPointScopes | Where-Object { $_.PrimarySiteCode -eq 'PRI' })
Assert-Equal 1 $primaryScope.Count 'one ownership scope is projected for the Primary site'
Assert-Equal 'EXISTINGDP.memlabs.test,NEWDP.memlabs.test' (@($primaryScope[0].DistributionPointNames | Sort-Object) -join ',') 'projected ownership combines existing and configured site DPs'

$fallbackConfig = [pscustomobject]@{
    vmOptions = [pscustomobject]@{ domainName = 'memlabs.test' }
    virtualMachines = @([pscustomobject]@{ vmName = 'LEGACYPRI'; role = 'Primary'; siteCode = 'LEG'; hidden = $true })
}
Add-Phase8DistributionPointMetadata -Config $fallbackConfig -ExistingVMs @() -InventoryRefreshVerified $true
Assert-Equal 'LEGACYPRI.memlabs.test' ($fallbackConfig.phase8ManagedDistributionPointScopes[0].DistributionPointNames -join ',') 'an existing Primary is retained as the deploy-time DP fallback'

$unverifiedConfig = [pscustomobject]@{
    vmOptions = [pscustomobject]@{ domainName = 'memlabs.test' }
    virtualMachines = @([pscustomobject]@{ vmName = 'LEGACYPRI'; role = 'Primary'; siteCode = 'LEG'; hidden = $true })
}
Assert-Throws { Add-Phase8DistributionPointMetadata -Config $unverifiedConfig -ExistingVMs @() -InventoryRefreshVerified $false } '*live VM inventory refresh returned no data*' 'unverified existing-site inventory is rejected'

if ($script:Failures -gt 0) {
    Write-Host "$script:Failures check(s) failed."
    exit 1
}

Write-Host 'All Phase 8 DP site-scope checks passed.'
