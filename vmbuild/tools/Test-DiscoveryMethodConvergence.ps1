<#
.SYNOPSIS
    Regresses culture-safe, bounded ConfigMgr discovery configuration.
#>
[CmdletBinding()]
param(
    [string]$RootPath
)

if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }

$ErrorActionPreference = 'Stop'
$script:Failures = 0

function Assert-DiscoveryEqual {
    param($Expected, $Actual, [string]$What)

    $passed = ("$Expected" -eq "$Actual")
    if (-not $passed) { $script:Failures++ }
    Write-Host ('{0}  {1}' -f $(if ($passed) { 'PASS' } else { 'FAIL' }), $What)
    if (-not $passed) {
        Write-Host "      expected: $Expected"
        Write-Host "      actual:   $Actual"
    }
}

function Invoke-DiscoveryScenario {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'DomainFullName', Justification = 'Consumed by the source-extracted discovery block.')]
    param(
        [string[]]$SystemValues,
        [string[]]$GroupValues,
        [bool]$Converges
    )

    $script:SystemValues = @($SystemValues)
    $script:GroupValues = @($GroupValues)
    $script:Converges = $Converges
    $script:SystemSetCalls = 0
    $script:GroupSetCalls = 0
    $script:GroupSiteCodes = @()
    $script:StatusLines = @()
    $script:DiscoveryReads = 0
    $script:DiscoverySleeps = 0

    function Get-CMDiscoveryMethod {
        $script:DiscoveryReads++
        @(
            [pscustomobject]@{
                ItemName = 'SMS_AD_SYSTEM_DISCOVERY_AGENT|SMS Site Server'
                Props = @($script:SystemValues | ForEach-Object {
                    [pscustomobject]@{ PropertyName = 'Settings'; Value1 = $_ }
                })
            }
            [pscustomobject]@{
                ItemName = 'SMS_AD_SECURITY_GROUP_DISCOVERY_AGENT|SMS Site Server'
                Props = @($script:GroupValues | ForEach-Object {
                    [pscustomobject]@{ PropertyName = 'Settings'; Value1 = $_ }
                })
            }
        )
    }

    function Set-CMDiscoveryMethod {
        [CmdletBinding()]
        param(
            [switch]$ActiveDirectorySystemDiscovery,
            [switch]$ActiveDirectoryGroupDiscovery,
            [string]$SiteCode,
            [bool]$Enabled,
            [string[]]$AddActiveDirectoryContainer,
            [switch]$Recursive,
            [object[]]$AddGroupDiscoveryScope
        )

        if ($ActiveDirectorySystemDiscovery) {
            $script:SystemSetCalls++
            if ($script:Converges) { $script:SystemValues = @('ACTIVE') }
        }
        if ($ActiveDirectoryGroupDiscovery) {
            $script:GroupSetCalls++
            $script:GroupSiteCodes += $SiteCode
            if ($script:Converges) { $script:GroupValues = @('ACTIVE') }
        }
    }

    function New-CMADGroupDiscoveryScope {
        [CmdletBinding()]
        param(
            [string]$Name,
            [string]$SiteCode,
            [string]$LdapLocation,
            [bool]$RecursiveSearch
        )
        [pscustomobject]@{ Name = $Name; SiteCode = $SiteCode; LdapLocation = $LdapLocation }
    }

    function Write-DscStatus {
        param([string]$Message, [int]$RetrySeconds)
        $script:StatusLines += $Message
    }

    function Start-Sleep { param([int]$Seconds) $script:DiscoverySleeps++ }

    $DomainFullName = 'locale1.lab'
    $SiteCode = 'L01'
    $failure = ''
    $blockOutput = @()
    try {
        $blockOutput = @(& $script:DiscoveryBlock)
    }
    catch {
        $failure = $_.Exception.Message
    }

    [pscustomobject]@{
        SystemSetCalls = $script:SystemSetCalls
        GroupSetCalls  = $script:GroupSetCalls
        GroupSiteCodes = @($script:GroupSiteCodes)
        StatusLines    = @($script:StatusLines)
        Reads          = $script:DiscoveryReads
        Sleeps         = $script:DiscoverySleeps
        OutputCount    = $blockOutput.Count
        Failure        = $failure
    }
}

