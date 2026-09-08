<#
.SYNOPSIS
    Coordinates and journals live MemLabs operations across sessions.

.DESCRIPTION
    Observe operations may run concurrently. Mutate and Destructive operations
    acquire one host-wide file lease for their full foreground lifetime. The
    operating-system handle, not the lock-file timestamp, owns the lease.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [ValidateSet('Observe', 'Mutate', 'Destructive')]
    [string] $Mode,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $Intent,

    [Parameter(Mandatory)]
    [AllowEmptyString()]
    [string[]] $Target,

    [Parameter(Mandatory)]
    [scriptblock] $Operation,

    [scriptblock] $Postcondition,

    [scriptblock] $FailureDiagnostics,

    [ValidateSet('VM', 'HostResource')]
    [string] $TargetType = 'VM',

    [string] $SessionId = '',

    [string] $ExpectedLoss = '',

    [string] $RecoveryPath = '',

    [switch] $AcknowledgeDestructive,

    [Parameter(DontShow)]
    [switch] $SkipActiveProcessCheck,

    [Parameter(DontShow)]
    [string] $TestCoordinationRoot = '',

    [Parameter(DontShow)]
    [switch] $TestLeaseDisposeFailure,

    [switch] $IncludeOperationOutput
)

$callbackErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Stop'

function Get-LiveOpsOperationHash {
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Text)

    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha256.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-', '')
    }
    finally {
        $sha256.Dispose()
    }
}

function Write-LiveOpsBytes {
    param(
        [Parameter(Mandatory)][IO.Stream] $Stream,
        [Parameter(Mandatory)][string] $Text
    )

    $encoding = New-Object Text.UTF8Encoding($false)
    $bytes = $encoding.GetBytes($Text)
    $Stream.Write($bytes, 0, $bytes.Length)
    $Stream.Flush()
}

function Write-LiveOpsJournal {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][object] $Record
    )

    $journalMutex = New-Object Threading.Mutex($false, 'Global\MemLabsLiveOpsJournal')
    $journalLockTaken = $false
    try {
        try {
            $journalLockTaken = $journalMutex.WaitOne([TimeSpan]::FromSeconds(10))
        }
        catch [Threading.AbandonedMutexException] {
            $journalLockTaken = $true
        }
        if (-not $journalLockTaken) { throw 'Timed out waiting for the Live Ops journal lock.' }

        $line = ($Record | ConvertTo-Json -Depth 8 -Compress) + [Environment]::NewLine
        $stream = [IO.File]::Open($Path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        try {
            $null = $stream.Seek(0, [IO.SeekOrigin]::End)
            Write-LiveOpsBytes -Stream $stream -Text $line
        }
        finally {
            $stream.Dispose()
        }
    }
    finally {
        if ($journalLockTaken) { $journalMutex.ReleaseMutex() }
        $journalMutex.Dispose()
    }
}

function Write-LiveOpsLeaseMetadata {
    param(
        [Parameter(Mandatory)][IO.Stream] $Stream,
        [Parameter(Mandatory)][object] $Metadata
    )

    $Stream.SetLength(0)
    $null = $Stream.Seek(0, [IO.SeekOrigin]::Begin)
    Write-LiveOpsBytes -Stream $Stream -Text ($Metadata | ConvertTo-Json -Depth 6 -Compress)
}

function Get-LiveOpsVmState {
    param(
        [Parameter(Mandatory)][string[]] $Name,
        [Parameter(Mandatory)][string] $Type
    )

    if ($Type -ne 'VM') {
        return @($Name | ForEach-Object { [pscustomobject]@{ Name = $_; Type = 'HostResource' } })
    }

    if (-not (Get-Command -Name Get-VM -ErrorAction SilentlyContinue)) {
        throw 'Hyper-V Get-VM is unavailable; VM targets cannot be validated.'
    }

    $states = [Collections.Generic.List[object]]::new()
    foreach ($vmName in $Name) {
        $vm = Get-VM -Name $vmName -ErrorAction Stop
        $states.Add([pscustomobject]@{
                Name                  = $vm.Name
                Id                    = "$($vm.Id)"
                State                 = "$($vm.State)"
                Status                = "$($vm.Status)"
                UptimeSeconds         = [math]::Round($vm.Uptime.TotalSeconds, 1)
                ConfigurationLocation = "$($vm.ConfigurationLocation)"
                CheckpointFileLocation = "$($vm.CheckpointFileLocation)"
                SnapshotFileLocation  = "$($vm.SnapshotFileLocation)"
            })
    }
    return $states.ToArray()
}

