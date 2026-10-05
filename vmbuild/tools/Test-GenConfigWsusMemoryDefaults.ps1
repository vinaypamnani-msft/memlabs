<#
.SYNOPSIS
    Verifies GenConfig memory floors for WSUS and Software Update Point databases.
#>
[CmdletBinding()]
param([string] $RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$cmMenusPath = Join-Path $RootPath 'common\Common.GenConfig.CmMenus.ps1'
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
. (Import-TestFunction -Path $validationPath -Name 'Get-AdditionalValidations')

function Get-ParentSiteServerForSiteCode {
    param($deployConfig, $siteCode, $type, [bool] $SmartUpdate)
    [pscustomobject]@{ SiteCode = $null }
}

function Get-List2 {
    param($deployConfig)
    @()
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
    throw "Unexpected GenConfig error: $message"
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
    domainDefaults  = [pscustomobject]@{ IncludeSSMSOnNONSQL = $false }
    virtualMachines = @()
}

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

Write-Host 'PASS: GenConfig applies safe WSUS/SUP memory floors for WID and remote SQL.' -ForegroundColor Green
