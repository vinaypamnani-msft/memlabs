<#
.SYNOPSIS
    Verifies semantic progress classification for monitored deployments.
#>
[CmdletBinding()]
param ([string] $RootPath)

if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$script:Failures = 0
function Assert-Equal {
    param ($Expected, $Actual, [string] $What)
    $passed = "$Expected" -eq "$Actual"
    if (-not $passed) { $script:Failures++ }
    Write-Host ('{0}  {1}' -f $(if ($passed) { 'PASS' } else { 'FAIL' }), $What)
}

function Import-MonitoredTestFunction {
    param ([string] $Path, [string] $Name)
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -ne 0) { throw "$Path has $($errors.Count) parse error(s)" }
    $definition = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($definition.Count -ne 1) { throw "Expected one $Name definition, found $($definition.Count)" }
    return [scriptblock]::Create($definition[0].Extent.Text)
}

. (Join-Path $RootPath 'tools\Invoke-MemLabsMonitoredDeployment.ps1')
$monitorSource = Get-Content -LiteralPath (Join-Path $RootPath 'tools\Invoke-MemLabsMonitoredDeployment.ps1') -Raw
$childSource = Get-Content -LiteralPath (Join-Path $RootPath 'tools\Invoke-MemLabsDeploymentChild.ps1') -Raw
$pathFixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('memlabs-path-fixture-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -Path $pathFixtureRoot -ItemType Directory -Force
try {
    $absoluteConfigPath = Join-Path $pathFixtureRoot 'absolute.json'
    $null = New-Item -Path $absoluteConfigPath -ItemType File
    Assert-Equal $absoluteConfigPath (Resolve-MemLabsConfigurationPath -Path $absoluteConfigPath -BasePath $RootPath) 'absolute configuration path is not prefixed with the current directory'
    Assert-Equal $absoluteConfigPath (Resolve-MemLabsConfigurationPath -Path 'absolute.json' -BasePath $pathFixtureRoot) 'relative configuration path is anchored to the current directory'
}
finally {
    Remove-Item -LiteralPath $pathFixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}
$timeoutBlockStart = $monitorSource.IndexOf('if ($reason) {')
$timeoutBlockEnd = $monitorSource.IndexOf('throw "Monitored deployment stopped:', $timeoutBlockStart)
$timeoutBlock = if ($timeoutBlockStart -ge 0 -and $timeoutBlockEnd -gt $timeoutBlockStart) { $monitorSource.Substring($timeoutBlockStart, $timeoutBlockEnd - $timeoutBlockStart) } else { '' }
Assert-Equal $true ($timeoutBlock.IndexOf('CloseHandle($jobHandle)') -ge 0 -and $timeoutBlock.IndexOf('CloseHandle($jobHandle)') -lt $timeoutBlock.IndexOf('WaitForExit(30000)') -and $timeoutBlock.IndexOf('WaitForExit(30000)') -lt $timeoutBlock.IndexOf('Save-MemLabsDeploymentDiagnostics')) 'timeout terminates and awaits the process tree before guest diagnostics'
Assert-Equal $true ($monitorSource -match '\$diagnosticVmNames = @\(\$config\.virtualMachines' -and $monitorSource -match 'Save-MemLabsDeploymentDiagnostics -VMName \$diagnosticVmNames') 'timeout diagnostics include hidden dependency VMs'
Assert-Equal $true ($monitorSource -match '\$arguments\.StopPhase = \$StopPhase' -and $childSource -match '\$arguments\.StopPhase = \$StopPhase') 'fresh monitored runs pass StopPhase through both process boundaries'
Assert-Equal $true ($monitorSource -match '\$StopPhase -and \(\$StartPhase -or \$Phase\)') 'stop-phase mode rejects ambiguous start/phase combinations'
$expectedPhaseFunction = Import-MonitoredTestFunction -Path (Join-Path $RootPath 'tools\Invoke-MemLabsMonitoredDeployment.ps1') -Name 'Resolve-MemLabsExpectedCompletedPhase'
. $expectedPhaseFunction
Assert-Equal 4 (Resolve-MemLabsExpectedCompletedPhase -Phase @(2, 4) -ExpectedCompletedPhase 11 -ExpectedPhaseWasBound $false) 'phase-only run derives expected completion from its highest requested phase'
Assert-Equal 2 (Resolve-MemLabsExpectedCompletedPhase -StopPhase 2 -ExpectedCompletedPhase 11 -ExpectedPhaseWasBound $false) 'fresh stop-phase run derives its expected completion threshold'
Assert-Equal 7 (Resolve-MemLabsExpectedCompletedPhase -StopPhase 2 -ExpectedCompletedPhase 7 -ExpectedPhaseWasBound $true) 'explicit expected completion override is preserved'
Assert-Equal 11 (Resolve-MemLabsExpectedCompletedPhase -ExpectedCompletedPhase 11 -ExpectedPhaseWasBound $false) 'full deployment retains the default Phase 11 postcondition'
Assert-Equal $true ($monitorSource -match '(?s)New-MemLabsDeploymentProcess.*?gateReady\.WaitOne.*?Add-MemLabsDeploymentProcessToJob.*?startGate\.Set\(\)' -and $childSource.IndexOf('gateReady.Set()') -lt $childSource.IndexOf('WaitOne([TimeSpan]::FromMinutes(2))') -and $childSource.IndexOf('WaitOne([TimeSpan]::FromMinutes(2))') -lt $childSource.IndexOf("& (Join-Path (Split-Path -Parent `$PSScriptRoot) 'New-Lab.ps1')")) 'deployment child acknowledges the gate then waits for job ownership before invoking New-Lab'
Assert-Equal $true ($monitorSource -match '(?s)finally \{.*?CloseHandle\(\$jobHandle\).*?\$process\.Kill\(\$true\).*?WaitForExit\(30000\)') 'monitor cleanup cannot return while an uncontained deployment process remains active'
Assert-Equal $true ($childSource -match '(?s)MEMLABS_CRASH_LOG_PATH.*?Assert-MemLabsDeploymentLease.*?catch \{.*?DEPLOYMENT CHILD FAILURE:.*?Add-Content -LiteralPath \$OutputPath' -and $monitorSource -match 'Monitored deployment failed during Live Ops stage.*?Failure=\$failurePath.*?Crash=\$crashEvidence.*?Output=\$outputPath.*?Monitor=\$monitorLogPath.*?Diagnostics=\$diagnosticsPath') 'bootstrap and callback failures publish synchronized evidence paths'

$failureWriter = Import-MonitoredTestFunction -Path (Join-Path $RootPath 'tools\Invoke-MemLabsMonitoredDeployment.ps1') -Name 'Save-MemLabsDeploymentFailure'
$stampWriter = Import-MonitoredTestFunction -Path (Join-Path $RootPath 'tools\Invoke-MemLabsMonitoredDeployment.ps1') -Name 'New-MemLabsDeploymentStamp'
$stamps = @(& { . $stampWriter; New-MemLabsDeploymentStamp; New-MemLabsDeploymentStamp })
Assert-Equal 2 @($stamps | Sort-Object -Unique).Count 'simultaneous monitor attempts receive unique artifact names'
$failureFixturePath = Join-Path ([IO.Path]::GetTempPath()) ('memlabs-monitor-failure-' + [guid]::NewGuid().ToString('N') + '.json')
$failureFixtureOutput = Join-Path ([IO.Path]::GetTempPath()) ('memlabs-monitor-output-' + [guid]::NewGuid().ToString('N') + '.txt')
$failureFixtureCrashExport = Join-Path ([IO.Path]::GetTempPath()) ('memlabs-monitor-crash-export-' + [guid]::NewGuid().ToString('N') + '.txt')
$blockedCrashExport = Join-Path ([IO.Path]::GetTempPath()) ('memlabs-monitor-blocked-export-' + [guid]::NewGuid().ToString('N'))
try {
    . $failureWriter
    1..125 | ForEach-Object { "output line $_" } | Set-Content -LiteralPath $failureFixtureOutput
    $finishedInfo = [Diagnostics.ProcessStartInfo]::new((Get-Command pwsh.exe).Source)
    $finishedInfo.UseShellExecute = $false
    $finishedInfo.ArgumentList.Add('-NoProfile')
    $finishedInfo.ArgumentList.Add('-Command')
    $finishedInfo.ArgumentList.Add('exit 37')
    $finishedProcess = [Diagnostics.Process]::Start($finishedInfo)
    if (-not $finishedProcess.WaitForExit(10000)) { throw 'Completed-process fixture did not exit.' }
    $failureFixtureCrash = Join-Path ([IO.Path]::GetTempPath()) "VMBuild.unhandled.$($finishedProcess.Id).log"
    'fixture CLR crash stack' | Set-Content -LiteralPath $failureFixtureCrash
    Save-MemLabsDeploymentFailure -Path $failureFixturePath -Stage Operation -ErrorMessage 'fixture operation failed' -Process $finishedProcess `
        -OutputPath $failureFixtureOutput -MonitorPath 'monitor.jsonl' -DiagnosticsPath 'diagnostics.json' `
        -CrashSourcePath $failureFixtureCrash -CrashExportPath $failureFixtureCrashExport
    $operationFailure = Get-Content -LiteralPath $failureFixturePath -Raw | ConvertFrom-Json
    Assert-Equal 'Operation' $operationFailure.Stage 'operation failure artifact records its stage'
    Assert-Equal 'fixture operation failed' $operationFailure.Error 'operation failure artifact preserves the actionable error'
    Assert-Equal $finishedProcess.Id $operationFailure.ProcessId 'operation failure artifact records the exact child PID'
    Assert-Equal 37 $operationFailure.ExitCode 'operation failure artifact records the nonzero child exit code'
    Assert-Equal 120 @($operationFailure.OutputTail).Count 'operation failure artifact preserves the final 120 child-output lines'
    Assert-Equal 'output line 6' $operationFailure.OutputTail[0] 'operation failure output tail excludes older lines'
    Assert-Equal $failureFixtureCrash $operationFailure.CrashSource 'operation failure artifact records the PID-derived crash source path'
    Assert-Equal $failureFixtureCrashExport $operationFailure.CrashExport 'operation failure artifact records the top-level crash export path'
    Assert-Equal 'fixture CLR crash stack' $operationFailure.Crash.Trim() 'operation failure artifact embeds the CLR crash evidence'
    Assert-Equal 'fixture CLR crash stack' (Get-Content -LiteralPath $failureFixtureCrashExport -Raw).Trim() 'CLR crash evidence is exported to the top-level synchronized path'

    $staleFailurePath = Join-Path ([IO.Path]::GetTempPath()) ('memlabs-monitor-stale-' + [guid]::NewGuid().ToString('N') + '.json')
    (Get-Item -LiteralPath $failureFixtureCrash).LastWriteTimeUtc = $finishedProcess.StartTime.ToUniversalTime().AddMinutes(-1)
    Save-MemLabsDeploymentFailure -Path $staleFailurePath -Stage Operation -ErrorMessage 'stale fixture' -Process $finishedProcess `
        -OutputPath $failureFixtureOutput -MonitorPath 'monitor.jsonl' -DiagnosticsPath 'diagnostics.json' `
        -CrashSourcePath $failureFixtureCrash -CrashExportPath $failureFixtureCrashExport
    $staleFailure = Get-Content -LiteralPath $staleFailurePath -Raw | ConvertFrom-Json
    Assert-Equal '' $staleFailure.Crash 'stale same-PID crash content is not attributed to the current child'
    Assert-Equal $true ($staleFailure.CrashCaptureError -like 'Ignored crash file outside child lifetime*') 'stale same-PID crash rejection is recorded'

    (Get-Item -LiteralPath $failureFixtureCrash).LastWriteTimeUtc = $finishedProcess.ExitTime.ToUniversalTime().AddMinutes(1)
    Save-MemLabsDeploymentFailure -Path $staleFailurePath -Stage Operation -ErrorMessage 'after-exit fixture' -Process $finishedProcess `
        -OutputPath $failureFixtureOutput -MonitorPath 'monitor.jsonl' -DiagnosticsPath 'diagnostics.json' `
        -CrashSourcePath $failureFixtureCrash -CrashExportPath $failureFixtureCrashExport
    $afterExitFailure = Get-Content -LiteralPath $staleFailurePath -Raw | ConvertFrom-Json
    Assert-Equal '' $afterExitFailure.Crash 'after-exit replacement crash content is not attributed to the child'
    Assert-Equal $true ($afterExitFailure.CrashCaptureError -like 'Ignored crash file outside child lifetime*') 'after-exit replacement rejection is recorded'

    $null = New-Item -Path $blockedCrashExport -ItemType Directory
    $blockedCrashExportPath = Join-Path $blockedCrashExport 'missing\crash.txt'
    (Get-Item -LiteralPath $failureFixtureCrash).LastWriteTimeUtc = [datetime]::UtcNow
    $blockedFailurePath = Join-Path ([IO.Path]::GetTempPath()) ('memlabs-monitor-blocked-' + [guid]::NewGuid().ToString('N') + '.json')
    Save-MemLabsDeploymentFailure -Path $blockedFailurePath -Stage Operation -ErrorMessage 'original child failure' -Process $finishedProcess `
        -OutputPath $failureFixtureOutput -MonitorPath 'monitor.jsonl' -DiagnosticsPath 'diagnostics.json' `
        -CrashSourcePath $failureFixtureCrash -CrashExportPath $blockedCrashExportPath
    $blockedFailure = Get-Content -LiteralPath $blockedFailurePath -Raw | ConvertFrom-Json
    Assert-Equal 'original child failure' $blockedFailure.Error 'blocked crash export does not mask the original deployment failure'
    Assert-Equal 37 $blockedFailure.ExitCode 'blocked crash export retains the child exit code'
    Assert-Equal $true (-not [string]::IsNullOrWhiteSpace([string]$blockedFailure.CrashCaptureError)) 'blocked crash export records its diagnostic I/O error'
    Assert-Equal '' $blockedFailure.CrashExport 'blocked crash export is not advertised as completed evidence'
    Save-MemLabsDeploymentFailure -Path $failureFixturePath -Stage Unhandled -ErrorMessage 'fixture fallback' -OperationId 'fixture-id' -JournalPath 'operations.jsonl' -ActiveOwnerMetadata '{"owner":"fixture"}' -FailureDiagnostics @('diagnostic fixture') -OutputPath 'output.txt' -MonitorPath 'monitor.jsonl' -DiagnosticsPath 'diagnostics.json'
    $coordinationFailure = Get-Content -LiteralPath $failureFixturePath -Raw | ConvertFrom-Json
    Assert-Equal 'Unhandled' $coordinationFailure.Stage 'uncorrelated failure artifact receives a nonempty fallback stage'
    Assert-Equal 'fixture fallback' $coordinationFailure.Error 'fallback failure artifact preserves the caught error'
    Assert-Equal 'fixture-id|operations.jsonl|{"owner":"fixture"}|diagnostic fixture' "$($coordinationFailure.OperationId)|$($coordinationFailure.Journal)|$($coordinationFailure.ActiveOwner)|$(@($coordinationFailure.FailureDiagnostics) -join ',')" 'correlated failure artifact preserves Live Ops evidence'
    Assert-Equal 'output.txt|monitor.jsonl|diagnostics.json' "$($coordinationFailure.Output)|$($coordinationFailure.Monitor)|$($coordinationFailure.Diagnostics)" 'failure artifact records every synchronized evidence path'
}
finally {
    if ($finishedProcess) { $finishedProcess.Dispose() }
    Remove-Item -LiteralPath $failureFixturePath, $failureFixtureOutput, $failureFixtureCrash, $failureFixtureCrashExport, $staleFailurePath, $blockedFailurePath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $blockedCrashExport -Recurse -Force -ErrorAction SilentlyContinue
}

$leaseFunction = Import-MonitoredTestFunction -Path (Join-Path $RootPath 'tools\Invoke-MemLabsDeploymentChild.ps1') -Name 'Assert-MemLabsDeploymentLease'
$leasePath = Join-Path ([IO.Path]::GetTempPath()) ('memlabs-child-lease-' + [guid]::NewGuid().ToString('N') + '.json')
$handoffToken = [guid]::NewGuid().ToString('N')
$sha256 = [Security.Cryptography.SHA256]::Create()
try { $handoffHash = [Convert]::ToHexString($sha256.ComputeHash([Text.Encoding]::UTF8.GetBytes($handoffToken))) }
finally { $sha256.Dispose() }
$ownerStartUtc = '2026-09-09T00:00:00.0000000Z'
[pscustomobject]@{ OperationId = 'test-operation'; State = 'Active'; PID = 4242; ProcessStartUtc = $ownerStartUtc; HandoffHash = $handoffHash } |
    ConvertTo-Json -Compress | Set-Content -LiteralPath $leasePath -Encoding UTF8
$savedLeaseEnvironment = @{}
foreach ($name in 'MEMLABS_LIVEOPS_OPERATION_ID', 'MEMLABS_LIVEOPS_LEASE_PATH', 'MEMLABS_LIVEOPS_HANDOFF_TOKEN', 'MEMLABS_LIVEOPS_OWNER_PID', 'MEMLABS_LIVEOPS_OWNER_START_UTC') {
    $savedLeaseEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, [EnvironmentVariableTarget]::Process)
}
try {
    foreach ($name in $savedLeaseEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $null, [EnvironmentVariableTarget]::Process)
    }
    $missingLeaseError = $null
    try { . $leaseFunction; Assert-MemLabsDeploymentLease }
    catch { $missingLeaseError = $_ }
    Assert-Equal $true ($missingLeaseError.Exception.Message -like '*requires an active Live Ops lease handoff*') 'deployment child rejects direct invocation without a lease handoff'

    $env:MEMLABS_LIVEOPS_OPERATION_ID = 'test-operation'
    $env:MEMLABS_LIVEOPS_LEASE_PATH = $leasePath
    $env:MEMLABS_LIVEOPS_HANDOFF_TOKEN = $handoffToken
    $env:MEMLABS_LIVEOPS_OWNER_PID = '4242'
    $env:MEMLABS_LIVEOPS_OWNER_START_UTC = $ownerStartUtc
    $validLeaseOutput = @(& {
            param($FunctionDefinition)
            function Get-CimInstance { [pscustomobject]@{ ParentProcessId = 4242 } }
            function Get-Process { [pscustomobject]@{ Id = 4242; StartTime = [datetime]::SpecifyKind([datetime]'2026-09-09T00:00:00', [DateTimeKind]::Utc) } }
            . $FunctionDefinition
            Assert-MemLabsDeploymentLease
        } $leaseFunction)
    Assert-Equal 0 $validLeaseOutput.Count 'deployment child accepts a matching active parent lease without output pollution'
    $env:MEMLABS_LIVEOPS_OPERATION_ID = 'wrong-operation'
    $mismatchedLeaseError = $null
    try { & {
            param($FunctionDefinition)
            function Get-CimInstance { [pscustomobject]@{ ParentProcessId = 4242 } }
            function Get-Process { [pscustomobject]@{ Id = 4242; StartTime = [datetime]::SpecifyKind([datetime]'2026-09-09T00:00:00', [DateTimeKind]::Utc) } }
            . $FunctionDefinition
            Assert-MemLabsDeploymentLease
        } $leaseFunction }
    catch { $mismatchedLeaseError = $_ }
    Assert-Equal $true ([bool]$mismatchedLeaseError) 'deployment child rejects a mismatched lease handoff'

    $childFixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('memlabs-child-fixture-' + [guid]::NewGuid().ToString('N'))
    $childFixtureTools = Join-Path $childFixtureRoot 'tools'
    $null = New-Item -Path $childFixtureTools -ItemType Directory -Force
    Copy-Item -LiteralPath (Join-Path $RootPath 'tools\Invoke-MemLabsDeploymentChild.ps1') -Destination $childFixtureTools
    @'
