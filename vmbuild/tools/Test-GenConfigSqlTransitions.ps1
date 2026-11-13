<#
.SYNOPSIS
    Verifies GenConfig transitions from remote SQL back to local SQL.
#>
[CmdletBinding()]
param([string] $RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$cmMenusPath = Join-Path $RootPath 'common\Common.GenConfig.CmMenus.ps1'
$vmListPath = Join-Path $RootPath 'common\Common.GenConfig.VMList.ps1'
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

. (Import-TestFunction -Path $cmMenusPath -Name 'Set-SiteServerLocalSql')
. (Import-TestFunction -Path $cmMenusPath -Name 'Set-SiteServerRemoteSQL')
. (Import-TestFunction -Path $cmMenusPath -Name 'Get-remoteSQLVM')
. (Import-TestFunction -Path $vmListPath -Name 'Remove-VMFromConfig')
. (Import-TestFunction -Path $validationPath -Name 'Get-GenConfigSqlVM')

function Write-Log {
    param([string] $Message, [switch] $Warning, [switch] $Activity, [switch] $NoNewLine)

    if ($Warning) { $script:Warnings += $Message }
}

function Get-Menu2 {
    param($MenuName, $Prompt, $OptionArray, $CurrentValue, [bool] $Test, $additionalOptions, [switch] $return)
    'L'
}

function Get-TestResult {
    param([switch] $SuccessOnWarning)
    $true
}

function New-TestConfig {
    param([string] $Role = 'Primary', [switch] $SqlAo)

    $site = [pscustomobject]@{
        vmName             = 'PS1SITE'
        Role               = $Role
        SiteCode           = 'PS1'
        sqlVersion         = 'SQL Server 2022'
        sqlInstanceName    = 'MSSQLSERVER'
        sqlInstanceDir     = 'F:\SQL'
        sqlPort            = '1433'
        installSSMS        = $true
        virtualProcs       = 8
        memory             = '10GB'
        dynamicMinRam      = '4GB'
        additionalDisks    = [pscustomobject]@{ E = '600GB'; F = '100GB' }
        InstallSUP         = $true
        wsusDataBaseServer = 'PS1SITE'
    }
    $sql = [pscustomobject]@{
        vmName     = 'PS1SQL'
        Role       = 'DomainMember'
        sqlVersion = 'SQL Server 2022'
    }
    $vms = @($site, $sql, [pscustomobject]@{ vmName = 'DC1'; Role = 'DC' })
    if ($SqlAo) {
        $sql.Role = 'SQLAO'
        $sql | Add-Member -MemberType NoteProperty -Name OtherNode -Value 'PS1SQL2'
        $vms += [pscustomobject]@{ vmName = 'PS1SQL2'; Role = 'SQLAO'; sqlVersion = 'SQL Server 2022' }
    }
    [pscustomobject]@{
        domainDefaults  = [pscustomobject]@{
            DefaultSqlVersion   = 'SQL Server 2022'
            IncludeSSMSOnNONSQL = $false
            UseDynamicMemory   = $false
        }
        virtualMachines = $vms
    }
}

$originalConfig = $global:Config
try {
    $script:Warnings = @()
    $global:Config = New-TestConfig
    $site = $global:Config.virtualMachines[0]
    Set-SiteServerRemoteSQL -virtualMachine $site -vmName 'PS1SQL'
    Remove-VMFromConfig -vmName 'PS1SQL'
    $site = $global:Config.virtualMachines | Where-Object vmName -eq 'PS1SITE'
    Assert-Equal 'PS1SQL' $site.remoteSQLVM 'The fixture must retain the deleted remote SQL reference before recovery.'
    Get-remoteSQLVM -property $site
    Assert-Equal 'SQL Server 2022' $site.sqlVersion 'Selecting local SQL after deleting the remote VM did not restore SQL.'
    Assert-Equal $null $site.PSObject.Properties['remoteSQLVM'] 'Recovery retained a stale remote SQL property.'
    Assert-Equal 'PS1SITE' $site.wsusDataBaseServer 'Recovery retained the deleted SQL VM as the SUP database.'
    Assert-Equal 2 $global:Config.virtualMachines.Count 'Recovery removed an unrelated VM.'
    Assert-Equal 1 $script:Warnings.Count 'Recovery should report that the remote SQL VM was already removed.'
    Assert-Equal $true ($script:Warnings[0] -like '*PS1SQL*') 'The recovery warning did not identify the missing SQL VM.'

    foreach ($role in @('Primary', 'CAS')) {
        $global:Config = New-TestConfig -Role $role
        $site = $global:Config.virtualMachines[0]
        $dc = $global:Config.virtualMachines[2]
        Set-SiteServerRemoteSQL -virtualMachine $site -vmName 'PS1SQL'
        Assert-Equal 'PS1SQL' $site.wsusDataBaseServer 'Selecting remote SQL did not move the local SUP database reference.'
        Get-remoteSQLVM -property $site
        Assert-Equal 2 $global:Config.virtualMachines.Count 'Selecting local SQL did not remove the previous remote SQL VM.'
        Assert-Equal 'PS1SITE' $site.wsusDataBaseServer 'Selecting local SQL did not move the SUP database reference back.'
        Assert-Equal 'MSSQLSERVER' $site.sqlInstanceName 'Selecting local SQL did not restore the default instance.'
        Assert-Equal 'F:\SQL' $site.sqlInstanceDir 'Selecting local SQL did not restore the SQL directory.'
        Assert-Equal '1433' $site.sqlPort 'Selecting local SQL did not restore the SQL port.'
        Assert-Equal 'LocalSystem' $site.SqlServiceAccount 'Selecting local SQL did not restore the SQL service account.'
        Assert-Equal 'LocalSystem' $site.SqlAgentAccount 'Selecting local SQL did not restore the SQL agent account.'
        Assert-Equal $true $site.installSSMS 'Selecting local SQL did not restore SSMS.'
        Assert-Equal $true ([object]::ReferenceEquals($site, $global:Config.virtualMachines[0])) 'SQL removal detached the active site-server object.'
        Assert-Equal $true ([object]::ReferenceEquals($dc, $global:Config.virtualMachines[1])) 'SQL removal replaced an unrelated VM object.'
        $site.InstallSUP = $false
        Assert-Equal $false $global:Config.virtualMachines[0].InstallSUP 'Edits after SQL removal did not persist in the configuration.'
        Set-SiteServerLocalSql -virtualMachine $site
        Assert-Equal 2 $global:Config.virtualMachines.Count 'Selecting local SQL twice changed the remaining VMs.'
    }

    $global:Config = New-TestConfig -SqlAo
    $site = $global:Config.virtualMachines[0]
    Set-SiteServerRemoteSQL -virtualMachine $site -vmName 'PS1SQL'
    Assert-Equal 'WID' $site.wsusDataBaseServer 'SQL Always On should keep WSUS on WID.'
    Get-remoteSQLVM -property $site
    Assert-Equal 'WID' $site.wsusDataBaseServer 'Selecting local SQL unexpectedly changed an explicit WID database.'
    Assert-Equal 2 $global:Config.virtualMachines.Count 'Selecting local SQL did not remove both SQL Always On nodes.'
    Assert-Equal 0 @($global:Config.virtualMachines | Where-Object Role -eq 'SQLAO').Count 'A SQL Always On node survived the local SQL transition.'
    Assert-Equal $true ([object]::ReferenceEquals($site, $global:Config.virtualMachines[0])) 'Removing SQL Always On detached the site-server object.'

    foreach ($remoteName in @($null, '', ' ')) {
        $global:Config = New-TestConfig
        $site = $global:Config.virtualMachines[0]
        $site | Add-Member -MemberType NoteProperty -Name remoteSQLVM -Value $remoteName
        Set-SiteServerLocalSql -virtualMachine $site
        Assert-Equal $null $site.PSObject.Properties['remoteSQLVM'] 'Selecting local SQL retained an empty remote SQL property.'
        Assert-Equal 3 $global:Config.virtualMachines.Count 'An empty remote SQL reference removed another VM.'
    }

    $global:Config = New-TestConfig
    $site = $global:Config.virtualMachines[0]
    $site.wsusDataBaseServer = ''
    Set-SiteServerLocalSql -virtualMachine $site
    Assert-Equal 'PS1SITE' $site.wsusDataBaseServer 'Selecting local SQL left an enabled SUP with an empty database server.'
    $site.wsusDataBaseServer = 'OtherWSUSSQL'
    Set-SiteServerLocalSql -virtualMachine $site
    Assert-Equal 'OtherWSUSSQL' $site.wsusDataBaseServer 'Selecting local SQL overwrote an unrelated WSUS database selection.'

    $global:Config = New-TestConfig -Role 'CAS'
    $cas = $global:Config.virtualMachines[0]
    $cas | Add-Member -MemberType NoteProperty -Name cmOptions -Value ([pscustomobject]@{ Version = 'CurrentBranch'; UsePKI = $true })
    $firstChild = [pscustomobject]@{ vmName = 'PS2SITE'; Role = 'Primary'; ParentSiteCode = 'PS1' }
    $secondChild = [pscustomobject]@{ vmName = 'PS3SITE'; Role = 'Primary'; ParentSiteCode = 'PS1' }
    $global:Config.virtualMachines = @($cas, $firstChild, $secondChild)
    Remove-VMFromConfig -vmName 'PS1SITE'
    Assert-Equal $null $firstChild.ParentSiteCode 'Removing a CAS did not clear the child parent-site reference.'
    Assert-Equal 'CurrentBranch' $firstChild.cmOptions.Version 'Removing a CAS did not preserve the inherited CM options.'
    $firstChild.cmOptions.Version = 'Changed'
    Assert-Equal 'CurrentBranch' $secondChild.cmOptions.Version 'Removing a CAS shared mutable CM options between its children.'

    Write-Host 'PASS: GenConfig recovers missing SQL references, preserves SUP database choices and keeps VM edits attached.' -ForegroundColor Green
}
finally {
    $global:Config = $originalConfig
}
