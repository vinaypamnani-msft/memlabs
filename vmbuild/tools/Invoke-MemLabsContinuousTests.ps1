<#
.SYNOPSIS
    Continuously selects and runs the highest-value MemLabs test that fits the host.
.DESCRIPTION
    Runs only while this foreground process is alive. No watcher or child is
    detached. Ctrl-C stops the scheduler and its attached Start-Test invocation.
#>
[CmdletBinding()]
param(
    [string] $VmbuildRoot,
    [string] $HistoryPath,
    [string] $RetentionPath,
    [int] $MaxIterations = 0,
    [switch] $PlanOnly,
    [double] $MinimumFreeStorageGB = 250,
    [int] $MaximumRetainedLabs = 2,
    [int] $RetentionDays = 7,
    [int] $WaitSeconds = 60
)

$ErrorActionPreference = 'Stop'
if (-not $VmbuildRoot) { $VmbuildRoot = Split-Path -Parent $PSScriptRoot }
$VmbuildRoot = [IO.Path]::GetFullPath($VmbuildRoot)
$repositoryRoot = Split-Path -Parent $VmbuildRoot
$startTestPath = Join-Path $VmbuildRoot 'Start-Test.ps1'
$removeLabPath = Join-Path $VmbuildRoot 'Remove-Lab.ps1'
. (Join-Path $PSScriptRoot 'Common.TestHistory.ps1')
. (Join-Path $PSScriptRoot 'Common.TestRetention.ps1')
. (Join-Path $PSScriptRoot 'Common.AttachedProcess.ps1')
$loadedCommit = Get-MemLabsCurrentCommit -RepositoryRoot $repositoryRoot
if (-not $HistoryPath) { $HistoryPath = Get-MemLabsTestHistoryPath }
if (-not $RetentionPath) { $RetentionPath = Get-MemLabsTestRetentionPath }

function Enter-MemLabsMutationLease {
    param([int] $PollSeconds = 60)

    $mutex = [Threading.Mutex]::new($false, 'Global\MemLabsTestMutationLock')
    $held = $false
    try {
        while (-not $held) {
            try { $held = $mutex.WaitOne(0) }
            catch [Threading.AbandonedMutexException] { $held = $true }
            if (-not $held) {
                Write-Host "Another Start-Test cycle owns the mutation lease; waiting ${PollSeconds}s..." -ForegroundColor DarkGray
                Start-Sleep -Seconds $PollSeconds
            }
        }
        return $mutex
    }
    catch {
        $mutex.Dispose()
        throw
    }
}

function Exit-MemLabsMutationLease {
    param([Threading.Mutex] $Mutex)
    if (-not $Mutex) { return }
    try { $Mutex.ReleaseMutex() } catch {}
    $Mutex.Dispose()
}

function Invoke-MemLabsDomainCleanup {
    param(
        [string[]] $Domains,
        [string] $Reason
    )

    foreach ($domain in @($Domains | Where-Object { $_ } | Select-Object -Unique)) {
        Write-Host "Cleanup ($Reason): $domain" -ForegroundColor DarkYellow
        $cleanupExit = Invoke-MemLabsAttachedPowerShell -Arguments @(
            '-NoLogo', '-NoProfile', '-NonInteractive',
            '-File', $removeLabPath, '-DomainName', $domain
        )
        if ($cleanupExit -ne 0) {
            throw "Cleanup of '$domain' failed with exit code $cleanupExit."
        }
    }
}