$sourcePath = Join-Path $RootPath 'DSC\phases\InstallBoundaryGroups.ps1'
$source = Get-Content -LiteralPath $sourcePath -Raw
$blockMatch = [regex]::Match($source, '(?s)# Setup System Discovery(?<Body>.*?)# Run discovery')
if (-not $blockMatch.Success) { throw 'Discovery configuration block was not found.' }
$script:DiscoveryBlock = [scriptblock]::Create($blockMatch.Groups['Body'].Value)
$fastPathMatch = [regex]::Match(
    $source,
    '(?s)if \((?<Condition>\$adiscoveryValues\.Count -eq 1.*?\$adsgdiscoveryValues\[0\] -ieq "active")\) \{\s*Write-DscStatus "All boundary groups, boundaries, and discovery already configured\. Skipping\."'
)
if (-not $fastPathMatch.Success) { throw 'Discovery fast-path condition was not found.' }
$fastPathCondition = [scriptblock]::Create(
    "param(`$adiscoveryValues, `$adsgdiscoveryValues) [bool]($($fastPathMatch.Groups['Condition'].Value))"
)

$workflowPath = Join-Path $RootPath 'DSC\phases\ScriptWorkFlow.ps1'
$workflowSource = Get-Content -LiteralPath $workflowPath -Raw
$boundaryGroupRethrowCalls = [regex]::Matches(
    $workflowSource,
    '(?s)Running InstallBoundaryGroups\.ps1.*?Invoke-DotSource -Script \$ScriptFile -Arguments \$ConfigFilePath, \$LogPath -Rethrow'
)
Assert-DiscoveryEqual 2 $boundaryGroupRethrowCalls.Count 'Both ScriptWorkflow paths rethrow InstallBoundaryGroups failures'

$scriptFunctionsPath = Join-Path $RootPath 'DSC\phases\ScriptFunctions.ps1'
$tokens = $null
$parseErrors = $null
$scriptFunctionsAst = [Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path -LiteralPath $scriptFunctionsPath).Path,
    [ref]$tokens,
    [ref]$parseErrors
)
if (@($parseErrors).Count -ne 0) { throw "ScriptFunctions.ps1 has parse errors: $($parseErrors -join '; ')" }
$invokeDotSourceAst = $scriptFunctionsAst.Find({
        param($candidate)
        $candidate -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $candidate.Name -eq 'Invoke-DotSource'
    }, $true)
if (-not $invokeDotSourceAst) { throw 'Invoke-DotSource was not found.' }
. ([scriptblock]::Create($invokeDotSourceAst.Extent.Text))
function Write-DscStatus { param($Message, [switch]$Failure, [switch]$NoStatus) }
function Get-CmSslStateNote { return '' }

$throwingScript = Join-Path ([IO.Path]::GetTempPath()) ("memlabs-discovery-throw-$([guid]::NewGuid().ToString('N')).ps1")
try {
    "throw 'discovery convergence failed'" | Set-Content -LiteralPath $throwingScript -Encoding Ascii
    $wrapperThrew = $false
    try { Invoke-DotSource -Script $throwingScript -Rethrow }
    catch { $wrapperThrew = $_.Exception.Message -match 'discovery convergence failed' }
    Assert-DiscoveryEqual $true $wrapperThrew 'Invoke-DotSource rethrows discovery convergence failures'
}
finally {
    Remove-Item -LiteralPath $throwingScript -Force -ErrorAction SilentlyContinue
}

