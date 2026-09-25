<#
.SYNOPSIS
    Verifies that an existing remote content library VM is added as a hidden dependency.
#>
[CmdletBinding()]
param (
    [string] $RootPath
)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }

function Import-TestFunction {
    param ([string] $Path, [string] $Name)

    $errors = $null
    $tokens = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    $parseErrors = @($errors | Where-Object { $null -ne $_ })
    if ($parseErrors.Count -ne 0) { throw "$Path has $($parseErrors.Count) parse error(s)" }
    $definitions = @($ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($definitions.Count -ne 1) { throw "Expected one $Name definition, found $($definitions.Count)" }
    return [scriptblock]::Create($definitions[0].Extent.Text)
}

$configPath = Join-Path $RootPath 'common\Common.Config.ps1'
. (Import-TestFunction -Path $configPath -Name 'Add-ExistingVMsToDeployConfig')

$script:AddedExistingVMs = [System.Collections.Generic.List[object]]::new()

function Get-List {
    param ([string] $Type, [string] $DomainName, [switch] $SmartUpdate)

    $global:vm_List_LastUpdate = Get-Date
    $global:vm_List_Dirty = $false
    return @()
}

function Get-ExistingForDomain {
    param ([string] $DomainName, [string] $Role)
    return $null
}

function Get-SiteServerForSiteCode {
    param ([object] $DeployConfig, [string] $SiteCode, [switch] $SmartUpdate)
    return $null
}

function Add-ExistingVMToDeployConfig {
    param (
        [string] $VmName,
        [object] $ConfigToModify,
        [bool] $Hidden = $false,
        [bool] $OtherDC = $false
    )

    $script:AddedExistingVMs.Add([pscustomobject]@{
            VmName = $VmName
            Hidden = $Hidden
        })
}

function Add-Phase8DistributionPointMetadata {
    param ([object] $Config, [object[]] $ExistingVMs, [bool] $InventoryRefreshVerified)
}

function Write-Log {
    param (
        [Parameter(Position = 0)]
        [string] $Message,
        [switch] $Verbose,
        [switch] $LogOnly,
        [switch] $Warning,
        [switch] $Failure
    )
}

$config = [pscustomobject]@{
    vmOptions      = [pscustomobject]@{ domainName = 'cstest2.com' }
    parameters     = [pscustomobject]@{ ExistingDCName = $null }
    virtualMachines = @(
        [pscustomobject]@{
            vmName             = 'CS2-CS1SITE-P'
            role               = 'PassiveSite'
            siteCode           = 'CS1'
            remoteContentLibVM = 'CS2-FS1'
        }
    )
}

Add-ExistingVMsToDeployConfig -Config $config

if ($script:AddedExistingVMs.Count -ne 1) {
    throw "Expected one existing dependency, found $($script:AddedExistingVMs.Count)"
}
if ($script:AddedExistingVMs[0].VmName -ne 'CS2-FS1') {
    throw "Expected CS2-FS1, found $($script:AddedExistingVMs[0].VmName)"
}
if (-not $script:AddedExistingVMs[0].Hidden) {
    throw 'Expected the remote content library dependency to be hidden'
}

Write-Host 'PASS existing remote content library VM is added as a hidden dependency'
