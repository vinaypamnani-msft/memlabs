#requires -Version 5.1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'DomainFullName', Justification = 'Consumed by shipped source-extracted workflow blocks.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'bgs', Justification = 'Consumed by shipped source-extracted workflow blocks.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'SiteCode', Justification = 'Consumed by shipped source-extracted workflow blocks.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'ThisVM', Justification = 'Consumed by shipped source-extracted workflow blocks.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'deployConfig', Justification = 'Consumed by shipped source-extracted workflow blocks.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'LogPath', Justification = 'Consumed by shipped source-extracted workflow blocks.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'pushClients', Justification = 'Consumed by shipped source-extracted workflow blocks.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'clearStuckDistmgrWedge', Justification = 'Consumed by shipped source-extracted workflow blocks.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'bgsitecode', Justification = 'Consumed by shipped source-extracted workflow blocks.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'ns', Justification = 'Consumed by shipped source-extracted workflow blocks.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'PackageID', Justification = 'Consumed by shipped source-extracted workflow blocks.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'parentSite', Justification = 'Consumed by shipped source-extracted workflow blocks.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'parentFqdn', Justification = 'Consumed by shipped source-extracted workflow blocks.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'cloudDpHosts', Justification = 'Consumed by shipped source-extracted workflow blocks.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'pkgSourceBumped', Justification = 'Consumed by shipped source-extracted workflow blocks.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'restartExecOnce', Justification = 'Consumed by shipped source-extracted workflow blocks.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'isPkgStrandedToSite', Justification = 'Consumed by shipped source-extracted workflow blocks.')]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$path = Join-Path $root 'DSC\phases\InstallBoundaryGroups.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "Boundary workflow parse errors: $($errors -join '; ')" }
$script:Assertions = 0
function Assert-True {
    param([bool]$Condition, [string]$Message)
    $script:Assertions++
    if (-not $Condition) { throw $Message }
}
& {
    $templatePath = Join-Path $root 'DSC\TemplateHelpDSC\TemplateHelpDSC.psm1'
    $templateAst = [Management.Automation.Language.Parser]::ParseFile($templatePath, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "Template helper parse errors: $($errors -join '; ')" }
    $definition = $templateAst.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-InstalledProducts'
        }, $true)
    if (-not $definition) { throw 'Installed-product inventory helper was not found.' }
    . ([scriptblock]::Create($definition.Extent.Text))
    $class = $templateAst.Find({
            param($node)
            $node -is [Management.Automation.Language.TypeDefinitionAst] -and $node.Name -eq 'InstallReportBuilder'
        }, $true)
    $method = $class.Members | Where-Object Name -EQ Test
    $text = $method.Extent.Text
    $bodyStart = $text.IndexOf('{') + 1
    $readiness = [scriptblock]::Create($text.Substring($bodyStart, $text.LastIndexOf('}') - $bodyStart))
    $script:MsiStatuses = [Collections.Generic.List[string]]::new()
    function Write-Status { param($Message); $script:MsiStatuses.Add("$Message") }
    function New-MsiFixtureProduct {
        param([string]$Name, [string]$State)
        $product = [pscustomobject]@{
            Name = $Name; State = $State; Reads = [Collections.Generic.List[string]]::new()
        }
        $product | Add-Member ScriptMethod ProductCode { return '{00000000-0000-0000-0000-000000000001}' }
        $product | Add-Member ScriptMethod InstallProperty {
            param($Property)
            $this.Reads.Add("$Property")
            if ($Property -eq 'State') { return $this.State }
            if ($this.State -ne '5') { throw [Runtime.InteropServices.COMException]::new('InstallProperty') }
            switch ($Property) {
                LocalPackage { return 'C:\Windows\Installer\fixture.msi' }
                VersionString { return '15.0.1' }
                ProductName { return $this.Name }
                default { throw "Unexpected MSI property '$Property'." }
            }
        }
        return $product
    }
    $installer = [pscustomobject]@{}
    $installer | Add-Member ScriptMethod ProductsEx {
        param($ProductCode, $UserSid, $Context)
        return $script:MsiProducts
    }
    function New-Object {
        param($ComObject)
        if ($ComObject -ne 'WindowsInstaller.Installer') { throw "Unexpected COM object '$ComObject'." }
        return $installer
    }
    $advertised = New-MsiFixtureProduct -Name 'Advertised application' -State '1'
    $installed = New-MsiFixtureProduct -Name 'Microsoft Report Builder' -State '5'
    $script:MsiProducts = @($advertised, $installed)
    $products = @(Get-InstalledProducts)
    Assert-True ($products.Count -eq 1 -and $products[0].ProductName -eq $installed.Name -and
        $products[0].VersionString -eq '15.0.1') 'Advertised MSI registration prevented installed Report Builder detection.'
    Assert-True ($advertised.Reads.Count -eq 1 -and $advertised.Reads[0] -eq 'State') `
        'Advertised MSI registration was queried for unavailable installed-only properties.'
    Assert-True (& $readiness) 'The shipped Report Builder readiness probe did not recognize the installed product.'
    Assert-True (@($script:MsiStatuses | Where-Object { $_ -like '*Ready=True' }).Count -eq 1) `
        'Installed Report Builder did not produce its readiness evidence.'
    $script:MsiProducts = @((New-MsiFixtureProduct -Name 'Microsoft Report Builder' -State '1'))
    Assert-True (-not (& $readiness)) 'Advertised-only Report Builder was treated as installed.'
    $script:MsiProducts = @((New-MsiFixtureProduct -Name 'Unrelated installed application' -State '5'))
    Assert-True (-not (& $readiness)) 'An unrelated installed MSI was treated as Report Builder.'
}
& {
    $source = $ast.Extent.Text
    $match = [regex]::Match($source, '(?s)# Create Boundaries for each subnet and add to BG(?<Body>.*?)# Setup System Discovery')
    if (-not $match.Success) { throw 'Boundary reconciliation block was not found.' }
    $reconcile = [scriptblock]::Create($match.Groups['Body'].Value)
    $quickIf = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.IfStatementAst] -and
            $node.Clauses[0].Item1.Extent.Text -eq '$allBGsExist' -and
            $node.Extent.Text.Contains('$IPBits')
        }, $true)
    if (-not $quickIf) { throw 'Boundary membership fast-path check was not found.' }
    $verifyMembership = [scriptblock]::Create($quickIf.Extent.Text)
    $DomainFullName = 'fixture.test'
    $bgs = @([pscustomobject]@{ SiteCode = 'PRI'; Subnet = '10.10.42.0' })
    $script:BoundaryCandidates = @(
        [pscustomobject]@{ BoundaryID = 0; DisplayName = '10.10.42.0' },
        [pscustomobject]@{ BoundaryID = 12; DisplayName = '10.10.42.0' }
    )
    $script:BoundaryMembers = [Collections.Generic.List[object]]::new()
    $script:BoundaryWrites = [Collections.Generic.List[int]]::new()
    $script:BoundaryFailures = [Collections.Generic.List[string]]::new()
    $script:BoundaryWriteFails = $false
    function Get-CMBoundary {
        param($BoundaryName, $BoundaryGroupName, $ErrorAction)
        if ($BoundaryGroupName) { return $script:BoundaryMembers.ToArray() }
        if (-not $BoundaryName -or $BoundaryName -eq '10.10.42.0') { return $script:BoundaryCandidates }
    }
    function Add-CMBoundaryToGroup {
        [CmdletBinding()]
        param([int]$BoundaryId, [string]$BoundaryGroupName)
        if ($script:BoundaryWriteFails) { throw 'Fixture membership provider failure.' }
        $script:BoundaryWrites.Add($BoundaryId)
        $script:BoundaryMembers.Add(($script:BoundaryCandidates | Where-Object BoundaryID -EQ $BoundaryId))
    }
    function New-CMBoundary {
        param($Type, $Name, $Value, $ErrorAction)
        $script:BoundaryCandidates = @([pscustomobject]@{ BoundaryID = 13; DisplayName = $Name })
        return $script:BoundaryCandidates
    }
    function Write-DscStatus {
        param($Message, [switch]$Failure)
        if ($Failure) { $script:BoundaryFailures.Add("$Message") }
    }
    function Start-Sleep { param($Seconds) }
    & $reconcile
    Assert-True (($script:BoundaryWrites -join ',') -eq '0,12' -and $script:BoundaryFailures.Count -eq 0) `
        'Duplicate boundary names did not reconcile individually by ID, including ID zero.'
    $script:BoundaryWrites.Clear()
    & $reconcile
    Assert-True ($script:BoundaryWrites.Count -eq 0) 'Existing duplicate-boundary memberships caused redundant writes.'
    $allBGsExist = $true
    . $verifyMembership
    Assert-True $allBGsExist 'Complete duplicate-boundary membership failed the quick check.'
    $script:BoundaryMembers.Clear()
    $script:BoundaryMembers.Add($script:BoundaryCandidates[0])
    $allBGsExist = $true
    . $verifyMembership
    Assert-True (-not $allBGsExist) 'A shared display name concealed a missing boundary ID in the quick check.'
    & $reconcile
    Assert-True (($script:BoundaryWrites -join ',') -eq '12') 'A shared display name concealed a missing boundary ID during reconciliation.'
    $script:BoundaryMembers.Clear()
    $script:BoundaryWrites.Clear()
    $script:BoundaryCandidates = @()
    & $reconcile
    Assert-True (($script:BoundaryWrites -join ',') -eq '13') 'New boundaries were not attached by their returned ID.'
    $script:BoundaryMembers.Clear()
    $script:BoundaryWrites.Clear()
    $script:BoundaryWriteFails = $true
    & $reconcile
    Assert-True ($script:BoundaryFailures.Count -eq 1) 'A genuine boundary provider write failure was hidden.'
}

foreach ($name in @('Test-MemLabsCloudDistributionPoint', 'Get-MemLabsDpVmMetadataMap', 'Test-MemLabsLocalComputerName')) {
    $definition = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
        }, $true)
    if (-not $definition) { throw "Required helper '$name' was not found." }
    . ([scriptblock]::Create($definition.Extent.Text))
}

foreach ($value in @(1, 2)) {
    Assert-True (Test-MemLabsCloudDistributionPoint -DistributionPoint ([pscustomobject]@{
                Props = @([pscustomobject]@{ PropertyName = 'IsCloud'; Value = $value })
            })) "Nonzero native IsCloud marker '$value' was not skipped."
}
Assert-True (Test-MemLabsCloudDistributionPoint -DistributionPoint ([pscustomobject]@{ ServiceType = 1 })) `
    'DPInfo ServiceType=1 was not identified as cloud.'