function Remove-MemLabsRetention {
    param(
        [Parameter(Mandatory = $true)][object] $Retention,
        [Parameter(Mandatory = $true)][string] $Reason,
        [Parameter(Mandatory = $true)][object[]] $AllRetentions,
        [switch] $SkipCleanup
    )

    if (-not $SkipCleanup.IsPresent) {
        Invoke-MemLabsDomainCleanup -Domains @($Retention.Domains) -Reason $Reason
    }
    $remaining = @($AllRetentions | Where-Object { "$($_.RetentionId)" -ne "$($Retention.RetentionId)" })
    Write-MemLabsTestRetentions -Retentions $remaining -Path $RetentionPath
    Write-MemLabsTestHistoryEvent -Path $HistoryPath -Event ([pscustomobject]@{
            EventType = 'RetentionReleased'; RetentionId = "$($Retention.RetentionId)"
            CandidateKey = "$($Retention.CandidateKey)"; Mode = "$($Retention.Mode)"
            Family = "$($Retention.Family)"; Commit = "$($Retention.Commit)"
            Reason = $Reason; Domains = @($Retention.Domains); NeedsRerun = $true
        })
    return @($remaining)
}

function Invoke-MemLabsRetentionMaintenance {
    param([object] $NextCandidate)

    $retentions = @(Read-MemLabsTestRetentions -Path $RetentionPath)
    if (Get-Command Get-VM -ErrorAction SilentlyContinue) {
        foreach ($stale in @($retentions | Where-Object {
                    $knownNames = @($_.VmNames | Where-Object { $_ })
                    $knownNames.Count -gt 0 -and
                    @($knownNames | Where-Object { Get-VM -Name $_ -ErrorAction SilentlyContinue }).Count -eq 0
                })) {
            $retentions = @(Remove-MemLabsRetention -Retention $stale -Reason 'retained lab no longer exists' `
                    -AllRetentions $retentions -SkipCleanup)
        }
    }
    foreach ($expired in @(Get-MemLabsExpiredRetentions -Retentions $retentions)) {
        $retentions = @(Remove-MemLabsRetention -Retention $expired -Reason 'expired' -AllRetentions $retentions)
    }
    while ($retentions.Count -gt $MaximumRetainedLabs) {
        $oldest = $retentions | Sort-Object RetainedUtc | Select-Object -First 1
        $retentions = @(Remove-MemLabsRetention -Retention $oldest -Reason 'retention cap' -AllRetentions $retentions)
    }
    if ($NextCandidate) {
        foreach ($conflict in @($retentions | Where-Object {
                    Test-MemLabsRetentionConflict -Retention $_ -Candidate $NextCandidate
                })) {
            $retentions = @(Remove-MemLabsRetention -Retention $conflict -Reason "conflicts with $($NextCandidate.CandidateKey)" -AllRetentions $retentions)
        }
    }
    return @($retentions)
}

function Save-MemLabsFailedLab {
    param(
        [Parameter(Mandatory = $true)][object] $Candidate,
        [Parameter(Mandatory = $true)][int] $ExitCode
    )

    $retentions = @(Invoke-MemLabsRetentionMaintenance)
    try {
        $freeStorageGB = Get-MemLabsFreeStorageGB -BasePaths @($Candidate.BasePaths) -FallbackPath $VmbuildRoot
    }
    catch {
        Write-Host "Could not prove storage headroom for retention: $($_.Exception.Message)" -ForegroundColor Yellow
        Invoke-MemLabsDomainCleanup -Domains @($Candidate.Domains) -Reason 'retention storage could not be measured'
        Write-MemLabsTestHistoryEvent -Path $HistoryPath -Event ([pscustomobject]@{
                EventType = 'RetentionDecision'; CandidateKey = $Candidate.CandidateKey
                Mode = $Candidate.Mode; Family = $Candidate.Family; Commit = $Candidate.CurrentCommit
                Retained = $false; NeedsRerun = $true; FreeStorageGB = $null
                Reason = 'storage measurement failed'; Domains = @($Candidate.Domains)
            })
        return $false
    }
    $decision = Test-MemLabsCanRetainFailure -FreeStorageGB $freeStorageGB `
        -MinimumFreeStorageGB $MinimumFreeStorageGB -CurrentRetentions $retentions `
        -MaximumRetentions $MaximumRetainedLabs
    if ($decision.CanRetain -and $decision.RequiresEviction) {
        $oldest = $retentions | Sort-Object RetainedUtc | Select-Object -First 1
        $retentions = @(Remove-MemLabsRetention -Retention $oldest -Reason 'replaced by newer failure' -AllRetentions $retentions)
    }
    if ($decision.CanRetain -and $retentions.Count -lt $MaximumRetainedLabs) {
        $now = [DateTime]::UtcNow
        $retention = [pscustomobject]@{
            SchemaVersion = 1
            RetentionId = [guid]::NewGuid().ToString('N')
            CandidateKey = $Candidate.CandidateKey
            Mode = $Candidate.Mode
            Family = $Candidate.Family
            Commit = $Candidate.CurrentCommit
            ExitCode = $ExitCode
            Domains = @($Candidate.Domains)
            VmNames = @($Candidate.VmNames)
            BasePaths = @($Candidate.BasePaths)
            CrossRevisionStateRoot = "$($Candidate.CrossRevisionStateRoot)"
            RetainedUtc = $now.ToString('o')
            ExpiresUtc = $now.AddDays($RetentionDays).ToString('o')
            FreeStorageGB = $freeStorageGB
        }
        $retentions += $retention
        Write-MemLabsTestRetentions -Retentions $retentions -Path $RetentionPath
        Write-MemLabsTestHistoryEvent -Path $HistoryPath -Event ([pscustomobject]@{
                EventType = 'RetentionDecision'; RetentionId = $retention.RetentionId
                CandidateKey = $Candidate.CandidateKey; Mode = $Candidate.Mode
                Family = $Candidate.Family; Commit = $Candidate.CurrentCommit
                Retained = $true; NeedsRerun = $true; FreeStorageGB = $freeStorageGB
                ExpiresUtc = $retention.ExpiresUtc; Domains = @($Candidate.Domains)
            })
        Write-Host "PRESERVED: $($Candidate.CandidateKey) until $($retention.ExpiresUtc) ($freeStorageGB GB free)." -ForegroundColor Yellow
        return $true
    }

    Write-Host "NOT PRESERVED: $($Candidate.CandidateKey) ($freeStorageGB GB free; minimum $MinimumFreeStorageGB GB)." -ForegroundColor Yellow
    Invoke-MemLabsDomainCleanup -Domains @($Candidate.Domains) -Reason 'failure not safe to retain'
    Write-MemLabsTestHistoryEvent -Path $HistoryPath -Event ([pscustomobject]@{
            EventType = 'RetentionDecision'; CandidateKey = $Candidate.CandidateKey
            Mode = $Candidate.Mode; Family = $Candidate.Family; Commit = $Candidate.CurrentCommit
            Retained = $false; NeedsRerun = $true; FreeStorageGB = $freeStorageGB
            Domains = @($Candidate.Domains)
        })
    return $false
}

function Show-MemLabsSelection {
    param([object[]] $Candidates)

    $Candidates | Select-Object -First 12 CandidateKey, Score, FitsHost,
        RequiredMemoryGB, AvailableMemoryGB, EstimatedMinutes,
        @{ Name = 'Reasons'; Expression = { $_.Reasons -join '; ' } } |
        Format-Table -AutoSize | Out-Host
}

function Get-MemLabsContinuousCrossRevisionStateRoot {
    param(
        [Parameter(Mandatory = $true)][object] $Candidate,
        [Parameter(Mandatory = $true)][string] $HistoryPath
    )

    $events = @(Read-MemLabsTestHistory -Path $HistoryPath)
    $selections = @($events | Where-Object {
            $_.EventType -eq 'SchedulerSelection' -and
            "$($_.CandidateKey)" -eq "$($Candidate.CandidateKey)" -and
            "$($_.Commit)" -eq "$($Candidate.CurrentCommit)"
        } | Sort-Object RecordedUtc)
    $latestSelection = $selections | Select-Object -Last 1
    if ($latestSelection -and $latestSelection.CrossRevisionStateRoot) {
        $completionAfterSelection = $events | Where-Object {
            $_.EventType -eq 'RunCompleted' -and
            "$($_.CandidateKey)" -eq "$($Candidate.CandidateKey)" -and
            "$($_.Commit)" -eq "$($Candidate.CurrentCommit)" -and
            -not [bool]$_.Interrupted -and
            ([DateTime]"$($_.RecordedUtc)") -ge ([DateTime]"$($latestSelection.RecordedUtc)")
        } | Select-Object -First 1
        if (-not $completionAfterSelection) { return "$($latestSelection.CrossRevisionStateRoot)" }
    }
    $generation = $selections.Count + 1
    $commitPart = if ($Candidate.CurrentCommit -match '^[0-9a-f]{8,}$') {
        $Candidate.CurrentCommit.Substring(0, 8)
    }
    else { 'unknown' }
    return Join-Path $env:ProgramData "MemLabs\Continuous\CrossRevision\$commitPart\$($Candidate.Family)-run$generation"
}

$iteration = 0
try {
    while ($MaxIterations -le 0 -or $iteration -lt $MaxIterations) {
        $iteration++
        $selectionLease = $null
        if (-not $PlanOnly.IsPresent) {
            $selectionLease = Enter-MemLabsMutationLease -PollSeconds $WaitSeconds
        }
        try {
            if (-not $PlanOnly.IsPresent) {
                $retentions = @(Invoke-MemLabsRetentionMaintenance)
            }
            else {
                $retentions = @(Read-MemLabsTestRetentions -Path $RetentionPath)
            }
            $ranked = @(Select-MemLabsNextTest -VmbuildRoot $VmbuildRoot -HistoryPath $HistoryPath)
            $candidate = $ranked | Where-Object {
                $_.FitsHost -and $_.CandidateKey -notin @($retentions.CandidateKey)
            } | Select-Object -First 1
            if (-not $PlanOnly.IsPresent -and $candidate) {
                $retentions = @(Invoke-MemLabsRetentionMaintenance -NextCandidate $candidate)
            }
        }
        finally {
            Exit-MemLabsMutationLease -Mutex $selectionLease
        }
        if ($PlanOnly.IsPresent) {
            Show-MemLabsSelection -Candidates $ranked
            if ($candidate) {
                Write-Host "NEXT: $($candidate.CandidateKey) -- $($candidate.Reasons -join '; ')" -ForegroundColor Cyan
            }
            else {
                Write-Host 'No unretained test currently fits available host memory.' -ForegroundColor Yellow
            }
            return
        }
        if (-not $candidate) {
            $fittingRetained = @($ranked | Where-Object { $_.FitsHost -and $_.CandidateKey -in @($retentions.CandidateKey) })
            if ($fittingRetained.Count -gt 0) {
                $release = $retentions | Sort-Object RetainedUtc | Select-Object -First 1
                $releaseLease = Enter-MemLabsMutationLease -PollSeconds $WaitSeconds
                try {
                    $null = Remove-MemLabsRetention -Retention $release `
                        -Reason 'all fitting candidates retained; releasing oldest for rerun' `
                        -AllRetentions $retentions
                }
                finally {
                    Exit-MemLabsMutationLease -Mutex $releaseLease
                }
                continue
            }
            $smallest = $ranked | Sort-Object RequiredMemoryGB | Select-Object -First 1
            Write-Host "No test fits current memory. Smallest is $($smallest.CandidateKey): needs $($smallest.RequiredMemoryGB)GB, available $($smallest.AvailableMemoryGB)GB. Waiting ${WaitSeconds}s." -ForegroundColor Yellow
            Start-Sleep -Seconds $WaitSeconds
            continue
        }

        if ($candidate.Mode -eq 'CrossRevision') {
            $candidate | Add-Member -NotePropertyName CrossRevisionStateRoot `
                -NotePropertyValue (Get-MemLabsContinuousCrossRevisionStateRoot -Candidate $candidate -HistoryPath $HistoryPath) -Force
        }
        Write-MemLabsTestHistoryEvent -Path $HistoryPath -Event ([pscustomobject]@{
                EventType = 'SchedulerSelection'; CandidateKey = $candidate.CandidateKey
                Mode = $candidate.Mode; Family = $candidate.Family
                Commit = $candidate.CurrentCommit; Score = $candidate.Score
                Reasons = @($candidate.Reasons); AvailableMemoryGB = $candidate.AvailableMemoryGB
                RequiredMemoryGB = $candidate.RequiredMemoryGB
                CrossRevisionStateRoot = "$($candidate.CrossRevisionStateRoot)"
            })
        Write-Host "`nSELECTED: $($candidate.CandidateKey)" -ForegroundColor Magenta
        Write-Host "  score  : $($candidate.Score)"
        Write-Host "  memory : $($candidate.RequiredMemoryGB)GB required / $($candidate.AvailableMemoryGB)GB available"
        Write-Host "  why    : $($candidate.Reasons -join '; ')"

        $arguments = @('-NoLogo', '-NoProfile', '-File', $startTestPath, '-Test', $candidate.Family, '-Automated')
        if ($candidate.Mode -eq 'CrossRevision') {
            $arguments += '-MainToDevelopExpansion'
            $arguments += @('-DevelopRevision', $candidate.CurrentCommit)
            $arguments += @('-CrossRevisionStateRoot', $candidate.CrossRevisionStateRoot)
        }
        else {
            $arguments += '-CleanupOnSuccess'
        }
        $exitCode = Invoke-MemLabsAttachedPowerShell -Arguments $arguments
        if ($exitCode -eq 0) {
            Write-Host "PASS: $($candidate.CandidateKey)" -ForegroundColor Green
        }
        else {
            Write-Host "FAIL: $($candidate.CandidateKey) exited $exitCode" -ForegroundColor Red
            $failedUtc = [DateTime]::UtcNow
            Write-MemLabsTestHistoryEvent -Path $HistoryPath -Event ([pscustomobject]@{
                    EventType = 'RunCompleted'; RunId = [guid]::NewGuid().ToString('N')
                    CandidateKey = $candidate.CandidateKey; Mode = $candidate.Mode
                    Family = $candidate.Family; Suite = 'Continuous'
                    StartedUtc = $failedUtc.ToString('o'); CompletedUtc = $failedUtc.ToString('o')
                    DurationSeconds = 0; Commit = $candidate.CurrentCommit
                    Success = $false; ExitCode = $exitCode
                    Error = "Attached Start-Test child exited $exitCode."
                    Domains = @($candidate.Domains); CoverageTags = @($candidate.CoverageTags)
                    NeedsRerun = $true
                })
            if ($exitCode -eq 2) {
                Write-Host 'The child stopped before a safe lab mutation (lease/setup failure); no retention or cleanup was attempted.' -ForegroundColor Yellow
                Start-Sleep -Seconds $WaitSeconds
            }
            else {
                $retentionLease = Enter-MemLabsMutationLease -PollSeconds $WaitSeconds
                try {
                    $null = Save-MemLabsFailedLab -Candidate $candidate -ExitCode $exitCode
                }
                finally {
                    Exit-MemLabsMutationLease -Mutex $retentionLease
                }
            }
        }
        $currentCommit = Get-MemLabsCurrentCommit -RepositoryRoot $repositoryRoot
        if ($loadedCommit -and $currentCommit -and $currentCommit -ne $loadedCommit) {
            Write-Host "Develop advanced $loadedCommit -> $currentCommit; restarting the foreground scheduler with current code." -ForegroundColor Yellow
            exit 57
        }
    }
}
finally {
    Write-Host 'Continuous testing stopped. No background scheduler was left running.' -ForegroundColor DarkGray
}
