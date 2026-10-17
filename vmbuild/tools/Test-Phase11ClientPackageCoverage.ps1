#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$validationPath = Join-Path $root 'common\Common.Validation.Functional.ps1'

function Get-TestAst {
    param([string]$Path)
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "$Path has parse errors: $($errors -join '; ')" }
    return $ast
}
function Import-TestFunction {
    param($Ast, [string]$Name)
    $definitions = @($Ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($definitions.Count -ne 1) { throw "Expected one $Name definition." }
    [scriptblock]::Create($definitions[0].Extent.Text)
}
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$ast = Get-TestAst $validationPath
. (Import-TestFunction -Ast $ast -Name 'Get-ClientPackageValidationScope')
. (Import-TestFunction -Ast (Get-TestAst (Join-Path $root 'common\Common.Config.ps1')) -Name 'Test-PushClientRequested')
$validator = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-CMClientPackageDistribution'
    }, $true)
$assignment = $validator.Body.Find({
        param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$scriptBlock'
    }, $true)
$factory = [scriptblock]::Create($assignment.Extent.Text + "`nreturn `$scriptBlock")
$guestValidator = & $factory

$primary = [pscustomobject]@{ vmName = 'PRI1'; role = 'Primary'; siteCode = 'PRI' }
$secondary = [pscustomobject]@{ vmName = 'SEC1'; role = 'Secondary'; siteCode = 'SEC'; parentSiteCode = 'PRI'; network = '10.20.2.0' }
$client = [pscustomobject]@{ vmName = 'CLIENT1'; role = 'DomainMember'; pushClient = $false; network = '10.20.2.0' }
$config = [pscustomobject]@{
    virtualMachines = @(
        $primary,
        [pscustomobject]@{ vmName = 'DP1'; role = 'SiteSystem'; siteCode = 'PRI'; installDP = $true },
        [pscustomobject]@{ vmName = 'DP2'; role = 'SiteSystem'; siteCode = 'PRI'; installDP = $true },
        $secondary, $client
    )
}
$scope = Get-ClientPackageValidationScope -CurrentItem $primary -DeployConfig $config
Assert-True ($scope.RequiredDpNames -contains 'DP1' -and $scope.RequiredDpNames -contains 'DP2' -and
    $scope.RequiredDpNames -notcontains 'SEC1') 'An unassigned Secondary was treated as required, or a regular DP was omitted.'
$client.pushClient = 'SEC'
$assignedScope = Get-ClientPackageValidationScope -CurrentItem $primary -DeployConfig $config
Assert-True ($assignedScope.RequiredDpNames -contains 'SEC1') 'A Secondary with assigned push clients was not required.'
$client.pushClient = $true
$networkScope = Get-ClientPackageValidationScope -CurrentItem $primary -DeployConfig $config
Assert-True ($networkScope.RequiredDpNames -contains 'SEC1') 'Legacy boolean push targeting lost its secondary-network requirement.'
$client.pushClient = $false
$config | Add-Member -NotePropertyName phase8ManagedDistributionPointScopes -NotePropertyValue @(
    [pscustomobject]@{ PrimarySiteCode = 'PRI'; DistributionPoints = @(
            [pscustomobject]@{ VmName = 'DP3'; Role = 'SiteSystem'; SiteCode = 'PRI'; Network = '10.20.3.0' }
        ) }
)
$projectedScope = Get-ClientPackageValidationScope -CurrentItem $primary -DeployConfig $config
Assert-True ($projectedScope.RequiredDpNames -contains 'DP3') 'An omitted but host-projected managed DP escaped final validation.'