foreach ($props in @(
        [pscustomobject]@{ Props = @([pscustomobject]@{ PropertyName = 'IsCloud'; Value = 0 }) },
        [pscustomobject]@{ Props = @([pscustomobject]@{ PropertyName = 'IsPullDP'; Value = 1 }) },
        [pscustomobject]@{ ServiceType = 0; InternetFacing = $true; Communication = 1; IsPullDP = $true }
    )) {
    Assert-True (-not (Test-MemLabsCloudDistributionPoint -DistributionPoint $props)) `
        'An on-premises, HTTPS/Internet-enabled, or pull DP was misclassified as cloud.'
}
foreach ($invalid in @(
        [pscustomobject]@{ ServiceType = $null },
        [pscustomobject]@{ NetworkOSPath = '\\unclassified.fixture.test' },
        [pscustomobject]@{ Props = @([pscustomobject]@{ PropertyName = 'IsCloud'; Value = 'unknown' }) }
    )) {
    $failed = $false
    try { $null = Test-MemLabsCloudDistributionPoint -DistributionPoint $invalid }
    catch { $failed = $_.Exception.Message -like '*refusing to manage*' }
    Assert-True $failed 'Unclassified distribution-point metadata silently became on-premises.'
}

$coreAssignment = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left.Extent.Text -eq '$ensureClientPkgCoverageCore'
    }, $true)
if (-not $coreAssignment) { throw 'The real coverage scriptblock was not found.' }
$factory = [scriptblock]::Create($coreAssignment.Extent.Text + "`nreturn `$ensureClientPkgCoverageCore")
$coverage = & $factory
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "memlabs-cmg-isolation-$([guid]::NewGuid().ToString('N'))"
$null = New-Item -ItemType Directory -Path $testRoot
try {
    $scenarios = @('Mixed', 'CloudOnly', 'OnPremProviderFailure', 'RefreshOnPrem', 'DistributeOnPrem' |
        ForEach-Object { [pscustomobject]@{ Mode = $_; Info = 'Healthy'; System = 'Healthy'; CloudFirst = $true; LinkCloud = $true } })
    foreach ($info in @('Healthy', 'Throw', 'Empty')) {
        foreach ($system in @('Healthy', 'Throw', 'Empty')) {
            foreach ($cloudFirst in @($true, $false)) {
                foreach ($linkCloud in @($true, $false)) {
                    $scenarios += [pscustomobject]@{
                        Mode = 'Discovery'; Info = $info; System = $system
                        CloudFirst = $cloudFirst; LinkCloud = $linkCloud
                    }
                }
            }
        }
    }
    foreach ($scenario in $scenarios) {
        & {
            param($Scenario, $Coverage, $LogDirectory)
            $Mode = $Scenario.Mode
            $SiteCode = 'PRI'
            $bgs = @([pscustomobject]@{ SiteCode = 'PRI' })
            $ThisVM = [pscustomobject]@{ vmName = 'PRI1'; role = 'Primary' }
            $deployConfig = [pscustomobject]@{ virtualMachines = @() }
            $LogPath = $LogDirectory
            $pushClients = $false
            $clearStuckDistmgrWedge = { return $false }
            $script:MemLabsCoverageProgressState = @{ Id = 'fixture' }
            $script:CmgMode = $Mode
            $script:CmgStatuses = [Collections.Generic.List[object]]::new()
            $script:CmgRequired = @()
            $script:CmgOutcome = ''
            $script:CmgPackageReads = 0
            $script:CmgProviderReads = 0
            $script:CmgScenario = $Scenario
            $script:CmgInstalled = $Mode -notin @('RefreshOnPrem', 'DistributeOnPrem')
            $script:CmgTargetExists = $Mode -ne 'DistributeOnPrem'
            $script:CmgRefreshes = [Collections.Generic.List[string]]::new()
            $script:CmgDistributions = [Collections.Generic.List[string]]::new()
            $script:CmgSleeps = 0
            $cloud = [pscustomobject]@{
                NetworkOSPath = '\\DP1.cloud.fixture.test'
                Props = @([pscustomobject]@{ PropertyName = 'IsCloud'; Value = 1 })
            }
            $onPrem = [pscustomobject]@{
                NetworkOSPath = '\\DP1.fixture.test'
                Props = @([pscustomobject]@{ PropertyName = 'IsCloud'; Value = 0 })
            }
            $script:CmgRoles = @($cloud)
            if ($Mode -ne 'CloudOnly') {
                $script:CmgRoles = if ($Scenario.CloudFirst) { @($cloud, $onPrem) } else { @($onPrem, $cloud) }
            }
            $target = [pscustomobject]@{ ServerNALPath = '\\DP1.fixture.test\'; RefreshNow = $false }
            $target | Add-Member ScriptMethod Put {
                $script:CmgRefreshes.Add('DP1.fixture.test')
                $script:CmgInstalled = $true
            }
            $script:CmgTarget = $target
            function Get-CMDistributionPoint {
                param([switch]$AllSite, $ErrorAction)
                Assert-True $AllSite.IsPresent 'CMG safety inventory did not include the entire hierarchy.'
                return $script:CmgRoles
            }
            function Get-CMPackage {
                param([switch]$Fast, $Name)
                $script:CmgPackageReads++
                if ($script:CmgMode -eq 'CloudOnly') { throw 'CMG-only coverage must not query packages.' }
                return [pscustomobject]@{ PackageID = 'PRI00003' }
            }
            function Get-WmiObject {
                param($Namespace, $Class, $Filter, $ErrorAction)
                switch ($Class) {
                    SMS_BoundaryGroup { return [pscustomobject]@{ GroupID = 1; Name = 'PRI' } }
                    SMS_BoundaryGroupSiteSystems {
                        foreach ($role in $script:CmgRoles) {
                            if (-not $script:CmgScenario.LinkCloud -and
                                (Test-MemLabsCloudDistributionPoint -DistributionPoint $role)) { continue }
                            [pscustomobject]@{ GroupID = 1; ServerNALPath = "$($role.NetworkOSPath)\" }
                        }
                    }
                    SMS_DistributionPointInfo {
                        if ($script:CmgScenario.Info -eq 'Throw') { throw 'Fixture DPInfo query is unavailable.' }
                        if ($script:CmgScenario.Info -eq 'Empty') { return }
                        foreach ($role in $script:CmgRoles) {
                            [pscustomobject]@{
                                NALPath = "$($role.NetworkOSPath)\"
                                ServiceType = [int](Test-MemLabsCloudDistributionPoint -DistributionPoint $role)
                            }
                        }
                    }
                    SMS_SystemResourceList {
                        if ($script:CmgScenario.System -eq 'Throw') { throw 'Fixture system-resource query is unavailable.' }
                        if ($script:CmgScenario.System -eq 'Empty') { return }
                        foreach ($role in $script:CmgRoles) { [pscustomobject]@{ NALPath = "$($role.NetworkOSPath)\" } }
                    }
                    SMS_DistributionPoint {
                        if ($script:CmgTargetExists) { return $script:CmgTarget }
                    }
                    default { throw "Unexpected provider query '$Class'." }
                }
            }
            function Get-MemLabsProjectedCimRows {
                param($Namespace, $ClassName, $Filter, $Property)
                $script:CmgProviderReads++
                if ($script:CmgMode -eq 'OnPremProviderFailure') { throw 'Fixture on-premises provider failure.' }
                switch ($ClassName) {
                    SMS_Package { return [pscustomobject]@{ StoredPkgVersion = 17; SourceVersion = 17 } }
                    SMS_PackageStatusDistPointsSummarizer {
                        $state = if ($script:CmgInstalled) { 0 } else { 2 }
                        [pscustomobject]@{ ServerNALPath = '\\DP1.fixture.test\'; State = $state; SourceVersion = 17 }
                        [pscustomobject]@{ ServerNALPath = '\\DP1.cloud.fixture.test\'; State = 2; SourceVersion = 17 }
                    }
                    SMS_DistributionPoint {
                        if ($script:CmgTargetExists) { return $script:CmgTarget }
                    }
                    default { throw "Unexpected coverage mutation or query '$ClassName'." }
                }
            }
            function Set-MemLabsClientPackageProgress {
                param($Stage, $DeadlineUtc, $Message, $Outcome, $PackageId, $RequiredDistributionPoints)
                if ($PSBoundParameters.ContainsKey('RequiredDistributionPoints')) { $script:CmgRequired = @($RequiredDistributionPoints) }
                if ($Outcome) { $script:CmgOutcome = $Outcome }
            }
            function Write-DscStatus {
                param($Status, [switch]$Warning, [switch]$Failure, [switch]$NoStatus)
                $script:CmgStatuses.Add([pscustomobject]@{ Text = "$Status"; Failure = [bool]$Failure })
            }
            function Write-MemLabsClientPackageTimelineRecord { param($Path, $Record) }
            function Invoke-MemLabsClientPackageDiagnosticProbe {
                param($ProbeScript, $Variables, $Parameters, $TimeoutSeconds)
                return [pscustomobject]@{
                    Error = ''
                    Output = [pscustomobject]@{ SchemaVersion = 2; PackageId = $Variables.PackageID; Trigger = $Parameters.Trigger }
                }
            }
            function Start-Sleep {
                param($Seconds)
                $script:CmgSleeps++
                if (-not $script:CmgInstalled -or $script:CmgSleeps -gt 3) {
                    $recent = @($script:CmgStatuses | Select-Object -Last 4 | ForEach-Object Text) -join '; '
                    throw "Coverage fixture '$script:CmgMode' waited without convergence (installed=$script:CmgInstalled, sleeps=$script:CmgSleeps). $recent"
                }
            }
            function Start-CMContentDistribution {
                param($PackageId, $DistributionPointName, $ErrorAction)
                if ($DistributionPointName -ine 'DP1.fixture.test') { throw "Distribution touched cloud/unrelated target '$DistributionPointName'." }
                $script:CmgDistributions.Add("$DistributionPointName")
                $script:CmgTargetExists = $true
                $script:CmgInstalled = $true
            }
            $null = & $Coverage
            $failures = @($script:CmgStatuses | Where-Object Failure)
            if ($Mode -eq 'CloudOnly') {
                Assert-True ($script:CmgOutcome -eq 'NotRequired' -and $script:CmgPackageReads -eq 0 -and
                    $script:CmgProviderReads -eq 0 -and $failures.Count -eq 0) 'CMG-only coverage queried content, waited, or failed instead of skipping.'
            }
            elseif ($Mode -ne 'OnPremProviderFailure') {
                Assert-True ($script:CmgOutcome -eq 'Covered' -and $script:CmgRequired.Count -eq 1 -and
                    $script:CmgRequired[0] -ieq 'DP1.fixture.test' -and $script:CmgProviderReads -gt 0 -and
                    $failures.Count -eq 0) 'The failed CMG delayed or failed otherwise healthy on-premises coverage.'
                if ($Mode -eq 'RefreshOnPrem') {
                    Assert-True (($script:CmgRefreshes -join ',') -eq 'DP1.fixture.test') 'Actual RefreshNow recovery did not touch only the retrying on-premises DP.'
                }
                if ($Mode -eq 'DistributeOnPrem') {
                    Assert-True (($script:CmgDistributions -join ',') -eq 'DP1.fixture.test') 'Actual missing-target distribution did not touch only the on-premises DP.'
                }
            }
            else {
                Assert-True ($failures.Count -eq 1 -and $failures[0].Text -like '*Fixture on-premises provider failure*' -and
                    $script:CmgOutcome -ne 'Covered') 'CMG exclusion hid a genuine on-premises provider failure.'
            }
            Assert-True (@($script:CmgStatuses | Where-Object { $_.Text -like '*skipping CMG/cloud DP*' }).Count -eq 1) `
                'CMG exclusion did not emit an explicit skip diagnostic.'
            Assert-True (@($script:CmgStatuses | Where-Object { $_.Text -like "*snapshot*failed:*" }).Count -eq 0) `
                'The coverage fixture failed to supply a valid native diagnostic snapshot.'
        } $scenario $coverage $testRoot
    }

    & {
        $bumpAssignment = $coreAssignment.Find({
                param($node)
                $node -is [Management.Automation.Language.AssignmentStatementAst] -and
                $node.Left.Extent.Text -eq '$bumpPkgSourceVersion'
            }, $true)
        $repairIf = $coreAssignment.Find({
                param($node)
                $node -is [Management.Automation.Language.IfStatementAst] -and
                $node.Clauses[0].Item1.Extent.Text.Contains('$pkgSourceBumped') -and
                $node.Extent.Text.Contains('if (& $restartExecOnce)')
            }, $true)
        if (-not $bumpAssignment -or -not $repairIf) { throw 'Package-wide source-recovery blocks were not found.' }
        $factory = [scriptblock]::Create($bumpAssignment.Extent.Text + "`nreturn `$bumpPkgSourceVersion")
        $bump = & $factory
        $repair = [scriptblock]::Create($repairIf.Extent.Text)
        $SiteCode = 'PRI'
        $ns = 'root\SMS\site_PRI'
        $PackageID = 'PRI00003'
        $parentSite = 'CAS'
        $parentFqdn = 'CAS1.fixture.test'
        $script:SourceRefreshes = 0
        $script:RemoteSourceRefreshes = 0
        function Write-DscStatus { param($Status, [switch]$Warning) }
        function Get-WmiObject {
            param($Namespace, $Class, $Filter, $ErrorAction)
            $package = [pscustomobject]@{ SourceSite = $script:PackageOwner }
            $package | Add-Member ScriptMethod RefreshPkgSource {
                $script:SourceRefreshes++
                return [pscustomobject]@{ ReturnValue = 0 }
            }
            return $package
        }
        function Invoke-Command {
            param($ComputerName, $ScriptBlock, $ArgumentList, $ErrorAction)
            $script:RemoteSourceRefreshes++
            return (& $ScriptBlock @ArgumentList)
        }
        foreach ($owner in @('PRI', 'CAS')) {
            $script:PackageOwner = $owner
            $cloudDpHosts = @{ 'DP1.cloud.fixture.test' = $true }
            $before = $script:SourceRefreshes
            $beforeRemote = $script:RemoteSourceRefreshes
            Assert-True (-not (& $bump 'SEC') -and $script:SourceRefreshes -eq $before -and
                $script:RemoteSourceRefreshes -eq $beforeRemote) 'Package-wide source recovery could refresh cloud targets at the local or parent owner.'
            $pkgSourceBumped = $false
            $restartExecOnce = { throw 'CMG-safe recovery must not restart the site service before a forbidden package bump.' }
            $isPkgStrandedToSite = { return $true }
            & $repair
            $cloudDpHosts = @{}
            Assert-True ((& $bump 'SEC') -and $script:SourceRefreshes -eq ($before + 1)) `
                'CMG isolation disabled source recovery for an on-premises-only hierarchy.'
        }
    }

    $writers = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.AssignmentStatementAst] -and
                $node.Left.Extent.Text -in @('$parentDps', '$sitesystems') -and
                $node.Right.Extent.Text.Contains('Get-CMDistributionPoint')
            }, $true))
    Assert-True ($writers.Count -eq 3) 'Not all boundary-group DP candidate writers were found.'
    function Get-CMDistributionPoint { param($SiteCode, $ErrorAction); return $script:CmgRoles }
    $SiteCode = 'PRI'
    $bgsitecode = 'PRI'
    foreach ($writer in $writers) {
        $sitesystems = @()
        $parentDps = @()
        . ([scriptblock]::Create($writer.Extent.Text))
        $candidates = @($sitesystems) + @($parentDps)
        Assert-True ($candidates.Count -eq 1 -and $candidates[0] -ieq 'DP1.fixture.test') `
            'Boundary-group writes still include a CMG endpoint.'
    }
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction Stop
}
Write-Host "PASS -- $script:Assertions Phase 8 rerun-resilience assertions on PowerShell $($PSVersionTable.PSVersion)."
