# Focused dual-engine tests for GenConfig VM summary formatting.
[CmdletBinding()]
param([string] $RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$script:Failures = 0

function Assert-Equal {
    param($Expected, $Actual, [string] $What)
    $passed = "$Expected" -eq "$Actual"
    if (-not $passed) { $script:Failures++ }
    Write-Host ('{0}  {1}' -f $(if ($passed) { 'PASS' } else { 'FAIL' }), $What)
    if (-not $passed) { Write-Host "      expected: $Expected`n      actual:   $Actual" }
}

function Import-TestFunction {
    param([string] $Path, [string] $Name)
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if (@($errors).Count) { throw "$Path has parse errors" }
    $definition = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($definition.Count -ne 1) { throw "Expected one $Name definition" }
    return [scriptblock]::Create($definition[0].Extent.Text)
}

function get-IsExistingVMModified { param($virtualMachine); return $false }
function get-list2 { param($deployConfig); return @($deployConfig.virtualMachines) }
function Test-VmIsLinux { param($Vm); return $false }
function write-log { param($Message, [switch] $Verbose) }

$summaryPath = Join-Path $RootPath 'common\Common.GenConfig.Summary.ps1'
. (Import-TestFunction -Path $summaryPath -Name 'get-VMString')
Write-Host "engine : $($PSVersionTable.PSVersion)"
$testBufferSize = $host.UI.RawUI.BufferSize
$testBufferSize.Width = 240
$host.UI.RawUI.BufferSize = $testBufferSize
$testWindowSize = $host.UI.RawUI.WindowSize
$testWindowSize.Width = 240
$host.UI.RawUI.WindowSize = $testWindowSize

$global:Common = [pscustomobject]@{
    Colors = [pscustomobject]@{
        GenConfigNormal = 'Gray'
        GenConfigNormalNumber = 7
    }
}
$config = [pscustomobject]@{
    vmOptions = [pscustomobject]@{ Prefix = ''; Network = '192.168.2.0' }
    virtualMachines = @()
}
$osd = [pscustomobject]@{
    vmName = 'OSD2'
    role = 'OSDClient'
    memory = '2GB'
    dynamicMinRam = '1GB'
    virtualProcs = 2
    BitLocker = $true
}
$config.virtualMachines = @($osd)
$global:Config = $config
$global:VMStringCache = @{}

$withoutOs = get-VMString -config $config -virtualMachine $osd
Assert-Equal $true ($withoutOs.Contains('VM [1GB-2GB RAM, 2 CPU] [BL]')) 'OSD client without an image OS has no empty comma field'
Assert-Equal $false ($withoutOs.Contains('CPU, ]')) 'OSD summary never renders comma-blank before the closing bracket'

$osd | Add-Member -MemberType NoteProperty -Name OperatingSystem -Value 'Windows 11 Latest' -Force
$withOs = get-VMString -config $config -virtualMachine $osd
Assert-Equal $true ($withOs.Contains('VM [1GB-2GB RAM, 2 CPU, Windows 11 Latest] [BL]')) 'configured operating system remains visible'
Assert-Equal 2 $global:VMStringCache.Count 'format cache separates changed VM content'

# A stale entry from the old formatter must not be selected by the versioned key.
$global:VMStringCache = @{ 'legacy-key' = 'OSD2 VM [1GB-2GB RAM, 2 CPU, ] [BL]' }
$osd.PSObject.Properties.Remove('OperatingSystem')
$afterLegacyCache = get-VMString -config $config -virtualMachine $osd
Assert-Equal $false ($afterLegacyCache.Contains('CPU, ]')) 'versioned cache ignores a pre-fix formatter entry'

if ($script:Failures) { Write-Host "$script:Failures check(s) failed."; exit 1 }
Write-Host 'All GenConfig VM summary checks passed.'
