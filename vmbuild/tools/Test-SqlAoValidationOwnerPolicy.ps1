#requires -Version 5.1
[CmdletBinding()]
param([string]$RootPath)

if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$ErrorActionPreference = 'Stop'
$failures = [Collections.Generic.List[string]]::new()

function Assert-ValidatorOwner {
    param([bool]$Condition, [string]$What)
    if ($Condition) { Write-Host "PASS  $What" }
    else { Write-Host "FAIL  $What"; $failures.Add($What) }
}

$path = Join-Path $RootPath 'common\Common.Validation.Functional.ps1'
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -ne 0) { throw "$path has parse errors: $($parseErrors.Message -join '; ')" }

$ownerTryBlocks = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.TryStatementAst] -and
            $node.Extent.Text -match 'AG SQL-managed owner state is inconsistent'
        }, $true) | Sort-Object { $_.Extent.Text.Length } | Select-Object -First 2 |
        Sort-Object { $_.Extent.StartLineNumber })
if ($ownerTryBlocks.Count -ne 2) { throw "Expected two validator owner-state blocks, found $($ownerTryBlocks.Count)" }
$validatorBlocks = @($ownerTryBlocks | ForEach-Object { [scriptblock]::Create($_.Extent.Text) })

$script:PossibleOwners = @()
$script:PreferredOwners = @()
$script:GroupOwner = 'SQLAO1'
$script:GroupState = 'Online'
$script:ResourceState = 'Online'
$script:OwnerQueryThrows = $false
function Get-ClusterResource {
    param($Name, $ErrorAction)
    [pscustomobject]@{ Name = $Name; State = $script:ResourceState }
}
function Get-ClusterGroup {
    param($Name, $ErrorAction)
    [pscustomobject]@{
        Name = $Name
        State = $script:GroupState
        OwnerNode = [pscustomobject]@{ Name = $script:GroupOwner }
    }
}
function Get-ClusterOwnerNode {
    param($Resource, $Group, $ErrorAction)
    if ($script:OwnerQueryThrows) { throw 'injected owner query failure' }
    $owners = if ($PSBoundParameters.ContainsKey('Resource')) { $script:PossibleOwners } else { $script:PreferredOwners }
    [pscustomobject]@{ OwnerNodes = @($owners | ForEach-Object { [pscustomobject]@{ Name = $_ } }) }
}

$recoveryOwner = 'SQLAO1'
$otherNode = 'SQLAO2'
$expectedReplicas = @('SQLAO1', 'SQLAO2')
$agName = 'CM Availability Group'

function Invoke-OwnerValidatorCase {
    param(
        [scriptblock]$Block,
        [string[]]$Possible,
        [string[]]$Preferred,
        [string]$GroupOwner = 'SQLAO1',
        [string]$GroupState = 'Online',
        [string]$ResourceState = 'Online',
        [bool]$Throws = $false
    )
    $script:PossibleOwners = @($Possible)
    $script:PreferredOwners = @($Preferred)
    $script:GroupOwner = $GroupOwner
    $script:GroupState = $GroupState
    $script:ResourceState = $ResourceState
    $script:OwnerQueryThrows = $Throws
    $script:results = @{ Passed = $true; Details = [Collections.Generic.List[string]]::new() }
    & $Block
    return [pscustomobject]@{
        Passed = [bool]$script:results.Passed
        Details = @($script:results.Details)
    }
}

for ($index = 0; $index -lt $validatorBlocks.Count; $index++) {
    $label = if ($index -eq 0) { 'Phase 11' } else { 'post-Phase-5' }
    $block = $validatorBlocks[$index]

    $manualPrimary1 = Invoke-OwnerValidatorCase -Block $block -Possible SQLAO1 -Preferred SQLAO1
    Assert-ValidatorOwner $manualPrimary1.Passed "$label accepts SQL-managed singleton owner on primary 1"

    $manualPrimary2 = Invoke-OwnerValidatorCase -Block $block -Possible SQLAO2 -Preferred SQLAO2 -GroupOwner SQLAO2
    Assert-ValidatorOwner $manualPrimary2.Passed "$label accepts SQL-managed singleton owner on primary 2"

    $automaticPair = Invoke-OwnerValidatorCase -Block $block -Possible SQLAO2,SQLAO1 -Preferred SQLAO2,SQLAO1
    Assert-ValidatorOwner $automaticPair.Passed "$label accepts multiple SQL-managed owners without enforcing preferred order"

    $missingCurrent = Invoke-OwnerValidatorCase -Block $block -Possible SQLAO2 -Preferred SQLAO1
    Assert-ValidatorOwner (-not $missingCurrent.Passed -and ($missingCurrent.Details -join ' ') -match 'absent') "$label rejects current owner missing from possible owners"

    $unexpectedOwner = Invoke-OwnerValidatorCase -Block $block -Possible SQLAO3 -Preferred SQLAO3 -GroupOwner SQLAO3
    Assert-ValidatorOwner (-not $unexpectedOwner.Passed -and ($unexpectedOwner.Details -join ' ') -match 'not a configured replica') "$label rejects a group owner outside configured replicas"

    $offline = Invoke-OwnerValidatorCase -Block $block -Possible SQLAO1 -Preferred SQLAO1 -ResourceState Offline
    Assert-ValidatorOwner (-not $offline.Passed -and ($offline.Details -join ' ') -match "resource state='Offline'") "$label rejects an offline AG resource"

    $offlineGroup = Invoke-OwnerValidatorCase -Block $block -Possible SQLAO1 -Preferred SQLAO1 -GroupState Offline
    Assert-ValidatorOwner (-not $offlineGroup.Passed -and ($offlineGroup.Details -join ' ') -match "group state='Offline'") "$label rejects an offline AG group"

    $partialGroup = Invoke-OwnerValidatorCase -Block $block -Possible SQLAO1 -Preferred SQLAO1 -GroupState PartialOnline
    Assert-ValidatorOwner (-not $partialGroup.Passed -and ($partialGroup.Details -join ' ') -match "group state='PartialOnline'") "$label rejects a partially online AG group"

    $noPreferred = Invoke-OwnerValidatorCase -Block $block -Possible SQLAO1 -Preferred @()
    Assert-ValidatorOwner $noPreferred.Passed "$label does not enforce SQL-managed preferred-owner membership"

    $queryFailure = Invoke-OwnerValidatorCase -Block $block -Possible @() -Preferred @() -Throws $true
    Assert-ValidatorOwner (-not $queryFailure.Passed -and ($queryFailure.Details -join ' ') -match 'Could not validate') "$label fails closed on owner query error"
}

if ($failures.Count -gt 0) {
    throw "$($failures.Count) SQLAO validator owner-policy assertion(s) failed: $($failures -join '; ')"
}
Write-Host 'All SQLAO validator owner-policy tests passed.'
