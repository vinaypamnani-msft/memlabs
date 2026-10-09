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

. (Import-TestFunction -Path $phasePath -Name 'Write-Phase8DiagnosticSnapshot')
. (Import-TestFunction -Path $boundaryPath -Name 'Write-MemLabsClientPackageTimelineRecord')

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
                    Server = 'CURRENT-DP.test'; SourceVersion = 3
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
        $packageAnalysis.Targeting -notmatch 'CURRENT-DP\.test=source:3/refresh:True') {
        throw "Phase 8 analyzer did not support both legacy and corrected targeting records: $($packageAnalysis.Targeting)"
    }

    $phaseSource = Get-Content -LiteralPath $phasePath -Raw
    foreach ($required in @("'periodic'", "'status-change'", "'phase-complete'", 'AddMinutes(5)', 'TotalSeconds -ge 30', 'phase8SeenJobs')) {
        if ($phaseSource -notmatch [regex]::Escape($required)) {
            throw "Wait-Phase is missing required telemetry trigger $required."
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
