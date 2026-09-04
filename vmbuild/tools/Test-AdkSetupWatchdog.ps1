<#
.SYNOPSIS
    Prove a hung ADK bootstrapper cannot consume the whole DSC phase or lose its evidence.

.DESCRIPTION
    InstallADK used Start-Process -Wait, so a bootstrapper that never returned bypassed
    all retry and diagnostic code until the host's five-hour phase timeout killed DSC.
    The useful Burn log stayed in C:\Windows\Temp and was absent from the failure bundle.

    This test lifts the shipped watchdog functions through the AST, launches a real
    powershell.exe -> ping.exe process tree, and gives it a four-second budget. It proves
    the watchdog emits a heartbeat, writes a diagnostic containing the Burn-log tail and
    process tree, terminates every captured process, and returns ERROR_TIMEOUT (1460).
    A separate fast process proves ordinary exit codes still pass through unchanged.

    The host collector is checked for the markers that make ADKSetupLogs cross the VM
    boundary on failure. The test creates and deletes files under %TEMP% only.

.EXAMPLE
    .\Test-AdkSetupWatchdog.ps1

.EXAMPLE
    powershell.exe -NoProfile -File .\Test-AdkSetupWatchdog.ps1
#>
[CmdletBinding()]
param(
    [string] $RootPath,
    [string] $ModulePath = 'DSC\TemplateHelpDSC\TemplateHelpDSC.psm1',
    [string] $CollectorPath = 'common\Common.ScriptBlocks.ps1'
)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$script:Failures = 0
$script:Statuses = New-Object System.Collections.Generic.List[string]

function Assert-Equal {
    param($Expected, $Actual, [string] $What)
    $ok = "$Expected" -eq "$Actual"
    if (-not $ok) { $script:Failures++ }
    Write-Host ('{0}  {1}' -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $What) -ForegroundColor $(if ($ok) { 'Green' } else { 'Red' })
    if (-not $ok) { Write-Host "      expected: $Expected`n      actual:   $Actual" -ForegroundColor Red }
}

function Assert-True {
    param([bool] $Condition, [string] $What)
    Assert-Equal $true $Condition $What
}

function Assert-Match {
    param([string] $Text, [string] $Pattern, [string] $What)
    Assert-True ($Text -match $Pattern) $What
}

function Write-Status {
    param([string] $Status)
    $script:Statuses.Add($Status)
}

$sourcePath = Join-Path $RootPath $ModulePath
$collectorSourcePath = Join-Path $RootPath $CollectorPath
foreach ($path in @($sourcePath, $collectorSourcePath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Write-Host "SETUP FAIL: source file not found: $path" -ForegroundColor Red
        exit 2
    }
}

$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path -LiteralPath $sourcePath).Path, [ref] $tokens, [ref] $parseErrors)
$realParseErrors = @($parseErrors | Where-Object ErrorId -ne 'ModuleNotFoundDuringParse')
if ($realParseErrors.Count -gt 0) {
    Write-Host "SETUP FAIL: $ModulePath has $($realParseErrors.Count) parse error(s)" -ForegroundColor Red
    exit 2
}

$wanted = @('Initialize-AdkBundleWorkspace', 'Get-AdkProcessTree', 'Stop-AdkProcessTree', 'Invoke-AdkSetupProcess')
$loaded = New-Object System.Collections.Generic.List[string]
foreach ($node in $ast.FindAll({ param($candidate) $candidate -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if ($wanted -notcontains $node.Name) { continue }
    . ([scriptblock]::Create($node.Extent.Text))
    $loaded.Add($node.Name)
}
$missing = @($wanted | Where-Object { $loaded -notcontains $_ })
if ($missing.Count -gt 0) {
    Write-Host "SETUP FAIL: watchdog function(s) missing from ${ModulePath}: $($missing -join ', ')" -ForegroundColor Red
    exit 2
}

$moduleText = [System.IO.File]::ReadAllText($sourcePath)
$collectorText = [System.IO.File]::ReadAllText($collectorSourcePath)
Assert-Match $moduleText 'Invoke-AdkSetupProcess[\s\S]+-TimeoutSeconds 5400' 'InstallADK invokes the watchdog with a 90-minute hard cap'
Assert-Match $moduleText 'C:\\staging\\DSC\\ADKSetupLogs' 'Burn logs are written to the durable DSC staging tree'
Assert-Match $moduleText 'StagedCount\s*=\s*\$stagedCount' 'ADK invocation reports successful dead-link payload staging'
Assert-Match $collectorText "Mode -eq 'Failure'[\s\S]+ADKSetupLogs" 'failure collector reads staged ADK artifacts'
Assert-Match $collectorText 'Pulled ADK diagnostic' 'collector reports each ADK artifact copied to the host'

$collectorTokens = $null
$collectorParseErrors = $null
$collectorAst = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path -LiteralPath $collectorSourcePath).Path,
    [ref] $collectorTokens, [ref] $collectorParseErrors)
