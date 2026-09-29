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
            $node.Extent.Text -match 'AG owner policy mismatch'
        }, $true) | Sort-Object { $_.Extent.Text.Length } | Select-Object -First 2 |
        Sort-Object { $_.Extent.StartLineNumber })
if ($ownerTryBlocks.Count -ne 2) { throw "Expected two validator owner-policy blocks, found $($ownerTryBlocks.Count)" }
$validatorBlocks = @($ownerTryBlocks | ForEach-Object { [scriptblock]::Create($_.Extent.Text) })

$script:PossibleOwners = @()
$script:PreferredOwners = @()
$script:OwnerQueryThrows = $false
function Get-ClusterResource { param($Name, $ErrorAction); [pscustomobject]@{ Name = $Name } }
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
        [bool]$Throws = $false
    )
    $script:PossibleOwners = @($Possible)
    $script:PreferredOwners = @($Preferred)
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

    $exact = Invoke-OwnerValidatorCase -Block $block -Possible SQLAO1,SQLAO2 -Preferred SQLAO1,SQLAO2
    Assert-ValidatorOwner $exact.Passed "$label accepts exact owner sets"

    $reversedPossible = Invoke-OwnerValidatorCase -Block $block -Possible SQLAO2,SQLAO1 -Preferred SQLAO1,SQLAO2
    Assert-ValidatorOwner $reversedPossible.Passed "$label accepts reordered possible-owner membership"

    $reversedPreferred = Invoke-OwnerValidatorCase -Block $block -Possible SQLAO1,SQLAO2 -Preferred SQLAO2,SQLAO1
    Assert-ValidatorOwner (-not $reversedPreferred.Passed -and ($reversedPreferred.Details -join ' ') -match 'preferred=') "$label rejects reversed preferred-owner priority"

    $missing = Invoke-OwnerValidatorCase -Block $block -Possible SQLAO1 -Preferred SQLAO1,SQLAO2
    Assert-ValidatorOwner (-not $missing.Passed -and ($missing.Details -join ' ') -match 'possible=') "$label rejects missing possible owner with details"

    $extra = Invoke-OwnerValidatorCase -Block $block -Possible SQLAO1,SQLAO2,SQLAO3 -Preferred SQLAO1,SQLAO2
    Assert-ValidatorOwner (-not $extra.Passed) "$label rejects extra possible owner"

    $zero = Invoke-OwnerValidatorCase -Block $block -Possible SQLAO1,SQLAO2 -Preferred @()
    Assert-ValidatorOwner (-not $zero.Passed -and ($zero.Details -join ' ') -match 'preferred=') "$label rejects zero preferred owners with details"

    $queryFailure = Invoke-OwnerValidatorCase -Block $block -Possible @() -Preferred @() -Throws $true
    Assert-ValidatorOwner (-not $queryFailure.Passed -and ($queryFailure.Details -join ' ') -match 'Could not validate') "$label fails closed on owner query error"
}

if ($failures.Count -gt 0) {
    throw "$($failures.Count) SQLAO validator owner-policy assertion(s) failed: $($failures -join '; ')"
}
Write-Host 'All SQLAO validator owner-policy tests passed.'
