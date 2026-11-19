<#
.SYNOPSIS
    Verifies GenConfig VM memory edits and memory floors for WSUS and Software Update Point databases.
#>
[CmdletBinding()]
param([string] $RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$cmMenusPath = Join-Path $RootPath 'common\Common.GenConfig.CmMenus.ps1'
$diskMenuPath = Join-Path $RootPath 'common\Common.GenConfig.DiskMenu.ps1'
$validationPath = Join-Path $RootPath 'common\Common.GenConfig.Validation.ps1'

function Import-TestFunction {
    param([string] $Path, [string] $Name)

    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref] $tokens, [ref] $errors)
    if ($errors.Count) { throw "$Path has parse errors: $($errors -join '; ')" }
    $functions = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($functions.Count -ne 1) { throw "Expected one $Name definition, found $($functions.Count)." }
    [scriptblock]::Create($functions[0].Extent.Text)
}

function Assert-Equal {
    param($Expected, $Actual, [string] $Message)

    if ("$Expected" -ne "$Actual") {
        throw "$Message`nExpected: $Expected`nActual:   $Actual"
    }
}

. (Import-TestFunction -Path $cmMenusPath -Name 'Set-WsusMemoryFloor')
. (Import-TestFunction -Path $cmMenusPath -Name 'Get-WsusDBName')
. (Import-TestFunction -Path $diskMenuPath -Name 'Get-VMDiskLetters')
. (Import-TestFunction -Path $diskMenuPath -Name 'Get-NextDiskLetter')
. (Import-TestFunction -Path $diskMenuPath -Name 'Set-WsusDedicatedContentDisk')
. (Import-TestFunction -Path $validationPath -Name 'Get-AdditionalValidations')
. (Import-TestFunction -Path $validationPath -Name 'Get-GenConfigSiteServer')

function Get-ParentSiteServerForSiteCode {
    param($deployConfig, $siteCode, $type, [bool] $SmartUpdate)
    [pscustomobject]@{ SiteCode = $null }
}

function Get-List2 {
    param($deployConfig)
    [pscustomobject]@{
        vmName     = 'PS1SITE'
        Role       = 'Primary'
        SiteCode   = 'PS1'
        InstallSUP = $script:ActiveSiteServer.InstallSUP
    }
}

function Get-ActiveSiteServerForSiteCode {
    param($deployConfig, $SiteCode, $type)
    $script:ActiveSiteServer
}

function Get-SqlServerForSiteCode {
    param($siteCode, $deployConfig, $type)
    $script:SiteSqlServer
}

function Rename-VirtualMachine {
    param($vm)
}

function Get-SiteCodeMenu {
    throw 'The test fixture should already have a site code.'
}

function Add-ErrorMessage {
    param($message, $property, [switch] $Warning)
    if (-not $Warning) { throw "Unexpected GenConfig error: $message" }
    $script:Warnings += [pscustomobject]@{ property = $property; Message = $message }
}

function Get-Menu2 {
    param(
        $MenuName,
        $Prompt,
        $OptionArray,
        $CurrentValue,
        [bool] $Test,
        $additionalOptions,
        [switch] $return
    )
    'W'
}

$global:Config = [pscustomobject]@{
    domainDefaults  = [pscustomobject]@{ IncludeSSMSOnNONSQL = $false; UseDynamicMemory = $false }
    virtualMachines = @()
}
$script:Warnings = @()

$script:ActiveSiteServer = [pscustomobject]@{ InstallSUP = $true }
$script:SiteSqlServer = [pscustomobject]@{ InstallSUP = $false; vmName = 'PS1SQL' }
$widSup = [pscustomobject]@{
    vmName          = 'PS1SUP1'
    Role            = 'SiteSystem'
    SiteCode        = 'PS1'
    InstallSUP      = $true
    Memory          = '5GB'
    additionalDisks = [pscustomobject]@{ E = '250GB' }
}
Get-AdditionalValidations -property $widSup -name 'installSUP' -CurrentValue $false
Assert-Equal 'WID' $widSup.wsusDataBaseServer 'Enabling a WID SUP did not select WID.'
Assert-Equal '8GB' $widSup.Memory 'Enabling a WID SUP did not raise memory to the safe 8GB floor.'

$script:ActiveSiteServer = [pscustomobject]@{ InstallSUP = $false }
$remoteSqlSup = [pscustomobject]@{
    vmName          = 'PS1SUP2'
    Role            = 'SiteSystem'
    SiteCode        = 'PS1'
    InstallSUP      = $true
    Memory          = '4GB'
    additionalDisks = [pscustomobject]@{ E = '250GB' }
}
Get-AdditionalValidations -property $remoteSqlSup -name 'installSUP' -CurrentValue $false
Assert-Equal 'PS1SQL' $remoteSqlSup.wsusDataBaseServer 'Enabling a remote-SQL SUP selected the wrong database.'
Assert-Equal '5GB' $remoteSqlSup.Memory 'A remote-SQL SUP did not retain the existing 5GB memory floor.'

$script:SiteSqlServer = $null
$missingSqlSup = [pscustomobject]@{
    vmName          = 'PS1SUP4'
    Role            = 'SiteSystem'
    SiteCode        = 'PS1'
    InstallSUP      = $true
    Memory          = '4GB'
    additionalDisks = [pscustomobject]@{ E = '250GB' }
}
Get-AdditionalValidations -property $missingSqlSup -name 'installSUP' -CurrentValue $false
Assert-Equal 'WID' $missingSqlSup.wsusDataBaseServer 'Enabling a SUP with a missing site SQL VM selected an empty database server.'
Assert-Equal '8GB' $missingSqlSup.Memory 'A SUP with a missing site SQL VM did not receive the WID memory floor.'

