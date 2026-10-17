<#
.SYNOPSIS
    Verifies Phase 8 host and client-package diagnostic timeline behavior.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$phasePath = Join-Path $root 'common\Common.Phases.ps1'
$boundaryPath = Join-Path $root 'DSC\phases\InstallBoundaryGroups.ps1'
$scriptBlockPath = Join-Path $root 'common\Common.ScriptBlocks.ps1'
$analyzerPath = Join-Path $PSScriptRoot 'Analyze-Phase8Diagnostics.ps1'
. (Join-Path $root 'DSC\phases\ProcessFunctions.ps1')

function Import-TestFunction {
    param([string]$Path, [string]$Name)

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw "$Path has $($errors.Count) parse error(s): $($errors -join '; ')" }
    $definitions = @($ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($definitions.Count -ne 1) { throw "Expected one $Name definition in $Path; found $($definitions.Count)." }
    [scriptblock]::Create($definitions[0].Extent.Text)
}

. (Import-TestFunction -Path $phasePath -Name 'Get-Phase8HostReliabilityEvents')
. (Import-TestFunction -Path $phasePath -Name 'Write-Phase8DiagnosticSnapshot')
. (Import-TestFunction -Path $boundaryPath -Name 'Write-MemLabsClientPackageTimelineRecord')
. (Import-TestFunction -Path $boundaryPath -Name 'Invoke-MemLabsClientPackageDiagnosticProbe')
. (Import-TestFunction -Path $boundaryPath -Name 'Test-MemLabsLocalComputerName')