param([string] $Configuration, [switch] $NoWindowResize, [switch] $NoSnapshot, [int] $StopPhase)
Set-Content -LiteralPath $env:MEMLABS_TEST_CHILD_MARKER -Value "StopPhase=$StopPhase"
'@ | Set-Content -LiteralPath (Join-Path $childFixtureRoot 'New-Lab.ps1') -Encoding UTF8
    $childMarker = Join-Path $childFixtureRoot 'started.txt'
    $childOutput = Join-Path $childFixtureRoot 'output.txt'
    $realOwnerStart = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
    [pscustomobject]@{ OperationId = 'test-operation'; State = 'Active'; PID = $PID; ProcessStartUtc = $realOwnerStart; HandoffHash = $handoffHash } |
        ConvertTo-Json -Compress | Set-Content -LiteralPath $leasePath -Encoding UTF8
    $env:MEMLABS_LIVEOPS_OPERATION_ID = 'test-operation'
    $env:MEMLABS_LIVEOPS_OWNER_PID = [string]$PID
    $env:MEMLABS_LIVEOPS_OWNER_START_UTC = $realOwnerStart
    $env:MEMLABS_TEST_CHILD_MARKER = $childMarker
    $childGateName = 'Local\MemLabsChildTest-' + [guid]::NewGuid().ToString('N')
    $childReadyName = $childGateName + '-Ready'
    $childGate = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, $childGateName)
    $childReady = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, $childReadyName)
    $childInfo = [Diagnostics.ProcessStartInfo]::new((Get-Command pwsh.exe).Source)
    $childInfo.UseShellExecute = $false
    $childCrashPath = Join-Path $childFixtureRoot 'child-crash.log'
    foreach ($argument in @('-NoProfile', '-File', (Join-Path $childFixtureTools 'Invoke-MemLabsDeploymentChild.ps1'), '-Configuration', 'fixture.json', '-OutputPath', $childOutput, '-GateName', $childGateName, '-GateReadyName', $childReadyName, '-CrashPath', $childCrashPath, '-StopPhase', '2')) {
        $childInfo.ArgumentList.Add($argument)
    }
    $childProcess = [Diagnostics.Process]::Start($childInfo)
    Assert-Equal $true $childReady.WaitOne(10000) 'real deployment child acknowledges its start gate'
    Assert-Equal $false (Test-Path -LiteralPath $childMarker) 'real deployment child does no New-Lab work before job assignment'
    $childJobHandle = [MemLabsNativeJob]::CreateKillOnClose()
    Add-MemLabsDeploymentProcessToJob -JobHandle $childJobHandle -Process $childProcess
    Assert-Equal $false (Test-Path -LiteralPath $childMarker) 'assigned deployment child remains blocked until parent gate release'
    $null = $childGate.Set()
    Assert-Equal $true $childProcess.WaitForExit(10000) 'released deployment child completes the harmless fixture'
    Assert-Equal 0 $childProcess.ExitCode 'released deployment child preserves the New-Lab exit code'
    Assert-Equal $true (Test-Path -LiteralPath $childMarker) 'real deployment child invokes New-Lab only after containment'
    Assert-Equal 'StopPhase=2' (Get-Content -LiteralPath $childMarker -Raw).Trim() 'deployment child passes StopPhase to New-Lab end to end'
    $null = [MemLabsNativeJob]::CloseHandle($childJobHandle)
    $childJobHandle = [IntPtr]::Zero
    $childProcess.Dispose()
    $childProcess = $null
    $childReady.Dispose()
    $childReady = $null
    $childGate.Dispose()
    $childGate = $null

    Remove-Item -LiteralPath $childMarker, $childOutput -Force -ErrorAction SilentlyContinue
    $conflictInfo = [Diagnostics.ProcessStartInfo]::new((Get-Command pwsh.exe).Source)
    $conflictInfo.UseShellExecute = $false
    foreach ($argument in @('-NoProfile', '-File', (Join-Path $childFixtureTools 'Invoke-MemLabsDeploymentChild.ps1'), '-Configuration', 'fixture.json', '-OutputPath', $childOutput, '-GateName', 'unused', '-GateReadyName', 'unused-ready', '-CrashPath', $childCrashPath, '-StartPhase', '3', '-StopPhase', '2')) {
        $conflictInfo.ArgumentList.Add($argument)
    }
    $conflictProcess = [Diagnostics.Process]::Start($conflictInfo)
    Assert-Equal $true $conflictProcess.WaitForExit(10000) 'conflicting child phase controls fail without waiting for a start gate'
    Assert-Equal 1 $conflictProcess.ExitCode 'conflicting child phase controls return failure'
    Assert-Equal $false (Test-Path -LiteralPath $childMarker) 'conflicting child phase controls cannot invoke New-Lab'
    Assert-Equal $true ((Get-Content -LiteralPath $childOutput -Raw) -like '*Specify -StopPhase only for a fresh sequential deployment*') 'conflicting child failure is actionable in the output artifact'
    $conflictProcess.Dispose()
    $conflictProcess = $null

    "throw 'fixture child bootstrap failure'" | Set-Content -LiteralPath (Join-Path $childFixtureRoot 'New-Lab.ps1') -Encoding UTF8
    Remove-Item -LiteralPath $childOutput -Force -ErrorAction SilentlyContinue
    $failureGateName = 'Local\MemLabsChildFailure-' + [guid]::NewGuid().ToString('N')
    $failureReadyName = $failureGateName + '-Ready'
    $failureGate = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, $failureGateName)
    $failureReady = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, $failureReadyName)
    $failureInfo = [Diagnostics.ProcessStartInfo]::new((Get-Command pwsh.exe).Source)
    $failureInfo.UseShellExecute = $false
    foreach ($argument in @('-NoProfile', '-File', (Join-Path $childFixtureTools 'Invoke-MemLabsDeploymentChild.ps1'), '-Configuration', 'fixture.json', '-OutputPath', $childOutput, '-GateName', $failureGateName, '-GateReadyName', $failureReadyName, '-CrashPath', $childCrashPath)) {
        $failureInfo.ArgumentList.Add($argument)
    }
    $failureProcess = [Diagnostics.Process]::Start($failureInfo)
    Assert-Equal $true $failureReady.WaitOne(10000) 'failing deployment child acknowledges its start gate'
    $failureJobHandle = [MemLabsNativeJob]::CreateKillOnClose()
    Add-MemLabsDeploymentProcessToJob -JobHandle $failureJobHandle -Process $failureProcess
    $null = $failureGate.Set()
    Assert-Equal $true $failureProcess.WaitForExit(10000) 'failing deployment child exits without hanging the monitor'
    Assert-Equal 1 $failureProcess.ExitCode 'deployment child returns failure when New-Lab throws'
    $failureOutput = Get-Content -LiteralPath $childOutput -Raw
    Assert-Equal $true ($failureOutput -like '*DEPLOYMENT CHILD FAILURE:*fixture child bootstrap failure*') 'deployment child preserves its bootstrap exception in the output artifact'
    $null = [MemLabsNativeJob]::CloseHandle($failureJobHandle)
    $failureJobHandle = [IntPtr]::Zero
    $failureProcess.Dispose()
    $failureProcess = $null
    $failureReady.Dispose()
    $failureReady = $null
    $failureGate.Dispose()
    $failureGate = $null

    $assignmentGateName = 'Local\MemLabsAssignmentTest-' + [guid]::NewGuid().ToString('N')
    $assignmentGate = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, $assignmentGateName)
    $assignmentMarker = Join-Path ([IO.Path]::GetTempPath()) ('memlabs-assignment-' + [guid]::NewGuid().ToString('N') + '.txt')
    $assignmentInfo = [Diagnostics.ProcessStartInfo]::new((Get-Command pwsh.exe).Source)
    $assignmentInfo.UseShellExecute = $false
    $assignmentInfo.ArgumentList.Add('-NoProfile')
    $assignmentInfo.ArgumentList.Add('-Command')
    $assignmentInfo.ArgumentList.Add('param($gateName, $marker); $gate = [Threading.EventWaitHandle]::OpenExisting($gateName); try { if ($gate.WaitOne(120000)) { Set-Content -LiteralPath $marker -Value started } } finally { $gate.Dispose() }')
    $assignmentInfo.ArgumentList.Add('-args')
    $assignmentInfo.ArgumentList.Add($assignmentGateName)
    $assignmentInfo.ArgumentList.Add($assignmentMarker)
    $assignmentProcess = [Diagnostics.Process]::Start($assignmentInfo)
    $assignmentFailure = $null
    try { Add-MemLabsDeploymentProcessToJob -JobHandle ([IntPtr]::Zero) -Process $assignmentProcess -TestAssignmentFailure }
    catch { $assignmentFailure = $_ }
    Assert-Equal $true ([bool]$assignmentFailure) 'injected job-assignment failure is observable'
    Assert-Equal $true $assignmentProcess.HasExited 'job-assignment failure terminates and awaits the unowned child'
    Assert-Equal $false (Test-Path -LiteralPath $assignmentMarker) 'job-assignment failure cannot release child work before containment'
    $assignmentProcess.Dispose()
    $assignmentGate.Dispose()
}
finally {
    if ($conflictProcess) {
        if (-not $conflictProcess.HasExited) { $conflictProcess.Kill($true); $null = $conflictProcess.WaitForExit(10000) }
        $conflictProcess.Dispose()
    }
    if ($failureJobHandle -and $failureJobHandle -ne [IntPtr]::Zero) { $null = [MemLabsNativeJob]::CloseHandle($failureJobHandle) }
    if ($failureProcess) {
        if (-not $failureProcess.HasExited) { $failureProcess.Kill($true); $null = $failureProcess.WaitForExit(10000) }
        $failureProcess.Dispose()
    }
    if ($failureReady) { $failureReady.Dispose() }
    if ($failureGate) { $failureGate.Dispose() }
    if ($childJobHandle -and $childJobHandle -ne [IntPtr]::Zero) { $null = [MemLabsNativeJob]::CloseHandle($childJobHandle) }
    if ($childProcess) {
        if (-not $childProcess.HasExited) { $childProcess.Kill($true); $null = $childProcess.WaitForExit(10000) }
        $childProcess.Dispose()
    }
    if ($childReady) { $childReady.Dispose() }
    if ($childGate) { $childGate.Dispose() }
    foreach ($name in $savedLeaseEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $savedLeaseEnvironment[$name], [EnvironmentVariableTarget]::Process)
    }
    [Environment]::SetEnvironmentVariable('MEMLABS_TEST_CHILD_MARKER', $null, [EnvironmentVariableTarget]::Process)
    Remove-Item -LiteralPath $leasePath -Force -ErrorAction SilentlyContinue
    if ($childFixtureRoot) { Remove-Item -LiteralPath $childFixtureRoot -Recurse -Force -ErrorAction SilentlyContinue }
    if ($assignmentMarker) { Remove-Item -LiteralPath $assignmentMarker -Force -ErrorAction SilentlyContinue }
}
$path = Join-Path ([IO.Path]::GetTempPath()) ('memlabs-monitor-' + [guid]::NewGuid().ToString('N') + '.jsonl')
$start = [datetime]'2026-09-09T00:00:00Z'
try {
    @(
        @{ t = '2026-09-09T00:00:01Z'; comp = 'New-Lab'; msg = '### START DEPLOYMENT test' }
        @{ t = '2026-09-09T00:01:00Z'; comp = 'Write-VmJobLedger'; msg = '[JobLedger] disposed id=changing-noise' }
        @{ t = '2026-09-09T00:02:00Z'; comp = 'VM_Config'; msg = '[Phase 2]: BDC1: DSC: Current Status for BDC: Promoting to Domain Controller' }
        @{ t = '2026-09-09T00:32:00Z'; comp = 'VM_Config'; msg = '[Phase 2]: BDC1: DSC: Current Status for BDC: Promoting to Domain Controller' }
        @{ t = '2026-09-09T00:33:00Z'; comp = 'Get-VmSession'; msg = 'connectMs=90123 lastError=timeout' }
        @{ t = '2026-09-09T00:34:00Z'; comp = 'VM_Config'; msg = '[Phase 2]: BDC1: DSC: Current Status for BDC: Applying ru-RU locale' }
        @{ t = '2026-09-09T00:35:00Z'; comp = 'Wait-Phase'; msg = '[Phase 2] Jobs completed; 5 success, 0 warnings, 0 failures.' }
    ) | ForEach-Object { $_ | ConvertTo-Json -Compress } | Set-Content -LiteralPath $path -Encoding UTF8

    $records = @(Get-MemLabsDeploymentProgressRecords -Path $path -SinceUtc $start)
    Assert-Equal 5 $records.Count 'only semantic phase and DSC status records count as progress'
    Assert-Equal 2 @($records | Where-Object Signature -like 'dsc-status*Promoting*').Count 'repeated identical status is observable but has the same signature'
    Assert-Equal 1 @($records.Signature | Sort-Object -Unique | Where-Object { $_ -like 'dsc-status*Promoting*' }).Count 'repeated status does not create new semantic progress'
    Assert-Equal 0 @(Get-MemLabsDeploymentProgressRecords -Path $path -SinceUtc ($start.AddHours(1))).Count 'records before monitor start are ignored'

    $jobHandle = [MemLabsNativeJob]::CreateKillOnClose()
    $waitInfo = [Diagnostics.ProcessStartInfo]::new((Get-Command pwsh.exe).Source)
    $waitInfo.UseShellExecute = $false
    $waitInfo.ArgumentList.Add('-NoProfile')
    $waitInfo.ArgumentList.Add('-Command')
    $waitInfo.ArgumentList.Add('$event = [Threading.ManualResetEventSlim]::new($false); $event.Wait()')
    $ownedProcess = [Diagnostics.Process]::Start($waitInfo)
    [MemLabsNativeJob]::Assign($jobHandle, $ownedProcess.Handle)
    [MemLabsNativeJob]::CloseHandle($jobHandle) | Out-Null
    Assert-Equal $true $ownedProcess.WaitForExit(10000) 'closing the native job terminates the owned process tree'
    $ownedProcess.Dispose()
}
finally {
    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
}

if ($script:Failures -ne 0) { throw "$script:Failures monitored deployment test(s) failed" }
Write-Host 'ALL MONITORED DEPLOYMENT TESTS PASSED' -ForegroundColor Green