$script:Rows = @()
$script:NoPackage = $false
$script:UpgradeOnly = $false
$script:ForeignPackage = $false
$script:FailClass = ''
function Start-Sleep { param($Seconds) }
function Get-ItemProperty { param($Path, $Name, $ErrorAction); throw 'No fixture installation directory.' }
function Get-WmiObject {
    param($Namespace, $Class, $Filter, $ErrorAction)
    if ($Class -eq $script:FailClass) { throw "Fixture query failure: $Class" }
    switch ($Class) {
        'SMS_Package' {
            if (-not $script:NoPackage) {
                [pscustomobject]@{
                    Name = $(if ($script:UpgradeOnly) { 'Configuration Manager Client Upgrade Package' } else { 'Configuration Manager Client Package' })
                    PackageID = 'PRI00004'
                    SourceSite = 'PRI'; SourceVersion = 1; StoredPkgVersion = 1
                }
                if ($script:ForeignPackage) {
                    [pscustomobject]@{
                        Name = 'Configuration Manager Client Package'; PackageID = 'OTH00004'
                        SourceSite = 'OTH'; SourceVersion = 2; StoredPkgVersion = 2
                    }
                }
            }
        }
        'SMS_PackageStatusDistPointsSummarizer' {
            if ($Filter -match '^State') { return }
            if ($Filter -match 'OTH00004') {
                return [pscustomobject]@{ ServerNALPath = '\\DP1.fixture.test\'; State = 0; SiteCode = 'PRI'; SourceVersion = 2 }
            }
            return $script:Rows
        }
        'SMS_BoundaryGroup' { return [pscustomobject]@{ Name = 'PRI'; GroupID = 1 } }
        'SMS_BoundaryGroupSiteSystems' {
            foreach ($name in @('DP1', 'DP2', 'SEC1')) {
                [pscustomobject]@{ GroupID = 1; ServerNALPath = "\\$name.fixture.test\" }
            }
        }
        default { throw "Unexpected fixture class $Class" }
    }
}
function New-DpRow {
    param([string]$Name, [int]$State, [string]$SiteCode = 'PRI')
    [pscustomobject]@{ ServerNALPath = "\\$Name.fixture.test\"; State = $State; SiteCode = $SiteCode; SourceVersion = 1 }
}
function Invoke-FixtureValidation {
    param([string[]]$RequiredNames = @('DP1', 'DP2'))
    & $guestValidator 'PRI' 'PRI,SEC' 'DP1,DP2,SEC1' ($RequiredNames -join ',')
}

$script:Rows = @((New-DpRow DP1 7), (New-DpRow DP2 0), (New-DpRow SEC1 7 SEC))
$pending = Invoke-FixtureValidation
Assert-True (-not $pending.Passed -and
    @($pending.Details | Where-Object { $_ -match "FAIL: required DP 'DP1'" }).Count -eq 1) `
    'A healthy fallback hid a pending required DP after Phase 8 deferred coverage.'

$script:Rows = @((New-DpRow DP1 0), (New-DpRow DP2 0), (New-DpRow SEC1 7 SEC))
$optional = Invoke-FixtureValidation
Assert-True $optional.Passed 'An unassigned optional Secondary failed otherwise healthy client-package coverage.'
$script:ForeignPackage = $true
$otherSitePackage = Invoke-FixtureValidation
Assert-True $otherSitePackage.Passed 'Another site-owned same-name package was incorrectly required on every local DP.'
$script:ForeignPackage = $false
$assigned = Invoke-FixtureValidation -RequiredNames @('DP1', 'DP2', 'SEC1')
Assert-True (-not $assigned.Passed -and
    @($assigned.Details | Where-Object { $_ -match "FAIL: required DP 'SEC1'" }).Count -eq 1) `
    'A pending Secondary required by clients did not fail Phase 11.'

$script:Rows = @((New-DpRow DP2 0))
$missing = Invoke-FixtureValidation
Assert-True (-not $missing.Passed -and
    @($missing.Details | Where-Object { $_ -match "FAIL: required DP 'DP1'" }).Count -eq 1) `
    'A missing required DP row was mistaken for installed coverage.'

$script:NoPackage = $true
$noPackage = Invoke-FixtureValidation
Assert-True (-not $noPackage.Passed) 'A missing client package produced success despite required DPs.'
$script:NoPackage = $false
$script:UpgradeOnly = $true
$upgradeOnly = Invoke-FixtureValidation
Assert-True (-not $upgradeOnly.Passed) 'An upgrade package hid the missing production client package.'
$script:UpgradeOnly = $false
$script:Rows = @((New-DpRow DP1 0), (New-DpRow DP2 0))
$script:Rows[0].SourceVersion = 0
$staleVersion = Invoke-FixtureValidation
Assert-True (-not $staleVersion.Passed -and
    @($staleVersion.Details | Where-Object { $_ -match "FAIL: required DP 'DP1'.*SourceVersion=1" }).Count -eq 1) `
    'An Installed row for an older client-package version passed required coverage.'
$script:Rows = @((New-DpRow DP1 0), (New-DpRow DP2 0))
$script:FailClass = 'SMS_BoundaryGroupSiteSystems'
$unreadable = Invoke-FixtureValidation
Assert-True (-not $unreadable.Passed -and
    @($unreadable.Details | Where-Object { $_ -match 'FAIL: boundary-group coverage could not be verified' }).Count -eq 1) `
    'Unreadable boundary coverage was treated as successful validation.'
$script:FailClass = 'SMS_PackageStatusDistPointsSummarizer'
$threw = $false
try { $null = Invoke-FixtureValidation }
catch { $threw = $_.Exception.Message -match 'Fixture query failure' }
Assert-True $threw 'An unreadable required summarizer was silently treated as empty or healthy.'

Write-Host 'PASS -- Phase 11 rejects unresolved required coverage while preserving optional Secondary and site ownership rules.'