function Get-JobStreamSource {
    param($Job)
    [pscustomobject]@{
        Output   = @('one')
        Error    = @()
        Warning  = @()
        Progress = @('one')
    }
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "memlabs-phase8-diag-$([guid]::NewGuid().ToString('N'))"
[void](New-Item -Path $tempRoot -ItemType Directory -Force)
try {
    $phaseTimeline = Join-Path $tempRoot 'Phase8-Timeline.jsonl'
    $job = [pscustomobject]@{
        Id          = 17
        Name        = 'LAB-PRI [Primary]'
        State       = 'Running'
        PSBeginTime = (Get-Date).AddMinutes(-7)
    }
    $global:JobProgressHistory = @{
        17 = @{
            Activity        = 'Installing Configuration Manager'
            Status          = 'Waiting for secondary content'
            StatusSince     = [DateTime]::UtcNow.AddMinutes(-6)
            PercentComplete = 64
        }
    }
    Write-Phase8DiagnosticSnapshot -Path $phaseTimeline -Jobs @($job) -PhaseStart (Get-Date).AddMinutes(-8) -Trigger 'test'

    $phaseRecord = Get-Content -LiteralPath $phaseTimeline -Raw | ConvertFrom-Json
    if ($phaseRecord.SchemaVersion -ne 1 -or $phaseRecord.Trigger -ne 'test') {
        throw 'Phase 8 timeline record did not preserve its schema or trigger.'
    }
    if ($phaseRecord.Jobs.Count -ne 1 -or $phaseRecord.Jobs[0].VMName -ne 'LAB-PRI' -or
        $phaseRecord.Jobs[0].Activity -ne 'Installing Configuration Manager' -or
        $phaseRecord.Jobs[0].StatusHeldSec -lt 300) {
        throw 'Phase 8 timeline record did not preserve job critical-path state.'
    }

    function Get-CimInstance {
        param([string]$ClassName, [string]$Filter, $ErrorAction)
        if ($ClassName -eq 'Win32_OperatingSystem') {
            return [pscustomobject]@{
                TotalVisibleMemorySize = 16GB / 1KB
                FreePhysicalMemory     = 8GB / 1KB
                TotalVirtualMemorySize = 24GB / 1KB
                FreeVirtualMemory      = 12GB / 1KB
            }
        }
        if ($ClassName -eq 'Win32_Processor') {
            return [pscustomobject]@{ LoadPercentage = 37 }
        }
        throw "Unexpected CIM class '$ClassName'."
    }
    function Get-Counter {
        param([string[]]$Counter, [int]$MaxSamples, $ErrorAction)
        [pscustomobject]@{
            CounterSamples = @($Counter | ForEach-Object {
                    [pscustomobject]@{ Path = $_; CookedValue = 1.25 }
                })
        }
    }
    function Get-VM {
        param($ErrorAction)
        [pscustomobject]@{
            Name           = 'LAB-PRI'
            State          = 'Running'
            Status         = 'Operating normally'
            CPUUsage       = 12
            MemoryAssigned = 4GB
            MemoryDemand   = 3GB
            Uptime         = [TimeSpan]::FromMinutes(20)
            Heartbeat      = 'OkApplicationsHealthy'
        }
    }
    function Get-WinEvent {
        param([hashtable]$FilterHashtable, $ErrorAction)
        @(
            [pscustomobject]@{
                TimeCreated      = (Get-Date).AddMinutes(-1)
                ProviderName     = 'disk'
                Id               = 153
                LevelDisplayName = 'Warning'
                RecordId         = 42
                Message          = "Synthetic disk warning`r`nwith wrapped text."
            },
            [pscustomobject]@{
                TimeCreated      = (Get-Date).AddMinutes(-1)
                ProviderName     = 'Unrelated-Provider'
                Id               = 1
                LevelDisplayName = 'Warning'
                RecordId         = 43
                Message          = 'This event must be filtered.'
            }
        )
    }
    $metricsTimeline = Join-Path $tempRoot 'Phase8-Metrics.jsonl'
    Write-Phase8DiagnosticSnapshot -Path $metricsTimeline -Jobs @($job) -PhaseStart (Get-Date).AddMinutes(-8) `
        -Trigger 'periodic' -DeployConfig ([pscustomobject]@{
            virtualMachines = @([pscustomobject]@{ vmName = 'LAB-PRI'; hidden = $false })
        }) -IncludeHostMetrics
    $metricsRecord = Get-Content -LiteralPath $metricsTimeline -Raw | ConvertFrom-Json
    if (-not $metricsRecord.Host -or $metricsRecord.Host.Memory.AvailableMB -ne 8192 -or
        $metricsRecord.Host.CpuLoadPercent -ne 37 -or $metricsRecord.Host.VMs.Count -ne 1) {
        throw 'Phase 8 periodic snapshot did not retain host/VM pressure metrics.'
    }
    if ($metricsRecord.Host.RecentReliabilityEvents.Count -ne 1 -or
        $metricsRecord.Host.RecentReliabilityEvents[0].Provider -ne 'disk' -or
        $metricsRecord.Host.RecentReliabilityEvents[0].EventId -ne 153 -or
        $metricsRecord.Host.RecentReliabilityEvents[0].Message -notmatch 'Synthetic disk warning with wrapped text') {
        throw 'Phase 8 periodic snapshot did not retain bounded host reliability events.'
    }

    $packageTimeline = Join-Path $tempRoot 'ClientPackageTimeline.jsonl'
    Write-MemLabsClientPackageTimelineRecord -Path $packageTimeline -Record ([ordered]@{
            SchemaVersion = 1
            CapturedAtUtc = [DateTime]::UtcNow.ToString('o')
            Trigger       = 'content-wait'
            SiteCode      = 'PRI'
            PackageId     = 'PRI00004'
            Package       = [ordered]@{ SourceVersion = 3; StoredPkgVersion = 2 }
            Targeting     = @(
                [ordered]@{
                    Server = 'LEGACY-DP.test'; StoredPkgVersion = 2
                    SourceVersion = 3; RefreshNow = $false
                },
                [ordered]@{
                    Server = 'CURRENT-DP.test'; SiteCode = 'PRI'
                    RefreshNow = $true
                }
            )
            Summarizer    = @([ordered]@{ Server = 'LAB-DP.test'; StateName = 'ContentValidating'; SourceVersion = 3 })
            Replication   = @()
            SourceNode    = $null
            Nodes         = @()
            Errors        = @()
        })
    $analysis = @(& $analyzerPath -Path $phaseTimeline, $packageTimeline)
    if ($analysis.Count -ne 2 -or @($analysis.Type) -notcontains 'Phase8' -or @($analysis.Type) -notcontains 'ClientPackage') {
        throw 'Phase 8 analyzer did not recognize both diagnostic record types.'
    }
    if (@($analysis | Where-Object { $_.TimeUtc.Kind -ne [DateTimeKind]::Utc }).Count -gt 0) {
        throw 'Phase 8 analyzer did not preserve UTC timestamps.'
    }
    $packageAnalysis = $analysis | Where-Object { $_.Type -eq 'ClientPackage' }
    if ($packageAnalysis.Targeting -notmatch 'LEGACY-DP\.test=stored:2/source:3/refresh:False' -or
        $packageAnalysis.Targeting -notmatch 'CURRENT-DP\.test=site:PRI/refresh:True') {
        throw "Phase 8 analyzer did not support both legacy and corrected targeting records: $($packageAnalysis.Targeting)"
    }

    $fixturePassword = New-Object System.Security.SecureString
    foreach ($character in ([guid]::NewGuid().ToString()).ToCharArray()) {
        $fixturePassword.AppendChar($character)
    }
    $fixturePassword.MakeReadOnly()
    $credential = New-Object System.Management.Automation.PSCredential('fixture\probe', $fixturePassword)
    $probe = Invoke-MemLabsClientPackageDiagnosticProbe -ProbeScript {
        param($Label)
        [pscustomobject]@{
            Label = $Label
            Value = $probeValue
            User = $probeCredential.UserName
            PasswordLength = $probeCredential.Password.Length
            WorkingDirectory = (Get-Location).Path
        }
    } -Variables @{ probeValue = 7; probeCredential = $credential } -Parameters @{ Label = "fixture's result" } -TimeoutSeconds 20
    if ($probe.Error -or $probe.TimedOut -or $probe.Output.Value -ne 7 -or
        $probe.Output.Label -ne "fixture's result" -or $probe.Output.User -ne 'fixture\probe' -or
        $probe.Output.PasswordLength -lt 1 -or (Test-Path -LiteralPath $probe.Output.WorkingDirectory)) {
        throw "Diagnostic isolation did not preserve inputs, credentials, output, or cleanup: $($probe.Error)"
    }
    $failedProbe = Invoke-MemLabsClientPackageDiagnosticProbe -ProbeScript {
        throw 'synthetic diagnostic error'
    } -TimeoutSeconds 20
    if ($failedProbe.TimedOut -or $failedProbe.Output -or $failedProbe.Error -notmatch 'synthetic diagnostic error') {
        throw 'An isolated diagnostic exception was hidden or misreported as a timeout.'
    }
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $hungProbe = Invoke-MemLabsClientPackageDiagnosticProbe -ProbeScript {
        Start-Sleep -Seconds 30
    } -TimeoutSeconds 1
    $stopwatch.Stop()
    if (-not $hungProbe.TimedOut -or $hungProbe.Error -notmatch '1-second wall-clock limit' -or
        $stopwatch.Elapsed.TotalSeconds -gt 8 -or -not $hungProbe.ProcessId -or
        (Get-Process -Id $hungProbe.ProcessId -ErrorAction SilentlyContinue)) {
        throw "A blocked diagnostic was not terminated within its wall-clock bound: $($stopwatch.Elapsed.TotalSeconds)s; $($hungProbe.Error)"
    }

    $tokens = $null
    $parseErrors = $null
    $boundaryAst = [System.Management.Automation.Language.Parser]::ParseFile($boundaryPath, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count) { throw "Boundary script has parse errors: $($parseErrors -join '; ')" }
    $blocks = @{}
    foreach ($name in @('collectNodeContentState', 'collectCoverageSnapshot', 'writeCoverageSnapshot', 'fqdnOf')) {
        $assignments = @($boundaryAst.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                    $node.Left.Extent.Text -eq ('$' + $name) -and
                    $node.Right.Expression -is [System.Management.Automation.Language.ScriptBlockExpressionAst]
                }, $true))
        if ($assignments.Count -ne 1) { throw "Expected one diagnostic assignment for $name." }
        $factory = [scriptblock]::Create($assignments[0].Extent.Text + "`nreturn `$$name")
        $blocks[$name] = & $factory
    }
    $ns = 'root\SMS\site_PRI'
    $SiteCode = 'PRI'
    $PackageID = 'PRI00004'
    $coverageRunId = 'fixture-run'
    $stateName = @{ '0' = 'Installed'; '2' = 'InstallRetrying' }
    $collectNodeContentState = $blocks.collectNodeContentState.ToString()
    $fqdnOf = $blocks.fqdnOf.ToString()
    $localComputerNameFunction = ${function:Test-MemLabsLocalComputerName}.ToString()
    $deployConfig = [pscustomobject]@{ virtualMachines = @() }
    $ThisVM = $null
    $DomainFullName = 'fixture.test'
    $clientPackageDiagCredential = $null
    $script:FailedDiagnosticClass = ''
    $script:MissingTargeting = $false
    function Get-CimInstance {
        param($Namespace, $ClassName, $Filter, [string[]]$Property, $OperationTimeoutSec, $ErrorAction)
        if ($OperationTimeoutSec -ne 15) { throw 'Diagnostic CIM reads lost their operation timeout.' }
        if ($ClassName -eq $script:FailedDiagnosticClass) { throw 'Generic failure' }
        switch ($ClassName) {
            'SMS_Package' {
                return [pscustomobject]@{ SourceSite = 'PRI'; SourceVersion = 3; StoredPkgVersion = 3; SourceDate = 'fixture' }
            }
            'SMS_DistributionPoint' {
                $unsupported = @($Property | Where-Object { $_ -notin @('ServerNALPath', 'SiteCode', 'RefreshNow') })
                if ($unsupported.Count) { throw "Unsupported targeting projection: $($unsupported -join ', ')" }
                if (-not $script:MissingTargeting) {
                    return [pscustomobject]@{ ServerNALPath = '\\LAB-DP.test\'; SiteCode = 'PRI'; RefreshNow = $false }
                }
                return
            }
            'SMS_PackageStatusDistPointsSummarizer' {
                return [pscustomobject]@{ ServerNALPath = '\\LAB-DP.test\'; State = 0; SourceVersion = 3 }
            }
            default { throw "Unexpected diagnostic class '$ClassName'." }
        }
    }
    $collectCoverageSnapshot = $blocks.collectCoverageSnapshot
    $installedRecord = & $collectCoverageSnapshot -Trigger 'fixture-installed' -DistributionPoints @('LAB-DP.test')
    if ($installedRecord.Classification -ne 'Installed' -or $installedRecord.Errors.Count -ne 0 -or
        $installedRecord.Targeting.Count -ne 1 -or $installedRecord.Targeting[0].Contains('SourceVersion') -or
        $installedRecord.Package.SourceVersion -ne '3' -or $installedRecord.Summarizer[0].SourceVersion -ne '3') {
        throw 'The actual snapshot did not preserve valid targeting and package/summarizer versions.'
    }
    foreach ($className in @('SMS_DistributionPoint', 'SMS_Package', 'SMS_PackageStatusDistPointsSummarizer')) {
        $script:FailedDiagnosticClass = $className
        $unreadableRecord = & $collectCoverageSnapshot -Trigger 'fixture-unreadable' -DistributionPoints @('LAB-DP.test')
        if ($unreadableRecord.Classification -ne 'ProviderStateUnreadable' -or
            @($unreadableRecord.Errors | Where-Object { $_ -match "$className`: Generic failure" }).Count -ne 1) {
            throw "A failed $className query was mistaken for known package or targeting state."
        }
    }
    $script:FailedDiagnosticClass = ''
    $script:MissingTargeting = $true
    $missingRecord = & $collectCoverageSnapshot -Trigger 'fixture-missing' -DistributionPoints @('LAB-DP.test')
    if ($missingRecord.Classification -ne 'MissingTargetingRow' -or $missingRecord.Errors.Count -ne 0) {
        throw 'A successful empty targeting query no longer reports a genuinely missing row.'
    }

    $probeVariables = @{
        ns = $ns
        SiteCode = $SiteCode
        PackageID = $PackageID
        coverageRunId = $coverageRunId
        stateName = $stateName
        collectNodeContentState = $collectNodeContentState
        fqdnOf = $fqdnOf
        localComputerNameFunction = $localComputerNameFunction
        deployConfig = $deployConfig
        ThisVM = $ThisVM
        DomainFullName = $DomainFullName
        clientPackageDiagCredential = $clientPackageDiagCredential
    }
    $isolatedSnapshot = Invoke-MemLabsClientPackageDiagnosticProbe -Variables $probeVariables -ProbeScript {
        param($CollectorText, $CimMockText, $SnapshotParameters)
        Set-Item -Path Function:\Get-CimInstance -Value ([scriptblock]::Create($CimMockText))
        & ([scriptblock]::Create($CollectorText)) @SnapshotParameters
    } -Parameters @{
        CollectorText = $collectCoverageSnapshot.ToString()
        CimMockText = ${function:Get-CimInstance}.ToString()
        SnapshotParameters = @{ Trigger = 'isolated-snapshot'; DistributionPoints = @('LAB-DP.test') }
    } -TimeoutSeconds 20
    if ($isolatedSnapshot.Error -or $isolatedSnapshot.Output.Classification -ne 'Installed' -or
        $isolatedSnapshot.Output.Targeting.Count -ne 1 -or
        $isolatedSnapshot.Output.Targeting[0].SiteCode -ne 'PRI') {
        throw "The production snapshot did not survive the process boundary: $($isolatedSnapshot.Error)"
    }
    $isolatedTimeline = Join-Path $tempRoot 'IsolatedClientPackageTimeline.jsonl'
    Write-MemLabsClientPackageTimelineRecord -Path $isolatedTimeline -Record $isolatedSnapshot.Output
    $isolatedRecord = Get-Content -LiteralPath $isolatedTimeline -Raw | ConvertFrom-Json
    $isolatedAnalysis = @(& $analyzerPath -Path $isolatedTimeline)
    if ($isolatedRecord.Targeting.Count -ne 1 -or $isolatedRecord.Package.SourceVersion -ne '3' -or
        $isolatedRecord.Errors.Count -ne 0 -or $isolatedAnalysis.Count -ne 1 -or
        $isolatedAnalysis[0].Targeting -ne 'LAB-DP.test=site:PRI/refresh:False') {
        throw 'The isolated snapshot lost its JSON shape or analyzer compatibility.'
    }

    $script:DiagnosticProbeCalls = 0
    $script:DiagnosticProbeSucceeds = $false
    $script:DiagnosticStatuses = [System.Collections.Generic.List[object]]::new()
    function Invoke-MemLabsClientPackageDiagnosticProbe {
        param($ProbeScript, $Variables, $Parameters, $TimeoutSeconds)
        $script:DiagnosticProbeCalls++
        if ($TimeoutSeconds -ne 60) { throw 'Snapshot collection lost its 60-second wall-clock limit.' }
        if ($script:DiagnosticProbeSucceeds) {
            $output = $installedRecord.PSObject.Copy()
            $output.Trigger = $Parameters.Trigger
            $output.CapturedAtUtc = [DateTime]::UtcNow.ToString('o')
            return [pscustomobject]@{ Output = $output; Error = ''; TimedOut = $false }
        }
        return [pscustomobject]@{ Output = $null; Error = 'fixture diagnostic timeout'; TimedOut = $true }
    }
    function Write-DscStatus {
        param($Status, [switch]$NoStatus, [switch]$Warning, [switch]$Failure)
        $script:DiagnosticStatuses.Add([pscustomobject]@{ Status = $Status; NoStatus = [bool]$NoStatus; Failure = [bool]$Failure })
    }
    $coverageTimelinePath = Join-Path $tempRoot 'BoundedClientPackageTimeline.jsonl'
    $coverageTimelineState = @{ Disabled = $false }
    $writeCoverageSnapshot = $blocks.writeCoverageSnapshot
    $null = & $writeCoverageSnapshot -Trigger 'content-wait' -DistributionPoints @('LAB-DP.test') -IncludeNodeState $true
    $timeoutRecord = Get-Content -LiteralPath $coverageTimelinePath -Raw | ConvertFrom-Json
    if ($timeoutRecord.Classification -ne 'DiagnosticTimedOut' -or $timeoutRecord.DiagnosticStatus -ne 'TimedOut' -or
        $timeoutRecord.NodeStateIncluded -or $timeoutRecord.Errors -notcontains 'fixture diagnostic timeout' -or
        -not $coverageTimelineState.Disabled -or
        @($script:DiagnosticStatuses | Where-Object { $_.Failure -or -not $_.NoStatus }).Count -gt 0) {
        throw 'A diagnostic timeout did not persist explicit unknown state independently of workflow status.'
    }
    $null = & $writeCoverageSnapshot -Trigger 'content-wait' -DistributionPoints @('LAB-DP.test')
    if ($script:DiagnosticProbeCalls -ne 1) { throw 'A disabled diagnostic probe was repeated.' }
    $script:DiagnosticProbeSucceeds = $true
    $null = & $writeCoverageSnapshot -Trigger 'coverage-deadline' -DistributionPoints @('LAB-DP.test') -ForceWrite $true
    $boundedAnalysis = @(& $analyzerPath -Path $coverageTimelinePath)
    if ($coverageTimelineState.Disabled -or $script:DiagnosticProbeCalls -ne 2 -or $boundedAnalysis.Count -ne 2 -or
        $boundedAnalysis[0].Classification -ne 'DiagnosticTimedOut' -or
        $boundedAnalysis[0].Errors -notmatch 'fixture diagnostic timeout' -or $boundedAnalysis[1].Classification -ne 'Installed') {
        $details = $script:DiagnosticStatuses | ConvertTo-Json -Compress
        throw "Forced capture did not recover after timeout, or the analyzer lost explicit timeout evidence. Disabled=$($coverageTimelineState.Disabled); calls=$script:DiagnosticProbeCalls; classifications=$(@($boundedAnalysis.Classification) -join ','); statuses=$details"
    }

    $phaseSource = Get-Content -LiteralPath $phasePath -Raw
    foreach ($required in @("'periodic'", "'status-change'", "'phase-complete'", "'critical-failure'", 'AddMinutes(5)', 'TotalSeconds -ge 30', 'phase8SeenJobs')) {
        if ($phaseSource -notmatch [regex]::Escape($required)) {
            throw "Wait-Phase is missing required telemetry trigger $required."
        }
    }
    foreach ($provider in @('WHEA-Logger', 'storport', 'Hyper-V-StorageVSP', 'Resource-Exhaustion-Detector')) {
        if ($phaseSource -notmatch [regex]::Escape($provider)) {
            throw "Phase 8 host reliability capture is missing provider $provider."
        }
    }
    if ($phaseSource -match '(?s)\$phase8FingerprintParts\s*=.*?\$phase8History\.Activity') {
        throw 'Phase 8 state fingerprint includes the elapsed Activity string and will emit duplicate records.'
    }
    $boundarySource = Get-Content -LiteralPath $boundaryPath -Raw
    foreach ($required in @(
            "'replication-link-wait'",
            "'content-wait'",
            '"before-refresh-now:$dp"',
            '"after-refresh-now:$dp"',
            "'coverage-deadline'",
            'SchemaVersion = 2'
        )) {
        if ($boundarySource -notmatch [regex]::Escape($required)) {
            throw "Client-package coverage is missing required telemetry trigger $required."
        }
        if ($boundarySource -notmatch '(?s)\$_.State\s+-eq\s+0\s+-and\s+\$_.Server\s+-in\s+\$DistributionPoints') {
            throw 'Client-package Installed classification is not scoped to the requested DP set.'
        }
    }
    $scriptBlockSource = Get-Content -LiteralPath $scriptBlockPath -Raw
    if ($scriptBlockSource -notmatch 'ClientPackageTimelineContent' -or
        $scriptBlockSource -notmatch 'Pulled client-package timeline') {
        throw 'Phase 8 completion does not persist the guest client-package timeline on the host.'
    }
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'PASS -- Phase 8 host and client-package timelines are structured, persistent, and analyzable.'
