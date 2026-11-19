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
function New-ValidationResult {
    [pscustomobject]@{
        Problems = 0
        Failures = 0
        Warnings = 0
        Message = [System.Text.StringBuilder]::new()
        Informational = 0
        InfoMessage = [System.Text.StringBuilder]::new()
    }
}
function Write-Log { param([string] $Message, [switch] $Verbose, [switch] $LogOnly) }
function Add-ErrorMessage {
    param([string] $Message, [string] $Property, [switch] $Warning)
    $script:Messages += [pscustomobject]@{ Message = $Message; Property = $Property; Warning = $Warning.IsPresent }
}
function Test-VmIsLinux { param($Vm); return $false }

$validationPath = Join-Path $RootPath 'common\Common.Validation.ps1'
$genConfigValidationPath = Join-Path $RootPath 'common\Common.GenConfig.Validation.ps1'
$addVmPath = Join-Path $RootPath 'common\Common.GenConfig.AddVM.ps1'
. (Import-TestFunction -Path $validationPath -Name 'Add-ValidationMessage')
. (Import-TestFunction -Path $validationPath -Name 'Test-ValidVmMemory')
. (Import-TestFunction -Path $genConfigValidationPath -Name 'Get-AdditionalValidations')
Write-Host "engine : $($PSVersionTable.PSVersion)"

$legacyOsd = [pscustomobject]@{
    vmName = 'OSD3'
    role = 'OSDClient'
    memory = '2GB'
    dynamicMinRam = '1GB'
}
$legacyResult = New-ValidationResult
Test-ValidVmMemory -VM $legacyOsd -ReturnObject $legacyResult
Assert-Equal '4GB' $legacyOsd.memory 'legacy 2GB OSD maximum is repaired to Windows 11 minimum'
Assert-Equal '4GB' $legacyOsd.dynamicMinRam 'legacy 1GB OSD dynamic floor is repaired to 4GB'
Assert-Equal 0 $legacyResult.Problems 'successful OSD memory repairs do not block validation'
Assert-Equal 0 $legacyResult.Warnings 'successful OSD memory repairs are not blocking warnings'
Assert-Equal '' ($legacyResult.Message.ToString()) 'successful OSD memory repairs do not enter the error display'
Assert-Equal 2 $legacyResult.Informational 'both OSD repairs are reported as informational advisories'
Assert-Equal $true ($legacyResult.InfoMessage.ToString().Contains('image-application')) 'OSD memory advisory explains deployment risk'

$lowFloorOsd = [pscustomobject]@{
    vmName = 'ADA-OSD1'
    role = 'OSDClient'
    memory = '4GB'
    dynamicMinRam = '1GB'
}
$floorResult = New-ValidationResult
Test-ValidVmMemory -VM $lowFloorOsd -ReturnObject $floorResult
Assert-Equal '4GB' $lowFloorOsd.memory 'an adequate OSD maximum remains unchanged while repairing its floor'
Assert-Equal '4GB' $lowFloorOsd.dynamicMinRam 'an OSD floor below an adequate maximum is repaired'
Assert-Equal 0 $floorResult.Problems 'a dynamic-floor-only repair does not fail validation'
Assert-Equal 1 $floorResult.Informational 'a dynamic-floor-only repair is reported as an advisory'

$compliantOsd = [pscustomobject]@{
    vmName = 'OSD4'
    role = 'OSDClient'
    memory = '4GB'
    dynamicMinRam = '4GB'
}
$compliantResult = New-ValidationResult
Test-ValidVmMemory -VM $compliantOsd -ReturnObject $compliantResult
Assert-Equal '4GB' $compliantOsd.memory 'compliant OSD maximum remains unchanged'
Assert-Equal '4GB' $compliantOsd.dynamicMinRam 'compliant OSD floor remains unchanged'
Assert-Equal 0 $compliantResult.Problems 'compliant OSD memory has no validation problems'
Assert-Equal 0 $compliantResult.Informational 'compliant OSD memory emits no repair advisory'

$invalidOsd = [pscustomobject]@{
    vmName = 'INVALIDOSD'
    role = 'OSDClient'
    memory = '*GB'
    dynamicMinRam = '1GB'
}
$invalidResult = New-ValidationResult
Test-ValidVmMemory -VM $invalidOsd -ReturnObject $invalidResult
Assert-Equal '*GB' $invalidOsd.memory 'invalid OSD memory is not silently replaced'
Assert-Equal 1 $invalidResult.Failures 'invalid OSD memory remains a blocking validation failure'
Assert-Equal 1 $invalidResult.Problems 'invalid OSD memory still blocks deployment'
Assert-Equal $true ($invalidResult.Message.ToString().Contains('Specify a whole number')) 'invalid OSD memory retains its actionable error'

$windows10 = [pscustomobject]@{
    vmName = 'CLIENT1'
    role = 'DomainMember'
    operatingSystem = 'Windows 10 Latest (64-bit)'
    memory = '2GB'
    dynamicMinRam = '1GB'
}
Test-ValidVmMemory -VM $windows10 -ReturnObject (New-ValidationResult)
Assert-Equal '2GB' $windows10.memory 'Windows 10 memory remains unchanged'
Assert-Equal '1GB' $windows10.dynamicMinRam 'Windows 10 dynamic floor remains unchanged'

$windows11 = [pscustomobject]@{
    vmName = 'W11CLIENT1'
    role = 'DomainMember'
    operatingSystem = 'Windows 11 Latest (64-bit)'
    memory = '2GB'
    dynamicMinRam = '1GB'
}
$windows11Result = New-ValidationResult
Test-ValidVmMemory -VM $windows11 -ReturnObject $windows11Result
Assert-Equal '4GB' $windows11.memory 'Windows 11 memory is repaired to 4GB'
Assert-Equal '1GB' $windows11.dynamicMinRam 'the OSD dynamic-floor repair does not affect a normal Windows 11 client'
Assert-Equal 0 $windows11Result.Problems 'the shared Windows 11 memory repair does not block validation'
Assert-Equal 1 $windows11Result.Informational 'the shared Windows 11 memory repair is reported as an advisory'

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

. (Import-TestFunction -Path $addVmPath -Name 'Add-NewVMForRole')
function Set-DefaultLocaleForVM {
    param($ConfigToCheck, $VirtualMachine, [switch] $RequireAvailable)
}
foreach ($useDynamicMemory in $false, $true) {
    $defaults = [pscustomobject]@{
        vmOptions = [pscustomobject]@{ prefix = 'OSD-'; domainName = 'osd.test' }
        domainDefaults = [pscustomobject]@{ UseDynamicMemory = $useDynamicMemory }
        virtualMachines = @()
    }
    Add-NewVMForRole -Role 'OSDClient' -Domain 'osd.test' -Name 'OSD1' `
        -OperatingSystem 'Windows 11 Latest (64-bit)' -ConfigToModify $defaults -Quiet $true -Test $true
    Assert-Equal 1 $defaults.virtualMachines.Count "one OSD client is generated with UseDynamicMemory=$useDynamicMemory"
    Assert-Equal '4GB' $defaults.virtualMachines[0].memory "new OSD clients default to 4GB with UseDynamicMemory=$useDynamicMemory"
    Assert-Equal '4GB' $defaults.virtualMachines[0].dynamicMinRam "new OSD clients default to static memory with UseDynamicMemory=$useDynamicMemory"
}

if ($script:Failures) { Write-Host "$script:Failures check(s) failed."; exit 1 }
Write-Host 'All OSD memory-floor checks passed.'
