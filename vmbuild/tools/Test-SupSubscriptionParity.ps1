#requires -Version 5.1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Fixture variables are read by the extracted production subscription blocks.')]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$path = Join-Path (Split-Path -Parent $PSScriptRoot) 'common\Common.Validation.Functional.ps1'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "$path has parse errors: $($errors -join '; ')" }
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
$helper = @($ast.EndBlock.Statements | Where-Object {
    $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -eq 'Invoke-CmWmiQueryWithRetry'
})
Assert-True ($helper.Count -eq 1) 'Expected one shared provider-query helper.'
. ([scriptblock]::Create($helper[0].Extent.Text))
$gather = @($ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.IfStatementAst] -and
        $node.Clauses[0].Item1.Extent.Text -eq '-not $offlineSup' -and
        $node.Extent.Text.Contains("Class 'SMS_UpdateCategoryInstance'")
}, $true))
$parity = @($ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.IfStatementAst] -and
        $node.Clauses[0].Item1.Extent.Text -eq '$offlineSup' -and
        $node.Extent.Text.Contains('CM-side parity remains unverified')
}, $true))
Assert-True ($gather.Count -eq 1 -and $parity.Count -eq 1) 'Could not locate the shipped subscription gather/parity blocks.'
$gatherScript = [scriptblock]::Create($gather[0].Extent.Text)
$parityScript = [scriptblock]::Create($parity[0].Extent.Text)
$script:Fixture = $null
function Get-WmiObject {
    [CmdletBinding()]
    param($Namespace, $Class, $Filter)
    Assert-True ($Namespace -eq 'root\SMS\site_PS1' -and $Class -eq 'SMS_UpdateCategoryInstance') 'Subscription read lost its provider scope.'
    Assert-True ($Filter -eq "IsSubscribed=TRUE AND (CategoryTypeName='Product' OR CategoryTypeName='UpdateClassification')") 'Subscription read includes unrelated category types.'
    $script:Fixture.Queries++
    if ($script:Fixture.Queries -le $script:Fixture.Failures) { throw 'fixture provider unavailable' }
    return $script:Fixture.Rows
}
function Get-CMSoftwareUpdateCategory {
    $script:Fixture.CmdletCalls++
    throw 'This command cannot be run from the current drive.'
}
function Start-Sleep {
    param($Seconds)
    $script:Fixture.Sleeps.Add([int]$Seconds)
}
function Invoke-ParityFixture {
    param([object[]]$Rows, [int]$Failures = 0, [switch]$Offline, [switch]$Downstream, [int]$Products = 2, [int]$Classifications = 3)
    $script:Fixture = [pscustomobject]@{
        Rows = $Rows; Failures = $Failures; Queries = 0; CmdletCalls = 0
        Sleeps = [Collections.Generic.List[int]]::new()
    }
    $results = @{ Passed = $true; Details = [Collections.Generic.List[string]]::new(); WsusDiagnosticsRequired = $false }
    $ns = 'root\SMS\site_PS1'; $offlineSup = $Offline.IsPresent; $isDownstreamSup = $Downstream.IsPresent
    $cmProdCount = $null; $cmClassCount = $null
    $subCats = $Products; $subClas = $Classifications; $taxCats = 435
    $wcmBit = '; WCM=SUCCESS'; $supTopoDiag = 'fixture'; $upstreamSupName = 'CAS-SUP'
    . $gatherScript
    $haveCm = ($cmProdCount -is [int]) -and ($cmClassCount -is [int])
    . $parityScript
    [pscustomobject]@{
        Result = $results; Products = $cmProdCount; Classifications = $cmClassCount
        Measured = $haveCm; Fixture = $script:Fixture
    }
}
$rows = @(
    foreach ($index in 1..2) { [pscustomobject]@{ CategoryTypeName = 'Product'; IsSubscribed = $true } }
    foreach ($index in 1..3) { [pscustomobject]@{ CategoryTypeName = 'UpdateClassification'; IsSubscribed = $true } }
)
$healthy = Invoke-ParityFixture -Rows $rows
Assert-True ($healthy.Measured -and $healthy.Products -eq 2 -and $healthy.Classifications -eq 3) 'Subscribed counts were not measured independently.'
Assert-True (($healthy.Result.Details -join ' ') -match '^OK: WSUS subscription matches CM SUP') 'Healthy parity did not pass.'
Assert-True ($healthy.Fixture.CmdletCalls -eq 0 -and -not $healthy.Result.WsusDiagnosticsRequired) 'Healthy parity still requires a CMSite drive or requests failure diagnostics.'

$recovered = Invoke-ParityFixture -Rows $rows -Failures 1
Assert-True ($recovered.Measured -and $recovered.Fixture.Queries -eq 2 -and $recovered.Fixture.Sleeps.Count -eq 1) 'A transient provider failure did not use the existing bounded retry.'
Assert-True (($recovered.Result.Details -join ' ') -match 'RECOVERED: CM SUP subscription') 'Recovered provider reads lost their evidence.'

$failed = Invoke-ParityFixture -Rows $rows -Failures 3
Assert-True (-not $failed.Measured -and $null -eq $failed.Products -and $null -eq $failed.Classifications) 'An exhausted provider read became a zero inventory.'
Assert-True ($failed.Fixture.Queries -eq 3 -and $failed.Fixture.Sleeps.Count -eq 2 -and $failed.Result.WsusDiagnosticsRequired) 'Exhausted provider reads lost retry limits or diagnostics.'
Assert-True (($failed.Result.Details -join ' ') -match 'WARN: CM SUP subscription parity could not be measured.*fixture provider unavailable') 'The original provider failure was hidden.'
Assert-True (($failed.Result.Details -join ' ') -match 'INFO: WSUS subscription set.+parity remains unverified') 'Degraded WSUS-only evidence was not clearly labelled.'
Assert-True (@($failed.Result.Details | Where-Object { $_ -like 'OK:*' }).Count -eq 0) 'Unmeasured CM parity still produces a success-shaped fallback.'

foreach ($bad in @(
    [pscustomobject]@{ CategoryTypeName = 'Product'; IsSubscribed = 'true' },
    [pscustomobject]@{ CategoryTypeName = 'Product' },
    [pscustomobject]@{ CategoryTypeName = 'ProductFamily'; IsSubscribed = $true }
)) {
    $invalid = Invoke-ParityFixture -Rows @($bad)
    Assert-True (-not $invalid.Measured -and $invalid.Result.WsusDiagnosticsRequired) 'Malformed provider data was accepted as measured parity.'
}
$empty = Invoke-ParityFixture -Rows @()
Assert-True ($empty.Measured -and $empty.Products -eq 0 -and $empty.Classifications -eq 0) 'A successful empty inventory was confused with an unreadable one.'
Assert-True (($empty.Result.Details -join ' ') -match 'WARN: CM SUP has nothing subscribed') 'Measured empty subscription behavior changed.'
$downstream = Invoke-ParityFixture -Rows @() -Downstream
Assert-True (($downstream.Result.Details -join ' ') -match 'INFO: WSUS/CM subscription not yet replicated') 'A pending downstream subscription became a failure.'
$offline = Invoke-ParityFixture -Rows @() -Failures 99 -Offline -Products 0 -Classifications 0
Assert-True ($offline.Fixture.Queries -eq 0 -and ($offline.Result.Details -join ' ') -match 'OK: WSUS subscription empty by design') 'Offline SUPs unnecessarily query or change their intentionally empty subscription.'

Write-Host 'PASS -- provider-scoped parity, bounded retries, explicit unmeasured failures, and offline/downstream behavior.'
