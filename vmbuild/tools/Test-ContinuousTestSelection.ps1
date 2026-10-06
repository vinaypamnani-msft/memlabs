<#
.SYNOPSIS
    Verifies capacity-aware test selection and failed-lab retention policy.
#>
[CmdletBinding()]
param([string] $RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
$repoRoot = Split-Path -Parent $RootPath
. (Join-Path $RootPath 'tools\Common.TestHistory.ps1')
. (Join-Path $RootPath 'tools\Common.TestRetention.ps1')
$continuousPath = Join-Path $RootPath 'tools\Invoke-MemLabsContinuousTests.ps1'

function Import-TestFunction {
    param([string] $Path, [string] $Name)
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "$Path has parse errors: $($errors -join '; ')" }
    $functions = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($functions.Count -ne 1) { throw "Expected one $Name definition, found $($functions.Count)." }
    [scriptblock]::Create($functions[0].Extent.Text)
}
. (Import-TestFunction -Path $continuousPath -Name 'Get-MemLabsContinuousCrossRevisionStateRoot')

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}
function Assert-Equal {
    param($Expected, $Actual, [string] $Message)
    if ("$Expected" -ne "$Actual") { throw "$Message`nExpected: $Expected`nActual:   $Actual" }
}

$testRoot = Join-Path $env:TEMP "memlabs-continuous-test-$PID"
$historyPath = Join-Path $testRoot 'history.jsonl'
$retentionPath = Join-Path $testRoot 'retained.json'
$null = New-Item -ItemType Directory -Path $testRoot -Force
try {
    $wacky = Get-MemLabsFamilyMetadata -VmbuildRoot $RootPath -Family 'Wacky'
    Assert-True ($wacky.EstimatedRequiredGB -gt 80) 'Wacky unexpectedly fits an 80 GB available-memory budget.'
    $standardCst3 = Get-MemLabsFamilyMetadata -VmbuildRoot $RootPath -Family 'CSTest3'
    $upgradeCst3 = Get-MemLabsFamilyMetadata -VmbuildRoot $RootPath -Family 'CSTest3' -IncludeMutations
    Assert-True ($standardCst3.ConfigNames -notcontains 'CSTest3-D-MutateExistingSiteSystem.json') `
        'Standard CSTest3 was credited with mutation coverage it does not execute.'
    Assert-True ($upgradeCst3.ConfigNames -contains 'CSTest3-D-MutateExistingSiteSystem.json') `
        'Cross-revision CSTest3 did not include its mutation manifest.'
    $ranked = @(Select-MemLabsNextTest -VmbuildRoot $RootPath -HistoryPath $historyPath -AvailableMemoryGB 80)
    Assert-True (@($ranked | Where-Object { $_.FitsHost }).Count -gt 0) 'No test fits an 80 GB host.'
    Assert-True (-not ($ranked | Where-Object { $_.CandidateKey -eq 'Standard|Wacky' }).FitsHost) `
        'Capacity filter did not exclude Wacky.'
    Assert-True (($ranked | Where-Object { $_.FitsHost } | Select-Object -First 1).RequiredMemoryGB -le 80) `
        'Selector chose a test that exceeds available memory.'

    $commit = Get-MemLabsCurrentCommit -RepositoryRoot $repoRoot
    $now = [DateTime]::UtcNow
    Write-MemLabsTestHistoryEvent -Path $historyPath -Event ([pscustomobject]@{
            EventType = 'RunCompleted'; CandidateKey = 'Standard|NOCM'; Mode = 'Standard'; Family = 'NOCM'
            CompletedUtc = $now.AddMinutes(-2).ToString('o'); DurationSeconds = 60
            Commit = $commit; Success = $false; NeedsRerun = $true
        })
    $afterFailure = @(Select-MemLabsNextTest -VmbuildRoot $RootPath -HistoryPath $historyPath -AvailableMemoryGB 80)
    Assert-Equal 'Standard|NOCM' ($afterFailure | Where-Object { $_.FitsHost } | Select-Object -First 1).CandidateKey `
        'A cleaned failed test was not prioritized for rerun.'
    Assert-True ((($afterFailure | Where-Object CandidateKey -eq 'Standard|NOCM').Reasons) -contains 'rerun requested') `
        'Failure rerun reason was not retained.'

    Write-MemLabsTestHistoryEvent -Path $historyPath -Event ([pscustomobject]@{
            EventType = 'RunCompleted'; CandidateKey = 'Standard|NOCM'; Mode = 'Standard'; Family = 'NOCM'
            CompletedUtc = $now.ToString('o'); DurationSeconds = 60
            Commit = $commit; Success = $true; NeedsRerun = $false
        })
    $afterRecovery = @(Select-MemLabsNextTest -VmbuildRoot $RootPath -HistoryPath $historyPath -AvailableMemoryGB 80)
    Assert-True (-not ((($afterRecovery | Where-Object CandidateKey -eq 'Standard|NOCM').Reasons) -contains 'rerun requested')) `
        'A newer successful run did not clear rerun priority.'

    Write-MemLabsTestHistoryEvent -Path $historyPath -Event ([pscustomobject]@{
            EventType = 'RunStarted'; RunId = 'interrupted-osd'
            CandidateKey = 'Standard|OSDTest'; Mode = 'Standard'; Family = 'OSDTest'
            Commit = $commit; StartedUtc = [DateTime]::UtcNow.ToString('o')
        })
    $afterInterrupt = @(Select-MemLabsNextTest -VmbuildRoot $RootPath -HistoryPath $historyPath -AvailableMemoryGB 80)
    Assert-Equal 'Standard|OSDTest' ($afterInterrupt | Where-Object { $_.FitsHost } | Select-Object -First 1).CandidateKey `
        'Interrupted run was not prioritized on restart.'
    Assert-True ((($afterInterrupt | Where-Object CandidateKey -eq 'Standard|OSDTest').Reasons) -contains 'rerun requested') `
        'Interrupted run did not request rerun priority.'

    $risk = @(Get-MemLabsRiskTagsForPaths -Paths @(
            'vmbuild/DSC/phases/perfloading.ps1',
            'vmbuild/common/Common.PKI.ps1',
            'vmbuild/common/Common.Linux.ps1'
        ))
    foreach ($requiredTag in @('DP', 'OSD', 'PKI', 'Role:LinuxServer', 'Proxy')) {
        Assert-True ($risk -contains $requiredTag) "Risk classifier missed '$requiredTag'."
    }

    $retention = [pscustomobject]@{
        RetentionId = 'one'; CandidateKey = 'Standard|NOCM'; Family = 'NOCM'; Mode = 'Standard'
        Domains = @('nocm.com'); VmNames = @('NOC-DC1')
        RetainedUtc = $now.AddDays(-8).ToString('o'); ExpiresUtc = $now.AddDays(-1).ToString('o')
    }
    Write-MemLabsTestRetentions -Retentions @($retention) -Path $retentionPath
    Assert-Equal 1 @(Read-MemLabsTestRetentions -Path $retentionPath).Count 'Retention registry did not round-trip.'
    Write-MemLabsTestRetentions -Retentions @() -Path $retentionPath
    Assert-Equal 0 @(Read-MemLabsTestRetentions -Path $retentionPath).Count 'Empty retention registry did not round-trip as an empty array.'
    Assert-Equal 1 @(Get-MemLabsExpiredRetentions -Retentions @($retention) -NowUtc $now).Count `
        'Expired retention was not detected.'
    $candidate = [pscustomobject]@{ Domains = @('nocm.com'); VmNames = @('OTHER') }
    Assert-True (Test-MemLabsRetentionConflict -Retention $retention -Candidate $candidate) `
        'Domain conflict was not detected.'
    Assert-True (-not (Test-MemLabsCanRetainFailure -FreeStorageGB 249 -CurrentRetentions @() -MaximumRetentions 2).CanRetain) `
        'Retention ignored the 250 GB free-space floor.'
    $atFloor = Test-MemLabsCanRetainFailure -FreeStorageGB 250 -CurrentRetentions @($retention, $retention) -MaximumRetentions 2
    Assert-True $atFloor.CanRetain 'Retention rejected the exact free-space floor.'
    Assert-True $atFloor.RequiresEviction 'Retention cap did not require an eviction.'

    $malformed = Join-Path $testRoot 'malformed.jsonl'
    [IO.File]::WriteAllText($malformed, '{bad json')
    $message = ''
    try { $null = Read-MemLabsTestHistory -Path $malformed } catch { $message = $_.Exception.Message }
    Assert-True ($message -like '*invalid JSON*line 1*') 'Malformed history did not fail closed with a line number.'

    $resumeHistory = Join-Path $testRoot 'resume.jsonl'
    $crossCandidate = [pscustomobject]@{
        CandidateKey = 'CrossRevision|CSTest3'; CurrentCommit = $commit; Family = 'CSTest3'
    }
    $firstRoot = Get-MemLabsContinuousCrossRevisionStateRoot -Candidate $crossCandidate -HistoryPath $resumeHistory
    Write-MemLabsTestHistoryEvent -Path $resumeHistory -Event ([pscustomobject]@{
            EventType = 'SchedulerSelection'; CandidateKey = $crossCandidate.CandidateKey
            Commit = $commit; CrossRevisionStateRoot = $firstRoot
        })
    Assert-Equal $firstRoot (Get-MemLabsContinuousCrossRevisionStateRoot -Candidate $crossCandidate -HistoryPath $resumeHistory) `
        'Interrupted cross-revision selection did not reuse its state root.'
    Write-MemLabsTestHistoryEvent -Path $resumeHistory -Event ([pscustomobject]@{
            EventType = 'RunCompleted'; CandidateKey = $crossCandidate.CandidateKey
            Commit = $commit; Success = $false; Interrupted = $true
            CompletedUtc = [DateTime]::UtcNow.ToString('o')
        })
    Assert-Equal $firstRoot (Get-MemLabsContinuousCrossRevisionStateRoot -Candidate $crossCandidate -HistoryPath $resumeHistory) `
        'Interrupted completion advanced away from its resumable state root.'
    Write-MemLabsTestHistoryEvent -Path $resumeHistory -Event ([pscustomobject]@{
            EventType = 'RunCompleted'; CandidateKey = $crossCandidate.CandidateKey
            Commit = $commit; Success = $true; CompletedUtc = [DateTime]::UtcNow.ToString('o')
        })
    $secondRoot = Get-MemLabsContinuousCrossRevisionStateRoot -Candidate $crossCandidate -HistoryPath $resumeHistory
    Assert-True ($secondRoot -ne $firstRoot -and $secondRoot -like '*-run2') `
        'Completed cross-revision selection did not advance to a fresh state generation.'

    Write-Host 'PASS -- continuous selection is capacity-aware, risk/freshness scored, and retention is bounded/conflict-safe.'
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
