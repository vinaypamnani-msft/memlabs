<#
.SYNOPSIS
    Proves blank VM-note strings survive Hyper-V inventory reconstruction.
#>
[CmdletBinding()]
param([string] $RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$script:Failures = 0

function Assert-Equal {
    param($Expected, $Actual, [string]$What)
    $passed = if ($null -eq $Expected) { $null -eq $Actual } else { $Expected.Equals($Actual) }
    if (-not $passed) { $script:Failures++ }
    Write-Host ('{0}  {1}' -f $(if ($passed) { 'PASS' } else { 'FAIL' }), $What)
    if (-not $passed) { Write-Host "      expected: <$Expected> ($($Expected.GetType().Name))`n      actual:   <$Actual> ($($Actual.GetType().Name))" }
}
function Import-TestFunction {
    param([string]$Path, [string]$Name)
    $errors = $null; $tokens = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if (@($errors).Count) { throw "$Path has parse errors" }
    $definition = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name }, $true))
    if ($definition.Count -ne 1) { throw "Expected one $Name definition" }
    [scriptblock]::Create($definition[0].Extent.Text)
}
function Write-Log { param($Message, [switch]$LogOnly, [switch]$Failure) }
function Test-SiteSystemClientOperatingSystem { param($VirtualMachine); return $false }

$configPath = Join-Path $RootPath 'common\Common.Config.ps1'
. (Import-TestFunction $configPath 'Update-VMFromHyperV')
Write-Host "engine : $($PSVersionTable.PSVersion)"

$note = [ordered]@{
    role          = 'DC'
    adminName     = 'admin'
    inProgress    = $false
    prefix        = ''
    BlankValue    = ''
    ZeroText      = '0'
    PositiveText  = '42'
    NegativeText  = '-7'
    TrueText      = 'True'
    SizeText      = '1GB'
    VersionText   = '1.2'
}
$vm = [pscustomobject]@{
    Name  = 'DC1'
    Id    = [guid]::NewGuid()
    vmID  = [guid]::NewGuid()
    State = 'Running'
    Notes = ($note | ConvertTo-Json)
}
$vmObject = [pscustomobject]@{ vmName = 'DC1'; vmId = $vm.vmID }
Update-VMFromHyperV -vm $vm -vmObject $vmObject

Assert-Equal '' $vmObject.prefix 'blank prefix remains an empty string'
Assert-Equal 'String' $vmObject.prefix.GetType().Name 'blank prefix type remains String'
Assert-Equal '' $vmObject.BlankValue 'arbitrary blank note value remains blank'
Assert-Equal 0 $vmObject.ZeroText 'lexical zero still converts to integer'
Assert-Equal 42 $vmObject.PositiveText 'positive integer text converts to integer'
Assert-Equal (-7) $vmObject.NegativeText 'signed integer text converts to integer'
Assert-Equal $true $vmObject.TrueText 'boolean text still converts to Boolean'
Assert-Equal '1GB' $vmObject.SizeText 'size text remains string'
Assert-Equal '1.2' $vmObject.VersionText 'dotted version remains string'

$configSource = Get-Content -LiteralPath $configPath -Raw
$newDomainSource = Get-Content -LiteralPath (Join-Path $RootPath 'common\Common.GenConfig.NewDomain.ps1') -Raw
Assert-Equal $true ($configSource.Contains('Read-VMListDiskCache: repaired $repairedPrefixes numeric-zero Prefix')) 'disk-cache load repairs previously corrupted prefix values'
Assert-Equal $true ($newDomainSource.Contains('$existingPrefix -isnot [string] -and $existingPrefix -eq 0')) 'existing-domain reconstruction treats typed numeric zero as blank'

if ($script:Failures) { Write-Host "$script:Failures check(s) failed."; exit 1 }
Write-Host 'All VM-note blank-string checks passed.'