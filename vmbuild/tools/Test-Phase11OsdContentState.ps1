<#
.SYNOPSIS
    Verifies which OSD content states may pass final functional validation.
#>
#requires -Version 5.1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Extracted guest scriptblocks read fixture variables dynamically.')]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$validationPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'common\Common.Validation.Functional.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($validationPath, [ref]$tokens, [ref]$parseErrors)

if ($parseErrors.Count -gt 0) {
    throw "Common.Validation.Functional.ps1 has $($parseErrors.Count) parse error(s): $($parseErrors -join '; ')"
}

$validationText = Get-Content -LiteralPath $validationPath -Raw
if ($validationText -match "Name='OSD DPS'[^\r\n]*Select-Object -First 1") {
    throw "Phase 11 validates only the first same-name 'OSD DPS' object."
}
if (-not $validationText.Contains('Get-MemLabsDistributionPointGroupValidationState -Namespace $ns -SiteCode $sc -GroupName ''OSD DPS''')) {
    throw "Phase 11 does not use the duplicate-safe DP-group validation helper."
}

$stateHelpers = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Get-MemLabsContentDistributionStateKind'
        }, $true))
if ($stateHelpers.Count -ne 1) {
    throw "Expected one Get-MemLabsContentDistributionStateKind definition; found $($stateHelpers.Count)."
}
Invoke-Expression $stateHelpers[0].Extent.Text

$stateCalls = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -eq 'Get-MemLabsContentDistributionStateKind'
        }, $true))
if ($stateCalls.Count -lt 3) {
    throw "Expected boot-image, OSD convergence, and final OS-package classifier calls; found $($stateCalls.Count)."
}
function Get-EnclosingScriptBlockExpressions {
    param($Node)
    $scopes = [System.Collections.Generic.List[object]]::new()
    for ($ancestor = $Node.Parent; $ancestor; $ancestor = $ancestor.Parent) {
        if ($ancestor -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) { $scopes.Add($ancestor) }
    }
    return $scopes.ToArray()
}
$helperScope = @(Get-EnclosingScriptBlockExpressions $stateHelpers[0]) | Select-Object -First 1
foreach ($stateCall in $stateCalls) {
    $callScopes = @(Get-EnclosingScriptBlockExpressions $stateCall)
    if (-not $helperScope -or
        @($callScopes | Where-Object { $_.Extent.StartOffset -eq $helperScope.Extent.StartOffset }).Count -eq 0) {
        throw 'The content-state helper is not defined inside the same remoted guest scriptblock as every call site.'
    }
}

$expected = @{
    0 = 'Installed'
    1 = 'Pending'
    2 = 'Pending'
    3 = 'Problem'
    4 = 'Problem'
    5 = 'Problem'
    6 = 'Problem'
    7 = 'Pending'
    8 = 'Problem'
}
foreach ($state in 0..8) {
    $actual = Get-MemLabsContentDistributionStateKind -State $state
    if ($actual -ne $expected[$state]) {
        throw "State $state classified as '$actual'; expected '$($expected[$state])'."
    }
}