function Get-LiveOpsRepositoryState {
    $repoRoot = ''
    $head = ''
    $dirtyCount = $null
    try {
        $repoRoot = "$(git -C $PSScriptRoot rev-parse --show-toplevel 2>$null)".Trim()
        if ($LASTEXITCODE -eq 0 -and $repoRoot) {
            $head = "$(git -C $repoRoot rev-parse HEAD 2>$null)".Trim()
            $dirty = @(git -C $repoRoot status --short 2>$null | Where-Object { $_ })
            $dirtyCount = $dirty.Count
        }
    }
    catch {}

    return [pscustomobject]@{ Root = $repoRoot; Head = $head; DirtyPathCount = $dirtyCount }
}

function Test-LiveOpsConflictingCommandLine {
    param([AllowEmptyString()][string] $CommandLine)

    $wrapperEntryPointPattern = '(?i)(^|\s)"?-(?:f|fi|fil|file)"?\s+(?:"[^"]*[\\/]Invoke-MemLabsLiveOperation\.ps1"|[^\s"'']*[\\/]Invoke-MemLabsLiveOperation\.ps1)(?=$|\s)'
    $commandModePattern = '(?i)(^|\s)"?[-/](?:c|co|com|comm|comma|comman|command)"?(?:\s|$)'
    $entryPointPattern = '(?i)(^|[\s"''=;&|()])(?:[^\s"'']*[\\/])?(?:New-Lab\.ps1|Start-Test(?:\.ps1)?|Invoke-OvernightLocaleMatrix\.ps1|Start-Phase(?:\.ps1)?)(?=$|[\s"'';,&|()])'
    $encodedCommandPattern = '(?i)(^|\s)"?[-/](?:e|ec|en|enc|enco|encod|encode|encoded|encodedc|encodedco|encodedcom|encodedcomm|encodedcomma|encodedcomman|encodedcommand)"?(?:\s|$)'
    if (-not $CommandLine) { return $false }
    if ($CommandLine -match $encodedCommandPattern) { return $true }
    $wrapperEntryPoint = [regex]::Match($CommandLine, $wrapperEntryPointPattern)
    $commandMode = [regex]::Match($CommandLine, $commandModePattern)
    if ($wrapperEntryPoint.Success -and (-not $commandMode.Success -or $wrapperEntryPoint.Index -lt $commandMode.Index)) { return $false }
    return [bool]($CommandLine -match $entryPointPattern)
}

function Get-LiveOpsConflictingProcesses {
    try {
        return @(Get-CimInstance Win32_Process -Filter "Name = 'pwsh.exe' OR Name = 'powershell.exe'" -ErrorAction Stop |
                Where-Object { $_.ProcessId -ne $PID -and (Test-LiveOpsConflictingCommandLine -CommandLine $_.CommandLine) } |
                Select-Object ProcessId, CreationDate, CommandLine)
    }
    catch {
        throw "Could not verify active MemLabs processes: $($_.Exception.Message)"
    }
}

function Read-LiveOpsActiveOwner {
    param([Parameter(Mandatory)][string] $Path)

    for ($attempt = 1; $attempt -le 20; $attempt++) {
        try {
            $text = (Get-Content -LiteralPath $Path -Raw -ErrorAction Stop).Trim()
            if ($text) {
                $metadata = $text | ConvertFrom-Json -ErrorAction Stop
                if ($metadata.OperationId -and $metadata.State -in @('Active', 'Releasing')) { return $text }
            }
        }
        catch {}
        if ($attempt -lt 20) { [Threading.Thread]::Sleep(50) }
    }
    return '<active lease; owner metadata was not published within 1 second>'
}

function Test-LiveOpsPathHasReparsePoint {
    param([Parameter(Mandatory)][string] $Path)

    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $true }
        }
        $parent = [IO.Path]::GetDirectoryName($current)
        if (-not $parent -or $parent -eq $current) { break }
        $current = $parent
    }
    return $false
}

function Test-LiveOpsTestHarnessCaller {
    $expectedHarness = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'Test-MemLabsLiveOperation.ps1'))
    $helperPath = [IO.Path]::GetFullPath($PSCommandPath)
    foreach ($frame in @(Get-PSCallStack | Select-Object -Skip 1)) {
        if (-not $frame.ScriptName) { continue }
        $framePath = [IO.Path]::GetFullPath($frame.ScriptName)
        if ($framePath -eq $helperPath) { continue }
        return $framePath -eq $expectedHarness
    }
    return $false
}

