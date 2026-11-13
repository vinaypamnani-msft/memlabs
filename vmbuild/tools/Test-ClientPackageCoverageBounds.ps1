#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$boundaryPath = Join-Path $root 'DSC\phases\InstallBoundaryGroups.ps1'
$processPath = Join-Path $root 'DSC\phases\ProcessFunctions.ps1'
$functionsPath = Join-Path $root 'DSC\phases\ScriptFunctions.ps1'
. $processPath

function Import-TestFunction {
    param([string]$Path, [string]$Name)
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "$Path has parse errors: $($errors -join '; ')" }
    $definitions = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($definitions.Count -ne 1) { throw "Expected one $Name definition." }
    [scriptblock]::Create($definitions[0].Extent.Text)
}
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

foreach ($name in @(
        'Write-MemLabsClientPackageTimelineRecord', 'Invoke-MemLabsClientPackageDiagnosticProbe',
        'Get-MemLabsDpVmMetadataMap', 'Test-MemLabsLocalComputerName',
        'Set-MemLabsClientPackageProgress', 'Invoke-MemLabsClientPackageCoverage'
    )) {
    . (Import-TestFunction -Path $boundaryPath -Name $name)
}
$script:Statuses = [Collections.Generic.List[object]]::new()
function Write-DscStatus {
    param($Status, [switch]$Warning, [switch]$Failure)
    $script:Statuses.Add([pscustomobject]@{ Message = "$Status"; Warning = [bool]$Warning; Failure = [bool]$Failure })
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) "memlabs-coverage-bounds-$([guid]::NewGuid().ToString('N'))"
$null = New-Item -Path $testRoot -ItemType Directory
try {
    $progressPath = Join-Path $testRoot 'heartbeat.json'
    $script:Reports = [Collections.Generic.List[object]]::new()
    $heartbeatProbe = {
        param($ProgressFile, $ProgressId, $ProcessFunctions)
        . $ProcessFunctions
        foreach ($index in 1..4) {
            Write-MemLabsProcessProgress -Path $ProgressFile -Record @{
                Id = $ProgressId; Stage = 'query'; Message = "checkpoint $index"
                UpdatedAtUtc = [DateTime]::UtcNow.ToString('o')
                DeadlineUtc = [DateTime]::UtcNow.AddSeconds(20).ToString('o')
            }
            Start-Sleep -Seconds 1
        }
        return 'completed'
    }
    $active = Invoke-MemLabsBoundedPowerShell -ProbeScript $heartbeatProbe -Parameters @{
        ProgressFile = $progressPath; ProgressId = 'active'; ProcessFunctions = $processPath
    } -ProgressPath $progressPath -ProgressId 'active' -TimeoutSeconds 15 -StallTimeoutSeconds 3 `
        -ProgressIntervalSeconds 1 -OnProgress { param($Report); $script:Reports.Add($Report) }
    Assert-True (-not $active.Error -and $active.Output -eq 'completed' -and $script:Reports.Count -ge 2) `
        "Live progress or heartbeat handling failed: $($active.Error)"

    $script:Reports.Clear()
    $blocked = Invoke-MemLabsBoundedPowerShell -ProbeScript {
        param($ProgressFile, $ProcessFunctions)
        . $ProcessFunctions
        Write-MemLabsProcessProgress -Path $ProgressFile -Record @{
            Id = 'blocked'; Stage = 'SMS_DistributionPoint'; Message = 'Starting provider query'
            UpdatedAtUtc = [DateTime]::UtcNow.ToString('o')
            DeadlineUtc = [DateTime]::UtcNow.AddSeconds(60).ToString('o')
        }
        Start-Sleep -Seconds 30
    } -Parameters @{ ProgressFile = $progressPath; ProcessFunctions = $processPath } `
        -ProgressPath $progressPath -ProgressId 'blocked' -TimeoutSeconds 15 -StallTimeoutSeconds 2 `
        -ProgressIntervalSeconds 1 -OnProgress { param($Report); $script:Reports.Add($Report) }
    Assert-True ($blocked.TimedOut -and $blocked.Stalled -and $blocked.ElapsedSeconds -lt 8 -and
        $script:Reports.Count -ge 2 -and $blocked.Error -match 'no checkpoint' -and
        -not (Get-Process -Id $blocked.ProcessId -ErrorAction SilentlyContinue)) `
        "A blocked provider call was not bounded: $($blocked.Error)"

    $childMarker = Join-Path $testRoot 'descendant.json'
    $descendants = Invoke-MemLabsBoundedPowerShell -ProbeScript {
        param($Marker)
        $engineName = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
        $command = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes('Start-Sleep -Seconds 30'))
        $startInfo = New-Object Diagnostics.ProcessStartInfo
        $startInfo.FileName = Join-Path $PSHOME $engineName
        $startInfo.Arguments = "-NoProfile -NonInteractive -EncodedCommand $command"
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $child = [Diagnostics.Process]::Start($startInfo)
        @{ Id = $child.Id; StartedTicks = $child.StartTime.ToUniversalTime().Ticks } |
            ConvertTo-Json | Set-Content -LiteralPath $Marker
        $child.Dispose()
        Start-Sleep -Seconds 30
    } -Parameters @{ Marker = $childMarker } -TimeoutSeconds 3
    Assert-True ($descendants.TimedOut -and (Test-Path -LiteralPath $childMarker)) 'The descendant cancellation fixture did not run.'
    $childInfo = Get-Content -LiteralPath $childMarker -Raw | ConvertFrom-Json
    $exitDeadline = [DateTime]::UtcNow.AddSeconds(2)
    do {
        $childProcess = Get-Process -Id $childInfo.Id -ErrorAction SilentlyContinue
        if (-not $childProcess -or $childProcess.HasExited) {
            if ($childProcess) { $childProcess.Dispose() }
            $childProcess = $null
            break
        }
        $childProcess.Dispose()
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $exitDeadline)
    if ($childProcess) {
        $remainingChild = Get-Process -Id $childInfo.Id -ErrorAction SilentlyContinue
        if ($remainingChild -and -not $remainingChild.HasExited -and
            $remainingChild.StartTime.ToUniversalTime().Ticks -eq $childInfo.StartedTicks) {
            Stop-Process -Id $remainingChild.Id -Force
        }
        throw "The bounded worker left descendant $($childInfo.Id) running. Worker result: $($descendants.Error)"
    }

    $fixtureRoot = Join-Path $testRoot 'guest'
    $logPath = Join-Path $testRoot 'logs'
    $null = New-Item -Path $fixtureRoot, $logPath -ItemType Directory
    Copy-Item -LiteralPath $processPath -Destination (Join-Path $fixtureRoot 'ProcessFunctions.ps1')
    $writer = Import-TestFunction -Path $functionsPath -Name 'Write-DscStatus'
    $logger = Import-TestFunction -Path $functionsPath -Name 'Write-StatusLogEntry'
    $fixtureFunctions = @'
$global:StatusFile = Join-Path $LogPath 'DSC_Status.txt'
$global:StatusLog = Join-Path $LogPath 'InstallCMLog.log'
function Import-Module { param($Name, $ErrorAction) }
function Get-PSDrive { param($Name, $PSProvider, $ErrorAction); return @{ Root = 'fixture.test' } }
function Set-Location { param($Path) }
'@
    [IO.File]::WriteAllText((Join-Path $fixtureRoot 'ScriptFunctions.ps1'),
        $fixtureFunctions + [Environment]::NewLine + $writer.ToString() + [Environment]::NewLine + $logger.ToString())
    [IO.File]::WriteAllText((Join-Path $logPath 'ScriptWorkflow.expected.runid'), 'fixture-run')
    $variables = @{
        SiteCode = 'PRI'; LogPath = $logPath; configurationManagerModulePath = 'fixture'
        siteProviderHost = 'fixture.test'; clearStuckDistmgrWedge = 'return $false'
    }
    Invoke-MemLabsClientPackageCoverage -ScriptRoot $fixtureRoot -LogPath $logPath -Variables $variables -CoverageScript {
        Set-MemLabsClientPackageProgress -Stage 'coverage' -DeadlineUtc ([DateTime]::UtcNow.AddSeconds(2)) `
            -PackageId 'PRI00004' -RequiredDistributionPoints @('DP1.fixture.test') -Message 'Querying required coverage'
        Start-Sleep -Seconds 30
    }
    $state = Get-Content -LiteralPath (Join-Path $logPath 'ClientPackageCoverage.progress.json') -Raw | ConvertFrom-Json
    Assert-True ($state.Status -eq 'TimedOut' -and $state.Outcome -eq 'Unverified' -and
        $state.WorkflowRunId -eq 'fixture-run' -and $state.RequiredDistributionPoints -contains 'DP1.fixture.test') `
        'The production coverage watchdog did not preserve an explicit, run-scoped incomplete outcome.'
    Assert-True (@($script:Statuses | Where-Object Failure).Count -eq 0 -and
        @($script:Statuses | Where-Object { $_.Warning -and $_.Message -match 'Continuing Phase 8' }).Count -eq 1) `
        'Coverage timeout did not honor the warning-only Phase 8 policy.'
    $analysis = @(& (Join-Path $PSScriptRoot 'Analyze-Phase8Diagnostics.ps1') `
        -Path (Join-Path $logPath 'ClientPackageTimeline.jsonl'))
    Assert-True ($analysis.Count -eq 1 -and $analysis[0].Classification -eq 'CoverageTimedOut' -and
        $analysis[0].Errors -match 'wall-clock deadline') 'The analyzer lost coverage-watchdog timeout evidence.'

    $script:Statuses.Clear()
    Invoke-MemLabsClientPackageCoverage -ScriptRoot $fixtureRoot -LogPath $logPath -Variables $variables -CoverageScript {
        Set-MemLabsClientPackageProgress -Stage 'final-state' -Outcome 'Incomplete' -PackageId 'PRI00004'
        Write-DscStatus 'Fixture coverage is still pending'
    }
    $state = Get-Content -LiteralPath (Join-Path $logPath 'ClientPackageCoverage.progress.json') -Raw | ConvertFrom-Json
    Assert-True ($state.Status -eq 'Completed' -and $state.Outcome -eq 'Incomplete' -and
        @($script:Statuses | Where-Object Failure).Count -eq 0 -and
        @($script:Statuses | Where-Object Warning).Count -eq 1) 'Incomplete coverage was presented as success or failed Phase 8.'

    $script:Statuses.Clear()
    Invoke-MemLabsClientPackageCoverage -ScriptRoot $fixtureRoot -LogPath $logPath -Variables $variables -CoverageScript {
        throw 'synthetic provider failure'
    }
    Assert-True (@($script:Statuses | Where-Object { $_.Failure -and $_.Message -match 'synthetic provider failure' }).Count -eq 1) `
        'A non-timeout provider failure was hidden by warning-only timeout policy.'

    $tokens = $null
    $errors = $null
    $hostAst = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $root 'common\Common.ScriptBlocks.ps1'), [ref]$tokens, [ref]$errors)
    Assert-True ($errors.Count -eq 0) 'The host status monitor has parse errors.'
    $progressBranches = @($hostAst.FindAll({
                param($node)
                $node -is [Management.Automation.Language.IfStatementAst] -and
                $node.Clauses[0].Item1.Extent.Text -match '^\$workflowRunId -and' -and
                $node.Extent.Text.Contains('$coverage.WorkflowRunId')
            }, $true))
    Assert-True ($progressBranches.Count -eq 1) 'The RunId-scoped host coverage status branch was not found.'
    $formatStatus = [scriptblock]::Create(
        'param($workflowRunId, $statusText, $coveragePath)' + [Environment]::NewLine +
        $progressBranches[0].Extent.Text + [Environment]::NewLine + 'return $statusText')
    $displayPath = Join-Path $testRoot 'display.json'
    @{
        WorkflowRunId = 'current'; Status = 'Running'; Stage = 'coverage'
        UpdatedAtUtc = [DateTime]::UtcNow.ToString('o'); Message = 'Waiting for required DP1'
    } | ConvertTo-Json | Set-Content -LiteralPath $displayPath
    Assert-True ((& $formatStatus current 'Waiting for receipt' $displayPath) -match 'Client pkg coverage: stage=coverage') `
        'The host UI still hides live coverage progress behind the receipt wait.'
    Assert-True ((& $formatStatus stale 'Waiting for receipt' $displayPath) -eq 'Waiting for receipt') `
        'A previous workflow RunId masked current host status.'
    Assert-True ((& $formatStatus current 'JOBFAILURE: fixture' $displayPath) -eq 'JOBFAILURE: fixture') `
        'Progress display masked an explicit guest failure.'
    Set-Content -LiteralPath $displayPath -Value '{invalid'
    Assert-True ((& $formatStatus current 'Waiting for receipt' $displayPath) -match 'progress is unreadable') `
        'Malformed progress was silently treated as healthy.'

    $source = Get-Content -LiteralPath $boundaryPath -Raw
    foreach ($required in @("'resolve-DPs'", "'replication-links'", "'coverage'", "'final-state'", "'legacy-diagnostics'", "'discovery-refresh'")) {
        Assert-True ($source.Contains($required)) "Coverage has no enforced stage boundary $required."
    }
    Assert-True ($source -match '-StallTimeoutSeconds 300 -ProgressIntervalSeconds 30' -and
        $source -match '-TimeoutSeconds 7200') 'Coverage lost its independent progress, stall limit, or absolute safety cap.'
    Assert-True ($source -notmatch "SiteCode=\$\(\`$tgt.SiteCode\) SourceVersion=") 'Legacy targeting diagnostics still request an unsupported package version.'
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction Stop
}

Write-Host 'PASS -- coverage has hard deadlines, independent progress, owned-process cleanup, and warning-only timeouts.'