if (-not $validationText.Contains('for ($pendingTry = 1; $pendingTry -le 10')) {
    throw 'Required boot-image pending states have no bounded convergence wait.'
}
if ($validationText -notmatch '(?s)\$getRequiredPendingBootRows\s*=\s*\{.{0,500}State -notin 1, 2, 7') {
    throw 'The boot-image convergence wait does not include InstallRetrying state 2.'
}
if ($validationText -notmatch 'bootPendingWaitTimedOut[\s\S]{0,800}requiredOsdCoverageProblems \+= "\$pendingDetail still pending') {
    throw 'A required boot-image DP that remains pending after the wait does not fail coverage.'
}
if ($validationText -notmatch '\$osdContentWaitSeconds\s*=\s*900' -or
    $validationText -notmatch '\$osdContentWaitTimedOut' -or
    $validationText -notmatch 'after \$\{osdContentWaitElapsedSeconds\}s of convergence waiting') {
    throw 'Required OS image/upgrade content has no bounded convergence wait and timeout failure.'
}
if ($validationText -notmatch '\$osdRetryingSince' -or
    $validationText -notmatch 'TotalSeconds -lt 300' -or
    $validationText -notmatch 'remained InstallRetrying.+for 300s') {
    throw 'InstallRetrying OSD content is not observed for five minutes before its one-time re-arm.'
}
if ($validationText -notmatch 'TargetedNoStatus' -or
    $validationText -notmatch '\$getOsdContentTargetRows') {
    throw 'Targeted content with no summarizer row does not participate in convergence.'
}
if ($validationText -notmatch '\$osdContentWaitProbeFailed' -or
    $validationText -notmatch 'convergence probe failed after') {
    throw 'A failed OSD convergence probe does not fail closed with elapsed-time evidence.'
}
if ($validationText -notmatch 'SMS_DistributionDPStatus' -or
    $validationText -notmatch 'DP smsdpprov tail') {
    throw 'Persistent OSD content failures do not capture provider and DP-side diagnostics.'
}
if ($validationText -notmatch 'FAIL: \$\(\$pkgClass\.Class\) query failed, so required') {
    throw 'Required OS content query failures do not fail closed.'
}
if ($validationText -notmatch '\$siteTaskSequenceReferenceIds' -or
    $validationText -notmatch '\$taskSequence\.References' -or
    $validationText -notmatch '\$reference\.Package') {
    throw 'Phase 11 does not resolve hierarchy-owned OSD content through this site''s task-sequence references.'
}
if ($validationText -notmatch 'hierarchy-owned OSD content is valid when referenced') {
    throw 'Phase 11 does not explain hierarchy-owned OSD content acceptance.'
}
if ($validationText -notmatch '\$siteTaskSequenceReferenceErrors' -or
    $validationText -notmatch 'could not read package references') {
    throw 'Task-sequence reference read failures are silently treated as an empty reference set.'
}
if ($validationText -notmatch 'FAIL: SMS_TaskSequencePackage query failed, so required OSD task sequences and their content references were not measured') {
    throw 'A required task-sequence query failure does not fail closed.'
}
if (@([regex]::Matches($validationText, '& \$selectRelevantOsdContent')).Count -ne 2) {
    throw 'Pending and final OSD content checks do not share one task-sequence-reference selector.'
}
if ($validationText -notmatch 'FAIL: \$missingContentMessage') {
    throw 'A task sequence with no referenced OS image or upgrade package does not fail required OSD validation.'
}
if ($validationText -notmatch 'Phase11-CMSite-Test[\s\S]{0,200}-TimeoutSeconds 600 -PollProgress') {
    throw 'The site-wide validation call does not use progress-aware stall timeout semantics.'
}

foreach ($helperName in @('ConvertFrom-MemLabsOsdTransferEvent', 'Get-MemLabsOsdTransferEvidence', 'Get-MemLabsOsdContentWaitState')) {
    $definitions = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $helperName
            }, $true))
    foreach ($definition in $definitions) { . ([scriptblock]::Create($definition.Extent.Text)) }
}
$pendingDefinition = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left.Extent.Text -eq '$readPendingOsdContent'
        }, $true))
$waitStarts = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left.Extent.Text -in '$osdPreparationWaitSeconds', '$osdContentWaitSeconds'
        }, $true) | Sort-Object { $_.Extent.StartOffset })
$waitEnd = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left.Extent.Text -eq '$getOsdContentFailureDiagnostic'
        }, $true))
if ($pendingDefinition.Count -ne 1 -or $waitStarts.Count -eq 0 -or $waitEnd.Count -ne 1) {
    throw 'Could not locate the production OSD convergence scriptblocks.'
}
$pendingFactory = [scriptblock]::Create($pendingDefinition[0].Extent.Text + "`n`$readPendingOsdContent")
$waitText = $validationText.Substring($waitStarts[0].Extent.StartOffset,
    $waitEnd[0].Extent.StartOffset - $waitStarts[0].Extent.StartOffset)
