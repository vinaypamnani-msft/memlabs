# Focused dual-engine tests for the OSD WinPE/image-application memory floor.
[CmdletBinding()]
param([string] $RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$script:Failures = 0
$script:Messages = @()

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
function Add-ValidationMessage {
    param([string] $Message, $ReturnObject, [switch] $Failure, [switch] $Warning)
    $script:Messages += [pscustomobject]@{ Message = $Message; Failure = $Failure.IsPresent; Warning = $Warning.IsPresent }
}
function Add-ErrorMessage {
    param([string] $Message, [string] $Property, [switch] $Warning)
    $script:Messages += [pscustomobject]@{ Message = $Message; Property = $Property; Warning = $Warning.IsPresent }
}
function Test-VmIsLinux { param($Vm); return $false }

$validationPath = Join-Path $RootPath 'common\Common.Validation.ps1'
$genConfigValidationPath = Join-Path $RootPath 'common\Common.GenConfig.Validation.ps1'
$addVmPath = Join-Path $RootPath 'common\Common.GenConfig.AddVM.ps1'
. (Import-TestFunction -Path $validationPath -Name 'Test-ValidVmMemory')
. (Import-TestFunction -Path $genConfigValidationPath -Name 'Get-AdditionalValidations')
Write-Host "engine : $($PSVersionTable.PSVersion)"

$legacyOsd = [pscustomobject]@{
    vmName = 'OSD3'
    role = 'OSDClient'
    memory = '2GB'
    dynamicMinRam = '1GB'
}
$script:Messages = @()
Test-ValidVmMemory -VM $legacyOsd -ReturnObject ([pscustomobject]@{})
Assert-Equal '4GB' $legacyOsd.memory 'legacy 2GB OSD maximum is repaired to Windows 11 minimum'
Assert-Equal '4GB' $legacyOsd.dynamicMinRam 'legacy 1GB OSD dynamic floor is repaired to 4GB'
Assert-Equal 2 @($script:Messages | Where-Object Warning).Count 'both OSD repairs are reported as validation warnings'
Assert-Equal $true (($script:Messages.Message -join "`n").Contains('0x800704D3') -or ($script:Messages.Message -join "`n").Contains('image-application')) 'OSD memory warning explains deployment risk'

$compliantOsd = [pscustomobject]@{
    vmName = 'OSD4'
    role = 'OSDClient'
    memory = '4GB'
    dynamicMinRam = '4GB'
}
$script:Messages = @()
Test-ValidVmMemory -VM $compliantOsd -ReturnObject ([pscustomobject]@{})
Assert-Equal '4GB' $compliantOsd.memory 'compliant OSD maximum remains unchanged'
Assert-Equal '4GB' $compliantOsd.dynamicMinRam 'compliant OSD floor remains unchanged'
Assert-Equal 0 $script:Messages.Count 'compliant OSD memory emits no warning'

$windows10 = [pscustomobject]@{
    vmName = 'CLIENT1'
    role = 'DomainMember'
    operatingSystem = 'Windows 10 Latest (64-bit)'
    memory = '2GB'
    dynamicMinRam = '1GB'
}
$script:Messages = @()
Test-ValidVmMemory -VM $windows10 -ReturnObject ([pscustomobject]@{})
Assert-Equal '2GB' $windows10.memory 'Windows 10 memory remains unchanged'
Assert-Equal '1GB' $windows10.dynamicMinRam 'Windows 10 dynamic floor remains unchanged'

$global:Config = [pscustomobject]@{ domainDefaults = [pscustomobject]@{ UseDynamicMemory = $true } }
$editedWindows11 = [pscustomobject]@{
    vmName = 'W11CLIENT1'
    role = 'DomainMember'
    operatingSystem = 'Windows 11 Latest (64-bit)'
    memory = '2GB'
    dynamicMinRam = '1GB'
}
$script:Messages = @()
Get-AdditionalValidations -Property $editedWindows11 -Name 'memory' -CurrentValue '4GB'
Assert-Equal '4GB' $editedWindows11.memory 'GenConfig raises an entered 2GB Windows 11 client value to 4GB'
Assert-Equal 1 @($script:Messages | Where-Object Warning).Count 'GenConfig reports the persisted memory correction as a warning'
Assert-Equal 'Raised memory from [2GB] to 4GB. Windows 11/OSD clients require at least 4GB during deployment.' $script:Messages[0].Message 'GenConfig memory warning reports the persisted correction and requirement'

$editedOsd = [pscustomobject]@{
    vmName = 'OSD5'
    role = 'OSDClient'
    memory = '2GB'
}
$script:Messages = @()
Get-AdditionalValidations -Property $editedOsd -Name 'memory' -CurrentValue '4GB'
Assert-Equal '4GB' $editedOsd.memory 'GenConfig raises an entered 2GB OSD client value to 4GB'

foreach ($domainControllerRole in 'DC', 'BDC') {
    $editedDomainController = [pscustomobject]@{
        vmName = "W11$domainControllerRole"
        role = $domainControllerRole
        operatingSystem = 'Windows 11 Latest (64-bit)'
        memory = '2GB'
    }
    $script:Messages = @()
    Get-AdditionalValidations -Property $editedDomainController -Name 'memory' -CurrentValue '4GB'
    Assert-Equal '2GB' $editedDomainController.memory "GenConfig preserves the Windows 11 $domainControllerRole memory exemption"
    Assert-Equal 0 $script:Messages.Count "GenConfig emits no memory-floor warning for a Windows 11 $domainControllerRole"
}

$addVmSource = Get-Content -LiteralPath $addVmPath -Raw
Assert-Equal $true ($addVmSource.Contains('"OSDClient" {') -and $addVmSource.Contains('$virtualMachine.memory = "4GB"')) 'new OSD clients default to 4GB maximum'
Assert-Equal $true ($addVmSource.Contains("if (`$role -eq 'OSDClient') { `"4GB`" }")) 'new OSD clients default to a 4GB dynamic floor'

if ($script:Failures) { Write-Host "$script:Failures check(s) failed."; exit 1 }
Write-Host 'All OSD memory-floor checks passed.'
