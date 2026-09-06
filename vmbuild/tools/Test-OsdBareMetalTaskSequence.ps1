<#
.SYNOPSIS
    Focused dual-engine tests for bare-metal OSD task-sequence shape.
#>
[CmdletBinding()]
param ([string] $RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$script:Failures = 0
$script:Log = @()

function Assert-Equal {
    param ($Expected, $Actual, [string] $What)
    $passed = "$Expected" -eq "$Actual"
    if (-not $passed) { $script:Failures++ }
    Write-Host ('{0}  {1}' -f $(if ($passed) { 'PASS' } else { 'FAIL' }), $What)
    if (-not $passed) { Write-Host "      expected: $Expected`n      actual:   $Actual" }
}

function Import-TestFunction {
    param ([string] $Path, [string] $Name)
    $errors = $null
    $tokens = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if (@($errors).Count) { throw "$Path has parse errors" }
    $definition = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($definition.Count -ne 1) { throw "Expected one $Name definition" }
    [scriptblock]::Create($definition[0].Extent.Text)
}

function Write-DscStatus { param($Message, [switch]$Failure); $script:Log += "$Message" }
function Get-CMTaskSequenceGroup {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline = $true)]$InputObject, [string]$StepName)
    process { return @($InputObject.Groups | Where-Object { $_ -and $_.Name -eq $StepName }) }
}
function Remove-CMTaskSequenceGroup {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline = $true)]$InputObject, [string]$StepName, [switch]$Force)
    process { $InputObject.Groups = @($InputObject.Groups | Where-Object { $_.Name -ne $StepName }) }
}

$perfloadingPath = Join-Path $RootPath 'DSC\phases\perfloading.ps1'
. (Import-TestFunction $perfloadingPath 'Sync-MemLabsBareOsdTaskSequenceShape')
Write-Host "engine : $($PSVersionTable.PSVersion)"

$taskSequences = @(
    [pscustomobject]@{ Name = 'MEMLABS-w11-Install OS image'; Groups = @(
            [pscustomobject]@{ Name = 'Capture User Files and Settings' }
            [pscustomobject]@{ Name = 'Capture Files and Settings' }
            [pscustomobject]@{ Name = 'Install Operating System' }
            [pscustomobject]@{ Name = 'Restore User Files and Settings' }
        ) }
    [pscustomobject]@{ Name = 'MEMLABS-w10-Install OS image'; Groups = @(
            [pscustomobject]@{ Name = 'Capture User Files and Settings' }
            [pscustomobject]@{ Name = 'Restore User Files and Settings' }
        ) }
    [pscustomobject]@{ Name = 'MEMLABS-w11-Build and capture'; Groups = @(
            [pscustomobject]@{ Name = 'Capture Files and Settings' }
        ) }
)

Assert-Equal $true (Sync-MemLabsBareOsdTaskSequenceShape -TaskSequences $taskSequences -StatusTag '[test]') 'bare-metal reconcile succeeds'
foreach ($taskSequence in @($taskSequences | Where-Object { $_.Name -like 'MEMLABS-w*-Install OS image' })) {
    Assert-Equal 0 @($taskSequence.Groups | Where-Object { $_.Name -eq 'Capture User Files and Settings' }).Count "$($taskSequence.Name) has no user-state capture group"
    Assert-Equal 0 @($taskSequence.Groups | Where-Object { $_.Name -eq 'Restore User Files and Settings' }).Count "$($taskSequence.Name) has no restore group"
}
Assert-Equal 1 @($taskSequences[0].Groups | Where-Object { $_.Name -eq 'Install Operating System' }).Count 'unmanaged install group is preserved'
Assert-Equal 1 @($taskSequences[0].Groups | Where-Object { $_.Name -eq 'Capture Files and Settings' }).Count 'capture-settings parent group is preserved'
Assert-Equal 1 @($taskSequences[2].Groups | Where-Object { $_.Name -eq 'Capture Files and Settings' }).Count 'build-and-capture sequence is unchanged'
Assert-Equal $true (Sync-MemLabsBareOsdTaskSequenceShape -TaskSequences $taskSequences -StatusTag '[test]') 'rerun remains successful and idempotent'

$source = Get-Content $perfloadingPath -Raw
Assert-Equal 2 ([regex]::Matches($source, 'CaptureUserSetting\s+=\s+\$false').Count) 'both generated install-image sequences disable user-state capture'
Assert-Equal 0 ([regex]::Matches($source, '(?m)^\s+(SaveLocally|CaptureLocallyUsingLink|UserStateMigrationToolPackageId)\s+=').Count) 'install-image definitions do not author USMT storage settings'
Assert-Equal $true ($source.Contains('Sync-MemLabsBareOsdTaskSequenceShape -TaskSequences $siteTaskSequencesForNaming')) 'existing task sequences are reconciled on rerun'

if ($script:Failures) { Write-Host "$script:Failures check(s) failed."; exit 1 }
Write-Host 'All bare-metal OSD task-sequence checks passed.'