$collectorDefinition = @($collectorAst.FindAll({
            param($candidate)
            $candidate -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $candidate.Name -eq 'Save-CMSetupLogsFromVm'
        }, $true))
if ($collectorDefinition.Count -ne 1) {
    Write-Host "SETUP FAIL: expected one Save-CMSetupLogsFromVm definition, found $($collectorDefinition.Count)" -ForegroundColor Red
    exit 2
}
. ([scriptblock]::Create($collectorDefinition[0].Extent.Text))

Write-Host "engine    : $($PSVersionTable.PSVersion)"
Write-Host "module    : $sourcePath"
Write-Host "collector : $collectorSourcePath"
Write-Host ''

$fingerprintTestDir = Join-Path ([System.IO.Path]::GetTempPath()) ('adk-fingerprint-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $fingerprintTestDir
try {
    $adk = Join-Path $fingerprintTestDir 'adksetup.exe'
    $winpe = Join-Path $fingerprintTestDir 'adkwinpesetup.exe'
    $marker = Join-Path $fingerprintTestDir '.memlabs-adk-bundle-fingerprint'
    $payloads = Join-Path $fingerprintTestDir 'Installers'
    $layout = Join-Path $fingerprintTestDir 'adk-layout-deptools'
    [System.IO.File]::WriteAllText($adk, 'bundle-v1')
    [System.IO.File]::WriteAllText($winpe, 'winpe-v1')
    $null = New-Item -ItemType Directory -Path $payloads, $layout
    [System.IO.File]::WriteAllText((Join-Path $payloads 'same-name.msi'), 'old-release-content')

    $first = Initialize-AdkBundleWorkspace -BootstrapperPaths @($adk, $winpe) -FingerprintPath $marker -CachePaths @($payloads, $layout)
    Assert-Equal $true $first.Changed 'first fingerprint adoption treats untracked payloads as stale'
    Assert-Equal $false (Test-Path -LiteralPath $payloads) 'first fingerprint adoption removes pre-marker payloads'
    Assert-Equal $false (Test-Path -LiteralPath $layout) 'first fingerprint adoption removes pre-marker layout'

    $null = New-Item -ItemType Directory -Path $payloads, $layout
    $retryPayload = Join-Path $payloads 'recovery-progress.cab'
    [System.IO.File]::WriteAllText($retryPayload, 'keep-for-same-bundle-retry')
    $same = Initialize-AdkBundleWorkspace -BootstrapperPaths @($adk, $winpe) -FingerprintPath $marker -CachePaths @($payloads, $layout)
    Assert-Equal $false $same.Changed 'same bootstrapper pair retains its recovery workspace'
    Assert-Equal $true (Test-Path -LiteralPath $retryPayload) 'same-bundle retry preserves staged recovery payloads'

    [System.IO.File]::WriteAllText($adk, 'bundle-v2')
    $upgrade = Initialize-AdkBundleWorkspace -BootstrapperPaths @($adk, $winpe) -FingerprintPath $marker -CachePaths @($payloads, $layout)
    Assert-Equal $true $upgrade.Changed 'changed bootstrapper content is detected as an upgrade'
    Assert-Equal $false (Test-Path -LiteralPath $payloads) 'upgrade removes same-name payloads from the previous release'
    Assert-Equal $false (Test-Path -LiteralPath $layout) 'upgrade removes the previous release layout'
}
finally {
    Remove-Item -LiteralPath $fingerprintTestDir -Recurse -Force -ErrorAction SilentlyContinue
}

$runAdkAssignments = @($ast.FindAll({
            param($candidate)
            $candidate -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $candidate.Left.Extent.Text -eq '$runAdkInstall'
        }, $true))
if ($runAdkAssignments.Count -ne 1) {
    Write-Host "SETUP FAIL: expected one runAdkInstall assignment, found $($runAdkAssignments.Count)" -ForegroundColor Red
    exit 2
}
$runAdkFactory = [scriptblock]::Create($runAdkAssignments[0].Right.Extent.Text)
$runAdkInstall = & $runAdkFactory
$script:RecoveryCalls = 0
$invokeAdk = {
    param($exe, [string[]]$argv, $label)
    $script:RecoveryCalls++
    if ($script:RecoveryCalls -le 6) {
        return [pscustomobject]@{ ExitCode = 15605; StagedCount = 1 }
    }
    return [pscustomobject]@{ ExitCode = 0; StagedCount = 0 }
}
$null = $invokeAdk # consumed dynamically by the extracted runAdkInstall script block
$script:Statuses.Clear()
$recoveryExit = & $runAdkInstall 'synthetic-adksetup.exe' @('SyntheticFeature') 'recovery-test' `
    (Join-Path ([System.IO.Path]::GetTempPath()) 'unused-adk-layout') 4 @() 0 12
Assert-Equal 0 $recoveryExit 'progress-aware recovery reaches success after more than four staged payloads'
Assert-Equal 7 $script:RecoveryCalls 'successful staging does not consume the four-attempt no-progress budget'
Assert-Match (@($script:Statuses) -join "`n") 'continuing without consuming the no-progress retry budget' 'recovery progress is explicit in status output'

$script:RecoveryCalls = 0
$invokeAdk = {
    param($exe, [string[]]$argv, $label)
    $script:RecoveryCalls++
    if ($label -like '*-layout') { return [pscustomobject]@{ ExitCode = 99; StagedCount = 0 } }
    return [pscustomobject]@{ ExitCode = 15605; StagedCount = 0 }
}
$null = $invokeAdk # consumed dynamically by the extracted runAdkInstall script block
$noProgressLayout = Join-Path ([System.IO.Path]::GetTempPath()) ('unused-adk-layout-' + [guid]::NewGuid().ToString('N'))
try {
    $noProgressExit = & $runAdkInstall 'synthetic-adksetup.exe' @('SyntheticFeature') 'no-progress-test' `
        $noProgressLayout 4 @() 0 12
    Assert-Equal 99 $noProgressExit 'four genuine no-progress failures still enter the layout fallback'
    Assert-Equal 5 $script:RecoveryCalls 'no-progress budget stops after four direct attempts plus one layout attempt'
}
finally {
    Remove-Item -LiteralPath $noProgressLayout -Recurse -Force -ErrorAction SilentlyContinue
}

$workDir = Join-Path ([System.IO.Path]::GetTempPath()) ('adk-watchdog-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $workDir
$burnLog = Join-Path $workDir 'adksetup-test.log'
[System.IO.File]::WriteAllLines($burnLog, @('fake burn start', 'fake burn progress marker'))
$timeoutResult = $null

try {
    $script:Common = [pscustomobject]@{ LogPath = Join-Path $workDir 'VMBuild.test.log' }
    $script:CollectorMessages = New-Object System.Collections.Generic.List[string]
    function Write-Log {
        param([string] $Message, [switch] $Warning, [switch] $OutputStream)
        $script:CollectorMessages.Add($Message)
    }
    function Invoke-VmCommand {
        param($VmName, $VmDomainName, $ScriptBlock, $ArgumentList, [switch] $SuppressLog, $DisplayName)
        return [pscustomobject]@{
            ScriptBlockFailed = $false
            ScriptBlockOutput = [pscustomobject]@{
                SetupExists   = $false
                WrapperExists = $false
                DscLogExists  = $false
                AdkArtifacts  = @([pscustomobject]@{
                        Name     = 'adksetup-winpe.log'
                        Bytes    = 24
                        TailOnly = $false
                        Content  = 'synthetic Burn evidence'
                    })
            }
        }
    }

    Save-CMSetupLogsFromVm -VmName 'WATCHDOG' -DomainName 'example.test' -Phase 3 -Mode 'Failure'
    $collected = @(Get-ChildItem -LiteralPath $workDir -Filter 'WATCHDOG-Phase3-*-adksetup-winpe.log' -File)
    Assert-Equal 1 $collected.Count 'real host collector writes one timestamped ADK artifact'
    if ($collected.Count -eq 1) {
        Assert-Match ([System.IO.File]::ReadAllText($collected[0].FullName)) 'synthetic Burn evidence' 'host copy retains ADK artifact content'
    }
    Assert-Match (@($script:CollectorMessages) -join "`n") 'Pulled ADK diagnostic adksetup-winpe.log' 'collector logs the copied ADK artifact'

    $enginePath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $enginePath -PathType Leaf)) {
        Write-Host "SETUP FAIL: Windows PowerShell not found at $enginePath" -ForegroundColor Red
        exit 2
    }

    $success = Invoke-AdkSetupProcess -FilePath $env:ComSpec `
        -ArgumentList @('/d', '/c', 'exit 7') `
        -Label 'test-exit' -LogFile $burnLog -DiagnosticDirectory $workDir `
        -TimeoutSeconds 10 -PollSeconds 1 -HeartbeatSeconds 2
    Assert-Equal 7 $success.ExitCode 'ordinary child exit code passes through unchanged'
    Assert-Equal $false $success.TimedOut 'ordinary child is not marked timed out'

    $escapedLog = $burnLog.Replace("'", "''")
    $timeoutPayload = @"
[System.IO.File]::AppendAllText('$escapedLog', "``r``nfake child entered wait")
`$child = Start-Process -FilePath (Join-Path `$env:SystemRoot 'System32\ping.exe') -ArgumentList @('-n', '30', '127.0.0.1') -PassThru -WindowStyle Hidden
`$child.WaitForExit()
"@
    $timeoutEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($timeoutPayload))
    $script:Statuses.Clear()
    $timeoutResult = Invoke-AdkSetupProcess -FilePath $enginePath `
        -ArgumentList @('-NoProfile', '-NonInteractive', '-EncodedCommand', $timeoutEncoded) `
        -Label 'test-timeout' -LogFile $burnLog -DiagnosticDirectory $workDir `
        -TimeoutSeconds 4 -PollSeconds 1 -HeartbeatSeconds 1

    Assert-Equal 1460 $timeoutResult.ExitCode 'timeout returns Win32 ERROR_TIMEOUT'
    Assert-Equal $true $timeoutResult.TimedOut 'hung child is marked timed out'
    Assert-True ($timeoutResult.ElapsedSeconds -ge 4 -and $timeoutResult.ElapsedSeconds -lt 20) 'timeout fires near its configured budget'
    Assert-True (Test-Path -LiteralPath $timeoutResult.DiagnosticPath -PathType Leaf) 'timeout diagnostic file is created'
    Assert-True (Test-Path -LiteralPath $burnLog -PathType Leaf) 'complete Burn log remains available for host collection'
    Assert-True ($timeoutResult.ProcessIds.Count -ge 2) 'snapshot captured the launcher and child process'

    $statusText = @($script:Statuses) -join "`n"
    Assert-Match $statusText 'still running' 'watchdog emits progress heartbeats while the process runs'
    Assert-Match $statusText 'TIMEOUT after' 'timeout is written to the durable status stream before termination'
    Assert-Match $statusText 'termination complete' 'termination result is written to the durable status stream'

    $diagnosticText = [System.IO.File]::ReadAllText($timeoutResult.DiagnosticPath)
    Assert-Match $diagnosticText 'PROCESS TREE \(captured before termination\)' 'diagnostic records the pre-kill process tree'
    Assert-Match $diagnosticText 'ping\.exe' 'diagnostic identifies the hanging child process'
    Assert-Match $diagnosticText 'BURN LOG TAIL' 'diagnostic includes a labelled Burn-log tail'
    Assert-Match $diagnosticText 'fake burn progress marker' 'diagnostic carries actual Burn-log content'
    Assert-Match $diagnosticText 'WINHTTP PROXY' 'diagnostic records the SYSTEM-context proxy state'

    foreach ($processId in $timeoutResult.ProcessIds) {
        Assert-Equal $null (Get-Process -Id $processId -ErrorAction SilentlyContinue) "captured process $processId was terminated"
    }
}
finally {
    if ($null -ne $timeoutResult) {
        foreach ($processId in @($timeoutResult.ProcessIds)) {
            Get-Process -Id $processId -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        }
    }
    Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:Failures -gt 0) {
    Write-Host "FAILURES: $script:Failures" -ForegroundColor Red
    exit 1
}
Write-Host 'OK - all checks passed.' -ForegroundColor Green
exit 0