$waitScript = [scriptblock]::Create($waitText + @'

[pscustomobject]@{
    ElapsedSeconds = $osdContentWaitElapsedSeconds
    TimedOut = $osdContentWaitTimedOut
    ProbeFailed = $osdContentWaitProbeFailed
    Passed = $results.Passed
    Targets = @($results.OsdContentWaitTargets)
    TransferStarts = @($transferStarts)
    Sources = @($results.OsdContentSourceSiteCodes)
    Details = @($results.Details)
    Refreshes = $fixture.Refreshes
}
'@)

function New-WaitTarget {
    param(
        [string]$PackageId = 'PRI00007',
        [string]$DP = 'DP1.fixture.test',
        [int]$State = 7,
        [int[]]$TransferStarts = @(),
        [int[]]$ProgressAt = @(),
        [string[]]$ProgressNames = @(),
        [int]$SourceReadyAt = -1,
        [int]$InstalledAt = 10000,
        [int]$LogVersion = 1,
        [switch]$NoStatus
    )
    [pscustomobject]@{
        PackageId = $PackageId; Name = $PackageId; DP = $DP
        SourceSite = 'SRC'; SourceVersion = 1; StoredPkgVersion = 1
        State = $State; TransferStarts = $TransferStarts; InstalledAt = $InstalledAt
        ProgressAt = $ProgressAt; ProgressNames = $ProgressNames; SourceReadyAt = $SourceReadyAt
        LogVersion = $LogVersion; NoStatus = $NoStatus.IsPresent
    }
}
function Invoke-WaitFixture {
    param([object[]]$Targets, [switch]$LogReadFails, [int]$QueryFailsAt = -1)

    $fixture = [pscustomobject]@{
        Seconds = 0; Refreshes = 0; Targets = $Targets
        LogReadFails = $LogReadFails.IsPresent; QueryFailsAt = $QueryFailsAt
    }
    $baseUtc = ([datetime]'2026-11-04T00:49:50Z').ToUniversalTime()
    $results = @{
        Passed = $true
        Details = [System.Collections.Generic.List[string]]::new()
        OsdContentSourceSiteCodes = [System.Collections.Generic.List[string]]::new()
        OsdContentWaitProblems = [System.Collections.Generic.List[string]]::new()
        OsdContentWaitTargets = @()
    }
    $ns = 'root\SMS\site_PRI'
    $osdProgressActivity = 'Fixture OSD'
    $expectedOsdDpNames = @($Targets.DP | Select-Object -Unique)
    $osdPackageClasses = @(
        @{ Class = 'SMS_ImagePackage'; Label = 'OS image' }
        @{ Class = 'SMS_OperatingSystemInstallPackage'; Label = 'OS upgrade package' }
    )
    $selectRelevantOsdContent = { param($VisibleContent) $VisibleContent }
    $dpNameOf = { param($NalPath) "$NalPath".Trim('\') }
    $getOsdContentTargetRows = {
        param($PackageId, $RequiredDp)
        $target = [pscustomobject]@{ RefreshNow = $false }
        $target | Add-Member -MemberType ScriptMethod -Name Put -Value { $fixture.Refreshes++ }
        $target
    }
    function Get-Date { $baseUtc.AddSeconds($fixture.Seconds) }
    function Start-Sleep {
        param($Seconds)
        $fixture.Seconds += $Seconds
        if ($fixture.Seconds -gt 3600) { throw 'The production OSD wait exceeded the fixture safety limit.' }
    }
    function Write-Progress { param($Activity, $Status, $CurrentOperation, [switch]$Completed) }
    function Get-ItemProperty {
        param($Path, $Name, $ErrorAction)
        [pscustomobject]@{ 'Installation Directory' = 'C:\FixtureSite' }
    }
    function Test-Path { param($LiteralPath, $Path) $true }
    function Get-Content {
        param($LiteralPath, $Tail, $ErrorAction)
        if ($fixture.LogReadFails) { throw 'fixture transfer log access denied' }
        if ($Tail -ne 10000) { throw 'The transfer-start reader lost its bounded log tail.' }
        $threadId = 1234
        foreach ($target in $fixture.Targets) {
            $threadId++
            foreach ($start in $target.TransferStarts) {
                if ($fixture.Seconds -lt $start) { continue }
                $timestamp = $baseUtc.AddSeconds($start).ToString('MM-dd-yyyy HH:mm:ss.fff')
                ('Sending thread starting for Job: 1, package: {0}, Version: {1}, Priority: 2, server: {2}, DPPriority: 200  $$<SMS_PACKAGE_TRANSFER_MANAGER><{3}+000><thread={4}>' -f
                    $target.PackageId, $target.LogVersion, $target.DP, $timestamp, $threadId)
            }
            for ($index = 0; $index -lt $target.ProgressAt.Count; $index++) {
                if ($fixture.Seconds -lt $target.ProgressAt[$index]) { continue }
                $timestamp = $baseUtc.AddSeconds($target.ProgressAt[$index]).ToString('MM-dd-yyyy HH:mm:ss.fff')
                $fileName = "sources\file$index.dll"
                if ($target.ProgressNames.Count -gt $index) { $fileName = $target.ProgressNames[$index] }
                ('Adding {0} file in {1}.{2}.  $$<SMS_PACKAGE_TRANSFER_MANAGER><{3}+000><thread={4}>' -f
                    $fileName, $target.PackageId, $target.LogVersion, $timestamp, $threadId)
            }
        }
    }
    function Get-WmiObject {
        param($Namespace, $Class, $Filter, $ErrorAction)
        if ($Class -eq 'SMS_ImagePackage') {
            foreach ($group in @($fixture.Targets | Group-Object PackageId)) {
                $target = $group.Group[0]
                $storedVersion = 1
                if ($target.SourceReadyAt -ge 0 -and $fixture.Seconds -lt $target.SourceReadyAt) { $storedVersion = 0 }
                [pscustomobject]@{
                    PackageID = $target.PackageId; Name = $target.Name
                    SourceSite = $target.SourceSite; SourceVersion = $target.SourceVersion
                    StoredPkgVersion = $storedVersion
                }
            }
            return
        }
        if ($Class -eq 'SMS_OperatingSystemInstallPackage') { return }
        if ($Class -ne 'SMS_PackageStatusDistPointsSummarizer' -or $Filter -notmatch "PackageID='([^']+)'") {
            throw "Unexpected fixture provider query: $Class / $Filter"
        }
        $packageId = $Matches[1]
        if ($fixture.QueryFailsAt -ge 0 -and $fixture.Seconds -ge $fixture.QueryFailsAt) {
            throw 'fixture convergence query failed'
        }
        foreach ($dp in $expectedOsdDpNames) {
            $target = @($fixture.Targets | Where-Object { $_.PackageId -eq $packageId -and $_.DP -eq $dp } |
                    Select-Object -First 1)
            $stateNumber = 0
            if ($target.Count -eq 1 -and $fixture.Seconds -lt $target[0].InstalledAt) {
                if ($target[0].NoStatus) { continue }
                $stateNumber = $target[0].State
            }
            [pscustomobject]@{ PackageID = $packageId; State = $stateNumber; ServerNALPath = "\\$dp\" }
        }
    }
    $readPendingOsdContent = & $pendingFactory
    & $waitScript
}

$late = Invoke-WaitFixture -Targets @(
    (New-WaitTarget -PackageId 'PRI00006' -TransferStarts 30 -InstalledAt 300),
    (New-WaitTarget -PackageId 'PRI00007' -TransferStarts 900 -InstalledAt 1799)
)
if ($late.TimedOut -or $late.ProbeFailed -or $late.ElapsedSeconds -ne 1800) {
    throw "A late required package did not receive its full 900-second transfer window: elapsed=$($late.ElapsedSeconds), timedOut=$($late.TimedOut), probeFailed=$($late.ProbeFailed)."
}
if ($late.Sources -notcontains 'SRC' -or $late.Targets[0].Stage -ne 'TransferOrInstallation' -or
    ($late.Targets[0].DeadlineUtc - $late.Targets[0].TransferStartedAtUtc).TotalSeconds -ne 900) {
    throw 'The executed wait lost its source site or exact per-target deadline.'
}
$progressing = Invoke-WaitFixture -Targets @(
    (New-WaitTarget -TransferStarts 30 -ProgressAt 600, 1200, 1800, 2400 -InstalledAt 2699)
)
if ($progressing.TimedOut -or $progressing.ProbeFailed -or $progressing.ElapsedSeconds -ne 2700) {
    throw "Verified file-copy progress did not keep the target alive until the 45-minute cap: elapsed=$($progressing.ElapsedSeconds), timedOut=$($progressing.TimedOut)."
}

function Assert-WaitOutcome {
    param($Actual, [int]$Seconds, [bool]$TimedOut)
    if ($Actual.ElapsedSeconds -ne $Seconds -or $Actual.TimedOut -ne $TimedOut -or $Actual.ProbeFailed) {
        throw "Unexpected wait result: elapsed=$($Actual.ElapsedSeconds), timedOut=$($Actual.TimedOut), probeFailed=$($Actual.ProbeFailed); expected $Seconds seconds, timeout=$TimedOut."
    }
}
$lateTimeout = Invoke-WaitFixture -Targets @(
    (New-WaitTarget -TransferStarts 900 -InstalledAt 1801)
)
Assert-WaitOutcome $lateTimeout 1800 $true
if ($lateTimeout.Passed -or $lateTimeout.Targets[0].ElapsedSeconds -ne 900 -or
    -not $lateTimeout.Targets[0].Expired) {
    throw 'A stalled late transfer did not fail after its own full 900-second window.'
}
$queueTimeout = Invoke-WaitFixture -Targets @((New-WaitTarget))
Assert-WaitOutcome $queueTimeout 900 $true
if ($queueTimeout.Passed -or $queueTimeout.Targets[0].Stage -ne 'PreparationOrUnobservedTransfer') {
    throw 'A transfer with no observed start escaped the separate preparation/queue limit.'
}
$tooLate = Invoke-WaitFixture -Targets @((New-WaitTarget -TransferStarts 901))
Assert-WaitOutcome $tooLate 900 $true
$lastPoll = Invoke-WaitFixture -Targets @((New-WaitTarget -TransferStarts 899 -InstalledAt 1798))
Assert-WaitOutcome $lastPoll 1799 $false
$twoDps = Invoke-WaitFixture -Targets @(
    (New-WaitTarget -DP 'DP1.fixture.test' -TransferStarts 30 -InstalledAt 300),
    (New-WaitTarget -DP 'DP2.fixture.test' -TransferStarts 840 -InstalledAt 1739)
)
Assert-WaitOutcome $twoDps 1740 $false
if ($twoDps.Targets[0].DP -ne 'DP2.fixture.test') { throw 'One DP borrowed another DP''s transfer clock.' }
$retry = Invoke-WaitFixture -Targets @((New-WaitTarget -State 2 -TransferStarts 30, 600))
Assert-WaitOutcome $retry 930 $true
if ($retry.Refreshes -ne 1 -or $retry.Targets[0].ElapsedSeconds -ne 900) {
    throw 'A retry reset the first transfer deadline or repeated the existing one-time re-arm.'
}
$otherVersion = Invoke-WaitFixture -Targets @((New-WaitTarget -TransferStarts 840 -LogVersion 2))
Assert-WaitOutcome $otherVersion 900 $true
$oldStart = Invoke-WaitFixture -Targets @((New-WaitTarget -TransferStarts -30))
Assert-WaitOutcome $oldStart 900 $true
$noStatus = Invoke-WaitFixture -Targets @((New-WaitTarget -NoStatus -TransferStarts 840 -InstalledAt 1739))
Assert-WaitOutcome $noStatus 1740 $false
$unreadable = Invoke-WaitFixture -Targets @((New-WaitTarget)) -LogReadFails
Assert-WaitOutcome $unreadable 900 $true
if (($unreadable.Details -join ' ') -notmatch 'fixture transfer log access denied') {
    throw 'An unreadable transfer log silently became a timing observation.'
}
$failedProbe = Invoke-WaitFixture -Targets @((New-WaitTarget)) -QueryFailsAt 300
if (-not $failedProbe.ProbeFailed -or $failedProbe.ElapsedSeconds -ne 300 -or
    ($failedProbe.Details -join ' ') -notmatch 'fixture convergence query failed') {
    throw 'A failed convergence recheck lost its error or continued waiting.'
}
$problem = Invoke-WaitFixture -Targets @(
    (New-WaitTarget -PackageId 'PRI00006' -State 3),
    (New-WaitTarget -PackageId 'PRI00007' -TransferStarts 840)
)
if ($problem.Passed -or $problem.ElapsedSeconds -ne 0 -or $problem.Refreshes -ne 0 -or
    ($problem.Details -join ' ') -notmatch 'problem state') {
    throw 'A known distribution problem was hidden by another target''s longer window.'
}
$healthy = Invoke-WaitFixture -Targets @((New-WaitTarget -InstalledAt 0))
Assert-WaitOutcome $healthy 0 $false
if (-not $healthy.Passed) { throw 'Already Installed content was changed by the timer fix.' }
$hardCap = Invoke-WaitFixture -Targets @(
    (New-WaitTarget -TransferStarts 30 -ProgressAt 600, 1200, 1800, 2400)
)
Assert-WaitOutcome $hardCap 2700 $true
if ($hardCap.Targets[0].LimitKind -ne 'OverallHardCap' -or
    $hardCap.Targets[0].NoProgressSeconds -ne 300 -or $hardCap.Targets[0].VerifiedCopiedFiles -ne 4) {
    throw 'The overall cap did not stop a still-progressing transfer without falsely calling it stalled.'
}
$stopped = Invoke-WaitFixture -Targets @((New-WaitTarget -TransferStarts 30 -ProgressAt 600))
Assert-WaitOutcome $stopped 1500 $true
if ($stopped.Targets[0].NoProgressSeconds -ne 900 -or $stopped.Targets[0].LimitKind -ne 'NoVerifiedProgress') {
    throw 'A stopped transfer did not receive exactly 900 seconds after its last verified file copy.'
}
$duplicateFile = Invoke-WaitFixture -Targets @(
    (New-WaitTarget -TransferStarts 30 -ProgressAt 600, 1200, 1800 -ProgressNames 'sources\same.dll', 'sources\same.dll', 'sources\same.dll')
)
Assert-WaitOutcome $duplicateFile 1500 $true
if ($duplicateFile.Targets[0].VerifiedCopiedFiles -ne 1) {
    throw 'Repeated attempts to add the same file renewed the no-progress clock.'
}
$sourceReady = Invoke-WaitFixture -Targets @(
    (New-WaitTarget -SourceReadyAt 840 -TransferStarts 1500 -InstalledAt 2399)
)
Assert-WaitOutcome $sourceReady 2400 $false
$uncorrelated = Invoke-WaitFixture -Targets @((New-WaitTarget -ProgressAt 600))
Assert-WaitOutcome $uncorrelated 900 $true
if (($uncorrelated.Details -join ' ') -notmatch 'no matching package/version sending thread' -or
    $uncorrelated.Targets[0].VerifiedCopiedFiles -ne 0 -or
    $uncorrelated.Targets[0].IntraFileBytesMeasured) {
    throw 'Uncorrelated file activity became proof of target progress.'
}
$isolated = Invoke-WaitFixture -Targets @(
    (New-WaitTarget -DP 'DP1.fixture.test' -TransferStarts 30 -ProgressAt 600, 1200),
    (New-WaitTarget -DP 'DP2.fixture.test' -TransferStarts 30)
)
Assert-WaitOutcome $isolated 930 $true
$isolatedTarget = @($isolated.Targets | Where-Object { $_.DP -eq 'DP2.fixture.test' })[0]
if (-not $isolatedTarget.Expired -or $isolatedTarget.VerifiedCopiedFiles -ne 0) {
    throw 'Another DP''s copied files kept an idle target alive.'
}
$oldProgress = Invoke-WaitFixture -Targets @((New-WaitTarget -TransferStarts -300 -ProgressAt -100))
Assert-WaitOutcome $oldProgress 900 $true
$wrongProgressVersion = Invoke-WaitFixture -Targets @(
    (New-WaitTarget -TransferStarts 30 -ProgressAt 600 -LogVersion 2)
)
Assert-WaitOutcome $wrongProgressVersion 900 $true

foreach ($helperName in @('ConvertFrom-MemLabsOsdTransferEvent', 'Get-MemLabsOsdTransferEvidence', 'Get-MemLabsOsdContentWaitState')) {
    $definitions = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $helperName
            }, $true))
    if ($definitions.Count -ne 1) { throw "Expected one remoted $helperName helper." }
    $scope = @(Get-EnclosingScriptBlockExpressions $definitions[0]) | Select-Object -First 1
    if ($scope.Extent.StartOffset -ne $helperScope.Extent.StartOffset) {
        throw "$helperName is outside the remoted content-validator scope."
    }
}
$classic = 'Sending thread starting for Job: 15, package: PS200007, Version: 1, Priority: 2, server: FAB-PS1DPMP1.FABRIKAM.COM, DPPriority: 200  $$<SMS_PACKAGE_TRANSFER_MANAGER><11-03-2026 19:04:14.299+360><thread=7772 (0x1E5C)>'
$parsed = ConvertFrom-MemLabsOsdTransferEvent -Line $classic
$expectedUtc = ([datetime]'2026-11-04T01:04:14.299Z').ToUniversalTime()
if ($parsed.PackageId -ne 'PS200007' -or $parsed.SourceVersion -ne 1 -or
    $parsed.DP -ne 'FAB-PS1DPMP1.FABRIKAM.COM' -or $parsed.StartedAtUtc -ne $expectedUtc -or
    $parsed.StartedAtUtc.Kind -ne [DateTimeKind]::Utc) {
    throw 'The captured classic transfer-start shape lost its identity, version, or UTC timestamp.'
}
$cmTrace = '<![LOG[Sending thread starting for Job: 15, package: PS200007, Version: 1, Priority: 2, server: FAB-PS1DPMP1.FABRIKAM.COM, DPPriority: 200]LOG]!><time="19:04:14.299+360" date="11-03-2026" component="SMS_PACKAGE_TRANSFER_MANAGER" thread="7772">'
if ((ConvertFrom-MemLabsOsdTransferEvent -Line $cmTrace).StartedAtUtc -ne $expectedUtc) {
    throw 'CMTrace and classic transfer records use different UTC clocks.'
}
if (@(ConvertFrom-MemLabsOsdTransferEvent -Line 'No more send requests found.').Count -ne 0) {
    throw 'An unrelated log line was treated as a transfer start.'
}
foreach ($badLine in @($classic.Replace('11-03-2026', '11-99-2026'), $classic.Replace('Version: 1', 'Version: invalid'))) {
    $rejected = $false
    try { $null = ConvertFrom-MemLabsOsdTransferEvent -Line $badLine }
    catch { $rejected = $_.Exception.Message -match 'Invalid timestamp or version|Malformed PkgXferMgr' }
    if (-not $rejected) { throw 'A malformed transfer record was silently accepted.' }
}
$anchorUtc = ([datetime]'2026-11-04T00:49:50Z').ToUniversalTime()
$foreignDp = Get-MemLabsOsdContentWaitState -PendingTargets @((New-WaitTarget)) `
    -TransferStarts @([pscustomobject]@{
        PackageId = 'PRI00007'; DP = 'DP1.other.test'; SourceVersion = 1; StartedAtUtc = $anchorUtc.AddSeconds(840)
    }) -StartedAtUtc $anchorUtc -NowUtc $anchorUtc.AddSeconds(900) -TransferClocks @{}
if ($foreignDp.Targets[0].Stage -ne 'PreparationOrUnobservedTransfer' -or
    -not $foreignDp.Targets[0].Expired) {
    throw 'A different FQDN with the same short name extended the target''s timer.'
}
$noResurrection = Get-MemLabsOsdContentWaitState -PendingTargets @((New-WaitTarget)) `
    -TransferStarts @([pscustomobject]@{
        PackageId = 'PRI00007'; DP = 'DP1.fixture.test'; SourceVersion = 1; StartedAtUtc = $anchorUtc
    }) -ProgressEvents @([pscustomobject]@{
        PackageId = 'PRI00007'; DP = 'DP1.fixture.test'; SourceVersion = 1
        Kind = 'FileCopiedToStaging'; Identity = 'late.dll'; AtUtc = $anchorUtc.AddSeconds(901); SortOrder = 1
    }) -StartedAtUtc $anchorUtc -NowUtc $anchorUtc.AddSeconds(930) -TransferClocks @{} -ProgressClocks @{}
if (-not $noResurrection.Targets[0].Expired -or
    ($noResurrection.Targets[0].DeadlineUtc - $anchorUtc).TotalSeconds -ne 900) {
    throw 'A late milestone resurrected a target after its no-progress deadline.'
}
& {
    $fixtureLines = @(
        'Sending thread starting for Job: 1, package: PRI00007, Version: 1, Priority: 2, server: DP1.fixture.test, DPPriority: 200 $$<SMS_PACKAGE_TRANSFER_MANAGER><11-04-2026 00:00:00.000+000><thread=1234>',
        'Adding sources\first.dll file in PRI00007.1. $$<SMS_PACKAGE_TRANSFER_MANAGER><11-04-2026 00:01:00.000+000><thread=1234>',
        'Sending thread starting for Job: 2, package: PRI00007, Version: 1, Priority: 2, server: DP2.fixture.test, DPPriority: 200 $$<SMS_PACKAGE_TRANSFER_MANAGER><11-04-2026 00:02:00.000+000><thread=1234>',
        'Adding sources\second.dll file in PRI00007.1. $$<SMS_PACKAGE_TRANSFER_MANAGER><11-04-2026 00:03:00.000+000><thread=1234>'
    )
    function Get-ItemProperty {
        param($Path, $Name, $ErrorAction)
        [pscustomobject]@{ 'Installation Directory' = 'C:\FixtureSite' }
    }
    function Test-Path { param($LiteralPath, $ErrorAction) $LiteralPath.EndsWith('.log') }
    function Get-Content { param($LiteralPath, $Tail, $ErrorAction) $fixtureLines }
    $evidence = Get-MemLabsOsdTransferEvidence -Details ([System.Collections.Generic.List[string]]::new())
    if ($evidence.Progress.Count -ne 2 -or $evidence.Progress[0].DP -ne 'DP1.fixture.test' -or
        $evidence.Progress[1].DP -ne 'DP2.fixture.test') {
        throw 'A recycled sending thread attributed a file copy to the wrong DP.'
    }
}

Write-Host 'PASS -- executed per-target progress/stall clocks, 45-minute cap, evidence correlation, and unchanged required-content checks.'
