#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$sourcePath = Join-Path $PSScriptRoot 'Get-WindowsVmSetupDiagnostics.ps1'
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$null, [ref]$errors)
if ($errors.Count) { throw ($errors -join '; ') }
$lastDefinition = $ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst]
    }, $true) | Sort-Object { $_.Extent.EndOffset } | Select-Object -Last 1
if (-not $lastDefinition) { throw 'Collector function definitions were not found.' }

$operationStub = @'
function __OPERATION__ {
    [CmdletBinding(SupportsShouldProcess)]
    param($VmName, $Destination, $StopTimeoutSeconds, $AllowTurnOff, $BackupPath,
        $GuestCredential, $RepairTimeoutSeconds, $BackupTimeoutSeconds, $IncludeLiveProbe)
    [pscustomobject]@{
        Operation = $MyInvocation.MyCommand.Name
        VMName = $VmName
        Destination = [IO.Path]::GetFullPath($Destination)
        StopTimeoutSeconds = $StopTimeoutSeconds
        IncludeLiveProbe = [bool]$IncludeLiveProbe
    } | ConvertTo-Json -Compress
}
'@
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "memlabs-setup-defaults-$([guid]::NewGuid().ToString('N'))"
try {
    $toolsRoot = Join-Path $testRoot 'tools with spaces'
    $null = New-Item -Path $toolsRoot -ItemType Directory -Force
    $fixturePath = Join-Path $toolsRoot 'collector fixture.ps1'
    $collectStub = $operationStub.Replace('__OPERATION__', 'Invoke-MemLabsWindowsSetupDiagnostics')
    $fixtureSource = $ast.Extent.Text.Insert($lastDefinition.Extent.EndOffset, "`r`n$collectStub`r`n")
    $fixtureSource = [regex]::Replace($fixtureSource, '(?im)^#requires -RunAsAdministrator[ \t]*\r?\n', '')
    $fixtureSource = $fixtureSource.Replace('Global\MemLabsTestMutationLock', "Local\MemLabsDefaultFixture-$([guid]::NewGuid().ToString('N'))")
    [IO.File]::WriteAllText($fixturePath, $fixtureSource, [Text.UTF8Encoding]::new($true))
    [IO.File]::WriteAllText((Join-Path $toolsRoot 'Common.WindowsVmOobeRepair.ps1'),
        $operationStub.Replace('__OPERATION__', 'Invoke-MemLabsWindowsOobeRepair'), [Text.UTF8Encoding]::new($true))
    [IO.File]::WriteAllText((Join-Path $toolsRoot 'Common.WindowsVmFirstLogonProbe.ps1'), '# Fixture: no live operations.', [Text.UTF8Encoding]::new($true))
    $engines = @(
        [pscustomobject]@{ Name = 'Windows PowerShell 5.1'; Path = (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') }
        [pscustomobject]@{ Name = 'PowerShell 7'; Path = (Get-Command pwsh.exe -CommandType Application -ErrorAction Stop).Source }
    )
    $casesRun = 0
    foreach ($engine in $engines) {
        if (-not (Test-Path -LiteralPath $engine.Path -PathType Leaf)) { throw "Missing test engine: $($engine.Path)" }
        foreach ($scenario in @('DefaultCollect', 'ExplicitCollect', 'DefaultRepair', 'ExplicitRepair', 'DefaultLive', 'ExplicitLive')) {
            $arguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                '-File', $fixturePath, '-VmName', 'BINDING-FIXTURE', '-WhatIf')
            $expectedDestination = [IO.Path]::GetFullPath((Join-Path $toolsRoot '..\logs\setup-diagnostics'))
            $expectedOperation = 'Invoke-MemLabsWindowsSetupDiagnostics'
            if ($scenario -like 'Explicit*') {
                $expectedDestination = Join-Path $testRoot 'explicit output'
                $arguments += @('-Destination', $expectedDestination)
            }
            if ($scenario -like '*Repair') {
                $arguments += '-RepairOobe'
                $expectedOperation = 'Invoke-MemLabsWindowsOobeRepair'
            }
            if ($scenario -like '*Live') { $arguments += '-IncludeLiveProbe' }
            try { $output = @(& $engine.Path @arguments 2>&1) }
            catch { throw "$($engine.Name)/$scenario cold -File launch failed: $($_.Exception.Message)" }
            if ($LASTEXITCODE -ne 0 -or $output.Count -ne 1) {
                throw "$($engine.Name)/$scenario returned exit $LASTEXITCODE and $($output.Count) records: $($output -join ' ')"
            }
            $report = $output[0] | ConvertFrom-Json -ErrorAction Stop
            if ($report.Operation -ne $expectedOperation -or $report.VMName -ne 'BINDING-FIXTURE' -or
                $report.Destination -ne $expectedDestination -or $report.StopTimeoutSeconds -ne 90 -or
                $report.IncludeLiveProbe -ne ($scenario -like '*Live')) {
                throw "$($engine.Name)/$scenario lost its default, explicit path, mode, or timeout: $($output[0])"
            }
            $casesRun++
        }
    }
    if ($casesRun -ne 12) { throw "Expected twelve cold -File cases, executed $casesRun." }
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction Stop
    }
}
Write-Host 'PASS -- twelve real -File launches preserve omitted/explicit offline, live and repair modes/destinations on PS5.1 and PS7; no VM operations run.'
