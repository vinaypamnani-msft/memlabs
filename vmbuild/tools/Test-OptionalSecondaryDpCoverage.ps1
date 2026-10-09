<#
.SYNOPSIS
    Verifies optional Secondary DP coverage exits and implicit role validation.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$coveragePath = Join-Path $root 'DSC\phases\InstallBoundaryGroups.ps1'
$validationPath = Join-Path $root 'common\Common.Validation.Functional.ps1'
$functionsPath = Join-Path $root 'DSC\phases\ScriptFunctions.ps1'

foreach ($path in @($coveragePath, $validationPath)) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw "$path has $($errors.Count) parse error(s): $($errors -join '; ')" }
}

$coverageText = Get-Content -LiteralPath $coveragePath -Raw
$validationText = Get-Content -LiteralPath $validationPath -Raw

function Import-TestFunction {
    param([string] $Path, [string] $Name)

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw "$Path has parse errors: $($errors -join '; ')" }
    $functions = @($ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $Name
            }, $true))
    if ($functions.Count -ne 1) {
        throw "Expected one $Name definition, found $($functions.Count)."
    }
    return [scriptblock]::Create($functions[0].Extent.Text)
}

. (Import-TestFunction -Path $coveragePath -Name 'Get-MemLabsDpVmMetadataMap')
. (Import-TestFunction -Path $coveragePath -Name 'Test-MemLabsLocalComputerName')
. (Import-TestFunction -Path $functionsPath -Name 'Get-MemLabsProjectedCimRows')

if (-not ('MemLabsDisposableCimFixture' -as [type])) {
    Add-Type -TypeDefinition @'
using System;

public sealed class MemLabsDisposableCimFixture : IDisposable
{
    public string Name { get; set; }
    public string GroupID { get; set; }
    public string SourceSite { get; set; }
    public bool Disposed { get; private set; }
    public void Dispose() { Disposed = true; }
}
'@
}

$script:CimProjectionAttempts = 0
$script:CimProjectionRow = [MemLabsDisposableCimFixture]::new()
$script:CimProjectionRow.Name = 'ALL DPS'
$script:CimProjectionRow.GroupID = 'GROUP-1'
$script:CimProjectionRow.SourceSite = 'PRI'
function Get-CimInstance {
    param(
        [string] $Namespace,
        [string] $ClassName,
        [string] $Filter,
        [string[]] $Property,
        [int] $OperationTimeoutSec,
        $ErrorAction
    )
    $script:CimProjectionAttempts++
    if ($script:CimProjectionAttempts -eq 1) {
        throw [System.OutOfMemoryException]::new('synthetic provider exhaustion')
    }
    return $script:CimProjectionRow
}
function Start-Sleep { param([int] $Seconds) }
function Write-DscStatus {
    param($Status, [switch] $Warning)
}

$projectedRows = @(Get-MemLabsProjectedCimRows -Namespace 'root\SMS\site_PRI' `
        -ClassName SMS_DistributionPointGroup -Filter "Name='ALL DPS'" `
        -Property @('Name', 'GroupID', 'SourceSite') -Attempts 2 -RetrySeconds 0)
if ($script:CimProjectionAttempts -ne 2 -or $projectedRows.Count -ne 1 -or
    $projectedRows[0].GroupID -ne 'GROUP-1') {
    throw 'Projected CIM helper did not recover the synthetic out-of-memory read.'
}
if (-not $script:CimProjectionRow.Disposed -or
    $projectedRows[0] -is [MemLabsDisposableCimFixture]) {
    throw 'Projected CIM helper retained the disposable provider object.'
}

