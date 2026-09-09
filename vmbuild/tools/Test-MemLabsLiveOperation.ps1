<#
.SYNOPSIS
    Verifies Live Ops lease exclusion, release, and journal behavior.

.DESCRIPTION
    Uses an isolated temporary coordination root and harmless HostResource
    operations. It does not query or modify Hyper-V, guests, or lab state.
#>
[CmdletBinding()]
param (
    [string] $RootPath
)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }

$script:Failures = 0
function Assert-LiveOpsEqual {
    param($Expected, $Actual, [string] $What)

    $passed = "$Expected" -eq "$Actual"
    if (-not $passed) { $script:Failures++ }
    $status = if ($passed) { 'PASS' } else { 'FAIL' }
    Write-Host ('{0}  {1}' -f $status, $What)
    if (-not $passed) {
        Write-Host "      expected: $Expected"
        Write-Host "      actual:   $Actual"
    }
}

function Import-LiveOpsTestFunction {
    param([string] $Path, [string] $Name)

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

$helper = Join-Path $RootPath 'tools\Invoke-MemLabsLiveOperation.ps1'
$helperSource = Get-Content -LiteralPath $helper -Raw
. (Import-LiveOpsTestFunction -Path $helper -Name 'Test-LiveOpsConflictingCommandLine')
. (Import-LiveOpsTestFunction -Path $helper -Name 'Read-LiveOpsActiveOwner')
$vmStateFunction = Import-LiveOpsTestFunction -Path $helper -Name 'Get-LiveOpsVmState'
$missingState = @(& {
        param($FunctionDefinition)
        function Get-Command { [pscustomobject]@{ Name = 'Get-VM' } }
        function Get-VM { param([string] $Name) @() }
        . $FunctionDefinition
        Get-LiveOpsVmState -Name 'DELETED-VM' -Type VM -AllowMissing
    } $vmStateFunction)
Assert-LiveOpsEqual 1 $missingState.Count 'Post-operation VM snapshot returns one record for a deleted target'
Assert-LiveOpsEqual $false $missingState[0].Exists 'Post-operation VM snapshot records an intentionally deleted target as absent'
Assert-LiveOpsEqual $true ($helperSource -match 'Get-LiveOpsVmState -Name \$normalizedTargets -Type \$TargetType -AllowMissing') 'Post-operation snapshots opt into missing-target representation'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('memlabs-liveops-test-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -Path $testRoot -ItemType Directory -Force
$heldStream = $null

try {
    $leasePath = Join-Path $testRoot 'mutation.lock'
    $journalPath = Join-Path $testRoot 'operations.jsonl'
    $heldStream = [IO.File]::Open($leasePath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read)
    $ownerText = '{"OperationId":"other-session","PID":4242,"State":"Active"}'
    $ownerBytes = [Text.Encoding]::UTF8.GetBytes($ownerText)
    $heldStream.Write($ownerBytes, 0, $ownerBytes.Length)
    $heldStream.Flush()

    $releasingText = '{"OperationId":"releasing-session","PID":4343,"State":"Releasing"}'
    [IO.File]::WriteAllText((Join-Path $testRoot 'releasing.lock'), $releasingText)
    Assert-LiveOpsEqual $releasingText (Read-LiveOpsActiveOwner -Path (Join-Path $testRoot 'releasing.lock')) 'Releasing metadata remains visible as an active lease owner'

    $observeResult = & $helper -Mode Observe -Intent 'test concurrent observation' -Target 'TEST-RESOURCE' -TargetType HostResource -TestCoordinationRoot $testRoot -Operation { 'observed' } -IncludeOperationOutput
    Assert-LiveOpsEqual 'observed' $observeResult.Output[0] 'Observe operation may run while mutation lease is held'

    $emptyObserveResult = & $helper -Mode Observe -Intent 'test empty observation' -Target 'TEST-RESOURCE' -TargetType HostResource -TestCoordinationRoot $testRoot -Operation {}
    Assert-LiveOpsEqual 0 $emptyObserveResult.Output.Count 'Literal empty operation executes with zero output'

    $observeFailureError = $null
    try {
        $null = & $helper -Mode Observe -Intent 'observe failure fixture' -Target 'TEST-RESOURCE' -TargetType HostResource -TestCoordinationRoot $testRoot -Operation { throw 'observe fixture failure' }
    }
    catch { $observeFailureError = $_ }
    Assert-LiveOpsEqual $true ([bool]$observeFailureError) 'Observe operation failure returns correlation data'
    $observeFailureDiagnostics = $observeFailureError.Exception.Data['FailureDiagnostics']
    Assert-LiveOpsEqual $false ($null -eq $observeFailureDiagnostics) 'Observe failure stores a real diagnostics collection'
    Assert-LiveOpsEqual 0 $observeFailureDiagnostics.Count 'Observe failure reports zero diagnostics when no callback ran'

    $trailingRootResult = & $helper -Mode Observe -Intent 'trailing root fixture' -Target 'TEST-RESOURCE' -TargetType HostResource -TestCoordinationRoot ($testRoot + [IO.Path]::DirectorySeparatorChar) -Operation {}
    Assert-LiveOpsEqual 0 $trailingRootResult.OutputCount 'Temporary coordination root accepts a trailing separator without changing identity'

    $externalCallerPath = Join-Path $testRoot 'external-caller.ps1'
    @'
param($Helper, $TestRoot)
& $Helper -Mode Observe -Intent 'external test-mode caller' -Target 'TEST-RESOURCE' -TargetType HostResource -TestCoordinationRoot $TestRoot -Operation {}
'@ | Set-Content -LiteralPath $externalCallerPath -Encoding UTF8
    $externalCallerError = $null
    try { $null = & $externalCallerPath -Helper $helper -TestRoot $testRoot }
    catch { $externalCallerError = $_ }
    Assert-LiveOpsEqual $true ($externalCallerError.Exception.Message -like '*only be used by Test-MemLabsLiveOperation.ps1*') 'Temporary-root test mode rejects an external caller'

    $suppressedOutputResult = & $helper -Mode Observe -Intent 'test default output suppression' -Target 'TEST-RESOURCE' -TargetType HostResource -TestCoordinationRoot $testRoot -Operation { 'sensitive fixture output' }
    Assert-LiveOpsEqual 1 $suppressedOutputResult.OutputCount 'Wrapper records operation output count'
    Assert-LiveOpsEqual 0 $suppressedOutputResult.Output.Count 'Wrapper suppresses operation output unless explicitly requested'

    $streamSuppressionResult = & $helper -Mode Observe -Intent 'auxiliary stream suppression fixture' -Target 'TEST-RESOURCE' -TargetType HostResource -TestCoordinationRoot $testRoot -Operation { $VerbosePreference = 'Continue'; $DebugPreference = 'Continue'; Write-Warning 'hidden warning'; Write-Information 'hidden information' -InformationAction Continue; Write-Verbose 'hidden verbose'; Write-Debug 'hidden debug'; Write-Host 'hidden host'; Write-Progress -Activity 'hidden progress'; 'safe output' } -IncludeOperationOutput
    Assert-LiveOpsEqual 1 $streamSuppressionResult.OutputCount 'Auxiliary operation streams do not pollute success output cardinality'
    Assert-LiveOpsEqual 'safe output' $streamSuppressionResult.Output[0] 'Auxiliary operation streams are suppressed from returned output'

    $normalizedTargetResult = & $helper -Mode Observe -Intent 'test target normalization' -Target @(' TEST-RESOURCE ', '', 'TEST-RESOURCE') -TargetType HostResource -TestCoordinationRoot $testRoot -Operation {}
    Assert-LiveOpsEqual 1 $normalizedTargetResult.Targets.Count 'Duplicate and blank target elements normalize to one target'
    $blankTargetError = $null
    try {
        $null = & $helper -Mode Observe -Intent 'blank target fixture' -Target @('', ' ') -TargetType HostResource -TestCoordinationRoot $testRoot -Operation {}
    }
    catch { $blankTargetError = $_ }
    Assert-LiveOpsEqual $true ($blankTargetError.Exception.Message -like '*non-empty target*') 'All-blank target list fails with the wrapper validation message'

    $blockedError = $null
    try {
        $null = & $helper -Mode Mutate -Intent 'must be rejected' -Target 'TEST-RESOURCE' -TargetType HostResource -TestCoordinationRoot $testRoot -Operation { 'should-not-run' } -Postcondition { $true } -FailureDiagnostics {} -SkipActiveProcessCheck
    }
    catch { $blockedError = $_ }
    Assert-LiveOpsEqual $true ([bool]$blockedError) 'Second mutation is rejected while lease is held'
    Assert-LiveOpsEqual $true ([string]$blockedError.Exception.Data['ActiveOwnerMetadata'] -like '*other-session*') 'Lease rejection includes readable owner metadata'

    $heldStream.Dispose()
    $heldStream = $null

    $missingPostconditionError = $null
    try {
        $null = & $helper -Mode Mutate -Intent 'missing postcondition fixture' -Target 'TEST-RESOURCE' -TargetType HostResource -TestCoordinationRoot $testRoot -Operation { 'should-not-run' } -FailureDiagnostics {} -SkipActiveProcessCheck
    }
    catch { $missingPostconditionError = $_ }
    Assert-LiveOpsEqual $true ($missingPostconditionError.Exception.Message -like '*Postcondition*') 'Mutation requires a behavior-specific postcondition'

    $missingFailureDiagnosticsError = $null
    try {
        $null = & $helper -Mode Mutate -Intent 'missing failure diagnostics fixture' -Target 'TEST-RESOURCE' -TargetType HostResource -TestCoordinationRoot $testRoot -Operation { 'should-not-run' } -Postcondition { $true } -SkipActiveProcessCheck
    }
    catch { $missingFailureDiagnosticsError = $_ }
    Assert-LiveOpsEqual $true ($missingFailureDiagnosticsError.Exception.Message -like '*FailureDiagnostics*') 'Mutation requires lease-held failure diagnostics'

    $unsafeBypassError = $null
    try {
        $null = & $helper -Mode Observe -Intent 'invalid bypass fixture' -Target 'NOT-A-REAL-VM' -TargetType VM -TestCoordinationRoot $testRoot -Operation {} -SkipActiveProcessCheck
    }
    catch { $unsafeBypassError = $_ }
    Assert-LiveOpsEqual $true ($unsafeBypassError.Exception.Message -like '*restricted to HostResource tests*') 'Active-process bypass cannot be used for VM targets'

    $junctionRoot = Join-Path $testRoot 'junction-root'
    $junctionTarget = Join-Path $testRoot 'junction-target'
    $null = New-Item -Path $junctionTarget -ItemType Directory -Force
    $null = New-Item -Path $junctionRoot -ItemType Junction -Target $junctionTarget -ErrorAction Stop
    $junctionBypassError = $null
    try {
        $null = & $helper -Mode Observe -Intent 'junction bypass fixture' -Target 'TEST-RESOURCE' -TargetType HostResource -TestCoordinationRoot $junctionRoot -Operation {} -SkipActiveProcessCheck
    }
    catch { $junctionBypassError = $_ }
    Assert-LiveOpsEqual $true ($junctionBypassError.Exception.Message -like '*restricted to HostResource tests*') 'Active-process bypass rejects junction coordination roots'

    $ancestorTarget = Join-Path $testRoot 'ancestor-target'
    $ancestorLink = Join-Path $testRoot 'ancestor-link'
    $null = New-Item -Path $ancestorTarget -ItemType Directory -Force
    $null = New-Item -Path $ancestorLink -ItemType Junction -Target $ancestorTarget -ErrorAction Stop
    $ancestorBypassError = $null
    try {
        $null = & $helper -Mode Observe -Intent 'junction ancestor fixture' -Target 'TEST-RESOURCE' -TargetType HostResource -TestCoordinationRoot (Join-Path $ancestorLink 'child') -Operation {} -SkipActiveProcessCheck
    }
    catch { $ancestorBypassError = $_ }
    Assert-LiveOpsEqual $true ($ancestorBypassError.Exception.Message -like '*non-reparse-point*') 'Temporary-root test mode rejects a junction ancestor'

    $mutateResult = & $helper -Mode Mutate -Intent 'harmless mutation fixture' -Target 'TEST-RESOURCE' -TargetType HostResource -TestCoordinationRoot $testRoot -Operation { [pscustomobject]@{ Changed = $true } } -Postcondition { param($Output) Write-Warning 'hidden postcondition warning'; return [bool]($Output.Count -eq 1 -and $Output[0].Changed) } -FailureDiagnostics {} -SkipActiveProcessCheck -IncludeOperationOutput
    Assert-LiveOpsEqual $true $mutateResult.Output[0].Changed 'Mutation executes after lease is released'
    Assert-LiveOpsEqual $true $mutateResult.PostconditionPassed 'Successful mutation records its postcondition result'

    $handoffNames = @('MEMLABS_LIVEOPS_OPERATION_ID', 'MEMLABS_LIVEOPS_LEASE_PATH', 'MEMLABS_LIVEOPS_HANDOFF_TOKEN', 'MEMLABS_LIVEOPS_OWNER_PID', 'MEMLABS_LIVEOPS_OWNER_START_UTC')
    $beforeHandoffEnvironment = @{}
    foreach ($name in $handoffNames) { $beforeHandoffEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, [EnvironmentVariableTarget]::Process) }
    $handoffResult = & $helper -Mode Mutate -Intent 'child handoff fixture' -Target 'TEST-RESOURCE' -TargetType HostResource -TestCoordinationRoot $testRoot -Operation {
        $metadata = Get-Content -LiteralPath $env:MEMLABS_LIVEOPS_LEASE_PATH -Raw | ConvertFrom-Json
        $sha256 = [Security.Cryptography.SHA256]::Create()
        try { $tokenHash = [Convert]::ToHexString($sha256.ComputeHash([Text.Encoding]::UTF8.GetBytes($env:MEMLABS_LIVEOPS_HANDOFF_TOKEN))) }
        finally { $sha256.Dispose() }
        [pscustomobject]@{
            OperationMatches = $metadata.OperationId -eq $env:MEMLABS_LIVEOPS_OPERATION_ID
            TokenMatches = $metadata.HandoffHash -eq $tokenHash
            OwnerMatches = [int]$env:MEMLABS_LIVEOPS_OWNER_PID -eq $PID
            StartMatches = [string]$metadata.ProcessStartUtc -and $env:MEMLABS_LIVEOPS_OWNER_START_UTC
        }
    } -Postcondition { param($Output) return [bool]($Output.Count -eq 1 -and $Output[0].OperationMatches -and $Output[0].TokenMatches -and $Output[0].OwnerMatches -and $Output[0].StartMatches) } -FailureDiagnostics {} -SkipActiveProcessCheck -IncludeOperationOutput
    Assert-LiveOpsEqual $true $handoffResult.PostconditionPassed 'Lease-held callback receives a handoff matching active owner metadata'
    $handoffEnvironmentRestored = $true
    foreach ($name in $handoffNames) {
        if ([Environment]::GetEnvironmentVariable($name, [EnvironmentVariableTarget]::Process) -ne $beforeHandoffEnvironment[$name]) { $handoffEnvironmentRestored = $false }
    }
    Assert-LiveOpsEqual $true $handoffEnvironmentRestored 'Live Ops restores child handoff environment after the callback'

    $multiOutputResult = & $helper -Mode Mutate -Intent 'two-output cardinality fixture' -Target 'TEST-RESOURCE' -TargetType HostResource -TestCoordinationRoot $testRoot -Operation { 'first'; 'second' } -Postcondition { param($Output) return [bool]($Output.Count -eq 2 -and $Output[0] -eq 'first' -and $Output[1] -eq 'second') } -FailureDiagnostics {} -SkipActiveProcessCheck -IncludeOperationOutput
    Assert-LiveOpsEqual 2 $multiOutputResult.Output.Count 'Postcondition receives operation output without an extra array wrapper'

    $savedErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $nativeFailureResult = & $helper -Mode Mutate -Intent 'handled native failure fixture' -Target 'TEST-RESOURCE' -TargetType HostResource -TestCoordinationRoot $testRoot -Operation {
            $nativeOutput = @(& cmd.exe /d /c 'echo expected native stderr 1>&2 & exit /b 7' 2>&1)
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; OutputCount = $nativeOutput.Count }
        } -Postcondition { param($Output) return [bool]($Output.Count -eq 1 -and $Output[0].ExitCode -eq 7 -and $Output[0].OutputCount -gt 0) } -FailureDiagnostics {} -SkipActiveProcessCheck -IncludeOperationOutput
    }
    finally {
        $ErrorActionPreference = $savedErrorActionPreference
    }
    Assert-LiveOpsEqual 7 $nativeFailureResult.Output[0].ExitCode 'Operation callback handles expected native stderr and exit status under the caller preference'
    Assert-LiveOpsEqual $true $nativeFailureResult.PostconditionPassed 'Handled native failure reaches postcondition verification'

    $savedErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $nativePostconditionResult = & $helper -Mode Mutate -Intent 'handled native postcondition fixture' -Target 'TEST-RESOURCE' -TargetType HostResource -TestCoordinationRoot $testRoot -Operation { 'changed' } -Postcondition {
            $nativeOutput = @(& cmd.exe /d /c 'echo expected postcondition stderr 1>&2 & exit /b 7' 2>&1)
            return [bool]($LASTEXITCODE -eq 7 -and $nativeOutput.Count -gt 0)
        } -FailureDiagnostics {} -SkipActiveProcessCheck
    }
    finally {
        $ErrorActionPreference = $savedErrorActionPreference
    }
    Assert-LiveOpsEqual $true $nativePostconditionResult.PostconditionPassed 'Postcondition callback handles expected native stderr under the caller preference'

    $savedErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $nativeDiagnosticsError = $null
        try {
            $null = & $helper -Mode Mutate -Intent 'handled native diagnostics fixture' -Target 'TEST-RESOURCE' -TargetType HostResource -TestCoordinationRoot $testRoot -Operation { throw 'diagnostics trigger' } -Postcondition { $true } -FailureDiagnostics {
                $nativeOutput = @(& cmd.exe /d /c 'echo expected diagnostics stderr 1>&2 & exit /b 7' 2>&1)
                [pscustomobject]@{ ExitCode = $LASTEXITCODE; OutputCount = $nativeOutput.Count }
            } -SkipActiveProcessCheck
        }
        catch { $nativeDiagnosticsError = $_ }
    }
    finally {
        $ErrorActionPreference = $savedErrorActionPreference
    }
    $nativeDiagnostics = $nativeDiagnosticsError.Exception.Data['FailureDiagnostics']
    Assert-LiveOpsEqual 7 $nativeDiagnostics[0].ExitCode 'Failure-diagnostics callback handles expected native stderr under the caller preference'

    $pipelineObservations = @(& $helper -Mode Mutate -Intent 'success pipeline ordering fixture' -Target 'TEST-RESOURCE' -TargetType HostResource -TestCoordinationRoot $testRoot -Operation { 'changed' } -Postcondition { $true } -FailureDiagnostics {} -SkipActiveProcessCheck |
        ForEach-Object {
            $consumerProbe = [IO.File]::Open($leasePath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            try { [pscustomobject]@{ Result = $_; LeaseReleased = $true } }
            finally { $consumerProbe.Dispose() }
        })
    Assert-LiveOpsEqual 1 $pipelineObservations.Count 'Successful operation emits exactly one result after cleanup'
    Assert-LiveOpsEqual $true $pipelineObservations[0].LeaseReleased 'Pipeline consumer sees the authoritative lease already released'

    $disposeFailureError = $null
    $disposeFailureConsumerOutput = [Collections.Generic.List[object]]::new()
    try {
        & $helper -Mode Mutate -Intent 'lease disposal failure fixture' -Target 'TEST-RESOURCE' -TargetType HostResource -TestCoordinationRoot $testRoot -Operation { 'changed' } -Postcondition { $true } -FailureDiagnostics {} -SkipActiveProcessCheck -TestLeaseDisposeFailure |
            ForEach-Object { $disposeFailureConsumerOutput.Add($_) }
    }
    catch { $disposeFailureError = $_ }
    Assert-LiveOpsEqual 'LeaseRelease' ([string]$disposeFailureError.Exception.Data['FailureStage']) 'Lease disposal failure rejects an otherwise successful operation at release'
    Assert-LiveOpsEqual $true ([bool]$disposeFailureError.Exception.Data['OperationSucceeded']) 'Lease disposal failure preserves that operation and postcondition completed'
    Assert-LiveOpsEqual 0 $disposeFailureConsumerOutput.Count 'Lease disposal failure emits no success object to pipeline consumers'
    $disposeFailureOperationId = [string]$disposeFailureError.Exception.Data['OperationId']
    $disposeFailureRecords = @(Get-Content -LiteralPath $journalPath | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object OperationId -eq $disposeFailureOperationId)
    Assert-LiveOpsEqual $false ([bool]($disposeFailureRecords | Where-Object Event -eq 'LeaseReleased' | Select-Object -First 1)) 'Lease disposal failure never produces a LeaseReleased journal event'
    Assert-LiveOpsEqual $true ($helperSource.IndexOf('$leaseStream.Dispose()') -lt $helperSource.IndexOf("Event = 'LeaseReleased'")) 'Wrapper closes the authoritative lease handle before journaling release'

    $exclusiveProbe = [IO.File]::Open($leasePath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $exclusiveProbe.Dispose()
    Assert-LiveOpsEqual $true $true 'Mutation lease handle is released after success'

    $destructiveError = $null
    try {
        $null = & $helper -Mode Destructive -Intent 'missing acknowledgment fixture' -Target 'TEST-RESOURCE' -TargetType HostResource -TestCoordinationRoot $testRoot -Operation { 'should-not-run' } -Postcondition { $true } -FailureDiagnostics {} -ExpectedLoss 'fixture data' -RecoveryPath 'recreate fixture' -SkipActiveProcessCheck
    }
    catch { $destructiveError = $_ }
    Assert-LiveOpsEqual $true ($destructiveError.Exception.Message -like '*AcknowledgeDestructive*') 'Destructive mode requires explicit acknowledgment'

    $destructiveMetadataError = $null
    try {
        $null = & $helper -Mode Destructive -Intent 'missing recovery metadata fixture' -Target 'TEST-RESOURCE' -TargetType HostResource -TestCoordinationRoot $testRoot -Operation { 'should-not-run' } -Postcondition { $true } -FailureDiagnostics {} -AcknowledgeDestructive -SkipActiveProcessCheck
    }
    catch { $destructiveMetadataError = $_ }
    Assert-LiveOpsEqual $true ($destructiveMetadataError.Exception.Message -like '*ExpectedLoss*RecoveryPath*') 'Destructive mode requires expected-loss and recovery metadata'

    $destructiveResult = & $helper -Mode Destructive -Intent 'harmless destructive contract fixture' -Target 'TEST-RESOURCE' -TargetType HostResource -TestCoordinationRoot $testRoot -Operation { 'fixture changed' } -Postcondition { $true } -FailureDiagnostics {} -ExpectedLoss 'temporary fixture value' -RecoveryPath 'rerun fixture setup' -AcknowledgeDestructive -SkipActiveProcessCheck
    Assert-LiveOpsEqual $true $destructiveResult.PostconditionPassed 'Acknowledged destructive fixture verifies its postcondition'

    $failureDiagnostics = {
        $diagnosticProbe = $null
        try {
            $diagnosticProbe = [IO.File]::Open($leasePath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            throw 'failure diagnostics ran without the mutation lease'
        }
        catch [IO.IOException] {
            'lease-held'
        }
        finally {
            if ($diagnosticProbe) { $diagnosticProbe.Dispose() }
        }
    }
    $failureError = $null
    try {
        $null = & $helper -Mode Mutate -Intent 'planted failure fixture' -Target 'TEST-RESOURCE' -TargetType HostResource -TestCoordinationRoot $testRoot -Operation { throw 'planted live-ops failure' } -Postcondition { $true } -FailureDiagnostics $failureDiagnostics -SkipActiveProcessCheck
    }
    catch { $failureError = $_ }
    Assert-LiveOpsEqual $true ($failureError.Exception.Message -like '*Live operation failed*OperationId=*JournalPath=*') 'Operation failure returns sanitized correlation data'
    Assert-LiveOpsEqual $true (-not $failureError.Exception.Message.Contains('planted live-ops failure')) 'Correlated failure message does not expose the original exception text'
    Assert-LiveOpsEqual $null $failureError.Exception.InnerException 'Correlated failure does not retain the original exception as InnerException'
    Assert-LiveOpsEqual $true (-not [string]::IsNullOrWhiteSpace([string]$failureError.Exception.Data['OperationId'])) 'Failed operation exposes its operation ID'
    Assert-LiveOpsEqual $journalPath ([string]$failureError.Exception.Data['JournalPath']) 'Failed operation exposes its journal path'
    Assert-LiveOpsEqual 'lease-held' (@($failureError.Exception.Data['FailureDiagnostics']) -join ',') 'Failed operation exposes lease-held diagnostic evidence to the caller'

    $postFailureProbe = [IO.File]::Open($leasePath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $postFailureProbe.Dispose()
    Assert-LiveOpsEqual $true $true 'Mutation lease handle is released after failure'

    $falsePostconditionError = $null
    try {
        $null = & $helper -Mode Mutate -Intent 'false postcondition fixture' -Target 'TEST-RESOURCE' -TargetType HostResource -TestCoordinationRoot $testRoot -Operation { 'changed' } -Postcondition { $false } -FailureDiagnostics { 'postcondition failure evidence' } -SkipActiveProcessCheck
    }
    catch { $falsePostconditionError = $_ }
    Assert-LiveOpsEqual 'Postcondition' ([string]$falsePostconditionError.Exception.Data['FailureStage']) 'False postcondition fails the operation at the postcondition stage'
    $postconditionFailureProbe = [IO.File]::Open($leasePath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $postconditionFailureProbe.Dispose()
    Assert-LiveOpsEqual $true $true 'Mutation lease handle is released after postcondition failure'

    $pollutedPostconditionError = $null
    try {
        $null = & $helper -Mode Mutate -Intent 'polluted postcondition fixture' -Target 'TEST-RESOURCE' -TargetType HostResource -TestCoordinationRoot $testRoot -Operation { 'changed' } -Postcondition { 'diagnostic'; $true } -FailureDiagnostics {} -SkipActiveProcessCheck
    }
    catch { $pollutedPostconditionError = $_ }
    Assert-LiveOpsEqual 'Postcondition' ([string]$pollutedPostconditionError.Exception.Data['FailureStage']) 'Postcondition output pollution fails closed'

    $records = @(Get-Content -LiteralPath $journalPath | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-LiveOpsEqual $true ($records.Count -gt 0) 'Journal contains operation records'
    Assert-LiveOpsEqual $true ([bool]($records | Where-Object Event -eq 'LeaseAcquired' | Select-Object -First 1)) 'Journal records lease acquisition'
    Assert-LiveOpsEqual $true ([bool]($records | Where-Object Event -eq 'OperationCompleted' | Select-Object -First 1)) 'Journal records successful completion'
    Assert-LiveOpsEqual $true ([bool]($records | Where-Object Event -eq 'PostconditionChecked' | Select-Object -First 1)) 'Journal records postcondition verification'
    $failureDiagnosticRecord = $records | Where-Object Event -eq 'FailureDiagnosticsCompleted' | Select-Object -First 1
    Assert-LiveOpsEqual 1 $failureDiagnosticRecord.OutputCount 'Failure diagnostics execute while the mutation lease is held'
    Assert-LiveOpsEqual $true ([bool]($records | Where-Object Event -eq 'OperationFailed' | Select-Object -First 1)) 'Journal records rejected and failed operations'
    Assert-LiveOpsEqual $true ([bool]($records | Where-Object Event -eq 'LeaseReleased' | Select-Object -First 1)) 'Journal records lease release'
    Assert-LiveOpsEqual $false ([bool](Get-Content -LiteralPath $journalPath -Raw | Select-String 'planted live-ops failure' -SimpleMatch)) 'Journal does not persist exception message text'
    $destructiveRequest = $records | Where-Object { $_.Event -eq 'Requested' -and $_.Owner.Mode -eq 'Destructive' -and $_.Owner.Intent -eq 'harmless destructive contract fixture' } | Select-Object -First 1
    Assert-LiveOpsEqual 'temporary fixture value' $destructiveRequest.Owner.ExpectedLoss 'Journal records destructive expected loss'
    Assert-LiveOpsEqual 'rerun fixture setup' $destructiveRequest.Owner.RecoveryPath 'Journal records destructive recovery path'

    Assert-LiveOpsEqual $true (Test-LiveOpsConflictingCommandLine -CommandLine 'pwsh -File C:\memlabs\vmbuild\New-Lab.ps1') 'Active-process matcher detects New-Lab entry point'
    Assert-LiveOpsEqual $true (Test-LiveOpsConflictingCommandLine -CommandLine 'pwsh -File C:\memlabs\vmbuild\tools\Invoke-MemLabsDeploymentChild.ps1 -Configuration x.json') 'Active-process matcher detects an uncoordinated deployment child'
    Assert-LiveOpsEqual $true (Test-LiveOpsConflictingCommandLine -CommandLine 'pwsh -Command "Start-Phase -Phase 3"') 'Active-process matcher detects direct Start-Phase command'
    Assert-LiveOpsEqual $true (Test-LiveOpsConflictingCommandLine -CommandLine 'pwsh -Command "Start-Phase; Write-Host done"') 'Active-process matcher detects semicolon-delimited Start-Phase command'
    Assert-LiveOpsEqual $true (Test-LiveOpsConflictingCommandLine -CommandLine 'pwsh -EncodedCommand ZgBpAHgAdAB1AHIAZQA=') 'Active-process matcher conservatively detects encoded PowerShell commands'
    Assert-LiveOpsEqual $false (Test-LiveOpsConflictingCommandLine -CommandLine 'pwsh -File C:\memlabs\vmbuild\tools\Invoke-MemLabsLiveOperation.ps1 -Mode Observe') 'Observe wrappers remain concurrent with lease-coordinated mutations'
    Assert-LiveOpsEqual $false (Test-LiveOpsConflictingCommandLine -CommandLine 'pwsh -File C:\memlabs\vmbuild\tools\Invoke-MemLabsLiveOperation.ps1 -Mode Mutate') 'Mutation wrappers defer to the authoritative file lease'
    Assert-LiveOpsEqual $false (Test-LiveOpsConflictingCommandLine -CommandLine 'pwsh -File C:\memlabs\vmbuild\tools\Invoke-MemLabsLiveOperation.ps1 -Mode Observe -Intent "Inspect New-Lab.ps1"') 'Wrapper intent text cannot become a legacy process conflict'
    Assert-LiveOpsEqual $false (Test-LiveOpsConflictingCommandLine -CommandLine 'pwsh -File C:\memlabs\vmbuild\tools\Invoke-MemLabsLiveOperation.ps1 -Mode Mutate -Intent "Run Start-Phase"') 'Wrapper mutation arguments defer to lease coordination'
    Assert-LiveOpsEqual $true (Test-LiveOpsConflictingCommandLine -CommandLine 'pwsh -EncodedCommand ZgBpAHgAdAB1AHIAZQA= Invoke-MemLabsLiveOperation.ps1') 'Encoded wrapper command lines remain conservatively blocked'
    Assert-LiveOpsEqual $true (Test-LiveOpsConflictingCommandLine -CommandLine 'powershell.exe /EncodedCommand ZgBpAHgAdAB1AHIAZQA=') 'Slash-prefixed encoded commands remain conservatively blocked'
    Assert-LiveOpsEqual $true (Test-LiveOpsConflictingCommandLine -CommandLine 'pwsh -EncodedCom ZgBpAHgAdAB1AHIAZQA=') 'EncodedCommand mid-prefix abbreviation remains conservatively blocked'
    Assert-LiveOpsEqual $true (Test-LiveOpsConflictingCommandLine -CommandLine 'powershell.exe "-EncodedCom" ZgBpAHgAdAB1AHIAZQA=') 'Quoted EncodedCommand mid-prefix remains conservatively blocked'
    Assert-LiveOpsEqual $true (Test-LiveOpsConflictingCommandLine -CommandLine 'pwsh -Command "& C:\memlabs\vmbuild\New-Lab.ps1; Write-Output Invoke-MemLabsLiveOperation.ps1"') 'Wrapper text in legacy command arguments cannot hide an unwrapped launcher'
    Assert-LiveOpsEqual $true (Test-LiveOpsConflictingCommandLine -CommandLine 'pwsh -Command "New-Lab.ps1 # -File C:\memlabs\vmbuild\tools\Invoke-MemLabsLiveOperation.ps1 "') 'Wrapper-like File text inside a Command payload cannot hide an unwrapped launcher'
    Assert-LiveOpsEqual $true (Test-LiveOpsConflictingCommandLine -CommandLine 'pwsh "-Command" "New-Lab.ps1 # -File C:\memlabs\vmbuild\tools\Invoke-MemLabsLiveOperation.ps1 "') 'Quoted Command mode cannot hide an unwrapped launcher behind wrapper text'
    Assert-LiveOpsEqual $false (Test-LiveOpsConflictingCommandLine -CommandLine 'pwsh "-File" "C:\memlabs\vmbuild\tools\Invoke-MemLabsLiveOperation.ps1" -Mode Observe -Intent "Inspect New-Lab.ps1"') 'Quoted File mode still identifies the real wrapper entry point'
    Assert-LiveOpsEqual $false (Test-LiveOpsConflictingCommandLine -CommandLine 'pwsh -File C:\temp\Start-Phase-benign-fixture.ps1') 'Active-process matcher ignores longer benign command names'

    $journalFailureDiagnostics = {
        Remove-Item -LiteralPath $journalPath -Force
        $null = New-Item -Path $journalPath -ItemType Directory -Force
        'journal failure evidence'
    }
    $journalFailureError = $null
    try {
        $null = & $helper -Mode Mutate -Intent 'journal failure fixture' -Target 'TEST-RESOURCE' -TargetType HostResource -TestCoordinationRoot $testRoot -Operation { throw 'journal-break trigger' } -Postcondition { $true } -FailureDiagnostics $journalFailureDiagnostics -SkipActiveProcessCheck
    }
    catch { $journalFailureError = $_ }
    Assert-LiveOpsEqual $true (-not [string]::IsNullOrWhiteSpace([string]$journalFailureError.Exception.Data['OperationId'])) 'Failure journal errors do not mask the operation ID'
    Assert-LiveOpsEqual $journalPath ([string]$journalFailureError.Exception.Data['JournalPath']) 'Failure journal errors do not mask the journal path'
    Assert-LiveOpsEqual 'journal failure evidence' (@($journalFailureError.Exception.Data['FailureDiagnostics']) -join ',') 'Failure journal errors do not mask diagnostic evidence'
    Assert-LiveOpsEqual $true (-not [string]::IsNullOrWhiteSpace([string]$journalFailureError.Exception.Data['FailureJournalErrorType'])) 'Failure journal error type is attached to correlation data'
    Assert-LiveOpsEqual $true (-not [string]::IsNullOrWhiteSpace([string]$journalFailureError.Exception.Data['LeaseReleaseJournalErrorType'])) 'Lease-release journal errors attach without masking the original operation failure'
}
finally {
    if ($heldStream) { $heldStream.Dispose() }
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:Failures -ne 0) { throw "$script:Failures Live Ops test(s) failed" }
Write-Host 'ALL MEMLABS LIVE OPS TESTS PASSED' -ForegroundColor Green