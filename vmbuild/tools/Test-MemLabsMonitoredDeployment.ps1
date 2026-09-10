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
Assert-Equal $true ($monitorSource -match '\$Phase -and -not \$PSBoundParameters\.ContainsKey\(''ExpectedCompletedPhase''\)') 'partial phase runs derive their completion postcondition from requested phases'
Assert-Equal $true ($monitorSource -match '(?s)New-MemLabsDeploymentProcess.*?gateReady\.WaitOne.*?Add-MemLabsDeploymentProcessToJob.*?startGate\.Set\(\)' -and $childSource.IndexOf('gateReady.Set()') -lt $childSource.IndexOf('WaitOne([TimeSpan]::FromMinutes(2))') -and $childSource.IndexOf('WaitOne([TimeSpan]::FromMinutes(2))') -lt $childSource.IndexOf("& (Join-Path (Split-Path -Parent `$PSScriptRoot) 'New-Lab.ps1')")) 'deployment child acknowledges the gate then waits for job ownership before invoking New-Lab'
Assert-Equal $true ($monitorSource -match '(?s)finally \{.*?CloseHandle\(\$jobHandle\).*?\$process\.Kill\(\$true\).*?WaitForExit\(30000\)') 'monitor cleanup cannot return while an uncontained deployment process remains active'
Assert-Equal $true ($childSource -match '(?s)catch \{.*?DEPLOYMENT CHILD FAILURE:.*?Add-Content -LiteralPath \$OutputPath' -and $monitorSource -match 'Monitored deployment failed during Live Ops stage.*?Failure=\$failurePath.*?Output=\$outputPath.*?Monitor=\$monitorLogPath.*?Diagnostics=\$diagnosticsPath') 'bootstrap and callback failures publish synchronized evidence paths'

$failureWriter = Import-MonitoredTestFunction -Path (Join-Path $RootPath 'tools\Invoke-MemLabsMonitoredDeployment.ps1') -Name 'Save-MemLabsDeploymentFailure'
$stampWriter = Import-MonitoredTestFunction -Path (Join-Path $RootPath 'tools\Invoke-MemLabsMonitoredDeployment.ps1') -Name 'New-MemLabsDeploymentStamp'
$stamps = @(& { . $stampWriter; New-MemLabsDeploymentStamp; New-MemLabsDeploymentStamp })
Assert-Equal 2 @($stamps | Sort-Object -Unique).Count 'simultaneous monitor attempts receive unique artifact names'
$failureFixturePath = Join-Path ([IO.Path]::GetTempPath()) ('memlabs-monitor-failure-' + [guid]::NewGuid().ToString('N') + '.json')
try {
    . $failureWriter
    Save-MemLabsDeploymentFailure -Path $failureFixturePath -Stage Operation -ErrorMessage 'fixture operation failed' -OutputPath 'output.txt' -MonitorPath 'monitor.jsonl' -DiagnosticsPath 'diagnostics.json'
    $operationFailure = Get-Content -LiteralPath $failureFixturePath -Raw | ConvertFrom-Json
    Assert-Equal 'Operation' $operationFailure.Stage 'operation failure artifact records its stage'
    Assert-Equal 'fixture operation failed' $operationFailure.Error 'operation failure artifact preserves the actionable error'
    Save-MemLabsDeploymentFailure -Path $failureFixturePath -Stage Unhandled -ErrorMessage 'fixture fallback' -OperationId 'fixture-id' -JournalPath 'operations.jsonl' -ActiveOwnerMetadata '{"owner":"fixture"}' -FailureDiagnostics @('diagnostic fixture') -OutputPath 'output.txt' -MonitorPath 'monitor.jsonl' -DiagnosticsPath 'diagnostics.json'
    $coordinationFailure = Get-Content -LiteralPath $failureFixturePath -Raw | ConvertFrom-Json
    Assert-Equal 'Unhandled' $coordinationFailure.Stage 'uncorrelated failure artifact receives a nonempty fallback stage'
    Assert-Equal 'fixture fallback' $coordinationFailure.Error 'fallback failure artifact preserves the caught error'
    Assert-Equal 'fixture-id|operations.jsonl|{"owner":"fixture"}|diagnostic fixture' "$($coordinationFailure.OperationId)|$($coordinationFailure.Journal)|$($coordinationFailure.ActiveOwner)|$(@($coordinationFailure.FailureDiagnostics) -join ',')" 'correlated failure artifact preserves Live Ops evidence'
    Assert-Equal 'output.txt|monitor.jsonl|diagnostics.json' "$($coordinationFailure.Output)|$($coordinationFailure.Monitor)|$($coordinationFailure.Diagnostics)" 'failure artifact records every synchronized evidence path'
}
finally {
    Remove-Item -LiteralPath $failureFixturePath -Force -ErrorAction SilentlyContinue
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
param([string] $Configuration, [switch] $NoWindowResize, [switch] $NoSnapshot)
Set-Content -LiteralPath $env:MEMLABS_TEST_CHILD_MARKER -Value started
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
    foreach ($argument in @('-NoProfile', '-File', (Join-Path $childFixtureTools 'Invoke-MemLabsDeploymentChild.ps1'), '-Configuration', 'fixture.json', '-OutputPath', $childOutput, '-GateName', $childGateName, '-GateReadyName', $childReadyName)) {
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
    $null = [MemLabsNativeJob]::CloseHandle($childJobHandle)
    $childJobHandle = [IntPtr]::Zero
    $childProcess.Dispose()
    $childProcess = $null
    $childReady.Dispose()
    $childReady = $null
    $childGate.Dispose()
    $childGate = $null

    "throw 'fixture child bootstrap failure'" | Set-Content -LiteralPath (Join-Path $childFixtureRoot 'New-Lab.ps1') -Encoding UTF8
    Remove-Item -LiteralPath $childOutput -Force -ErrorAction SilentlyContinue
    $failureGateName = 'Local\MemLabsChildFailure-' + [guid]::NewGuid().ToString('N')
    $failureReadyName = $failureGateName + '-Ready'
    $failureGate = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, $failureGateName)
    $failureReady = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, $failureReadyName)
    $failureInfo = [Diagnostics.ProcessStartInfo]::new((Get-Command pwsh.exe).Source)
    $failureInfo.UseShellExecute = $false
    foreach ($argument in @('-NoProfile', '-File', (Join-Path $childFixtureTools 'Invoke-MemLabsDeploymentChild.ps1'), '-Configuration', 'fixture.json', '-OutputPath', $childOutput, '-GateName', $failureGateName, '-GateReadyName', $failureReadyName)) {
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