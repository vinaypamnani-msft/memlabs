<#
.SYNOPSIS
    Verifies Phase 8 Distribution Point ownership and reconciliation by site.
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
    $status = if ($passed) { 'PASS' } else { 'FAIL' }
    Write-Host ('{0}  {1}' -f $status, $What)
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
    return [scriptblock]::Create($definitions[0].Extent.Text)
}

$perfloadingPath = Join-Path $RootPath 'DSC\phases\perfloading.ps1'
$configPath = Join-Path $RootPath 'common\Common.Config.ps1'
. (Import-TestFunction -Path $perfloadingPath -Name 'Get-MemLabsManagedDistributionPointNames')
. (Import-TestFunction -Path $perfloadingPath -Name 'Test-MemLabsDistributionPointGroupMember')
. (Import-TestFunction -Path $perfloadingPath -Name 'Sync-MemLabsDistributionPointGroupMembership')
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

$script:LiveDpMode = 'Present'
$script:LiveDpReadCount = 0
$script:MemberReadCount = 0
$script:MemberProjectionAfterRead = 2
$script:AddReadCount = 0
$script:AddFailureAttempts = 0
$script:GroupMembers = New-Object System.Collections.Generic.List[string]
$script:PendingGroupMembers = New-Object System.Collections.Generic.List[string]
$script:Statuses = New-Object System.Collections.Generic.List[object]

function Get-CMDistributionPoint {
    param ([switch] $AllSite, $ErrorAction)

    $script:LiveDpReadCount++
    if ($script:LiveDpMode -eq 'Missing') { return @() }
    if ($script:LiveDpMode -eq 'Delayed' -and $script:LiveDpReadCount -eq 1) { return @() }
    return [pscustomobject]@{ NetworkOSPath = '\\PRIMARY1.memlabs.test' }
}

function Get-WmiObject {
    param ([string] $Namespace, [string] $Class, [string] $Filter, $ErrorAction)

    if ($Class -eq 'SMS_DistributionPointGroup') { return [pscustomobject]@{ GroupID = 'G1' } }
    if ($Class -ne 'SMS_DPGroupMembers') { return }
    $script:MemberReadCount++
    if ($script:PendingGroupMembers.Count -gt 0 -and $script:MemberReadCount -gt $script:MemberProjectionAfterRead) {
        foreach ($pendingMember in @($script:PendingGroupMembers)) {
            if (-not $script:GroupMembers.Contains($pendingMember)) { [void]$script:GroupMembers.Add($pendingMember) }
        }
        $script:PendingGroupMembers.Clear()
    }
    @($script:GroupMembers | ForEach-Object {
            [pscustomobject]@{ DPNALPath = "[`"Display=\\$_`"]MSWNET:[`"SMS_SITE=ABC`"]\\$_\" }
        })
}

function Add-CMDistributionPointToGroup {
    param ([string] $DistributionPointGroupName, [string] $DistributionPointName, $ErrorAction)

    $script:AddReadCount++
    if ($script:AddReadCount -le $script:AddFailureAttempts) { throw 'simulated transient add failure' }
    if (-not $script:PendingGroupMembers.Contains($DistributionPointName)) {
        [void]$script:PendingGroupMembers.Add($DistributionPointName)
    }
}

function Write-DscStatus {
    param ([Parameter(Position = 0)][string] $Message, [switch] $Failure)

    $script:Statuses.Add([pscustomobject]@{ Message = $Message; Failure = [bool]$Failure })
}

function Write-Log {
    param ([Parameter(Position = 0)][string] $Message, [switch] $LogOnly)
}

function Start-Sleep { param ([int] $Seconds) }

$coverage = Sync-MemLabsDistributionPointGroupMembership -SiteCode ABC -GroupName 'ALL DPS' -ExpectedDistributionPointNames @('PRIMARY1.memlabs.test') -StatusTag '[test]' -Attempts 2 -RetrySeconds 0
Assert-Equal $true $coverage 'membership waits for provider projection after adding the managed DP'
Assert-Equal 1 $script:AddReadCount 'a missing managed DP is added once'

$script:LiveDpMode = 'Missing'
$script:LiveDpReadCount = 0
$script:MemberReadCount = 0
$script:GroupMembers.Clear()
[void]$script:GroupMembers.Add('PRIMARY1.memlabs.test')
$script:PendingGroupMembers.Clear()
$script:Statuses.Clear()
$coverage = Sync-MemLabsDistributionPointGroupMembership -SiteCode ABC -GroupName 'ALL DPS' -ExpectedDistributionPointNames @('PRIMARY1.memlabs.test') -StatusTag '[test]' -Attempts 1 -RetrySeconds 0
Assert-Equal $false $coverage 'stale group membership cannot mask a missing live DP'
Assert-Equal 1 @($script:Statuses | Where-Object { $_.Failure -and $_.Message -match 'not registered as live DP' }).Count 'missing live DP records a phase failure'

$script:LiveDpMode = 'Present'
$script:LiveDpReadCount = 0
$script:MemberReadCount = 0
$script:MemberProjectionAfterRead = 0
$script:AddReadCount = 0
$script:AddFailureAttempts = 1
$script:GroupMembers.Clear()
$script:PendingGroupMembers.Clear()
$script:Statuses.Clear()
$coverage = Sync-MemLabsDistributionPointGroupMembership -SiteCode ABC -GroupName 'ALL DPS' -ExpectedDistributionPointNames @('PRIMARY1.memlabs.test') -StatusTag '[test]' -Attempts 2 -RetrySeconds 0
Assert-Equal $true $coverage 'membership retries a transient add failure'
Assert-Equal 2 $script:AddReadCount 'the add is retried rather than merely observed'

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