$metadataConfig = [pscustomobject]@{
    virtualMachines = @(
        [pscustomobject]@{
            vmName = 'PRI1'; role = 'Primary'; siteCode = 'PRI'
        }
    )
    phase8ManagedDistributionPointScopes = @(
        [pscustomobject]@{
            DistributionPoints = @(
                [pscustomobject]@{
                    VmName = 'SEC1'; Fqdn = 'SEC1.lab.test'; Role = 'Secondary'
                    SiteCode = 'SEC'; Network = '10.20.2.0'
                }
            )
        }
    )
}
$metadata = Get-MemLabsDpVmMetadataMap -DeployConfig $metadataConfig
if (-not $metadata.ContainsKey('SEC1') -or
    $metadata['SEC1'].role -ne 'Secondary' -or
    $metadata['SEC1'].siteCode -ne 'SEC' -or
    $metadata['SEC1'].network -ne '10.20.2.0') {
    throw 'Projected Phase 8 DP metadata did not restore an omitted Secondary identity.'
}
if (-not (Test-MemLabsLocalComputerName -Candidate 'PRI1.lab.test' `
        -LocalComputerName 'PRI1')) {
    throw 'FQDN self-probe was not recognized as local.'
}
if (Test-MemLabsLocalComputerName -Candidate 'PRI2.lab.test' `
        -LocalComputerName 'PRI1') {
    throw 'A different host was misclassified as the local source node.'
}

if ($coverageText -notmatch '\$coverageExitReason\s*=\s*''OptionalGrace''') {
    throw 'Optional grace does not record a distinct exit reason.'
}
if ($coverageText -match "moving on after the.*grace[\s\S]{0,300}-Warning") {
    throw 'The intentional optional-grace exit still emits an unconditional warning.'
}
if ($coverageText -notmatch '(?s)\$physicalContent\s*=\s*&\s*\$dpHasPackageContent.+?\$versionMatches.+?\$physicalContent\s+-eq\s+\$true\s+-and\s+\$versionMatches.+?\$optionalStatusLag\.Add') {
    throw 'Optional summarizer lag is not gated on physical PkgLib content at the matching source version.'
}
if ($coverageText -notmatch 'optional grace ended, but final verification could not prove current physical content plus matching DP source version') {
    throw 'Optional content that is absent or unmeasurable no longer captures diagnostics.'
}
if ($coverageText -notmatch "'optional-grace-complete'") {
    throw 'The timeline does not distinguish optional grace from a wall-clock deadline.'
}
if ($coverageText -notmatch
    '(?s)ContentValidating but physically holds.+?Leaving RefreshNow untouched.+?continue') {
    throw 'Current physical content can still be reset repeatedly while the summarizer validates it.'
}
$coverageLoop = [regex]::Match(
    $coverageText,
    '(?s)\$coverageStart\s*=\s*Get-Date.+?# Final state \+ rich DP-side diagnostics')
if (-not $coverageLoop.Success) {
    throw 'Client package coverage polling loop was not found.'
}
foreach ($className in @(
        'SMS_Package',
        'SMS_PackageStatusDistPointsSummarizer',
        'SMS_DistributionPoint'
    )) {
    if ($coverageLoop.Value -match
        "Get-WmiObject[^\r\n]+-Class\s+$className") {
        throw "Client package polling still retains full WMI objects for $className."
    }
}
if ($coverageLoop.Value -notmatch 'Client pkg coverage memory checkpoint' -or
    $coverageLoop.Value -notmatch 'Get-MemLabsProjectedCimRows') {
    throw 'Client package polling lost projected CIM reads or periodic memory telemetry.'
}
$projectedCalls = [regex]::Matches(
    $coverageText,
    '(?s)-ClassName\s+(SMS_DistributionPoint|SMS_PackageStatusDistPointsSummarizer)\b(?:(?!-ClassName).){0,300}?-Property\s+@\(([^)]*)\)')
if ($projectedCalls.Count -lt 6) {
    throw "Expected at least six projected client-package provider calls; found $($projectedCalls.Count)."
}
foreach ($call in $projectedCalls) {
    $className = $call.Groups[1].Value
    $properties = @([regex]::Matches($call.Groups[2].Value, "'([^']+)'") |
        ForEach-Object { $_.Groups[1].Value })
    $allowed = if ($className -eq 'SMS_DistributionPoint') {
        @('ServerNALPath', 'SiteCode', 'SourceVersion', 'RefreshNow')
    }
    else {
        @('ServerNALPath', 'State', 'SourceVersion')
    }
    $unsupported = @($properties | Where-Object { $_ -notin $allowed })
    if ($unsupported.Count -gt 0) {
        throw "$className projection requests unsupported properties: $($unsupported -join ', ')."
    }
}
if ($coverageText -notmatch 'SchemaVersion\s*=\s*2') {
    throw 'Client package timeline schema was not advanced for the corrected provider projection.'
}
if ($coverageText -match '&\s+\$writeCoverageSnapshot\s+[''"]' -or
    $coverageText -match '&\s+\$writeCoverageSnapshot\s+\$') {
    throw 'Client package timeline still uses positional scriptblock arguments that collapse when an array is empty.'
}
if ($coverageText -notmatch
    '(?s)-Trigger\s+''content-installed''.+?-IncludeNodeState\s+\$false' -or
    $coverageText -notmatch
    '(?s)-Trigger\s+\$finalSnapshotTrigger.+?-IncludeNodeState:\(\$stillBad\.Count -gt 0\)') {
    throw 'Successful client package convergence still launches duplicate heavy node snapshots.'
}
if ($coverageText -notmatch
    '\$lastCoverageNodeCapture.+?TotalMinutes -ge 20' -or
    $coverageText -notmatch '\[IO\.Directory\]::EnumerateFiles') {
    throw 'Client package diagnostics lost their low-frequency node cadence or streaming queue inventory.'
}

$secondaryCase = [regex]::Match($validationText, "(?s)'Secondary'\s*\{(?:(?!\n\s{8}'\w+'\s*\{).)*?\n\s{8}\}")
if (-not $secondaryCase.Success -or
    $secondaryCase.Value -notmatch 'Test-SecondaryFunctionality' -or
    $secondaryCase.Value -notmatch '\$siteSystemRolesOk\s*=\s*Test-SiteSystemFunctionality' -or
    $secondaryCase.Value -notmatch '\$testsPassed\s*=\s*\$testsPassed\s+-and\s+\$siteSystemRolesOk') {
    throw 'Secondary Phase 11 validation does not include the shared site-system role checks.'
}
if ($validationText -notmatch '\$isSecondary\s*=\s*.*role.*Secondary' -or
    $validationText -notmatch 'if \(\$CurrentItem\.installMP -or \$isSecondary\)' -or
    $validationText -notmatch 'if \(\$CurrentItem\.installDP -or \$isSecondary\)') {
    throw 'Test-SiteSystemFunctionality does not treat Secondary MP/DP roles as implicit.'
}
if ($validationText -notmatch '(?s)\$dpServesOsd\s*=\s*\[bool\]\(-not \$isSecondary.+?skipping all PXE checks') {
    throw 'Secondary implicit DP validation incorrectly assumes MemLabs enabled PXE on that role.'
}

Write-Host 'PASS -- optional Secondary DP lag is informational only with physical content, and implicit MP/DP roles are validated.'