$commonApplicationData = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
$defaultCoordinationRoot = Join-Path $commonApplicationData 'MemLabs\LiveOps'
$coordinationRoot = $defaultCoordinationRoot
if (-not [string]::IsNullOrWhiteSpace($TestCoordinationRoot)) {
    if (-not (Test-LiveOpsTestHarnessCaller)) {
        throw '-TestCoordinationRoot may only be used by Test-MemLabsLiveOperation.ps1.'
    }
    $testRootFull = [IO.Path]::GetFullPath($TestCoordinationRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $tempRootFull = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $underTempRoot = $testRootFull.StartsWith($tempRootFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
    if ($TargetType -ne 'HostResource' -or -not $underTempRoot -or (Test-LiveOpsPathHasReparsePoint -Path $testRootFull)) {
        throw '-TestCoordinationRoot is restricted to HostResource tests under a non-reparse-point OS temporary directory.'
    }
    $coordinationRoot = $testRootFull
}
if ($SkipActiveProcessCheck -and [string]::IsNullOrWhiteSpace($TestCoordinationRoot)) {
    throw '-SkipActiveProcessCheck requires the restricted -TestCoordinationRoot test mode.'
}
if ($TestLeaseDisposeFailure -and [string]::IsNullOrWhiteSpace($TestCoordinationRoot)) {
    throw '-TestLeaseDisposeFailure requires the restricted -TestCoordinationRoot test mode.'
}
$normalizedTargets = @($Target | ForEach-Object { "$_".Trim() } | Where-Object { $_ } | Sort-Object -Unique)
if ($normalizedTargets.Count -eq 0) { throw 'At least one non-empty target is required.' }
if ($Mode -ne 'Observe' -and -not $Postcondition) {
    throw "$Mode operations require a behavior-specific -Postcondition that returns exactly one Boolean result."
}
if ($Mode -ne 'Observe' -and -not $FailureDiagnostics) {
    throw "$Mode operations require -FailureDiagnostics so post-failure evidence is collected while the lease remains held."
}
if ($Mode -eq 'Destructive' -and -not $AcknowledgeDestructive) {
    throw 'Destructive operations require -AcknowledgeDestructive after the action and recovery path are recorded.'
}
if ($Mode -eq 'Destructive' -and ([string]::IsNullOrWhiteSpace($ExpectedLoss) -or [string]::IsNullOrWhiteSpace($RecoveryPath))) {
    throw 'Destructive operations require non-empty -ExpectedLoss and -RecoveryPath values.'
}

$null = New-Item -Path $coordinationRoot -ItemType Directory -Force
$leasePath = Join-Path $coordinationRoot 'mutation.lock'
$journalPath = Join-Path $coordinationRoot 'operations.jsonl'
$operationId = [guid]::NewGuid().ToString('N')
$startedUtc = [datetime]::UtcNow
$process = Get-Process -Id $PID
$repository = Get-LiveOpsRepositoryState
$operationText = $Operation.ToString()
if ($null -eq $operationText) { $operationText = '' }
$postconditionText = if ($Postcondition) { $Postcondition.ToString() } else { '' }
$failureDiagnosticsText = if ($FailureDiagnostics) { $FailureDiagnostics.ToString() } else { '' }
$owner = [ordered]@{
    OperationId   = $operationId
    State         = 'Requested'
    Mode          = $Mode
    Intent        = $Intent
    Targets       = $normalizedTargets
    TargetType    = $TargetType
    PID           = $PID
    ProcessStartUtc = $process.StartTime.ToUniversalTime().ToString('o')
    SessionId     = $SessionId
    User          = [Environment]::UserName
    Host          = [Environment]::MachineName
    StartedUtc    = $startedUtc.ToString('o')
    OperationHash = Get-LiveOpsOperationHash -Text $operationText
    PostconditionHash = Get-LiveOpsOperationHash -Text $postconditionText
    FailureDiagnosticsHash = Get-LiveOpsOperationHash -Text $failureDiagnosticsText
    ExpectedLoss  = $ExpectedLoss
    RecoveryPath  = $RecoveryPath
    Repository    = $repository
}

Write-LiveOpsJournal -Path $journalPath -Record ([ordered]@{ Event = 'Requested'; TimeUtc = $startedUtc.ToString('o'); Owner = $owner })

$leaseStream = $null
$operationSucceeded = $false
$beforeState = $null
$afterState = $null
$failureStage = 'Coordination'
$activeOwnerMetadata = $null
$correlatedException = $null
$successResult = $null
try {
    if ($Mode -ne 'Observe') {
        if (-not $SkipActiveProcessCheck) {
            $conflictingProcesses = @(Get-LiveOpsConflictingProcesses)
            if ($conflictingProcesses.Count -gt 0) {
                $summary = @($conflictingProcesses | ForEach-Object { "PID $($_.ProcessId)" }) -join ', '
                throw "Active MemLabs process(es) detected ($summary); mutation coordination is required before proceeding."
            }
        }

        try {
            $leaseStream = [IO.File]::Open($leasePath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read)
        }
        catch [IO.IOException] {
            $currentOwner = Read-LiveOpsActiveOwner -Path $leasePath
            $activeOwnerMetadata = $currentOwner
            throw "Live Ops mutation lease is held by another session. Owner metadata: $currentOwner"
        }

        $owner.State = 'Active'
        $owner.AcquiredUtc = [datetime]::UtcNow.ToString('o')
        Write-LiveOpsLeaseMetadata -Stream $leaseStream -Metadata $owner
        Write-LiveOpsJournal -Path $journalPath -Record ([ordered]@{ Event = 'LeaseAcquired'; TimeUtc = [datetime]::UtcNow.ToString('o'); OperationId = $operationId })
    }

    $beforeState = @(Get-LiveOpsVmState -Name $normalizedTargets -Type $TargetType)
    Write-LiveOpsJournal -Path $journalPath -Record ([ordered]@{ Event = 'OperationStarted'; TimeUtc = [datetime]::UtcNow.ToString('o'); OperationId = $operationId; Before = $beforeState })

    $failureStage = 'Operation'
    $savedProgressPreference = $ProgressPreference
    $savedErrorActionPreference = $ErrorActionPreference
    $ProgressPreference = 'SilentlyContinue'
    $ErrorActionPreference = $callbackErrorActionPreference
    try {
        $operationOutput = @(& $Operation 3>$null 4>$null 5>$null 6>$null)
    }
    finally {
        $ErrorActionPreference = $savedErrorActionPreference
        $ProgressPreference = $savedProgressPreference
    }
    $afterState = @(Get-LiveOpsVmState -Name $normalizedTargets -Type $TargetType)

    $postconditionPassed = $null
    if ($Postcondition) {
        $failureStage = 'Postcondition'
        $savedProgressPreference = $ProgressPreference
        $savedErrorActionPreference = $ErrorActionPreference
        $ProgressPreference = 'SilentlyContinue'
        $ErrorActionPreference = $callbackErrorActionPreference
        try {
            $postconditionOutput = @(& $Postcondition $operationOutput 3>$null 4>$null 5>$null 6>$null)
        }
        finally {
            $ErrorActionPreference = $savedErrorActionPreference
            $ProgressPreference = $savedProgressPreference
        }
        if ($postconditionOutput.Count -ne 1 -or $postconditionOutput[0] -isnot [bool]) {
            throw 'Postcondition must return exactly one Boolean result and no other output.'
        }
        $postconditionPassed = [bool]$postconditionOutput[0]
        Write-LiveOpsJournal -Path $journalPath -Record ([ordered]@{ Event = 'PostconditionChecked'; TimeUtc = [datetime]::UtcNow.ToString('o'); OperationId = $operationId; Passed = $postconditionPassed })
        if (-not $postconditionPassed) { throw 'Live operation postcondition returned False.' }
    }

    $failureStage = 'Completion'
    $operationSucceeded = $true
    Write-LiveOpsJournal -Path $journalPath -Record ([ordered]@{ Event = 'OperationCompleted'; TimeUtc = [datetime]::UtcNow.ToString('o'); OperationId = $operationId; OutputCount = $operationOutput.Count; After = $afterState })

    [object[]]$returnedOutput = @()
    if ($IncludeOperationOutput) { $returnedOutput = @($operationOutput) }
    $successResult = [pscustomobject]@{
        OperationId = $operationId
        Mode        = $Mode
        Targets     = $normalizedTargets
        JournalPath = $journalPath
        Before      = $beforeState
        After       = $afterState
        PostconditionPassed = $postconditionPassed
        OutputCount = $operationOutput.Count
        Output      = $returnedOutput
    }
}
catch {
    $operationError = $_
    $postFailureStateErrorType = $null
    $failureDiagnosticsErrorType = $null
    [object[]] $failureDiagnosticsOutput = @()
    $failureDiagnosticsOutputCount = 0
    try {
        $afterState = @(Get-LiveOpsVmState -Name $normalizedTargets -Type $TargetType)
    }
    catch {
        $postFailureStateErrorType = $_.Exception.GetType().FullName
    }
    if ($FailureDiagnostics -and $leaseStream) {
        try {
            $savedProgressPreference = $ProgressPreference
            $savedErrorActionPreference = $ErrorActionPreference
            $ProgressPreference = 'SilentlyContinue'
            $ErrorActionPreference = $callbackErrorActionPreference
            try {
                $failureDiagnosticsOutput = @(& $FailureDiagnostics 3>$null 4>$null 5>$null 6>$null)
            }
            finally {
                $ErrorActionPreference = $savedErrorActionPreference
                $ProgressPreference = $savedProgressPreference
            }
            $failureDiagnosticsOutputCount = $failureDiagnosticsOutput.Count
            Write-LiveOpsJournal -Path $journalPath -Record ([ordered]@{ Event = 'FailureDiagnosticsCompleted'; TimeUtc = [datetime]::UtcNow.ToString('o'); OperationId = $operationId; OutputCount = $failureDiagnosticsOutputCount })
        }
        catch {
            $failureDiagnosticsErrorType = $_.Exception.GetType().FullName
        }
    }
    $failureJournalErrorType = $null
    try {
        Write-LiveOpsJournal -Path $journalPath -Record ([ordered]@{
                Event                     = 'OperationFailed'
                TimeUtc                   = [datetime]::UtcNow.ToString('o')
                OperationId               = $operationId
                ErrorType                 = $operationError.Exception.GetType().FullName
                FailureStage              = $failureStage
                Before                    = $beforeState
                After                     = $afterState
                PostFailureStateErrorType = $postFailureStateErrorType
                FailureDiagnosticsOutputCount = $failureDiagnosticsOutputCount
                FailureDiagnosticsErrorType = $failureDiagnosticsErrorType
            })
    }
    catch {
        $failureJournalErrorType = $_.Exception.GetType().FullName
    }
    $correlatedException = New-Object InvalidOperationException(
        "Live operation failed. OperationId=$operationId JournalPath=$journalPath ErrorType=$($operationError.Exception.GetType().FullName)"
    )
    $correlatedException.Data['OperationId'] = $operationId
    $correlatedException.Data['JournalPath'] = $journalPath
    $correlatedException.Data['FailureStage'] = $failureStage
    $correlatedException.Data['ActiveOwnerMetadata'] = $activeOwnerMetadata
    $correlatedException.Data['FailureDiagnostics'] = @($failureDiagnosticsOutput)
    $correlatedException.Data['FailureDiagnosticsErrorType'] = $failureDiagnosticsErrorType
    $correlatedException.Data['FailureJournalErrorType'] = $failureJournalErrorType
    throw $correlatedException
}
finally {
    if ($leaseStream) {
        $leaseReleaseErrorType = $null
        $leaseDisposeErrorType = $null
        try {
            $owner.State = 'Releasing'
            $owner.ReleasedUtc = [datetime]::UtcNow.ToString('o')
            Write-LiveOpsLeaseMetadata -Stream $leaseStream -Metadata $owner
        }
        catch {
            $leaseReleaseErrorType = $_.Exception.GetType().FullName
        }
        try {
            $leaseStream.Dispose()
            if ($TestLeaseDisposeFailure) {
                throw [IO.IOException]::new('Injected lease disposal failure for Test-MemLabsLiveOperation.ps1.')
            }
        }
        catch {
            $leaseDisposeErrorType = $_.Exception.GetType().FullName
        }

        if (-not $leaseDisposeErrorType) {
            try {
                $releasedState = if ($operationSucceeded) { 'Released' } else { 'Failed' }
                Write-LiveOpsJournal -Path $journalPath -Record ([ordered]@{ Event = 'LeaseReleased'; TimeUtc = [datetime]::UtcNow.ToString('o'); OperationId = $operationId; State = $releasedState })
            }
            catch {
                $leaseReleaseErrorType = $_.Exception.GetType().FullName
            }
        }

        if ($correlatedException) {
            $correlatedException.Data['LeaseReleaseJournalErrorType'] = $leaseReleaseErrorType
            $correlatedException.Data['LeaseDisposeErrorType'] = $leaseDisposeErrorType
        }
        elseif ($leaseReleaseErrorType -or $leaseDisposeErrorType) {
            $releaseException = New-Object InvalidOperationException(
                "Live operation completed, but lease release recording failed. OperationId=$operationId JournalPath=$journalPath"
            )
            $releaseException.Data['OperationId'] = $operationId
            $releaseException.Data['JournalPath'] = $journalPath
            $releaseException.Data['FailureStage'] = 'LeaseRelease'
            $releaseException.Data['OperationSucceeded'] = $operationSucceeded
            $releaseException.Data['LeaseReleaseJournalErrorType'] = $leaseReleaseErrorType
            $releaseException.Data['LeaseDisposeErrorType'] = $leaseDisposeErrorType
            throw $releaseException
        }
    }
}

if ($successResult) { $successResult }