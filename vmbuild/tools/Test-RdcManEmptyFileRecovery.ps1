[CmdletBinding()]
param(
    [string] $RootPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }

$script:Failures = 0

function Assert-True {
    param([bool] $Condition, [string] $What)

    if ($Condition) {
        Write-Host "PASS  $What" -ForegroundColor Green
        return
    }

    $script:Failures++
    Write-Host "FAIL  $What" -ForegroundColor Red
}

function Invoke-RdcManRecoveryCase {
    param(
        [Parameter(Mandatory = $true)] [string] $SourcePath,
        [Parameter(Mandatory = $true)] [string] $TargetPath,
        [switch] $OverWrite
    )

    Set-StrictMode -Off
    . $SourcePath

    $state = [pscustomobject]@{
        InstallCalled = $false
        Logs          = [System.Collections.ArrayList]::new()
    }

    function Write-Log {
        [CmdletBinding()]
        param(
            [Parameter(Position = 0)] [string] $Message,
            [switch] $Activity,
            [switch] $Failure,
            [switch] $LogOnly,
            [switch] $Success,
            [switch] $Warning
        )

        [void]$state.Logs.Add([pscustomobject]@{
                Message = $Message
                Failure = $Failure.IsPresent
                LogOnly = $LogOnly.IsPresent
                Verbose = $PSBoundParameters.ContainsKey('Verbose')
            })
    }

    function Get-RDCSettings {
        return [pscustomobject]@{
            DefaultGrouping = $true
            AllVMsGroup     = $false
            RoleGroups      = $false
            OSGroups        = $false
            SubnetGroups    = $false
            SiteCodeGroups  = $false
        }
    }

    function Get-Process {
        [CmdletBinding()]
        param([string] $Name)
    }

    function Get-List {
        param(
            [string] $Type,
            [string] $Domain,
            [switch] $SmartUpdate
        )
    }

    function Invoke-VMNetworkBulkWarmup {}
    function Install-RDCman { $state.InstallCalled = $true }
    function Test-RDCManCertTrustSupported { return $false }
    function Save-RdcManSettingsFile { return $false }
    function Start-Sleep { param([int] $Seconds) }
    function Write-GreenCheck { param([string] $Message, $ForegroundColor) }
    function Out-Host { process {} }

    New-RDCManFileFromHyperV -rdcmanfile $TargetPath -OverWrite:$OverWrite

    [xml]$result = Get-Content -LiteralPath $TargetPath -Raw
    return [pscustomobject]@{
        InstallCalled = $state.InstallCalled
        Logs          = @($state.Logs)
        FileName      = "$($result.RDCMan.file.properties.name)"
    }
}

$source = Join-Path $RootPath 'common\Common.RdcMan.ps1'
$template = Join-Path $RootPath 'common\template.rdg'
if (-not (Test-Path -LiteralPath $source) -or -not (Test-Path -LiteralPath $template)) {
    Write-Host 'SETUP FAIL: RDCMan source or template was not found.' -ForegroundColor Red
    exit 2
}

$groupLessRdg = @'
<?xml version="1.0" encoding="utf-8"?>
<RDCMan programVersion="2.92" schemaVersion="3">
  <file>
    <credentialsProfiles />
    <properties>
      <expanded>True</expanded>
      <name>stale</name>
    </properties>
    <remoteDesktop inherit="None">
      <sameSizeAsClientArea>True</sameSizeAsClientArea>
      <fullScreen>False</fullScreen>
      <colorDepth>24</colorDepth>
    </remoteDesktop>
  </file>
  <connected />
  <favorites />
  <recentlyUsed />
</RDCMan>
'@

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "memlabs-rdcman-test-$([guid]::NewGuid().ToString('N'))"
try {
    $normalRoot = Join-Path $tempRoot 'normal'
    $brokenRoot = Join-Path $tempRoot 'broken'
    $null = New-Item -ItemType Directory -Path $normalRoot, $brokenRoot -Force

    Copy-Item -LiteralPath $source -Destination (Join-Path $normalRoot 'Common.RdcMan.ps1')
    Copy-Item -LiteralPath $template -Destination (Join-Path $normalRoot 'template.rdg')
    Set-Content -LiteralPath (Join-Path $normalRoot 'target.rdg') -Value $groupLessRdg -Encoding UTF8

    Copy-Item -LiteralPath $source -Destination (Join-Path $brokenRoot 'Common.RdcMan.ps1')
    Set-Content -LiteralPath (Join-Path $brokenRoot 'template.rdg') -Value $groupLessRdg -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $brokenRoot 'target.rdg') -Value $groupLessRdg -Encoding UTF8

    $normal = Invoke-RdcManRecoveryCase `
        -SourcePath (Join-Path $normalRoot 'Common.RdcMan.ps1') `
        -TargetPath (Join-Path $normalRoot 'target.rdg')
    $normalRecoveryLogs = @($normal.Logs | Where-Object { $_.Message -like 'No groups remain*' })

    Assert-True ($normalRecoveryLogs.Count -eq 1) 'group-less RDG takes one recovery path'
    if ($normalRecoveryLogs.Count -eq 1) {
        Assert-True ($normalRecoveryLogs[0].LogOnly -and $normalRecoveryLogs[0].Verbose -and -not $normalRecoveryLogs[0].Failure) 'expected recovery is log-only and verbose'
    }
    else {
        Write-Host "      captured: $(@($normal.Logs.Message) -join ' | ')" -ForegroundColor Red
        Assert-True $false 'expected recovery is log-only and verbose'
    }
    Assert-True (@($normal.Logs | Where-Object Failure).Count -eq 0) 'expected recovery emits no failure'
    Assert-True ($normal.InstallCalled -and $normal.FileName -eq 'memlabs') 'expected recovery reloads the template and continues'

    $broken = Invoke-RdcManRecoveryCase `
        -SourcePath (Join-Path $brokenRoot 'Common.RdcMan.ps1') `
        -TargetPath (Join-Path $brokenRoot 'target.rdg') `
        -OverWrite
    $brokenFailureLogs = @($broken.Logs | Where-Object { $_.Failure -and $_.Message -like 'Could not load group section*' })

    Assert-True ($brokenFailureLogs.Count -eq 1) 'group-less template remains a failure'
    Assert-True (@($broken.Logs | Where-Object { $_.Message -like 'No groups remain*' }).Count -eq 0) 'template failure does not retry'
    Assert-True (-not $broken.InstallCalled) 'template failure stops before installation work'
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:Failures -gt 0) {
    Write-Host "FAIL: $script:Failures assertion(s) failed." -ForegroundColor Red
    exit 1
}

Write-Host 'PASS: RDCMan empty-file recovery preserves real template failures.' -ForegroundColor Green
exit 0