<#
.SYNOPSIS
    Verifies servicing-marker collection in the quiet Windows Update probe.
#>
[CmdletBinding()]
param (
    [string] $RootPath
)

if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }

$script:Failures = 0
$script:UpdateExeVolatile = $null

function Assert-Equal {
    param ($Expected, $Actual, [string] $What)

    $passed = "$Expected" -eq "$Actual"
    if (-not $passed) { $script:Failures++ }
    $status = if ($passed) { 'PASS' } else { 'FAIL' }
    Write-Host ('{0}  {1}' -f $status, $What)
    if (-not $passed) {
        Write-Host "      expected: $Expected"
        Write-Host "      actual:   $Actual"
    }
}

function Get-QuietWindowsUpdateProbe {
    param ([string] $Path)

    $errors = $null
    $tokens = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if (@($errors | Where-Object { $null -ne $_ }).Count -ne 0) { throw "$Path has parse errors" }
    $assignments = @($ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                $node.Left.Extent.Text -eq '$wuResult' -and
                $node.Extent.Text -like '*Quiet Windows Update*'
            }, $true))
    if ($assignments.Count -ne 1) { throw "Expected one quiet Windows Update assignment, found $($assignments.Count)" }
    $blocks = @($assignments[0].Right.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.ScriptBlockExpressionAst] -and
                $node.Extent.Text -like '*pre-existing servicing markers before quiet*'
            }, $true))
    if ($blocks.Count -ne 1) { throw "Expected one quiet Windows Update guest block, found $($blocks.Count)" }
    return $blocks[0].ScriptBlock.GetScriptBlock()
}

function Test-Path { return $false }
function Get-ItemProperty {
    if ($null -eq $script:UpdateExeVolatile) { return [pscustomobject]@{} }
    return [pscustomobject]@{ UpdateExeVolatile = $script:UpdateExeVolatile }
}
function Get-Service { return $null }

$probe = Get-QuietWindowsUpdateProbe -Path (Join-Path $RootPath 'common\Common.ScriptBlocks.ps1')

$withoutValue = @(& $probe)
Assert-Equal 1 $withoutValue.Count 'missing UpdateExeVolatile returns one result without an error record'
Assert-Equal 'no WU services present; pre-existing servicing markers before quiet: none' $withoutValue[0] 'missing UpdateExeVolatile is not reported as pending servicing'

$script:UpdateExeVolatile = 7
$withValue = @(& $probe)
Assert-Equal 1 $withValue.Count 'nonzero UpdateExeVolatile returns one result'
Assert-Equal 'no WU services present; pre-existing servicing markers before quiet: UpdateExeVolatile=7' $withValue[0] 'nonzero UpdateExeVolatile remains visible'

if ($script:Failures -ne 0) { throw "$script:Failures quiet Windows Update probe test(s) failed" }

Write-Host 'ALL QUIET WINDOWS UPDATE PROBE TESTS PASSED' -ForegroundColor Green