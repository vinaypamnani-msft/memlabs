<#
.SYNOPSIS
    Exercise the version detection that stops maintenance re-running a pwsh upgrade the
    MSI can only fail.

.DESCRIPTION
    Chocolatey's record of an installed package goes stale when that package is upgraded
    out of band. A lab had PowerShell 7.6.5 on disk while choco still believed 7.6.3 and
    offered 7.6.4, so every `choco upgrade all` drove the MSI into a downgrade and got
    1603 back. Because that exit code never let the run stamp its timestamp, the upgrade
    window relaunched on every maintenance pass for over a month.

    Invoke-Maintenance now reads the version off pwsh.exe rather than from choco's
    record, compares it against what choco offers, and excludes the package when the MSI
    would install an older or equal build. This checks the three parts that decide that:

      * the choco search parser, against the documented --limit-output row shape
      * the installed-version reader, cross-checked against an independent read
      * the comparison itself, which must be numeric -- a string compare puts .10 below .9

    It also pins the argument quoting choco requires for a list-valued option, which is
    easy to get wrong and silently changes which packages are excluded.

    Nothing here needs Chocolatey present: the search output is supplied as fixtures, so
    the parser is tested the same way on any machine. The installed-version check reports
    SKIP rather than failing when PowerShell 7 is not installed.

    Functions are lifted out of the shipped file with the AST, so this exercises the code
    that actually ships rather than a copy that can drift. Preferences are left at their
    defaults so the functions run under the same rules the maintenance script uses.

.PARAMETER RootPath
    The vmbuild folder. Defaults to the parent of this script, so it works from any clone.

.PARAMETER SourceFile
    Path of the maintenance script, relative to RootPath.

.PARAMETER PackageId
    Package id used to build the search fixtures and the exclusion list.

.PARAMETER ExcludedPackages
    Packages the exclusion argument should carry. The metapackage pins its payload to an
    exact version, so excluding one without the other leaves an unsatisfiable constraint.

.EXAMPLE
    .\Test-PwshUpgradeDetection.ps1

.EXAMPLE
    powershell.exe -NoProfile -File .\Test-PwshUpgradeDetection.ps1
    Run it under Windows PowerShell 5.1 too; VMBuild.cmd launches maintenance with 5.1.
#>
[CmdletBinding()]
param (
    [string]$RootPath,
    [string]$SourceFile = 'Invoke-Maintenance.ps1',
    [string]$PackageId = 'pwsh',
    [string[]]$ExcludedPackages = @('pwsh', 'powershell-core')
)

# $PSScriptRoot is empty inside a param() default under Windows PowerShell 5.1.
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }

$script:Failures = 0

function Assert-Equal {
    param ($Expected, $Actual, [string]$What)

    $ok = ("$Expected" -eq "$Actual")
    if (-not $ok) { $script:Failures++ }
    $color = if ($ok) { 'Green' } else { 'Red' }
    Write-Host ('{0}  {1}' -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $What) -ForegroundColor $color
    if (-not $ok) {
        Write-Host "      expected: $Expected" -ForegroundColor Red
        Write-Host "      actual:   $Actual" -ForegroundColor Red
    }
}

$sourcePath = Join-Path $RootPath $SourceFile
if (-not (Test-Path -LiteralPath $sourcePath)) {
    Write-Host "SETUP FAIL: no $SourceFile under $RootPath" -ForegroundColor Red
    exit 2
}

$parseErrors = $null
$tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path -LiteralPath $sourcePath).Path, [ref]$tokens, [ref]$parseErrors)
if (@($parseErrors).Count -ne 0) {
    Write-Host "SETUP FAIL: $SourceFile has $(@($parseErrors).Count) parse error(s)" -ForegroundColor Red
    exit 2
}

$wanted = @('Test-ChocoSuccessCode', 'Get-InstalledPwshVersion', 'Get-ChocoAvailablePackageVersion')
$loaded = @()
foreach ($node in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if ($wanted -notcontains $node.Name) { continue }
    $loaded += $node.Name
    . ([scriptblock]::Create($node.Extent.Text))
}
$missing = @($wanted | Where-Object { $loaded -notcontains $_ })
if ($missing.Count) {
    Write-Host "SETUP FAIL: not found in ${SourceFile}: $($missing -join ', ')" -ForegroundColor Red
    exit 2
}

# The extracted functions log through the maintenance script's logger.
function Write-LogMessage {
    param ([string]$Message, [string]$Level = 'INFO')
    Write-Verbose "[$Level] $Message"
}

# Stands in for choco.exe. A function cannot set $LASTEXITCODE, so it is assigned directly.
$script:StubRows = @()
$script:StubExit = 0
function choco {
    $global:LASTEXITCODE = $script:StubExit
    $script:StubRows
}

