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
. (Import-TestFunction -Ast $ast -Name 'Invoke-CmWmiQueryWithRetry')
. (Import-TestFunction -Ast (Get-TestAst (Join-Path $root 'common\Common.Config.ps1')) -Name 'Test-PushClientRequested')
$queryDefinition = (Get-Command -Name Invoke-CmWmiQueryWithRetry -CommandType Function).Definition
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
$script:FailOnceClass = ''
$script:QueryAttempts = @{}
function Start-Sleep { param($Seconds) }
function Get-ItemProperty { param($Path, $Name, $ErrorAction); throw 'No fixture installation directory.' }
function Get-WmiObject {
    param($Namespace, $Class, $Filter, $ErrorAction)
    if (-not $script:QueryAttempts.ContainsKey($Class)) { $script:QueryAttempts[$Class] = 0 }
    $script:QueryAttempts[$Class]++
    if ($Class -eq $script:FailOnceClass) {
        $script:FailOnceClass = ''
        throw 'Generic failure'
    }
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
    & $guestValidator 'PRI' 'PRI,SEC' 'DP1,DP2,SEC1' ($RequiredNames -join ',') $queryDefinition
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
$script:QueryAttempts = @{}
$threw = $false
try { $null = Invoke-FixtureValidation }
catch {
    $threw = $_.Exception.Message -match 'Fixture query failure' -and
        $_.Exception.Message -match 'Namespace=root\\SMS\\site_PRI; Class=SMS_PackageStatusDistPointsSummarizer' -and
        $_.Exception.Message -match "Filter=\[PackageID='PRI00004'\]" -and
        $_.Exception.Message -match 'HResult=0x' -and $_.Exception.Message -match 'FQID='
}
Assert-True $threw 'An unreadable required summarizer was silently treated as empty or healthy.'
Assert-True ($script:QueryAttempts.SMS_PackageStatusDistPointsSummarizer -eq 3) 'Persistent client-package queries did not stop at three attempts.'
$script:FailClass = ''
$script:FailOnceClass = 'SMS_PackageStatusDistPointsSummarizer'
$recovered = Invoke-FixtureValidation
Assert-True ($recovered.Passed -and
    @($recovered.Details | Where-Object { $_ -like 'RECOVERED: Client package PRI00004 DP status query succeeded on attempt 2/3*' }).Count -eq 1) `
    'The observed generic provider failure did not recover within the package check.'

& {
    . (Import-TestFunction -Ast $ast -Name 'Get-ClientPackageContentProofBlock')
    $probe = Get-ClientPackageContentProofBlock
    $script:ProofFixture = 'Present'
    function Get-ItemProperty {
        param($LiteralPath, $Name, $ErrorAction)
        if ($script:ProofFixture -eq 'RegistryFailure') { throw 'Fixture DP registry unavailable.' }
        Assert-True ($LiteralPath -eq 'HKLM:\SOFTWARE\Microsoft\SMS\DP' -and $Name -eq 'ContentLibraryPath') 'Physical proof queried an unrelated registry location.'
        [pscustomobject]@{ ContentLibraryPath = 'C:\fixture\SCCMContentLib' }
    }
    function Test-Path {
        param($LiteralPath, $PathType, $ErrorAction)
        if ($script:ProofFixture -eq 'AccessDenied') { throw [UnauthorizedAccessException]::new('Fixture access denied.') }
        if ($PathType -eq 'Container') { return $script:ProofFixture -ne 'Unreachable' }
        Assert-True ($LiteralPath -eq 'C:\fixture\SCCMContentLib\PkgLib\PRI00004.INI' -and $PathType -eq 'Leaf') 'Physical proof used a guessed drive or wildcard package match.'
        return $script:ProofFixture -ne 'Missing'
    }
    foreach ($scenario in @('Present', 'Missing', 'AccessDenied', 'Unreachable', 'RegistryFailure')) {
        $script:ProofFixture = $scenario
        $proof = & $probe 'PRI00004'
        if ($scenario -in @('Present', 'Missing')) {
            Assert-True ($proof.Present -is [bool] -and $proof.Present -eq ($scenario -eq 'Present') -and -not $proof.Error) "$scenario did not preserve the measured physical state: $($proof | ConvertTo-Json -Compress)"
        }
        else {
            Assert-True ($null -eq $proof.Present -and $proof.Error) "$scenario was misreported as proven missing or present."
        }
    }
}

& {
    . (Import-TestFunction -Ast $ast -Name 'Get-ClientPackageContentProofBlock')
    . (Import-TestFunction -Ast $ast -Name 'Test-CMClientPackageDistribution')
    . (Import-TestFunction -Ast $ast -Name 'Test-SecondaryClientPackageDistribution')
    $script:HostMessages = [Collections.Generic.List[string]]::new()
    $script:PhysicalPresent = $false
    $script:PhysicalMalformed = $false
    $script:ProviderFailed = $false
    $script:SiteLogCaptures = 0
    $script:PhysicalTargets = @()
    $script:LastPayload = $null
    $hostPrimary = [pscustomobject]@{ vmName = 'PRI1'; role = 'Primary'; siteCode = 'PRI' }
    $hostSecondary = [pscustomobject]@{ vmName = 'SEC1'; role = 'Secondary'; siteCode = 'SEC'; parentSiteCode = 'PRI'; network = '10.20.2.0' }
    $hostClient = [pscustomobject]@{ vmName = 'CLIENT1'; role = 'DomainMember'; pushClient = $false; network = '10.20.2.0' }
    $hostConfig = [pscustomobject]@{
        vmOptions = [pscustomobject]@{ domainName = 'fixture.test' }
        virtualMachines = @($hostPrimary, $hostSecondary, $hostClient)
    }
    function Write-Log { param($Message, [switch]$LogOnly) }
    function Add-Phase11Output { param($Text, $Level); $script:HostMessages.Add($Text) }
    function Get-List { param($Type, $DomainName); return @($hostPrimary, $hostSecondary) }
    function Save-Phase11GuestLogs {
        param($VMName, $DomainName, $RoleLabel, $Collector, $TimeoutSeconds)
        $script:SiteLogCaptures++
    }
    function Format-TestResult {
        param($VMName, $RoleLabel, $Result)
        $script:LastPayload = $Result.ScriptBlockOutput
        return (-not $Result.ScriptBlockFailed -and $Result.ScriptBlockOutput.Passed)
    }
    function Invoke-VmCommand {
        param($VmName, $VmDomainName, $ScriptBlock, $ArgumentList, $DisplayName, [switch]$AsJob, $TimeoutSeconds, $SessionMaxRetries, [switch]$SuppressLog)
        if ($DisplayName -eq 'Phase11-ClientPkg-Test') {
            Assert-True ($VmName -eq 'PRI1' -and $ArgumentList[0] -eq 'PRI' -and $ArgumentList[1] -eq 'PRI,SEC') 'Secondary validation did not use its owning Primary and site scope.'
            Assert-True ($ArgumentList[4] -match 'Namespace' -and $ArgumentList[4] -match 'Get-WmiObject') 'The shared provider retry helper was not sent to the guest.'
            return [pscustomobject]@{
                ScriptBlockFailed = $script:ProviderFailed
                ScriptBlockOutput = @{
                    Passed = $true; Details = @('Fixture provider evidence.')
                    FailingDPs = @(); HealthyDPs = @(); ContentPendingFromParent = $false
                    ClientPackageId = 'PRI00004'; ClientPackageSourceVersion = '1'
                }
            }
        }
        Assert-True ($DisplayName -eq 'Phase11-ClientPkg-Physical' -and $VmName -eq 'SEC1' -and $TimeoutSeconds -eq 30 -and $SessionMaxRetries -eq 1 -and $AsJob) 'Secondary physical proof lost its exact target or deadline.'
        $script:PhysicalTargets += $VmName
        $present = if ($script:PhysicalMalformed) { 'True' } else { $script:PhysicalPresent }
        return [pscustomobject]@{
            ScriptBlockFailed = $false
            ScriptBlockOutput = [pscustomobject]@{
                PackageId = 'PRI00004'; ContentRoot = 'E:\SCCMContentLib'
                PackagePath = 'E:\SCCMContentLib\PkgLib\PRI00004.INI'; Present = $present
                CapturedAtUtc = '2026-10-28T12:00:00Z'; Error = ''
            }
        }
    }

    $optional = Test-SecondaryClientPackageDistribution -VMName SEC1 -CurrentItem $hostSecondary -DeployConfig $hostConfig
    Assert-True (@($optional).Count -eq 1 -and $optional -is [bool] -and $optional -and
        $script:PhysicalTargets.Count -eq 1 -and $script:SiteLogCaptures -gt 0 -and
        $script:LastPayload.Details -contains 'Fixture provider evidence.' -and
        @($script:LastPayload.Details | Where-Object { $_ -like "WARN: DP 'SEC1' physical client-package content is unverified*" }).Count -eq 1) `
        'An optional Secondary was failed or its missing physical content disappeared behind a successful provider result.'
    $hostClient.pushClient = 'SEC'
    $required = Test-SecondaryClientPackageDistribution -VMName SEC1 -CurrentItem $hostSecondary -DeployConfig $hostConfig
    Assert-True (-not $required) 'A Secondary needed by assigned clients passed without physical client-package content.'
    $script:PhysicalPresent = $true
    Assert-True (Test-SecondaryClientPackageDistribution -VMName SEC1 -CurrentItem $hostSecondary -DeployConfig $hostConfig) 'Measured physical content did not pass required coverage.'
    $script:PhysicalMalformed = $true
    Assert-True (-not (Test-SecondaryClientPackageDistribution -VMName SEC1 -CurrentItem $hostSecondary -DeployConfig $hostConfig)) 'A string-valued physical proof bypassed required coverage.'
    $script:PhysicalMalformed = $false
    $script:ProviderFailed = $true
    $before = $script:SiteLogCaptures
    Assert-True (-not (Test-SecondaryClientPackageDistribution -VMName SEC1 -CurrentItem $hostSecondary -DeployConfig $hostConfig)) 'A failed provider job was reported as successful validation.'
    Assert-True ($script:SiteLogCaptures -gt $before) 'Provider job failure did not collect site-side diagnostics.'
    $script:ProviderFailed = $false
    $hostConfig.virtualMachines = @($hostSecondary, $hostClient)
    Assert-True (Test-SecondaryClientPackageDistribution -VMName SEC1 -CurrentItem $hostSecondary -DeployConfig $hostConfig) 'An expansion omitting the unchanged parent could not resolve it from domain metadata.'
    $hostSecondary.parentSiteCode = ''
    Assert-True (-not (Test-SecondaryClientPackageDistribution -VMName SEC1 -CurrentItem $hostSecondary -DeployConfig $hostConfig)) 'An unresolved Secondary parent silently skipped package validation.'
}

Write-Host 'PASS -- Phase 11 retries provider failures, verifies Secondary physical content, and preserves required/optional and site ownership rules.'