$originalCulture = [Globalization.CultureInfo]::CurrentCulture
$originalUiCulture = [Globalization.CultureInfo]::CurrentUICulture
try {
    $turkish = [Globalization.CultureInfo]::GetCultureInfo('tr-TR')
    [Globalization.CultureInfo]::CurrentCulture = $turkish
    [Globalization.CultureInfo]::CurrentUICulture = $turkish

    $alreadyActive = Invoke-DiscoveryScenario -SystemValues 'ACTIVE' -GroupValues 'ACTIVE' -Converges $true
    Assert-DiscoveryEqual 0 $alreadyActive.SystemSetCalls 'Turkish ACTIVE System state needs no provider write'
    Assert-DiscoveryEqual 0 $alreadyActive.GroupSetCalls 'Turkish ACTIVE Group state needs no provider write'
    Assert-DiscoveryEqual $true ([bool]($alreadyActive.StatusLines -contains 'AD Group Discovery state is: ACTIVE')) 'Group success status is labeled correctly'
    Assert-DiscoveryEqual 2 $alreadyActive.Reads 'Already-active methods require one read each'
    Assert-DiscoveryEqual 0 $alreadyActive.Sleeps 'Already-active methods do not sleep'
    Assert-DiscoveryEqual 0 $alreadyActive.OutputCount 'Successful discovery configuration emits no pipeline output'
    Assert-DiscoveryEqual $true (& $fastPathCondition @('ACTIVE') @('ACTIVE')) 'Fast path accepts one ACTIVE value per method under Turkish culture'
    Assert-DiscoveryEqual $false (& $fastPathCondition @('ACTIVE') @('ACTIVE', 'PASSIVE')) 'Fast path rejects multiple Group Settings values'
    Assert-DiscoveryEqual $false (& $fastPathCondition @() @('ACTIVE')) 'Fast path rejects missing System Settings'
    Assert-DiscoveryEqual $false (& $fastPathCondition @('ACTIVE') @('')) 'Fast path rejects blank Group Settings'

    $converging = Invoke-DiscoveryScenario -SystemValues 'PASSIVE' -GroupValues 'PASSIVE' -Converges $true
    Assert-DiscoveryEqual 1 $converging.SystemSetCalls 'Inactive System discovery converges after one provider write'
    Assert-DiscoveryEqual 1 $converging.GroupSetCalls 'Inactive Group discovery converges after one provider write'
    Assert-DiscoveryEqual 'L01' ($converging.GroupSiteCodes -join ',') 'Group discovery write targets the configured site explicitly'
    Assert-DiscoveryEqual $true ([bool]($converging.StatusLines -contains 'AD Group Discovery state is: PASSIVE (attempt 1/10)')) 'Group retry status reports the Group value and attempt'
    Assert-DiscoveryEqual 4 $converging.Reads 'One-write convergence performs two reads per method'
    Assert-DiscoveryEqual 2 $converging.Sleeps 'One-write convergence sleeps once per method'

    $nonConverging = Invoke-DiscoveryScenario -SystemValues 'ACTIVE' -GroupValues @('PASSIVE', 'UNKNOWN') -Converges $false
    Assert-DiscoveryEqual 1 $nonConverging.GroupSetCalls 'Non-converging Group discovery submits its additive scope once'
    Assert-DiscoveryEqual $true ($nonConverging.Failure -match 'AD Group Discovery did not become ACTIVE after 10 attempts') 'Non-convergence fails instead of looping forever'
    Assert-DiscoveryEqual $true ($nonConverging.Failure -match 'Settings count=2, values=\[PASSIVE, UNKNOWN\]') 'Failure reports state cardinality and values'
    Assert-DiscoveryEqual 11 $nonConverging.Reads 'Non-convergence performs one System and ten Group state reads'
    Assert-DiscoveryEqual 9 $nonConverging.Sleeps 'Non-convergence sleeps only between the first nine Group checks'

    $systemNonConverging = Invoke-DiscoveryScenario -SystemValues @('PASSIVE', 'UNKNOWN') -GroupValues 'ACTIVE' -Converges $false
    Assert-DiscoveryEqual 9 $systemNonConverging.SystemSetCalls 'Non-converging System discovery stops after bounded writes'
    Assert-DiscoveryEqual 0 $systemNonConverging.GroupSetCalls 'Group discovery is not configured after System timeout'
    Assert-DiscoveryEqual $true ($systemNonConverging.Failure -match 'AD System Discovery did not become ACTIVE after 10 attempts') 'System non-convergence propagates failure'
    Assert-DiscoveryEqual $true ($systemNonConverging.Failure -match 'Settings count=2, values=\[PASSIVE, UNKNOWN\]') 'System failure reports state cardinality and values'

    $missing = Invoke-DiscoveryScenario -SystemValues 'ACTIVE' -GroupValues @() -Converges $false
    Assert-DiscoveryEqual $true ($missing.Failure -match 'Settings count=0, values=\[<missing>\]') 'Missing Group Settings fail with explicit evidence'
    $blank = Invoke-DiscoveryScenario -SystemValues 'ACTIVE' -GroupValues '' -Converges $false
    Assert-DiscoveryEqual $true ($blank.Failure -match 'Settings count=1, values=\[\]') 'Blank Group Settings fail with explicit evidence'
}
finally {
    [Globalization.CultureInfo]::CurrentCulture = $originalCulture
    [Globalization.CultureInfo]::CurrentUICulture = $originalUiCulture
}

if ($script:Failures -ne 0) { exit 1 }
exit 0
