<#
.SYNOPSIS
    Verifies that both SQLAO nodes inherit their ConfigMgr site code in RDCMan.
#>
[CmdletBinding()]
param([string]$RootPath)

if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }

$ErrorActionPreference = 'Stop'
$script:Failures = 0

function Assert-Equal {
    param($Expected, $Actual, [string]$What)

    $passed = $Expected -eq $Actual
    if (-not $passed) { $script:Failures++ }
    Write-Host ('{0}  {1}' -f $(if ($passed) { 'PASS' } else { 'FAIL' }), $What)
    if (-not $passed) {
        Write-Host "      Expected: $Expected"
        Write-Host "      Actual:   $Actual"
    }
}

$rdcManPath = Join-Path $RootPath 'common\Common.RdcMan.ps1'
$mRemoteNgPath = Join-Path $RootPath 'common\Common.mRemoteNG.ps1'
foreach ($functionSpec in @(
        @{ Path = $rdcManPath; Name = 'Get-RDCVmSiteCode' }
        @{ Path = $rdcManPath; Name = 'Get-RDCManDisplayName' }
        @{ Path = $mRemoteNgPath; Name = 'Get-MECMSiteHierarchy' }
    )) {
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($functionSpec.Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -ne 0) { throw "$($functionSpec.Path) has $($errors.Count) parse error(s)." }

    $definition = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionSpec.Name
            }, $true))
    if ($definition.Count -ne 1) {
        throw "Expected one $($functionSpec.Name) definition in $($functionSpec.Path), found $($definition.Count)."
    }
    . ([scriptblock]::Create($definition[0].Extent.Text))
}

$vms = @(
    [pscustomobject]@{
        vmName     = 'FAB-PS1SITE'
        Role       = 'Primary'
        SiteCode   = 'PS1'
        RemoteSQLVM = 'FAB-PS1SQLAO1'
    }
    [pscustomobject]@{
        vmName    = 'FAB-PS1SQLAO1'
        Role      = 'SQLAO'
        SqlVersion = 'SQL Server 2025'
        OtherNode = 'FAB-PS1SQLAO2'
    }
    [pscustomobject]@{
        vmName    = 'FAB-PS1SQLAO2'
        Role      = 'SQLAO'
        SqlVersion = 'SQL Server 2025'
    }
)

$settings = [pscustomobject]@{
    ShowRole       = $false
    ShowOS         = $false
    ShowSqlVersion = $false
    ShowCMVersion  = $false
    ShowSiteRoles  = $false
    ShowSiteCode   = $true
}
$hierarchy = Get-MECMSiteHierarchy -VmListFull $vms
$clientPushSiteMap = @{}

Assert-Equal 'PS1' $hierarchy.VmSiteMap['FAB-PS1SQLAO1'] 'SQLAO owner maps to the site that references it'
Assert-Equal 'PS1' $hierarchy.VmSiteMap['FAB-PS1SQLAO2'] 'SQLAO partner inherits the owner site mapping'

$primaryDisplay = Get-RDCManDisplayName -vm $vms[1] -settings $settings -siteHierarchy $hierarchy -clientPushSiteMap $clientPushSiteMap
$secondaryDisplay = Get-RDCManDisplayName -vm $vms[2] -settings $settings -siteHierarchy $hierarchy -clientPushSiteMap $clientPushSiteMap
Assert-Equal 'FAB-PS1SQLAO1 (PS1)' $primaryDisplay 'RDCMan labels the SQLAO owner with its mapped site code'
Assert-Equal 'FAB-PS1SQLAO2 (PS1)' $secondaryDisplay 'RDCMan labels the SQLAO partner with its mapped site code'

$directSiteVm = [pscustomobject]@{
    vmName        = 'FAB-PRI2'
    Role          = 'Primary'
    SiteCode      = 'P02'
    ParentSiteCode = 'CAS'
}
$directDisplay = Get-RDCManDisplayName -vm $directSiteVm -settings $settings -siteHierarchy $null -clientPushSiteMap $clientPushSiteMap
Assert-Equal 'FAB-PRI2 (P02->CAS)' $directDisplay 'Direct hierarchy labels retain the parent-site suffix'

$settings.ShowSiteCode = $false
$hiddenDisplay = Get-RDCManDisplayName -vm $vms[2] -settings $settings -siteHierarchy $hierarchy -clientPushSiteMap $clientPushSiteMap
Assert-Equal 'FAB-PS1SQLAO2' $hiddenDisplay 'ShowSiteCode still suppresses inherited site labels'

if ($script:Failures -ne 0) { throw "$script:Failures RDCMan SQLAO site-code assertion(s) failed." }
Write-Host 'PASS  RDCMan SQLAO site-code tests completed'