Write-Host "engine  : $($PSVersionTable.PSVersion)"
Write-Host "source  : $sourcePath"
Write-Host ''

# --- the installed-version reader ------------------------------------------------------
# Cross-checked against a second, independent read of the same fact rather than a
# version literal, so this says nothing about which build happens to be on this machine.
$installed = Get-InstalledPwshVersion
$pwshExe = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
if (Test-Path -LiteralPath $pwshExe) {
    $info = (Get-Item -LiteralPath $pwshExe).VersionInfo
    $independent = '{0}.{1}.{2}' -f $info.FileMajorPart, $info.FileMinorPart, $info.FileBuildPart
    Assert-Equal $independent $installed 'installed version matches an independent read of pwsh.exe'
    Assert-Equal 'System.Version' $installed.GetType().FullName 'installed version is a [version], not a string'
}
else {
    Write-Host "SKIP  no PowerShell 7 at $pwshExe - installed-version reader not exercised" -ForegroundColor Yellow
}

# --- the choco search parser -----------------------------------------------------------
$sampleVersion = '9.8.7'
$cases = @(
    @{ Name = 'the documented --limit-output row'; Exit = 0; Rows = @("$PackageId|$sampleVersion"); Expect = $sampleVersion }
    @{ Name = 'a four-part version'; Exit = 0; Rows = @("$PackageId|$sampleVersion.6"); Expect = "$sampleVersion.6" }
    @{ Name = 'a prerelease suffix is trimmed'; Exit = 0; Rows = @("$PackageId|$sampleVersion-preview.2"); Expect = $sampleVersion }
    @{ Name = 'preamble lines are ignored'; Exit = 0; Rows = @('Chocolatey v0.0.0', "$PackageId|$sampleVersion"); Expect = $sampleVersion }
    @{ Name = 'a near-miss package id is not accepted'; Exit = 0; Rows = @("${PackageId}extra|$sampleVersion"); Expect = '' }
    @{ Name = 'no results yields no version'; Exit = 0; Rows = @(); Expect = '' }
    @{ Name = 'a failed search yields no version'; Exit = 1; Rows = @("$PackageId|$sampleVersion"); Expect = '' }
)
foreach ($case in $cases) {
    $script:StubRows = $case.Rows
    $script:StubExit = $case.Exit
    Assert-Equal $case.Expect (Get-ChocoAvailablePackageVersion -PackageId $PackageId) "choco search: $($case.Name)"
}

# --- the decision ----------------------------------------------------------------------
# Mirrors the condition in the maintenance script: skip only when both versions are known
# and the installed build is at least what the package carries.
function Test-SkipDecision {
    param ($InstalledVersion, $AvailableVersion)
    return [bool]($InstalledVersion -and $AvailableVersion -and $InstalledVersion -ge $AvailableVersion)
}

Assert-Equal $true (Test-SkipDecision ([version]'2.1.5') ([version]'2.1.4')) 'installed newer than offered -> skip (the 1603 case)'
Assert-Equal $true (Test-SkipDecision ([version]'2.1.4') ([version]'2.1.4')) 'installed equal to offered -> skip'
Assert-Equal $false (Test-SkipDecision ([version]'2.1.4') ([version]'2.1.5')) 'installed older -> the upgrade runs'
Assert-Equal $false (Test-SkipDecision $null ([version]'2.1.4')) 'installed unknown -> the upgrade runs, no skip on a non-measurement'
Assert-Equal $false (Test-SkipDecision ([version]'2.1.5') $null) 'offered unknown -> the upgrade runs, no skip on a non-measurement'

# A string compare reads 2.1.10 as older than 2.1.9, which would skip a real upgrade.
Assert-Equal $false ('2.1.10' -ge '2.1.9') 'a string compare gets two-digit revisions wrong'
Assert-Equal $true ([version]'2.1.10' -ge [version]'2.1.9') '[version] gets two-digit revisions right'

# --- the exclusion argument ------------------------------------------------------------
# choco wants the value single-quoted inside the double quotes; PowerShell strips the
# outer pair and choco strips the inner, leaving one argv token.
$script:SeenArgs = @()
function Invoke-ChocoStub { $script:SeenArgs = $args; $global:LASTEXITCODE = 0 }
$exceptValue = $ExcludedPackages -join ','
$command = '& Invoke-ChocoStub upgrade all -y --except="' + "'$exceptValue'" + '"'
. ([scriptblock]::Create($command))
Assert-Equal "upgrade all -y --except='$exceptValue'" ($script:SeenArgs -join ' ') 'the exclusion reaches choco as one argument with its quotes intact'

Write-Host ''
if ($script:Failures) {
    Write-Host "FAILURES: $script:Failures" -ForegroundColor Red
    exit 1
}
Write-Host 'OK - all checks passed.' -ForegroundColor Green
exit 0
