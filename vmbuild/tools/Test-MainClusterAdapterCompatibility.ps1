<#
.SYNOPSIS
    Verifies exact-main can coexist with the intentional ClusterV2 host adapter.
#>
[CmdletBinding()]
param([string] $RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$sourcePath = Join-Path $RootPath 'tools\Invoke-MainToDevelopExpansionTest.ps1'

$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    $sourcePath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "$sourcePath has parse errors: $($errors -join '; ')" }

function Import-TestFunction {
    param([string] $Name)
    $definitions = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $Name
            }, $true))
    if ($definitions.Count -ne 1) {
        throw "Expected one $Name definition, found $($definitions.Count)."
    }
    return [scriptblock]::Create($definitions[0].Extent.Text)
}

. (Import-TestFunction -Name 'Restore-ExactMainClusterAdapterCompatibility')
. (Import-TestFunction -Name 'Enter-ExactMainClusterAdapterCompatibility')

$script:Adapters = [System.Collections.Generic.List[object]]::new()
$script:ExactMainClusterAdapterCompatibilityActive = $false
function Set-TestAdapters {
    param([string[]] $Names)
    $script:Adapters.Clear()
    foreach ($name in $Names) {
        $script:Adapters.Add([pscustomobject]@{ Name = $name; InterfaceAlias = $name })
    }
}
function Get-NetAdapter {
    param([string] $ErrorAction)
    return @($script:Adapters)
}
function Rename-NetAdapter {
    param([string] $Name, [string] $NewName, [string] $ErrorAction)
    $matches = @($script:Adapters | Where-Object { $_.Name -eq $Name })
    if ($matches.Count -ne 1) { throw "Rename source '$Name' count=$($matches.Count)" }
    $matches[0].Name = $NewName
    $matches[0].InterfaceAlias = $NewName
}

Set-TestAdapters -Names @('vEthernet (Cluster)', 'vEthernet (ClusterV2)')
$entered = Enter-ExactMainClusterAdapterCompatibility
if (-not $entered -or -not $script:ExactMainClusterAdapterCompatibilityActive) {
    throw 'ClusterV2 compatibility mode did not activate.'
}
$legacyMatches = @($script:Adapters | Where-Object { $_.Name -like '*Cluster*' })
if ($legacyMatches.Count -ne 1 -or $legacyMatches[0].Name -ne 'vEthernet (Cluster)') {
    throw "Exact-main still sees an ambiguous Cluster adapter set: $($legacyMatches.Name -join ', ')."
}
$restored = Restore-ExactMainClusterAdapterCompatibility
if (-not $restored -or $script:ExactMainClusterAdapterCompatibilityActive -or
    @($script:Adapters | Where-Object { $_.Name -eq 'vEthernet (ClusterV2)' }).Count -ne 1) {
    throw 'ClusterV2 adapter alias was not restored after exact-main.'
}

Set-TestAdapters -Names @('vEthernet (Cluster)', 'MemLabs-HB2-Compat')
$null = Restore-ExactMainClusterAdapterCompatibility
if (@($script:Adapters | Where-Object { $_.Name -eq 'vEthernet (ClusterV2)' }).Count -ne 1) {
    throw 'An alias left by an interrupted run was not recovered.'
}

Set-TestAdapters -Names @('vEthernet (Cluster)', 'vEthernet (ClusterV2)', 'MemLabs-HB2-Compat')
$collision = ''
try { $null = Enter-ExactMainClusterAdapterCompatibility }
catch { $collision = $_.Exception.Message }
if ($collision -notmatch 'Both.+exist') {
    throw "An existing compatibility-alias collision did not fail closed: '$collision'."
}

$source = Get-Content -LiteralPath $sourcePath -Raw
if ($source -notmatch
    '(?s)Enter-ExactMainClusterAdapterCompatibility.+?Invoke-NewLabFixture.+?finally.+?Restore-ExactMainClusterAdapterCompatibility') {
    throw 'Exact-main invocation is not wrapped by compatibility enter/restore.'
}
if ($source -notmatch
    '(?s)finally\s*\{.+?ExactMainClusterAdapterCompatibilityActive.+?Restore-ExactMainClusterAdapterCompatibility -BestEffort') {
    throw 'The runner outer finally cannot recover a hidden ClusterV2 alias.'
}
if ($source -notmatch
    "(?s)Hyper-V PowerShell module is unavailable.+?Restore-ExactMainClusterAdapterCompatibility.+?PowerShell 7 executable") {
    throw 'Runner startup does not recover an alias left by a previously interrupted process.'
}

Write-Host 'PASS -- exact-main sees one Cluster adapter while ClusterV2 is restored after every run.'
