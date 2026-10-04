<#
.SYNOPSIS
    Verifies curated test suites cover every ordinary family without exposing mutation manifests.
#>
[CmdletBinding()]
param([string] $RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$suiteHelperPath = Join-Path $RootPath 'tools\Common.TestSuites.ps1'
$startTestPath = Join-Path $RootPath 'Start-Test.ps1'
$runnerPath = Join-Path $RootPath 'tools\Invoke-MainToDevelopExpansionTest.ps1'
. $suiteHelperPath

function Assert-Equal {
    param($Expected, $Actual, [string] $Message)
    if ("$Expected" -ne "$Actual") {
        throw "$Message`nExpected: $Expected`nActual:   $Actual"
    }
}

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

$core = Resolve-MemLabsTestSuite -VmbuildRoot $RootPath -Name 'Core'
$upgrade = Resolve-MemLabsTestSuite -VmbuildRoot $RootPath -Name 'Upgrade'
$specialized = Resolve-MemLabsTestSuite -VmbuildRoot $RootPath -Name 'Specialized'
$stress = Resolve-MemLabsTestSuite -VmbuildRoot $RootPath -Name 'Stress'
$full = Resolve-MemLabsTestSuite -VmbuildRoot $RootPath -Name 'Full'

Assert-Equal 'Standard' $core.Mode 'Core suite mode changed unexpectedly.'
Assert-Equal 'CrossRevision' $upgrade.Mode 'Upgrade suite is no longer cross-revision.'
Assert-Equal 'NOCM,PSTest2,CSTest2,CSTest3,CSTest5,CSTEST8' `
    (@($core.Families) -join ',') 'Core suite membership changed unexpectedly.'
Assert-True ($upgrade.Families -contains 'CSTest3') 'Upgrade suite dropped the existing-VM mutation family.'
Assert-True ($upgrade.Families -contains 'CSTest5') 'Upgrade suite dropped the Proxy/Linux follow-on family.'
Assert-True ($upgrade.Families -contains 'PSTest2') 'Upgrade suite dropped the pull-DP follow-on family.'

$ordinaryFamilies = @(Get-MemLabsOrdinaryTestFamilies -VmbuildRoot $RootPath)
$curatedUnion = @($core.Families + $specialized.Families + $stress.Families | Select-Object -Unique)
Assert-Equal (@($ordinaryFamilies | Sort-Object) -join ',') (@($curatedUnion | Sort-Object) -join ',') `
    'Core + Specialized + Stress do not cover every ordinary test family.'
Assert-Equal (@($ordinaryFamilies | Sort-Object) -join ',') (@($full.Families | Sort-Object) -join ',') `
    'Full suite does not resolve to every ordinary test family.'

$mutationManifests = @(Get-ChildItem -LiteralPath (Join-Path $RootPath 'config\tests\mutations') -Filter '*.json' -File)
Assert-True ($mutationManifests.Count -gt 0) 'No mutation manifests were found.'
$ordinaryConfigNames = @(Get-ChildItem -LiteralPath (Join-Path $RootPath 'config\tests') -Filter '*.json' -File |
        ForEach-Object { $_.Name })
foreach ($mutationManifest in $mutationManifests) {
    Assert-True ($ordinaryConfigNames -notcontains $mutationManifest.Name) `
        "Mutation manifest '$($mutationManifest.Name)' leaked into ordinary config discovery."
}

foreach ($family in $upgrade.Families) {
    $familyFiles = @(Get-ChildItem -LiteralPath (Join-Path $RootPath 'config\tests') -Filter "$family-*.json" -File)
    Assert-True (@($familyFiles | Where-Object { $_.Name -match "-A(?:-|\.json$)" }).Count -eq 1) `
        "Upgrade family '$family' does not have exactly one A baseline."
    Assert-True (@($familyFiles | Where-Object { $_.Name -match "-[B-Z](?:-|\.json$)" }).Count -gt 0 -or $family -eq 'CSTest3') `
        "Upgrade family '$family' has no follow-on fixture."
}

$proxyLinux = Get-Content -LiteralPath (Join-Path $RootPath 'config\tests\CSTest5-C-AddProxyLinux.json') -Raw | ConvertFrom-Json
Assert-Equal 'LinuxClient,LinuxServer,Proxy' `
    (@($proxyLinux.virtualMachines.role | Where-Object { $_ -in @('Proxy', 'LinuxServer', 'LinuxClient') } | Sort-Object) -join ',') `
    'Proxy/Linux upgrade fixture does not cover all develop-only role classes.'
Assert-True (($proxyLinux.virtualMachines | Where-Object role -eq 'LinuxServer').joinDomain -eq $true) `
    'Proxy/Linux upgrade fixture does not exercise Linux domain join.'

$pullDp = Get-Content -LiteralPath (Join-Path $RootPath 'config\tests\PSTest2-F-AddPullDP.json') -Raw | ConvertFrom-Json
Assert-Equal $true ([bool]$pullDp.virtualMachines[0].enablePullDP) 'Pull-DP upgrade fixture no longer enables pull-DP.'
Assert-Equal 'DPMP1' "$($pullDp.virtualMachines[0].pullDPSourceDP)" 'Pull-DP upgrade fixture source changed unexpectedly.'

$startTestSource = Get-Content -LiteralPath $startTestPath -Raw
$runnerSource = Get-Content -LiteralPath $runnerPath -Raw
Assert-True ($startTestSource -match "Resolve-MemLabsTestSuite -VmbuildRoot \`$PSScriptRoot -Name 'Core'") `
    'Start-Test -All is no longer mapped to Core.'
Assert-True ($startTestSource.Contains("'-TestsCsv'")) 'Start-Test does not forward curated upgrade families.'
Assert-True ($runnerSource.Contains('[string] $TestsCsv')) 'Cross-revision runner does not accept a curated family list.'

Write-Host "PASS -- suites cover $($ordinaryFamilies.Count) ordinary families; Core=$($core.Families.Count), Upgrade=$($upgrade.Families.Count), Specialized=$($specialized.Families.Count), Stress=$($stress.Families.Count)."
