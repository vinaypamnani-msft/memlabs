<#
.SYNOPSIS
    Verifies MSI 1618 retry behavior and passive-site completion dependencies.
#>
[CmdletBinding()]
param([string]$RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }

function Import-TestFunction {
    param([string]$Path, [string]$Name)

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    $realErrors = @($errors | Where-Object ErrorId -ne 'ModuleNotFoundDuringParse')
    if ($realErrors.Count -gt 0) { throw "$Path has parse errors: $($realErrors -join '; ')" }
    $definitions = @($ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($definitions.Count -ne 1) { throw "Expected one $Name definition, found $($definitions.Count)." }
    [scriptblock]::Create($definitions[0].Extent.Text)
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$modulePath = Join-Path $RootPath 'DSC\TemplateHelpDSC\TemplateHelpDSC.psm1'
$phase8Path = Join-Path $RootPath 'DSC\phases\Phase8.ps1'
. (Import-TestFunction -Path $modulePath -Name 'Install-MSIPackage')

$script:ExitCodes = [System.Collections.Queue]::new()
$script:ProcessCalls = 0
$script:Sleeps = [System.Collections.Generic.List[int]]::new()
$script:Statuses = [System.Collections.Generic.List[string]]::new()

function Start-Process {
    param(
        [string]$FilePath,
        $ArgumentList,
        [switch]$Wait,
        [switch]$PassThru,
        [switch]$NoNewWindow
    )
    $script:ProcessCalls++
    [pscustomobject]@{ ExitCode = [int]$script:ExitCodes.Dequeue() }
}

function Start-Sleep {
    param([int]$Seconds)
    $script:Sleeps.Add($Seconds)
}

function Write-Status {
    param([string]$Status)
    $script:Statuses.Add($Status)
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('memlabs-msi-retry-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $tempRoot -Force
$msiPath = Join-Path $tempRoot 'test.msi'
$null = New-Item -ItemType File -Path $msiPath -Force

try {
    foreach ($code in @(1618, 1618, 0)) { $script:ExitCodes.Enqueue($code) }
    Install-MSIPackage -MsiPath $msiPath -DisplayName 'Retry Test' `
        -InstallBusyMaxAttempts 4 -InstallBusyRetrySeconds 7
    Assert-True ($script:ProcessCalls -eq 3) 'MSI 1618 should retry until success.'
    Assert-True ($script:Sleeps.Count -eq 2 -and @($script:Sleeps | Where-Object { $_ -ne 7 }).Count -eq 0) `
        'MSI 1618 retries should use the configured bounded delay.'
    Assert-True ((@($script:Statuses) -join "`n") -match 'exit 1618.+attempt 2 of 4') `
        'MSI retry status should report the bounded attempt.'

    $script:ExitCodes.Clear()
    $script:Sleeps.Clear()
    $script:Statuses.Clear()
    $script:ProcessCalls = 0
    foreach ($code in @(1618, 1618)) { $script:ExitCodes.Enqueue($code) }
    $threw = $false
    try {
        Install-MSIPackage -MsiPath $msiPath -DisplayName 'Exhausted Test' `
            -InstallBusyMaxAttempts 2 -InstallBusyRetrySeconds 3
    }
    catch {
        $threw = $_.Exception.Message -like '*exit 1618*'
    }
    Assert-True $threw 'Exhausted MSI 1618 retries should remain fatal.'
    Assert-True ($script:ProcessCalls -eq 2 -and $script:Sleeps.Count -eq 1) `
        'MSI retry budget should not sleep after its final attempt.'

    $phase8Source = Get-Content -LiteralPath $phase8Path -Raw
    Assert-True ($phase8Source -match '(?s)InstallReportBuilder\s+InstallReportBuilder\s*\{.+?\$nextDepend\s*=\s*"\[InstallReportBuilder\]InstallReportBuilder".+?WriteStatus\s+WaitActive\s*\{.+?DependsOn\s*=\s*\$nextDepend') `
        'Passive-site WaitActive must depend on the Report Builder resource chain.'
    Assert-True ($phase8Source -notmatch '(?s)WriteStatus\s+WaitActive\s*\{[^}]+DependsOn\s*=\s*''\[InstallADK\]ADKInstall''') `
        'Passive-site completion must not bypass Report Builder through a direct ADK dependency.'
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'PASS -- MSI busy retries are bounded and passive completion includes Report Builder.'
