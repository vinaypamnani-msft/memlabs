<#
.SYNOPSIS
    Compiles Phase 4 and Phase 5 and verifies locale-independent SQL sysadmin convergence.

.DESCRIPTION
    Run on a DSC build host under Windows PowerShell 5.1 with an expanded deployConfig.json.
    The test uses a dummy compile-only credential and removes all generated MOFs.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string] $DeployConfigPath,

    [string] $RootPath
)

$ErrorActionPreference = 'Stop'
$script:Failures = 0

if ($PSVersionTable.PSEdition -ne 'Desktop') {
    throw 'Test-SqlSysadminSidConvergence.ps1 must run under Windows PowerShell 5.1.'
}
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$DeployConfigPath = (Resolve-Path -LiteralPath $DeployConfigPath -ErrorAction Stop).Path

function Assert-SqlSidConvergence {
    param([bool] $Condition, [string] $What)

    if (-not $Condition) { $script:Failures++ }
    Write-Host ('{0}  {1}' -f $(if ($Condition) { 'PASS' } else { 'FAIL' }), $What)
}

function Get-MofResourceBlock {
    param([string] $Text, [string] $ResourceId)

    return @([regex]::Matches($Text, '(?ms)^instance of\s+\S+\s+as\s+\$\S+.*?^\};') |
        ForEach-Object { $_.Value } |
        Where-Object { $_ -match [regex]::Escape("ResourceID = `"$ResourceId`"") })
}

$phase4Output = Join-Path ([IO.Path]::GetTempPath()) ('memlabs-phase4-sqlsid-' + [guid]::NewGuid().ToString('N'))
$phase5Output = Join-Path ([IO.Path]::GetTempPath()) ('memlabs-phase5-sqlsid-' + [guid]::NewGuid().ToString('N'))
$originalModulePath = $env:PSModulePath

try {
    $env:PSModulePath = @("$env:ProgramFiles\WindowsPowerShell\Modules", "$PSHOME\Modules") -join ';'

    . (Join-Path $RootPath 'common\Common.Phases.ps1')
    . (Join-Path $RootPath 'DSC\phases\Phase4.ps1')
    . (Join-Path $RootPath 'DSC\phases\Phase5.ps1')

    $deployConfig = Get-Content -LiteralPath $DeployConfigPath -Raw | ConvertFrom-Json -ErrorAction Stop
    $phase4Data = Get-Phase4ConfigurationData -DeployConfig $deployConfig
    $phase5Data = Get-Phase5ConfigurationData -DeployConfig $deployConfig
    $phase4SqlNodes = @($deployConfig.virtualMachines | Where-Object { $_.sqlVersion } | ForEach-Object { $_.vmName })
    $phase5SqlNodes = @($phase5Data.AllNodes | Where-Object { $_.Role -in @('ClusterNode1', 'ClusterNode2') } | ForEach-Object { $_.NodeName })

    Assert-SqlSidConvergence -Condition ($phase4SqlNodes.Count -gt 0) -What "Phase 4 config contains SQL nodes (count=$($phase4SqlNodes.Count))"
    Assert-SqlSidConvergence -Condition ($phase5SqlNodes.Count -gt 0) -What "Phase 5 config contains SQL AO nodes (count=$($phase5SqlNodes.Count))"
    if ($phase4SqlNodes.Count -eq 0 -or $phase5SqlNodes.Count -eq 0) {
        throw 'The supplied deployment config did not produce applicable SQL nodes; no MOFs were measured.'
    }

    $securePassword = New-Object Security.SecureString
    $securePassword.AppendChar('x')
    $securePassword.MakeReadOnly()
    $compileCredential = New-Object Management.Automation.PSCredential('vmbuildadmin', $securePassword)
    Phase4 -DeployConfigPath $DeployConfigPath -Admincreds $compileCredential -ConfigurationData $phase4Data -OutputPath $phase4Output -ErrorAction Stop | Out-Null
    Phase5 -DeployConfigPath $DeployConfigPath -Admincreds $compileCredential -ConfigurationData $phase5Data -OutputPath $phase5Output -ErrorAction Stop | Out-Null

    $phase4Mofs = @(Get-ChildItem -LiteralPath $phase4Output -Filter '*.mof' -File)
    $phase5Mofs = @(Get-ChildItem -LiteralPath $phase5Output -Filter '*.mof' -File)
    Assert-SqlSidConvergence -Condition ($phase4Mofs.Count -gt 0) -What "Phase 4 compiled nonzero MOFs (count=$($phase4Mofs.Count))"
    Assert-SqlSidConvergence -Condition ($phase5Mofs.Count -gt 0) -What "Phase 5 compiled nonzero MOFs (count=$($phase5Mofs.Count))"

    foreach ($nodeName in $phase4SqlNodes) {
        $mofPath = Join-Path $phase4Output "$nodeName.mof"
        Assert-SqlSidConvergence -Condition (Test-Path -LiteralPath $mofPath -PathType Leaf) -What "Phase 4 compiled $nodeName.mof"
        if (-not (Test-Path -LiteralPath $mofPath -PathType Leaf)) { continue }

        $mof = Get-Content -LiteralPath $mofPath -Raw
        $sidScript = @(Get-MofResourceBlock -Text $mof -ResourceId '[Script]EnsureSidSqlSysadmins')
        $sqlRole = @(Get-MofResourceBlock -Text $mof -ResourceId '[SqlRole]SqlRole')
        Assert-SqlSidConvergence -Condition ($sidScript.Count -eq 1) -What "$nodeName has one SID convergence Script resource"
        Assert-SqlSidConvergence -Condition ($sqlRole.Count -eq 1) -What "$nodeName has one post-install SqlRole resource"
        if ($sidScript.Count -eq 1) {
            Assert-SqlSidConvergence -Condition ([regex]::Matches($sidScript[0], '010100000000000512000000').Count -eq 2) -What "$nodeName embeds LocalSystem SID in test and repair scripts"
            Assert-SqlSidConvergence -Condition ([regex]::Matches($sidScript[0], '01020000000000052000000020020000').Count -eq 2) -What "$nodeName embeds builtin Administrators SID in test and repair scripts"
            Assert-SqlSidConvergence -Condition ([regex]::Matches($sidScript[0], "ISNULL\(IS_SRVROLEMEMBER\(N'sysadmin'").Count -eq 2) -What "$nodeName treats indeterminate role membership as noncompliant"
            Assert-SqlSidConvergence -Condition ($sidScript[0] -match 'SUSER_SNAME\(@sid\)' -and $sidScript[0] -match 'CREATE LOGIN' -and $sidScript[0] -match 'ALTER SERVER ROLE \[sysadmin\] ADD MEMBER') -What "$nodeName resolves, creates, and assigns well-known principals by SID"
        }
        if ($sqlRole.Count -eq 1) {
            Assert-SqlSidConvergence -Condition ($sqlRole[0] -notmatch 'BUILTIN\\+Administrators') -What "$nodeName SqlRole excludes the English builtin Administrators name"
        }
    }

    foreach ($nodeName in $phase5SqlNodes) {
        $mofPath = Join-Path $phase5Output "$nodeName.mof"
        Assert-SqlSidConvergence -Condition (Test-Path -LiteralPath $mofPath -PathType Leaf) -What "Phase 5 compiled $nodeName.mof"
        if (-not (Test-Path -LiteralPath $mofPath -PathType Leaf)) { continue }

        $mof = Get-Content -LiteralPath $mofPath -Raw
        $sqlRole = @(Get-MofResourceBlock -Text $mof -ResourceId '[SqlRole]Add_ServerRole')
        Assert-SqlSidConvergence -Condition ($sqlRole.Count -eq 1) -What "$nodeName has one Phase 5 SqlRole resource"
        if ($sqlRole.Count -eq 1) {
            Assert-SqlSidConvergence -Condition ($sqlRole[0] -notmatch 'BUILTIN\\+Administrators') -What "$nodeName Phase 5 SqlRole excludes the English builtin Administrators name"
        }
    }
}
finally {
    $env:PSModulePath = $originalModulePath
    Remove-Item -LiteralPath $phase4Output, $phase5Output -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:Failures -ne 0) { exit 1 }
exit 0