$switchToWid = [pscustomobject]@{
    vmName             = 'PS1SUP3'
    Role               = 'SiteSystem'
    SiteCode           = 'PS1'
    Memory             = '5GB'
    wsusDataBaseServer = 'PS1SQL'
}
Get-WsusDBName -property $switchToWid -name 'wsusDataBaseServer' -CurrentValue 'PS1SQL'
Assert-Equal 'WID' $switchToWid.wsusDataBaseServer 'Selecting WID did not update the WSUS database.'
Assert-Equal '8GB' $switchToWid.Memory 'Switching an existing SUP to WID did not raise memory to 8GB.'

$alreadySized = [pscustomobject]@{ Memory = '12GB' }
Set-WsusMemoryFloor -property $alreadySized -UsesWID $true
Assert-Equal '12GB' $alreadySized.Memory 'The WID floor reduced an explicitly larger memory value.'

Assert-Equal 0 $script:Warnings.Count 'WSUS/SUP memory floors emitted an unexpected warning.'

foreach ($useDynamicMemory in $false, $true) {
    $global:Config.domainDefaults.UseDynamicMemory = $useDynamicMemory
    foreach ($case in @(
            @{ Before = '2GB'; Entered = '4GB'; Minimum = '1GB'; ExpectedMemory = '4GB'; ExpectedMinimum = '1GB'; Warnings = 0 },
            @{ Before = '4GB'; Entered = '2GB'; Minimum = '1GB'; ExpectedMemory = '2GB'; ExpectedMinimum = '1GB'; Warnings = 0 },
            @{ Before = '4GB'; Entered = '1GB'; Minimum = '1GB'; ExpectedMemory = '1GB'; ExpectedMinimum = '1GB'; Warnings = 0 },
            @{ Before = '4GB'; Entered = '1024mb'; Minimum = '2GB'; ExpectedMemory = '1024MB'; ExpectedMinimum = '1024MB'; Warnings = 1 },
            @{ Before = '2GB'; Entered = '4'; Minimum = '512MB'; ExpectedMemory = '4GB'; ExpectedMinimum = '512MB'; Warnings = 0 },
            @{ Before = '4GB'; Entered = '8GB'; Minimum = '4GB'; ExpectedMemory = '8GB'; ExpectedMinimum = '4GB'; Warnings = 0 },
            @{ Before = '4GB'; Entered = '8GB'; Minimum = $null; ExpectedMemory = '8GB'; ExpectedMinimum = $null; Warnings = 0 },
            @{ Before = '8GB'; Entered = '2GB'; Minimum = '3GB'; ExpectedMemory = '4GB'; ExpectedMinimum = '3GB'; Warnings = 1; OperatingSystem = 'Windows 11 Latest' },
            @{ Before = '8GB'; Entered = '2GB'; Minimum = '6GB'; ExpectedMemory = '4GB'; ExpectedMinimum = '4GB'; Warnings = 2; OperatingSystem = 'Windows 11 Latest' },
            @{ Before = '4GB'; Entered = '128GB'; Minimum = '1GB'; ExpectedMemory = '4GB'; ExpectedMinimum = '1GB'; Warnings = 1 }
        )) {
        $script:Warnings = @()
        $vm = [pscustomobject]@{
            vmName          = 'MEM1'
            Role            = 'DomainMember'
            OperatingSystem = $case.OperatingSystem
            Memory          = $case.Entered
        }
        if ($null -ne $case.Minimum) {
            $vm | Add-Member -NotePropertyName 'dynamicMinRam' -NotePropertyValue $case.Minimum
        }
        $context = "Memory $($case.Before) -> $($case.Entered), minimum $($case.Minimum), UseDynamicMemory=$useDynamicMemory."
        Get-AdditionalValidations -property $vm -name 'memory' -CurrentValue $case.Before
        Assert-Equal $case.ExpectedMemory $vm.Memory "$context Startup/maximum memory changed unexpectedly."
        Assert-Equal $case.ExpectedMinimum $vm.dynamicMinRam "$context The per-VM minimum was not preserved or clamped correctly."
        Assert-Equal $case.Warnings $script:Warnings.Count "$context An expected warning was missing or an unexpected warning was emitted."
        Assert-Equal $null $vm.PSObject.Properties['dynamicMinRam-Original'] "$context A new VM received existing-VM change tracking."
        if ($null -eq $case.Minimum) {
            Assert-Equal $false ($null -ne $vm.PSObject.Properties['dynamicMinRam']) "$context Editing maximum memory added a minimum property."
        }
        elseif ($case.ExpectedMinimum -ne $case.Minimum) {
            $minimumWarnings = @($script:Warnings | Where-Object property -eq 'dynamicMinRam')
            Assert-Equal 1 $minimumWarnings.Count "$context The minimum adjustment warning identified the wrong property."
            Assert-Equal $true ($minimumWarnings[0].Message -like "*$($case.Minimum)*$($case.ExpectedMinimum)*") "$context The warning omitted the previous or adjusted minimum."
            $script:Warnings = @()
            Get-AdditionalValidations -property $vm -name 'memory' -CurrentValue $vm.Memory
            Assert-Equal $case.ExpectedMinimum $vm.dynamicMinRam "$context Repeating the normalized edit changed the minimum."
            Assert-Equal 0 $script:Warnings.Count "$context Repeating the normalized edit emitted another warning."
        }
    }
}

Write-Host 'PASS: GenConfig preserves valid per-VM minimum memory, clamps excessive minimums, and applies safe WSUS/SUP memory floors.' -ForegroundColor Green
