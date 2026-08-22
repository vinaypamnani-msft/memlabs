# ScriptFunctions.ps1
$global:StatusFile = "C:\staging\DSC\DSC_Status.txt"
$global:StatusLog = "C:\staging\DSC\InstallCMLog.log"


function Test-TcpPortFast {
    # Hard-timeout TCP probe using TcpClient + WaitHandle. Never use Test-NetConnection:
    # it can hang well past its own timeouts on DNS reverse lookups and ICMP fallbacks,
    # and in-guest that stalls a DSC phase with no way to bound it.
    # In-guest twin of Test-TcpPort in Common.HyperV.ps1, which the guest cannot reach.
    param(
        [Parameter(Mandatory)] [string]$ComputerName,
        [Parameter(Mandatory)] [int]$Port,
        [int]$TimeoutMs = 3000,
        [int]$Retries = 3,
        [int]$RetryDelayMs = 1000
    )
    for ($attempt = 1; $attempt -le $Retries; $attempt++) {
        $client = $null
        try {
            $client = New-Object System.Net.Sockets.TcpClient
            $iar = $client.BeginConnect($ComputerName, $Port, $null, $null)
            if ($iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) {
                try {
                    $client.EndConnect($iar)
                    if ($client.Connected) { return $true }
                }
                catch { }
            }
        }
        catch { }
        finally {
            if ($client) { try { $client.Close() } catch { } }
        }
        if ($attempt -lt $Retries) { Start-Sleep -Milliseconds $RetryDelayMs }
    }
    return $false
}

function Write-StatusLogEntry {
    # Pipeline-friendly writer that emits CMTrace-format entries to $global:StatusLog.
    # Drop-in replacement for `Write-StatusLogEntry` so the log can
    # be opened cleanly in CMTrace / OneTrace / the memlabs log viewer.
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline = $true)]
        [object]$InputObject,
        [string]$Component,
        [int]$Type = 1,   # 1=Info, 2=Warning, 3=Error
        [switch]$AllowBlank  # emit blank CMTrace entries instead of filtering them out
    )
    begin {
        if (-not $Component) {
            try {
                $cs = Get-PSCallStack
                $cmd = $cs[1].Command
                if ($cmd -and $cmd -like '*.ps1') { $cmd = $cmd -replace '\.ps1$', '' }
                if (-not $cmd -or $cmd -eq '<ScriptBlock>') { $cmd = '<Script>' }
                $Component = $cmd
            }
            catch { $Component = '<Script>' }
        }
        $date = Get-Date -Format 'MM-dd-yyyy'
        # Bias = minutes to ADD to this stamp to reach UTC (ConfigMgr's own convention).
        # This log is written in the GUEST's timezone, which need not match the host's.
        # Offset comes from the INSTANT: GetUtcOffset(localDateTime) returns the STANDARD
        # offset for an ambiguous wall clock, i.e. 60 min wrong through a DST fall-back.
        # Guarded -- this runs in begin{}, so an escape would take out every status line
        # this guest writes. Bias is optional, the log is not.
        $tzBias = ''
        try {
            $biasMin = [int](-[DateTimeOffset]::Now.Offset.TotalMinutes)
            $tzBias = $(if ($biasMin -ge 0) { "+$biasMin" } else { "$biasMin" })
        }
        catch { }
        $buffer = New-Object System.Collections.Generic.List[string]
    }
    process {
        if ($null -eq $InputObject) {
            if (-not $AllowBlank) { return }
            $text = ''
        }
        else {
            $text = if ($InputObject -is [string]) { $InputObject } else { ($InputObject | Out-String) }
            $text = $text.TrimEnd("`r", "`n")
        }
        if ([string]::IsNullOrWhiteSpace($text)) {
            if (-not $AllowBlank) { return }
            $time = (Get-Date -Format 'HH:mm:ss.fff') + $tzBias
            $tid = [System.Threading.Thread]::CurrentThread.ManagedThreadId
            $buffer.Add("<![LOG[]LOG]!><time=`"$time`" date=`"$date`" component=`"$Component`" context=`"`" type=`"$Type`" thread=`"$tid`" file=`"`">")
            return
        }
        $tid = [System.Threading.Thread]::CurrentThread.ManagedThreadId
        foreach ($line in ($text -split "`r?`n")) {
            if ([string]::IsNullOrWhiteSpace($line)) {
                if ($AllowBlank) {
                    $time = (Get-Date -Format 'HH:mm:ss.fff') + $tzBias
                    $buffer.Add("<![LOG[]LOG]!><time=`"$time`" date=`"$date`" component=`"$Component`" context=`"`" type=`"$Type`" thread=`"$tid`" file=`"`">")
                }
                continue
            }
            $clean = [System.Text.RegularExpressions.Regex]::Replace($line, '[^\x09\x20-\x7E]', '')
            $clean = [System.Text.RegularExpressions.Regex]::Replace($clean, '\?{2,}', '')
            $clean = $clean.TrimEnd()
            if ([string]::IsNullOrWhiteSpace($clean)) {
                if ($AllowBlank) {
                    $time = (Get-Date -Format 'HH:mm:ss.fff') + $tzBias
                    $buffer.Add("<![LOG[]LOG]!><time=`"$time`" date=`"$date`" component=`"$Component`" context=`"`" type=`"$Type`" thread=`"$tid`" file=`"`">")
                }
                continue
            }
            $time = (Get-Date -Format 'HH:mm:ss.fff') + $tzBias
            $buffer.Add("<![LOG[$clean]LOG]!><time=`"$time`" date=`"$date`" component=`"$Component`" context=`"`" type=`"$Type`" thread=`"$tid`" file=`"`">")
        }
    }
    end {
        if ($buffer.Count -gt 0) {
            try {
                Add-Content -Path $global:StatusLog -Value $buffer -Encoding utf8 -ErrorAction Stop
            }
            catch {
                # Best-effort: retry once. Concurrent writers from parallel DSC scripts
                # can briefly collide; one retry is plenty in practice.
                Start-Sleep -Milliseconds 50
                try { Add-Content -Path $global:StatusLog -Value $buffer -Encoding utf8 -ErrorAction SilentlyContinue } catch { }
            }
        }
    }
}

function Get-CmSslStateNote {
    # Short "  [ssl=63]" tag for the Invoke-DotSource boundary lines, so a revert of
    # IISSSLState can be attributed to the script whose window it happened in.
    # Reads SCM's registry mirror (sitecomp.cpp CSiteComponentManager::WriteToRegistry),
    # NOT the site control file: this runs in the LOGGING path under ScriptWorkflow's
    # top-level trap, and an SMS-provider WMI query has no timeout and can hang there.
    # Cost of that choice: the value lags the SCF by SCM's detection interval.
    $note = ''
    try {
        $v = Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Microsoft\SMS\Components\SMS_SITE_COMPONENT_MANAGER' -Name 'IISSSLState' -ErrorAction Stop
        if ($null -ne $v) { $note = "  [ssl=$v]" }
    }
    catch { $note = '' }
    return $note
}

function Invoke-DotSource {
    # Wrapper for dot-sourcing scripts with error handling.
    # Catches parse errors, execution policy blocks, and other failures
    # that would otherwise be silently swallowed by the caller.
    param(
        [Parameter(Mandatory)]
        [string]$Script,
        [object[]]$Arguments,
        # By default a runtime exception in the dot-sourced script is logged as a
        # WARNING and swallowed (see the catch note below). Set -Rethrow when the
        # CALLER owns retry/recovery for that script (e.g. the perfloading retry
        # loop in ScriptWorkFlow.ps1): the exception is still logged, then re-thrown
        # so the caller's try/catch can act on it.
        [switch]$Rethrow
    )

    # HARDENING: `. $Script` runs the script in THIS function's scope, so any
    # variable the dot-sourced script assigns clobbers a like-named local here.
    # That is not theoretical: perfloading.ps1 sets $ScriptName in its CM-script
    # import loop, which used to overwrite our $scriptName and made the END /
    # exception log line show the wrong name (e.g. "MEMLABS-CheckFilesToBe-
    # CleanedUp" instead of "Perfloading.ps1") -- and a script that happened to
    # assign $Rethrow or $sw could flip the rethrow decision or break the
    # finally. Capture everything the catch / finally / rethrow decision need
    # into collision-proof $__ids* locals up front; a dot-sourced script won't
    # define those. ($Script / $Arguments are consumed by the dot-source call
    # itself before the script body runs, so they can't be clobbered in flight.)
    $__idsScriptName = Split-Path $Script -Leaf
    $__idsRethrow = [bool]$Rethrow

    # Pre-flight: verify the file exists
    if (-not (Test-Path $Script)) {
        Write-DscStatus "FAILED to dot-source $__idsScriptName -- file not found: $Script" -Failure
        return
    }

    # Pre-flight: verify the file parses without errors
    $__idsTokens = $null
    $__idsParseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($Script, [ref]$__idsTokens, [ref]$__idsParseErrors)
    if ($__idsParseErrors -and $__idsParseErrors.Count -gt 0) {
        $__idsFirstErr = $__idsParseErrors[0]
        Write-DscStatus "FAILED to dot-source $__idsScriptName -- parse error at line $($__idsFirstErr.Extent.StartLineNumber): $($__idsFirstErr.Message)" -Failure
        return
    }

    # Run with error handling.
    # We use the CALL operator (&), not dot-source (.), so the script runs in its
    # OWN child scope: it can still READ ambient state up the scope chain
    # ($deployConfig, $SiteCode, Write-DscStatus, etc.) but its variable WRITES
    # are isolated and cannot clobber this wrapper's bookkeeping. Audited safe:
    # no phase script communicates via $script: scope (which is the only construct
    # that behaves differently under & vs .), and none relies on writing a plain
    # variable back to the caller (the function boundary already blocked that).
    # The collision-proof $__ids* locals below are now belt-and-suspenders.
    # The catch logs runtime errors from within the script for diagnostics but
    # does NOT mark them as -Failure (unless the caller passed -Rethrow). The
    # pre-flight checks above catch the real infrastructure failures (missing
    # file, parse errors). Runtime errors from CM cmdlets are otherwise transient
    # and the scripts have their own retry logic; marking them as JOBFAILURE
    # would abort the phase prematurely.
    $__idsStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    Write-DscStatus "[Invoke-DotSource] START $__idsScriptName$(Get-CmSslStateNote)" -NoStatus
    try {
        & $Script @Arguments
    }
    catch {
        Write-DscStatus "WARNING: exception in ${__idsScriptName}: $_"
        if ($__idsRethrow) { throw }
    }
    finally {
        $__idsStopwatch.Stop()
        $__idsElapsed = $__idsStopwatch.Elapsed.ToString('hh\:mm\:ss')
        Write-DscStatus "[Invoke-DotSource] END   $__idsScriptName  ($__idsElapsed elapsed)$(Get-CmSslStateNote)" -NoStatus
    }
}

function Write-CmSslStateForensics {
    # Called when IISSSLState is found reverted. Names WHO rewrote the site control
    # file. Everything lands via Write-DscStatus so it reaches the HOST jsonl and
    # survives lab deletion. Read-only; never throws.
    param([string]$Tag = '[SSLState]', [int]$TailLines = 4000)

    try {
        $sc = ''
        try { $sc = Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Microsoft\SMS\Identification' -Name 'Site Code' -ErrorAction Stop } catch { }

        # Full site-control picture first: which components carry which value.
        if ($sc) {
            try {
                $rows = @(Get-WmiObject -Namespace "root\SMS\site_$sc" -Class SMS_SCI_Component -Filter "FileType=2 AND SiteCode='$sc'" -ErrorAction Stop)
                $withSsl = @($rows | Where-Object { $_.Props | Where-Object { $_.PropertyName -eq 'IISSSLState' } })
                Write-DscStatus "$Tag $($withSsl.Count) of $($rows.Count) site-control component(s) carry IISSSLState:"
                foreach ($r in $withSsl) {
                    $v = $r.Props | Where-Object { $_.PropertyName -eq 'IISSSLState' } | Select-Object -First 1
                    Write-DscStatus "$Tag   $($r.ComponentName) [$($r.ItemName)] IISSSLState=$($v.Value)"
                }
            }
            catch {
                Write-DscStatus "$Tag site control read FAILED ($($_.Exception.Message)) -- the component values are UNKNOWN, not unchanged."
            }
        }
        else {
            Write-DscStatus "$Tag no 'Site Code' under HKLM:\SOFTWARE\Microsoft\SMS\Identification -- cannot read the site control file."
        }

        $logDir = ''
        foreach ($k in @('HKLM:\SOFTWARE\Microsoft\SMS\Setup', 'HKLM:\SOFTWARE\Microsoft\SMS\Identification')) {
            $d = $null
            try { $d = (Get-ItemProperty -Path $k -Name 'Installation Directory' -ErrorAction Stop).'Installation Directory' } catch { }
            if ($d) { $logDir = Join-Path $d 'Logs'; break }
        }
        if (-not $logDir -or -not (Test-Path $logDir)) {
            Write-DscStatus "$Tag ConfigMgr log directory not found -- no log evidence collected."
            return
        }

        # SMSProv.log is the only log that names the CALLER of a site-control write.
        # sitecomp.cpp logs the literal string 'Detected change in SSLState' when SCM
        # notices the new value, which brackets the write from the consumer side.
        $probes = @(
            @{ Log = 'SMSProv.log'; Pattern = 'IISSSLState'; Keep = 25 },
            @{ Log = 'sitecomp.log'; Pattern = 'SSLState|site control file'; Keep = 20 },
            @{ Log = 'hman.log'; Pattern = 'site control|SSLState'; Keep = 15 }
        )
        foreach ($p in $probes) {
            $found = $false
            foreach ($name in @($p.Log, ($p.Log -replace '\.log$', '.lo_'))) {
                $path = Join-Path $logDir $name
                if (-not (Test-Path $path)) { continue }
                $found = $true
                try {
                    $tail = @(Get-Content -LiteralPath $path -Tail $TailLines -ErrorAction Stop)
                    $hits = @($tail | Select-String -Pattern $p.Pattern)
                    if ($hits.Count -eq 0) {
                        Write-DscStatus "$Tag $name : 0 of the last $($tail.Count) line(s) match '$($p.Pattern)'. That is a measured ABSENCE over that window only."
                        continue
                    }
                    Write-DscStatus "$Tag $name : $($hits.Count) match(es) in the last $($tail.Count) line(s); newest $([Math]::Min($hits.Count, $p.Keep)):"
                    foreach ($h in ($hits | Select-Object -Last $p.Keep)) {
                        $line = ($h.Line -replace '^<!\[LOG\[', '' -replace '\]LOG\]!>', ' @ ')
                        $line = ($line -replace '\s+', ' ').Trim()
                        if ($line.Length -gt 400) { $line = $line.Substring(0, 400) + '...' }
                        Write-DscStatus "$Tag   $line"
                    }
                }
                catch {
                    Write-DscStatus "$Tag $name : read FAILED ($($_.Exception.Message)) -- UNKNOWN, not absent."
                }
            }
            if (-not $found) { Write-DscStatus "$Tag $($p.Log) : NOT FOUND in $logDir -- this component may not run on this server." }
        }
    }
    catch {
        Write-DscStatus "$Tag forensics collection failed: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# ScriptWorkflow.json concurrency helpers
# ---------------------------------------------------------------------------
# Phase 8 can run a long-poller step (e.g. the secondary-site install monitor,
# or InstallPassiveSiteServer) in a BACKGROUND JOB so it overlaps the rest of
# the workflow instead of blocking it. Start-Job spawns a child process; both
# it and the main ScriptWorkflow process update DIFFERENT properties of the
# SAME ScriptWorkflow.json with a read-whole / modify / write-whole cycle.
# Without serialization one writer's update silently clobbers the other's
# (last-writer-wins on the entire file), so e.g. the background job stamping
# InstallPassive=Completed could wipe out the main thread's InstallSecondary
# progress, or vice-versa. A machine-wide named mutex makes each update atomic.
#
# PS5.1-safe (no ternary / null-conditional). Mirrors the Global\MemLabs_DHCP
# pattern in Common.ps1, but self-contained because this file is dot-sourced
# in-guest where Common.ps1 isn't present. The mutex is per-machine and each
# site server VM owns exactly one ScriptWorkflow.json, so a single global name
# is correctly scoped.
function Invoke-WithScriptWorkflowJsonMutex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,
        [object[]]$ArgumentList,
        [int]$TimeoutSeconds = 60
    )

    $mutexName = 'Global\MemLabs_ScriptWorkflowJson'
    $mutex = $null
    $owned = $false
    try {
        try { $mutex = New-Object System.Threading.Mutex($false, $mutexName) }
        catch { $mutex = $null }

        if ($mutex) {
            try { $owned = $mutex.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds)) }
            catch [System.Threading.AbandonedMutexException] {
                # A prior holder died without releasing; ownership transfers to
                # us and the wait is considered satisfied.
                $owned = $true
            }
            catch { $owned = $false }
        }

        # Run the update whether or not the mutex was acquired -- a failed/timed
        # out acquisition must never deadlock the deploy; worst case is the
        # (rare) unsynchronized write the mutex was meant to prevent.
        return (& $ScriptBlock @ArgumentList)
    }
    finally {
        if ($mutex) {
            if ($owned) { try { [void]$mutex.ReleaseMutex() } catch { } }
            try { $mutex.Dispose() } catch { }
        }
    }
}

# Atomically update one step's fields in ScriptWorkflow.json under the mutex.
# This is the safe replacement for the scattered
#   $c = Get-Content $ConfigurationFile | ConvertFrom-Json
#   $c.<Step>.Status = '...'; $c | ConvertTo-Json | Out-File $ConfigurationFile
# read-modify-write blocks. Returns the refreshed configuration object so the
# caller can keep using $Configuration with no stale-state surprises.
function Set-ScriptWorkflowStep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigurationFile,
        [Parameter(Mandatory)]
        [string]$Step,
        [string]$Status,
        [switch]$StampStartTime,
        [switch]$StampEndTime
    )

    $now = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $hasStatus = $PSBoundParameters.ContainsKey('Status')

    return (Invoke-WithScriptWorkflowJsonMutex -ArgumentList $ConfigurationFile, $Step, $Status, $hasStatus, ([bool]$StampStartTime), ([bool]$StampEndTime), $now -ScriptBlock {
            param($file, $step, $status, $hasStatus, $stampStart, $stampEnd, $now)

            $cfg = Get-Content -Path $file -Raw | ConvertFrom-Json
            if (-not $cfg.$step) {
                $cfg | Add-Member -MemberType NoteProperty -Name $step -Value ([pscustomobject]@{ Status = 'NotStart'; StartTime = ''; EndTime = '' }) -Force
            }
            if ($hasStatus) { $cfg.$step.Status = $status }
            if ($stampStart) { $cfg.$step.StartTime = $now }
            if ($stampEnd) { $cfg.$step.EndTime = $now }
            $cfg | ConvertTo-Json | Out-File -FilePath $file -Force
            return $cfg
        })
}

# Launch InstallPassiveSiteServer.ps1 in a BACKGROUND JOB so the passive-site
# install overlaps the rest of the site server's single workflow thread -- the
# secondary-site install when there is one, otherwise InstallRoles /
# ConfigureMPReplica / ConfigureCMProxy / InstallBoundaryGroups. Measured on a
# child primary: secondary ~1h08 + passive ~56m ran strictly back-to-back, so the
# passive was pure serial tail on the Phase 8 critical path; overlapping removes
# ~the shorter one. Same shape without a secondary: 2026-08-22 CS6-PS1SITE ran
# InstallBoundaryGroups 864s and then passive 971s back-to-back.
#
# Runspace isolation is what makes this safe: the job's Set-CMSiteProvider imports
# its OWN ConfigurationManager module + CMSite PSDrive (scope = the JOB's global),
# so it never touches the main thread's CM drive. The job runs the passive script
# with -SkipStatusFileUpdate, so it NEVER writes ScriptWorkflow.json -- the main
# thread owns the InstallPassive status (Running stamped here before launch;
# Completed stamped after the join, gated on the role actually being present).
# That leaves the main thread as the SOLE writer of the file for the whole overlap
# window, so there is no concurrent-writer race with InstallRoles / BoundaryGroups.
# Dot-sources ScriptFunctions.ps1 for Write-DscStatus / CM helpers, matching the
# existing InstallProvider background-job pattern. Returns the job, or $null when
# the passive is already installed (caller falls back to the inline path).
function Start-ParallelPassiveJob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ConfigFilePath,
        [Parameter(Mandatory)][string]$LogPath,
        [Parameter(Mandatory)][string]$ScriptRoot,
        [Parameter(Mandatory)][string]$ConfigurationFile
    )

    # Already installed (re-run / -StartPhase)? Don't launch a job; let the caller
    # fall through to the inline path which logs the skip.
    try {
        $cfg = Get-Content -Path $ConfigurationFile -Raw | ConvertFrom-Json
        if ($cfg.InstallPassive -and $cfg.InstallPassive.Status -eq 'Completed') {
            return $null
        }
    }
    catch { }

    # Stamp Running now (single-threaded, before the overlapped work starts).
    $null = Set-ScriptWorkflowStep -ConfigurationFile $ConfigurationFile -Step 'InstallPassive' -Status 'Running' -StampStartTime

    Write-DscStatus "Parallel passive: launching InstallPassiveSiteServer.ps1 in a background job to overlap the rest of the Phase 8 workflow."
    return Start-Job -Name "InstallPassive" -ScriptBlock {
        param($jobConfigFilePath, $jobLogPath, $jobScriptRoot)
        . (Join-Path -Path $jobScriptRoot -ChildPath "ScriptFunctions.ps1")
        Set-Location $jobLogPath
        & (Join-Path -Path $jobScriptRoot -ChildPath "InstallPassiveSiteServer.ps1") -ConfigFilePath $jobConfigFilePath -LogPath $jobLogPath -SkipStatusFileUpdate
    } -ArgumentList $ConfigFilePath, $LogPath, $ScriptRoot
}

function Write-DscStatusSetup {
    $StatusPrefix = "Setting up ConfigMgr. See ConfigMgrSetup.log"
    $StatusPrefix | Out-File $global:StatusFile -Force
    start-sleep -seconds 5
    $StatusPrefix | Write-StatusLogEntry -Component 'Write-DscStatusSetup'
}

function Write-DscStatus {
    param($status, [switch]$NoLog, [switch]$NoStatus, [int]$RetrySeconds, [switch]$Failure, [string]$MachineName)

    $RemoteStatusFile = $null
    if ($MachineName -and ($MachineName -ne $Env:ComputerName)) {
        $RemoteStatusFile = "FileSystem::\\$($MachineName)\c$\staging\DSC\DSC_Status.txt"
    }

    if ($RetrySeconds) {
        $status = "$status; checking again in $RetrySeconds seconds"
    }

    if ($Failure.IsPresent) {
        # Add prefix that host job can use to acknowledge failure
        $status = "JOBFAILURE: $status"
    }

    if (-not $NoStatus.IsPresent) {
        $StatusPrefix = "Setting up ConfigMgr."
        try {
            if ($RemoteStatusFile) {
                $contents = Get-Content $RemoteStatusFile
                if ($contents -and $contents.EndsWith("Complete!")) {
                    #Remote Contents end with Complete!.  Write to local file to prevent overwriting this event.
                    "$StatusPrefix Status: $status" | Out-File $global:StatusFile -Force
                }
                else {
                    #Remote Contents Are fine to overwrite
                    "$StatusPrefix [$($Env:ComputerName)]: $status" | Out-File -FilePath $RemoteStatusFile -Force
                }
            }
            else {
                #Write Status Locally, since RemoteStatusFile was not set.
                "$StatusPrefix Status: $status" | Out-File $global:StatusFile -Force
            }

        }
        catch {
            if ($RemoteStatusFile) {
                #If we are writing remote, and we had an exception.. Log the Status Locally
                "Exception: $_ $StatusPrefix Status: $status" | Out-File $global:StatusFile -Force
            }
        }
    }

    if (-not $NoLog.IsPresent) {
        $logType = if ($Failure.IsPresent) { 3 } else { 1 }
        $status | Write-StatusLogEntry -Component 'Write-DscStatus' -Type $logType
    }

    write-host $Status
    if ($Failure.IsPresent) {
        # Add a sleep so host VM has had time to poll for this entry
        Start-Sleep -Seconds 10
    }
}

function Invoke-CMSetupPrereqDownload {
    # Runs Setupdl.exe (/NOUI) to populate the ConfigMgr prerequisite redist
    # folder. Idempotent: setupdl only (re)downloads missing files and we
    # require two consecutive "Setup downloader ... FINISHED" passes before
    # declaring success.
    #
    # Single-sourced so the real Phase 8 InstallAndUpdateSCCM path AND the
    # Phase 3 "ScriptWorkflow Download" pre-warm (ScriptWorkflow.ps1
    # -DownloadOnly) run the EXACT same robust loop: per-attempt 30-min hard
    # cap, 5-min log-stall early-kill, 90s fast-kill on a known-bad wedge
    # marker, and straggler-process cleanup.
    #
    # Returns $true on success, $false after $MaxTries failed attempts. The
    # caller owns any state-file / status bookkeeping on failure.
    param(
        [Parameter(Mandatory)] [string] $CMSetupDL,
        [Parameter(Mandatory)] [string] $CMRedist,
        [Parameter(Mandatory)] [string] $CMLog,
        [int] $MaxTries = 20
    )

    $success = 0
    $fail = 0
    $redistPurged = 0

    # --- Single-instance guard -------------------------------------------------
    # Only ONE setupdl download may run against $CMRedist at a time. Two setupdl.exe
    # processes writing the same redist folder corrupt each other's partial files --
    # a source of the deterministic "Manifest verification failed" wedge. A system
    # mutex serializes callers (Phase 3 pre-warm vs Phase 8 vs a DSC re-apply); we
    # also kill any stray setupdl.exe immediately before each launch below.
    $setupdlMutex = $null; $haveSetupdlMutex = $false
    try { $setupdlMutex = New-Object System.Threading.Mutex($false, 'Global\MemLabs_CMSetupPrereqDownload') } catch { $setupdlMutex = $null }
    if ($setupdlMutex) {
        try { $haveSetupdlMutex = $setupdlMutex.WaitOne([TimeSpan]::FromMinutes(90)) }
        catch [System.Threading.AbandonedMutexException] { $haveSetupdlMutex = $true }  # prior holder died; we own it now
        if (-not $haveSetupdlMutex) { Write-DscStatus "CM pre-req download: could not acquire the setupdl lock within 90 min; proceeding best-effort." }
    }

    try {

    # Per-attempt timeout for setupdl.exe. Historically we called
    # Start-Process -Wait with no cap; if setupdl wedged on a single CDN
    # fetch we'd hang for hours with no progress in the DSC status stream.
    # Now we cap each attempt at $setupDlTimeoutSec, surface the tail of
    # ConfigMgrSetup.log every $setupDlPollSec while it runs, and kill+retry
    # if the cap is hit.
    $setupDlTimeoutSec = 1800   # 30 min hard cap per attempt
    $setupDlStallSec = 300      # kill early if log hasn't advanced for 5 min
    $setupDlFastKillSec = 90    # kill in 90s if log is parked on a known-bad marker
    $setupDlPollSec = 30        # status cadence while running
    $lastReportedTail = ''

    # Log lines that immediately precede a known setupdl hang. When the log
    # is parked on one of these AND stops advancing, we don't need to wait
    # the full $setupDlStallSec -- kill quickly and let the retry path
    # re-launch. Pattern is matched case-insensitively as a substring of the
    # latest log line.
    $setupDlBadMarkers = @(
        # MSODBCSQL18 download wedge (observed on CS2-CS1SITE 05/25).
        # setupdl probes for the driver, finds it missing ("Error = 2"),
        # then hangs on the Microsoft CDN fetch.
        'MSODBCSQL18'
    )

    # We require 2 success entries in a row
    while ($success -le 1) {

        # Single-instance: kill any stray setupdl.exe (a leftover pre-warm, a prior
        # killed attempt, or a racing caller) so OURS is the only one writing the
        # redist folder / setup log this pass.
        Get-Process -Name 'setupdl' -ErrorAction SilentlyContinue | ForEach-Object { try { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue } catch { } }

        # Remember the setup-log size before this attempt so the failure handler can
        # inspect ONLY the lines this attempt writes (offset-based slice), and a
        # stale failure line from an earlier attempt can't re-trigger a purge.
        $logPosBefore = 0
        try { if (Test-Path $CMLog) { $logPosBefore = (Get-Item $CMLog -ErrorAction SilentlyContinue).Length } } catch { }

        # Start Setupdl.exe asynchronously so we can poll its log for progress
        # and enforce a per-attempt timeout.
        $dlProc = Start-Process -Filepath ($CMSetupDL) -ArgumentList ('/NOUI ' + $CMRedist) -PassThru
        $dlStart = Get-Date
        $lastLogAdvanceAt = Get-Date
        $dlTimedOut = $false
        $dlStalled = $false
        while (-not $dlProc.HasExited) {
            Start-Sleep -Seconds $setupDlPollSec
            $elapsedSec = [int]((Get-Date) - $dlStart).TotalSeconds
            $stalledSec = [int]((Get-Date) - $lastLogAdvanceAt).TotalSeconds

            # Tail the setup log and surface the latest activity so the
            # operator can see whether setupdl is making progress or stuck on
            # a specific file.
            $tail = $null
            try { $tail = Get-Content -Path $CMLog -Tail 1 -ErrorAction SilentlyContinue } catch { }
            if ($tail -and $tail -ne $lastReportedTail) {
                $lastReportedTail = $tail
                $lastLogAdvanceAt = Get-Date
                $stalledSec = 0
                Write-DscStatus ("Pre-Req download in progress ({0}s elapsed): {1}" -f $elapsedSec, $tail.Trim())
            }
            elseif ($tail) {
                Write-DscStatus ("Pre-Req download still running ({0}s elapsed, no new log activity for {1}s): {2}" -f $elapsedSec, $stalledSec, $tail.Trim())
            }
            else {
                Write-DscStatus ("Pre-Req download still running ({0}s elapsed; setup log not yet readable)" -f $elapsedSec)
            }

            # Early-kill: if the setup log has been completely silent for
            # $setupDlStallSec, setupdl is wedged on a single fetch (CDN
            # stall, TLS hang, etc.). Kill now rather than waiting the full
            # 30-min hard cap; the outer retry will relaunch and setupdl is
            # idempotent (only re-downloads missing files). Faster-kill: if
            # the latest log line matches a known-bad wedge marker (e.g.
            # MSODBCSQL18 download), use the shorter $setupDlFastKillSec
            # threshold so we recover in ~90s instead of 5 min.
            $matchedBadMarker = $null
            if ($tail) {
                foreach ($marker in $setupDlBadMarkers) {
                    if ($tail -match [Regex]::Escape($marker)) { $matchedBadMarker = $marker; break }
                }
            }
            $effectiveStallLimit = if ($matchedBadMarker) { $setupDlFastKillSec } else { $setupDlStallSec }

            if ($stalledSec -ge $effectiveStallLimit) {
                $dlStalled = $true
                if ($matchedBadMarker) {
                    Write-DscStatus ("Pre-Req download parked on known-bad marker '{0}' for {1}s (fast-kill threshold {2}s); killing setupdl.exe (PID {3}) and retrying" -f $matchedBadMarker, $stalledSec, $effectiveStallLimit, $dlProc.Id)
                }
                else {
                    Write-DscStatus ("Pre-Req download log stalled for {0}s (threshold {1}s); killing setupdl.exe (PID {2}) and retrying" -f $stalledSec, $effectiveStallLimit, $dlProc.Id)
                }
                try { Stop-Process -Id $dlProc.Id -Force -ErrorAction SilentlyContinue } catch { }
                Get-Process -Name 'setupdl' -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $dlProc.Id } | ForEach-Object {
                    try { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue } catch { }
                }
                break
            }

            if ($elapsedSec -ge $setupDlTimeoutSec) {
                $dlTimedOut = $true
                Write-DscStatus ("Pre-Req download exceeded {0}s; killing setupdl.exe (PID {1}) and retrying" -f $setupDlTimeoutSec, $dlProc.Id)
                try { Stop-Process -Id $dlProc.Id -Force -ErrorAction SilentlyContinue } catch { }
                # Also kill any straggler setupdl/Setupdl children spawned by the bootstrap copy
                Get-Process -Name 'setupdl' -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $dlProc.Id } | ForEach-Object {
                    try { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue } catch { }
                }
                break
            }
        }

        # Just to make sure the log is flushed.
        start-sleep -seconds 5

        # Get the last line of the log. Assumption: No other components are writing to the log at this time.
        $LogLine = Get-Content -Path $CMLog -Tail 1

        if ($dlStalled) {
            $LogLine = "STALLED: setupdl log idle for $setupDlStallSec seconds. Last log line: $LogLine"
        }
        elseif ($dlTimedOut) {
            # Treat as a failed attempt and let the retry/fail counter logic below handle it.
            $LogLine = "TIMEOUT: setupdl exceeded $setupDlTimeoutSec seconds. Last log line: $LogLine"
        }

        # Check for success indicator.
        if (-not $dlTimedOut -and -not $dlStalled -and $LogLine -and $LogLine.Contains("INFO: Setup downloader") -and $LogLine.Contains("FINISHED")) {
            $success++
            Write-DscStatus "Pre-Req downloading complete Success Count $success out of 2."
        }
        else {
            # If we didn't find it, increment fail count, and bail after $MaxTries fails
            Clear-DnsClientCache -ErrorAction SilentlyContinue
            $success = 0
            $fail++

            # DETERMINISTIC-corruption recovery. setupdl is idempotent -- it never
            # re-downloads a file that already exists on disk -- so a stale or corrupt
            # file in $CMRedist (classically carried over from an OLDER CM build across
            # lab re-runs) fails hash/manifest verification IDENTICALLY on every retry,
            # burning all $MaxTries. When THIS attempt's setup-log slice shows a
            # manifest/hash failure, delete the prereq redist content so the next
            # setupdl re-fetches a clean, media-matching set. We inspect ONLY the log
            # written during this attempt (offset $logPosBefore) so a stale failure
            # line from an earlier attempt can't re-trigger a purge. Purge at most
            # twice: if a FRESH redist still fails verification it's a real media/CDN
            # problem, not staleness, so let the normal retry/fail path handle it.
            $attemptLog = ''
            try {
                if (Test-Path $CMLog) {
                    $fsChk = [System.IO.File]::Open($CMLog, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                    try {
                        if ($fsChk.Length -gt $logPosBefore) {
                            $fsChk.Seek($logPosBefore, [System.IO.SeekOrigin]::Begin) | Out-Null
                            $srChk = New-Object System.IO.StreamReader($fsChk)
                            $attemptLog = $srChk.ReadToEnd()
                            $srChk.Dispose()
                        }
                    }
                    finally { $fsChk.Dispose() }
                }
            }
            catch { }

            if ($attemptLog -match 'Manifest verification failed|File hash check failed' -and $redistPurged -lt 2) {
                Write-DscStatus "Pre-Req: manifest/hash verification FAILED -- deleting the prereq redist content under '$CMRedist' and re-downloading fresh (stale/corrupt files setupdl would otherwise never re-fetch)."
                try { Remove-Item -Path (Join-Path $CMRedist '*') -Recurse -Force -ErrorAction SilentlyContinue } catch { }
                $redistPurged++
                # A purge-and-refetch is a recovery, not a transient flake -- don't
                # let it consume the retry budget meant for network hiccups.
                $fail = [Math]::Max(0, $fail - 1)
            }

            if ($fail -ge $MaxTries) {
                Write-DscStatus "Pre-Req Downloading failed after $MaxTries tries. see $CMLog"
                return $false
            }
            Write-DscStatus "Pre-Req downloading Failed. Try $fail out of $MaxTries See $CMLog for progress"
            start-sleep -Seconds 30
        }
    }

    return $true
    }
    finally {
        if ($setupdlMutex) {
            if ($haveSetupdlMutex) { try { $setupdlMutex.ReleaseMutex() } catch { } }
            try { $setupdlMutex.Dispose() } catch { }
        }
    }
}

function Stop-CMSetupPrereqPrewarm {
    # Stop + unregister the Phase 3 "ScriptWorkflow Download" pre-warm task and
    # kill any setupdl.exe it left running, so the real Phase 8 download is the
    # only setupdl writing to the redist folder / ConfigMgrSetup.log. The
    # pre-warm only populates REdist (idempotent); whatever it finished persists
    # on disk and the Phase 8 download just verifies it fast.
    #
    # Task name MUST match the RegisterTaskScheduler instance in Phase3.ps1.
    $taskName = "ScriptWorkflow Download"
    try {
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($task) {
            Write-DscStatus "Pre-warm task '$taskName' present (state=$($task.State)); stopping and unregistering before Phase 8 download."
            if ($task.State -eq 'Running') {
                Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            }
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        }
    }
    catch {
        Write-DscStatus "Pre-warm task cleanup warning: $($_.Exception.Message)"
    }

    # Kill any setupdl.exe left running by the pre-warm (or a prior attempt) so
    # it can't race the Phase 8 download against the same REdist / log.
    try {
        $procs = @(Get-Process -Name 'setupdl' -ErrorAction SilentlyContinue)
        if ($procs.Count -gt 0) {
            Write-DscStatus "Killing $($procs.Count) orphaned setupdl.exe process(es) before Phase 8 download."
            $procs | ForEach-Object { try { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue } catch { } }
            Start-Sleep -Seconds 3
        }
    }
    catch { }
}

function Get-VmSqlConnectionTarget {
    # The one place that turns a deployConfig VM into a SQL "Data Source" / -ServerInstance
    # string. A DEFAULT instance on a non-default port is the case that keeps being missed:
    # it has no instance name to hang the port on, so omitting the port aims the connection
    # at 1433 -- which is not listening, because ChangeSqlInstancePort moves IPAll\TcpPort.
    # CT3-CS1SQL (MSSQLSERVER on 5422) failed an 83-minute Phase 8 that way; 13 of 62 lab
    # configs use a non-1433 port, so this is the normal case, not an edge case.
    param(
        [Parameter(Mandatory)]$SiteVm,
        [Parameter(Mandatory)]$DeployConfig,
        [Parameter(Mandatory)][string]$DomainFullName
    )

    $sqlVmName = if ($SiteVm.remoteSQLVM) { "$($SiteVm.remoteSQLVM)" } else { "$($SiteVm.vmName)" }
    $sqlVm = $DeployConfig.virtualMachines | Where-Object { $_.vmName -eq $sqlVmName } | Select-Object -First 1
    $sqlServer = $sqlVmName
    $sqlInstance = if ($sqlVm) { "$($sqlVm.sqlInstanceName)" } else { '' }
    $sqlPort = if ($sqlVm -and $sqlVm.sqlPort) { $sqlVm.sqlPort } else { $null }

    if ($sqlVm -and $sqlVm.AlwaysOnListenerName) {
        $sqlServer = "$($sqlVm.AlwaysOnListenerName)"
        $sqlInstance = ''
        # The listener has its own port; a node's sqlPort does not reach it.
        $sqlPort = if ($sqlVm.thisParams -and $sqlVm.thisParams.SQLAO -and $sqlVm.thisParams.SQLAO.SQLAOPort) { $sqlVm.thisParams.SQLAO.SQLAOPort } else { $null }
    }

    $target = if ($sqlServer -like '*.*') { $sqlServer } else { "$sqlServer.$DomainFullName" }
    if ($sqlInstance -and $sqlInstance.ToUpper() -ne 'MSSQLSERVER') { $target = "$target\$sqlInstance" }
    if ($sqlPort -and "$sqlPort" -ne '1433') { $target = "$target,$sqlPort" }
    return $target
}

function Set-CMSiteProvider {
    param($SiteCode, $ProviderFQDN)

    # Get CM module path
    $key = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry32)
    $subKey = $key.OpenSubKey("SOFTWARE\Microsoft\ConfigMgr10\Setup")
    $uiInstallPath = $subKey.GetValue("UI Installation Directory")
    $modulePath = $uiInstallPath + "bin\ConfigurationManager.psd1"
    $initParams = @{}

    # Import the ConfigurationManager.psd1 module
    if ($null -eq (Get-Module ConfigurationManager)) {
        Import-Module $modulePath
    }

    # Connect to the site's drive if it is not already present
    Write-DscStatus "Setting PS Drive" -NoStatus
    New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $ProviderFQDN -scope global @initParams -ErrorAction SilentlyContinue | Out-Null

    $psDriveFailcount = 0
    while ($null -eq (Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue)) {
        $psDriveFailcount++
        if ($psDriveFailcount -gt 20) {
            Write-DscStatus "Failed to get the PS Drive for site $SiteCode. Install may have failed. Check C:\ConfigMgrSetup.log" -Failure
            return $false
        }
        Write-DscStatus "Retry in 10s to Set PS Drive for site $SiteCode on $ProviderFQDN" -NoStatus
        Start-Sleep -Seconds 10
        New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $ProviderFQDN -scope global @initParams | Out-Null
    }

    Write-DscStatus "Successfully set PS Drive for site $SiteCode on $ProviderFQDN" -NoStatus
    return $true
}

function Get-SMSProvider {
    param($SiteCode)

    $return = [PSCustomObject]@{
        FQDN          = $null
        NamespacePath = $null
    }

    $retry = 0

    while ($retry -lt 4) {
        # try local provider first
        $localTest = Get-CimInstance -Namespace "root\SMS\Site_$SiteCode" -Class "SMS_Site" -ErrorVariable WmiErr
        if ($localTest -and $WmiErr.Count -eq 0) {
            $return.FQDN = "$($env:COMPUTERNAME).$($env:USERDNSDOMAIN)"
            $return.NamespacePath = "root\SMS\Site_$SiteCode"
            return $return
        }

        # loop through providers
        $providers = Get-CimInstance -class "SMS_ProviderLocation" -Namespace "root\SMS"
        foreach ($provider in $providers) {

            # Test provider Fix me \\server
            Get-CimInstance -Namespace $provider.NamespacePath -Class SMS_Site -ErrorVariable WmiErr | Out-Null
            if ($WmiErr.Count -gt 0) {
                continue
            }
            else {
                $return.FQDN = $provider.Machine
                $return.NamespacePath = "root\SMS\Site_$SiteCode"
                return $return
            }
        }
        $retry++
        $seconds = $retry * 45
        start-sleep -seconds $seconds
    }

    return $return
}

function Wait-CMRoleRegistered {
    # Replaces the blind post-add Start-Sleep in the role installers with a poll on
    # the SAME predicate the caller's do/until already exits on, so the wait ends when
    # the role appears instead of when a hardcoded timer expires. Worst case equals the
    # sleep it replaces, so this can only ever finish earlier.
    #
    # It also records how long registration actually took, which no log has ever
    # carried: measured DP 72s / MP 72s / SUP 71s against a 70s floor and Reporting
    # Point 43s against a 40s floor, i.e. every role landed 1-3s past its own sleep and
    # the true latency was never observable.
    param (
        [Parameter(Mandatory = $true)]
        [scriptblock]$Probe,
        [Parameter(Mandatory = $true)]
        [string]$RoleName,
        [Parameter(Mandatory = $true)]
        [string]$ServerFQDN,
        [int]$TimeoutSeconds = 60,
        [int]$PollSeconds = 5
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $result = $null
    $probeError = $null

    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        Start-Sleep -Seconds $PollSeconds
        try {
            $result = & $Probe
            $probeError = $null
        }
        catch {
            # A provider hiccup is not the same answer as "role absent", so keep
            # polling -- but keep the reason so a timeout can name it.
            $result = $null
            $probeError = $_.Exception.Message
        }
        if ($result) { break }
    }

    $sw.Stop()
    $secs = [math]::Round($sw.Elapsed.TotalSeconds, 1)

    if ($result) {
        # Wording keeps the existing "<Role> Role detected on <FQDN>" marker so log
        # analysis that pairs it with "Role not detected ... Adding" still works.
        Write-DscStatus "$RoleName Role detected on $ServerFQDN after ${secs}s (polled every ${PollSeconds}s, budget ${TimeoutSeconds}s)"
    }
    elseif ($probeError) {
        Write-DscStatus "$RoleName Role not registered on $ServerFQDN within ${secs}s; last probe error: $probeError. Retrying."
    }
    else {
        Write-DscStatus "$RoleName Role not registered on $ServerFQDN within ${secs}s. Retrying."
    }

    return $result
}

function Install-DP {
    param (
        [Parameter()]
        [string]
        $ServerFQDN,
        [string]
        $ServerSiteCode,
        [bool]
        $usePKI = $false
    )

    $i = 0
    $installFailure = $false
    $DPFQDN = $ServerFQDN

    do {

        $i++

        # Create Site system Server
        #============
        $SystemServer = Get-CMSiteSystemServer -SiteSystemServerName $DPFQDN -SiteCode $ServerSiteCode
        if (-not $SystemServer) {
            Write-DscStatus "Creating new CM Site System server on $DPFQDN SiteCode: $ServerSiteCode"
            New-CMSiteSystemServer -SiteSystemServerName $DPFQDN -SiteCode $ServerSiteCode *>&1 | Write-StatusLogEntry
            $SystemServer = Wait-CMRoleRegistered -RoleName 'Site System' -ServerFQDN $DPFQDN -TimeoutSeconds 15 -PollSeconds 3 `
                -Probe { Get-CMSiteSystemServer -SiteSystemServerName $DPFQDN -SiteCode $ServerSiteCode }
        }

        # Install DP
        #============
        $dpinstalled = Get-CMDistributionPoint -SiteSystemServerName $DPFQDN -SiteCode $ServerSiteCode
        if (-not $dpinstalled) {
            Write-DscStatus "DP Role not detected on $DPFQDN. Adding Distribution Point role."
            $Date = [DateTime]::Now.AddYears(30)
            #Add-CMDistributionPoint -InputObject $SystemServer -CertificateExpirationTimeUtc $Date *>&1 | Write-StatusLogEntry
            if ($usePKI) {
                $CertPath = "C:\temp\ConfigMgrClientDistributionPointCertificate.pfx"
                if (Test-Path $CertPath) {
                    $CertAuth = "$env:windir\temp\ProvisionScript\certauth.txt"
                    if (Test-Path $CertAuth) {
                        $certPass = Get-Content $CertAuth | ConvertTo-SecureString -AsPlainText -Force
                        "Add-CMDistributionPoint -SiteSystemServerName $DPFQDN -SiteCode $ServerSiteCode -CertificatePath $CertPath -CertificatePassword $certPass -EnableSSL -EnablePxe -EnableNonWdsPxe -AllowPxeResponse -EnableUnknownComputerSupport -Force" *>&1 | Write-StatusLogEntry
                        Add-CMDistributionPoint -SiteSystemServerName $DPFQDN -SiteCode $ServerSiteCode -CertificatePath $CertPath -CertificatePassword $certPass -EnableSSL -EnablePxe -EnableNonWdsPxe -AllowPxeResponse -EnableUnknownComputerSupport -Force *>&1 | Write-StatusLogEntry
                    }
                    else {
                        "Could Not find $CertAuth" *>&1 | Write-StatusLogEntry
                        $installFailure = $true
                    }
                }
                else {
                    "Could Not find $CertPath" *>&1 | Write-StatusLogEntry
                    $installFailure = $true
                }
            }
            else {
                Add-CMDistributionPoint -SiteSystemServerName $DPFQDN -SiteCode $ServerSiteCode -CertificateExpirationTimeUtc $Date -EnablePxe -EnableNonWdsPxe -AllowPxeResponse -EnableUnknownComputerSupport -Force *>&1 | Write-StatusLogEntry
            }
            if (-not $installFailure) {
                $dpinstalled = Wait-CMRoleRegistered -RoleName 'DP' -ServerFQDN $DPFQDN -TimeoutSeconds 60 `
                    -Probe { Get-CMDistributionPoint -SiteSystemServerName $DPFQDN -SiteCode $ServerSiteCode }
            }
        }
        else {
            Write-DscStatus "DP Role detected on $DPFQDN SiteCode: $ServerSiteCode"
            $dpinstalled = $true
        }

        if ($i -gt 10) {
            Write-DscStatus "No Progress after $i tries, Giving up on $DPFQDN SiteCode: $ServerSiteCode ."
            $installFailure = $true
        }

        if (-not $dpinstalled -and -not $installFailure) {
            Start-Sleep -Seconds 10
        }

    } until ($dpinstalled -or $installFailure)

    if ($dpinstalled -and $usePKI) {        
        Invoke-Command -ComputerName $DPFQDN -ScriptBlock {
            Set-ItemProperty -Path "HKLM:\Software\Microsoft\SMS\DP" -Name "SSLState" -Value 63 -Force
        }    
    }

    return [bool]$dpinstalled
}

function Install-PullDP {
    param (
        [Parameter()]
        [string]
        $ServerFQDN,
        [string]
        $ServerSiteCode,
        [string]
        $SourceDPFQDN,
        [bool]
        $usePKI = $false
    )

    $i = 0
    $installFailure = $false
    $DPFQDN = $ServerFQDN

    do {

        $i++

        # Create Site system Server
        #============
        $SystemServer = Get-CMSiteSystemServer -SiteSystemServerName $DPFQDN -SiteCode $ServerSiteCode
        if (-not $SystemServer) {
            Write-DscStatus "Creating new CM Site System server on $DPFQDN SiteCode: $ServerSiteCode"
            New-CMSiteSystemServer -SiteSystemServerName $DPFQDN -SiteCode $ServerSiteCode *>&1 | Write-StatusLogEntry
            $SystemServer = Wait-CMRoleRegistered -RoleName 'Site System' -ServerFQDN $DPFQDN -TimeoutSeconds 15 -PollSeconds 3 `
                -Probe { Get-CMSiteSystemServer -SiteSystemServerName $DPFQDN -SiteCode $ServerSiteCode }
        }

        # Install Pull DP
        #=================
        $dpinstalled = Get-CMDistributionPoint -SiteSystemServerName $DPFQDN -SiteCode $ServerSiteCode
        if (-not $dpinstalled) {
            # The source DP MUST already be an installed standard DP, otherwise
            # Add-CMDistributionPoint -SourceDistributionPoint throws a terminating
            # "No object corresponds to the specified parameters" that aborts the
            # caller. Guard here so a not-yet-ready source degrades to a retry/skip
            # instead of taking down the whole InstallDPMPClient run.
            $sourceDPObj = Get-CMDistributionPoint -SiteSystemServerName $SourceDPFQDN -SiteCode $ServerSiteCode
            if (-not $sourceDPObj) {
                Write-DscStatus "Pull DP source '$SourceDPFQDN' is not an installed Distribution Point yet; cannot add pull DP $DPFQDN this pass."
                if ($i -gt 10) { $installFailure = $true }
                else { Start-Sleep -Seconds 30 }
                continue
            }
            Write-DscStatus "DP Role not detected on $DPFQDN. Adding Distribution Point role as a Pull DP, with Source DP $SourceDPFQDN."
            $Date = [DateTime]::Now.AddYears(30)
            if ($usePKI) {
                $CertPath = "C:\temp\ConfigMgrClientDistributionPointCertificate.pfx"
                if (Test-Path $CertPath) {
                    $CertAuth = "$env:windir\temp\ProvisionScript\certauth.txt"
                    if (Test-Path $CertAuth) {
                        $certPass = Get-Content $CertAuth | ConvertTo-SecureString -AsPlainText -Force
                        Add-CMDistributionPoint -SiteCode $ServerSiteCode -SiteSystemServerName $DPFQDN -CertificatePath $CertPath -CertificatePassword $certPass -EnablePullDP -SourceDistributionPoint $SourceDPFQDN -Force *>&1 | Write-StatusLogEntry
                    }
                    else {
                        "Could Not find $CertAuth" *>&1 | Write-StatusLogEntry
                        $installFailure = $true
                    }
                }
                else {
                    "Could Not find $CertPath" *>&1 | Write-StatusLogEntry
                    $installFailure = $true
                }
            }
            else {
                Add-CMDistributionPoint -SiteCode $ServerSiteCode -SiteSystemServerName $DPFQDN -CertificateExpirationTimeUtc $Date -EnablePullDP -SourceDistributionPoint $SourceDPFQDN -Force *>&1 | Write-StatusLogEntry

            }
            if (-not $installFailure) {
                $dpinstalled = Wait-CMRoleRegistered -RoleName 'DP' -ServerFQDN $DPFQDN -TimeoutSeconds 60 `
                    -Probe { Get-CMDistributionPoint -SiteSystemServerName $DPFQDN -SiteCode $ServerSiteCode }
            }
        }
        else {
            Write-DscStatus "DP Role detected on $DPFQDN SiteCode: $ServerSiteCode"
            $dpinstalled = $true
        }

        if ($i -gt 10) {
            Write-DscStatus "No Progress after $i tries, Giving up on $DPFQDN SiteCode: $ServerSiteCode ."
            $installFailure = $true
        }

        if (-not $dpinstalled -and -not $installFailure) {
            Start-Sleep -Seconds 10
        }

    } until ($dpinstalled -or $installFailure)

    return [bool]$dpinstalled
}

function Confirm-MPHttpsBinding {
    # An HTTPS (PKI) Management Point requires the MP box's IIS "Default Web Site"
    # to have a 443 binding with a valid ServerAuth cert. If it is missing, the
    # MP MSI aborts with "Error 25055. Internet Information Services Default Web
    # Site is not correctly configured for SSL" and SMS_MP is never created.
    #
    # On a re-run the site-system's Phase 8 CertReq/AddCertificateToIIS can report
    # InDesiredState even though the actual http.sys 443 SSL cert was lost, so we
    # cannot rely on it. Verify + self-heal the binding on the MP box HERE, right
    # before Add-CMManagementPoint -CommunicationType Https, so the MSI precheck
    # always passes. Idempotent: a no-op when the binding is already correct.
    param (
        [Parameter(Mandatory = $true)]
        [string]$MPFQDN
    )

    Write-DscStatus "Ensuring IIS Default Web Site SSL (443) binding on $MPFQDN before HTTPS MP install (prevents MP MSI error 25055)..."

    $sb = {
        $fn  = 'ConfigMgr WebServer Certificate'
        $log = New-Object System.Collections.Generic.List[string]
        $now = Get-Date
        $fqdn = "$env:COMPUTERNAME.$env:USERDNSDOMAIN"
        $srvAuthOid = '1.3.6.1.5.5.7.3.1'
        $tplExtOid  = '1.3.6.1.4.1.311.21.7'

        # 1. Locate a date-valid cert by the FriendlyName the binding expects.
        $cert = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
            Where-Object { $_.FriendlyName -eq $fn -and $_.NotBefore -lt $now -and $_.NotAfter -gt $now } |
            Sort-Object NotBefore -Descending | Select-Object -First 1

        # 2. Recover a WebServer-template cert (CA-issued, ServerAuth, this host's
        #    FQDN, has the V2 template extension) that merely lost its FriendlyName.
        if (-not $cert) {
            $cand = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue | Where-Object {
                ($_.EnhancedKeyUsageList.ObjectId -contains $srvAuthOid) -and
                ($_.Subject -match [regex]::Escape($fqdn)) -and
                ($_.Issuer -ne $_.Subject) -and
                ($_.Extensions.Oid.Value -contains $tplExtOid) -and
                ($_.NotBefore -lt $now -and $_.NotAfter -gt $now)
            } | Sort-Object NotBefore -Descending | Select-Object -First 1
            if ($cand) {
                try {
                    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store('My', 'LocalMachine')
                    $store.Open('ReadWrite')
                    $live = $store.Certificates | Where-Object { $_.Thumbprint -eq $cand.Thumbprint } | Select-Object -First 1
                    if ($live) { $live.FriendlyName = $fn }
                    $store.Close()
                    $log.Add("Recovered CA-issued ServerAuth cert $($cand.Thumbprint.Substring(0,8)).. that had lost FriendlyName '$fn'; re-applied name")
                    $cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.FriendlyName -eq $fn } | Select-Object -Last 1
                }
                catch { $log.Add("WARN: could not re-apply FriendlyName to recovered cert: $($_.Exception.Message)") }
            }
        }

        # 3. Nothing usable in the store -- re-enroll from the CA template.
        if (-not $cert) {
            try {
                $enroll = Get-Certificate -Template 'ConfigMgrWebServerCertificate' -DnsName $fqdn -SubjectName "CN=$fqdn" -CertStoreLocation Cert:\LocalMachine\My -ErrorAction Stop
                if ($enroll -and $enroll.Certificate) {
                    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store('My', 'LocalMachine')
                    $store.Open('ReadWrite')
                    $live = $store.Certificates | Where-Object { $_.Thumbprint -eq $enroll.Certificate.Thumbprint } | Select-Object -First 1
                    if ($live) { $live.FriendlyName = $fn }
                    $store.Close()
                    $cert = $enroll.Certificate
                    $log.Add("Re-enrolled WebServer cert $($cert.Thumbprint.Substring(0,8)).. from ConfigMgrWebServerCertificate template")
                }
            }
            catch { $log.Add("WARN: re-enroll from ConfigMgrWebServerCertificate template failed: $($_.Exception.Message)") }
        }

        if (-not $cert) {
            $log.Add("FAIL: no valid WebServer cert found, recovered, or enrolled on this host. IIS 443 cannot be bound (MP HTTPS install will fail 25055). Verify the machine is in 'ConfigMgr IIS Servers' and the CA advertises 'ConfigMgrWebServerCertificate'.")
            return $log
        }

        # 4. Ensure Default Web Site has a 443 https binding carrying this cert.
        try {
            Import-Module WebAdministration -ErrorAction Stop
            $bound = netsh http show sslcert ipport=0.0.0.0:443 2>&1
            if ($bound -match $cert.Thumbprint) {
                $log.Add("OK: Default Web Site:443 already bound to WebServer cert $($cert.Thumbprint.Substring(0,8)).")
            }
            else {
                $b = Get-WebBinding -Name 'Default Web Site' -Port 443 -Protocol 'https' -ErrorAction SilentlyContinue
                if (-not $b) {
                    New-WebBinding -Name 'Default Web Site' -IPAddress '*' -Port 443 -Protocol 'https' -ErrorAction Stop
                    $b = Get-WebBinding -Name 'Default Web Site' -Port 443 -Protocol 'https' -ErrorAction SilentlyContinue
                }
                if ($b) {
                    $b.AddSslCertificate($cert.Thumbprint, 'my')
                    $log.Add("Bound WebServer cert $($cert.Thumbprint.Substring(0,8)).. to Default Web Site:443")
                }
                else {
                    $log.Add("FAIL: could not create the 443 https binding on Default Web Site")
                }
            }
        }
        catch { $log.Add("WARN: IIS 443 binding step failed: $($_.Exception.Message)") }

        return $log
    }

    try {
        $result = Invoke-Command -ComputerName $MPFQDN -ScriptBlock $sb -ErrorAction Stop
        foreach ($line in @($result)) { Write-DscStatus "  [$MPFQDN 443] $line" }
        # Signal to the caller whether we actually created/updated the 443 binding
        # (as opposed to finding it already correct or failing to obtain a cert).
        # A newly-bound MP means the earlier server-side install failed at 25055, so
        # the caller can force Site Component Manager to retry immediately.
        $changed = @($result | Where-Object { $_ -match 'Bound WebServer cert' }).Count -gt 0
        return $changed
    }
    catch {
        Write-DscStatus "WARNING: Could not verify/repair IIS 443 SSL binding on $MPFQDN`: $($_.Exception.Message). HTTPS MP install may fail with error 25055."
        return $false
    }
}

function Install-MP {
    param (
        [string]
        $ServerFQDN,
        [string]
        $ServerSiteCode,
        [bool]
        $UsePKI = $false
    )

    $i = 0
    $installFailure = $false
    $MPFQDN = $ServerFQDN

    # For an HTTPS (PKI) MP, guarantee the MP box's IIS 443 SSL binding is in
    # place before we ever call Add-CMManagementPoint -CommunicationType Https;
    # otherwise the remote MP MSI aborts with "Error 25055 ... not correctly
    # configured for SSL" and SMS_MP is never provisioned.
    if ($UsePKI) {
        $null = Confirm-MPHttpsBinding -MPFQDN $MPFQDN
    }

    do {

        $i++
        $SystemServer = Get-CMSiteSystemServer -SiteSystemServerName $MPFQDN
        if (-not $SystemServer) {
            Write-DscStatus "Creating new CM Site System server on $MPFQDN"
            New-CMSiteSystemServer -SiteSystemServerName $MPFQDN -SiteCode $ServerSiteCode *>&1 | Write-StatusLogEntry
            $SystemServer = Wait-CMRoleRegistered -RoleName 'Site System' -ServerFQDN $MPFQDN -TimeoutSeconds 15 -PollSeconds 3 `
                -Probe { Get-CMSiteSystemServer -SiteSystemServerName $MPFQDN }
        }

        $mpinstalled = Get-CMManagementPoint -SiteSystemServerName $MPFQDN
        if (-not $mpinstalled) {
            Write-DscStatus "MP Role not detected on $MPFQDN. Adding Management Point role."
            if ($UsePKI) {
                Add-CMManagementPoint -InputObject $SystemServer -CommunicationType Https -EnableSSL *>&1 | Write-StatusLogEntry
            }
            else {
                Add-CMManagementPoint -InputObject $SystemServer -CommunicationType Http *>&1 | Write-StatusLogEntry
            }
            $mpinstalled = Wait-CMRoleRegistered -RoleName 'MP' -ServerFQDN $MPFQDN -TimeoutSeconds 60 `
                -Probe { Get-CMManagementPoint -SiteSystemServerName $MPFQDN }
        }
        else {
            Write-DscStatus "MP Role detected on $MPFQDN"
            $mpinstalled = $true
        }

        if ($i -gt 10) {
            Write-DscStatus "No Progress after $i tries, Giving up."
            $installFailure = $true
        }

        if (-not $mpinstalled -and -not $installFailure) {
            Start-Sleep -Seconds 10
        }

    } until ($mpinstalled -or $installFailure)
}

function Install-SUP {
    param (
        [string]
        $ServerFQDN,
        [string]
        $ServerSiteCode,
        [bool]
        $usePKI = $false
    )

    $i = 0
    $installFailure = $false


    
    do {

        $i++
        $SystemServer = Get-CMSiteSystemServer -SiteSystemServerName $ServerFQDN
        if (-not $SystemServer) {
            Write-DscStatus "Creating new CM Site System server on $ServerFQDN SiteCode: $ServerSiteCode"
            try {
                New-CMSiteSystemServer -SiteSystemServerName $ServerFQDN -SiteCode $ServerSiteCode -ErrorAction Stop *>&1 | Write-StatusLogEntry
            } catch {
                if ($_.Exception.Message -notmatch 'already exists') { Write-DscStatus "WARNING: New-CMSiteSystemServer failed: $($_.Exception.Message)" }
            }
            $SystemServer = Wait-CMRoleRegistered -RoleName 'Site System' -ServerFQDN $ServerFQDN -TimeoutSeconds 15 -PollSeconds 3 `
                -Probe { Get-CMSiteSystemServer -SiteSystemServerName $ServerFQDN }
        }

        $installed = Get-CMSoftwareUpdatePoint -SiteCode $ServerSiteCode -SiteSystemServerName $ServerFQDN
        if (-not $installed) {
            Write-DscStatus "SUP Role not detected on $ServerFQDN. Adding Software Update Point role."
            try {
                Add-CMSoftwareUpdatePoint -SiteCode $ServerSiteCode -SiteSystemServerName $ServerFQDN -WsusIisPort 8530 -WsusIisSslPort 8531 -WsusSSL:$usePKI *>&1 | Write-StatusLogEntry
            }
            catch {
                if ($_.FullyQualifiedErrorId -like '*RoleExists*') {
                    Write-DscStatus "SUP Role already exists on $ServerFQDN (detection lag). Treating as installed."
                    $installed = $true
                }
                else {
                    $_ | Write-StatusLogEntry
                    Write-DscStatus "Failed to add SUP on $ServerFQDN`: $_"
                }
            }
            if (-not $installed) {
                $installed = Wait-CMRoleRegistered -RoleName 'SUP' -ServerFQDN $ServerFQDN -TimeoutSeconds 60 `
                    -Probe { Get-CMSoftwareUpdatePoint -SiteCode $ServerSiteCode -SiteSystemServerName $ServerFQDN }
            }
        }
        else {
            Write-DscStatus "SUP Role detected on $ServerFQDN"
            $installed = $true
        }

        if ($i -gt 10) {
            Write-DscStatus "No Progress for SUP Role after $i tries, Giving up."
            $installFailure = $true
        }

        if (-not $installed -and -not $installFailure) {
            Start-Sleep -Seconds 10
        }

    } until ($installed -or $installFailure)
}


function Add-ReportingUser {
    [CmdletBinding()]
    Param(
        [string]
        $SiteCode,
        [string]
        $UserName,
        [Parameter(Mandatory = $true)]
        [String]$unencrypted
    )

    # Encrypt the Password
    $SMSSite = "SMS_Site"
    $class_PWD = [wmiclass]""
    $class_PWD.psbase.Path = "ROOT\SMS\site_$($SiteCode):$($SMSSite)"
    $Parameters = $class_PWD.GetMethodParameters("EncryptDataEx")
    $Parameters.Data = $unencrypted
    $Parameters.SiteCode = $SiteCode
    $encryptedPassword = $class_PWD.InvokeMethod("EncryptDataEx", $Parameters, $null)

    # Create the user in the site
    $SMSSCIReserved = "SMS_SCI_Reserved"
    $class_User = [wmiclass]""
    $class_User.psbase.Path = "ROOT\SMS\Site_$($SiteCode):$($SMSSCIReserved)"
    $user = $class_User.createInstance()
    $user.ItemName = "$($UserName)| 0"
    $user.ItemType = "User"
    $user.UserName = $UserName
    $user.Availability = "0"
    $user.FileType = "2"
    $user.SiteCode = $SiteCode
    $user.Reserved2 = $encryptedPassword.EncryptedData.ToString()
    $user.Put() | Out-Null
}

function Install-SRP {
    param (
        [string]
        $ServerFQDN,
        [string]
        $ServerSiteCode,
        [string]
        $UserName,
        [string]
        $SqlServerName,
        [string]
        $DatabaseName
    )

    $i = 0
    $installFailure = $false

    do {

        $i++
        $SystemServer = Get-CMSiteSystemServer -SiteSystemServerName $ServerFQDN
        if (-not $SystemServer) {
            Write-DscStatus "Creating new CM Site System server on $ServerFQDN"
            New-CMSiteSystemServer -SiteSystemServerName $ServerFQDN -SiteCode $ServerSiteCode  *>&1 | Write-StatusLogEntry
            $SystemServer = Wait-CMRoleRegistered -RoleName 'Site System' -ServerFQDN $ServerFQDN -TimeoutSeconds 15 -PollSeconds 3 `
                -Probe { Get-CMSiteSystemServer -SiteSystemServerName $ServerFQDN }
        }

        $installed = Get-CMReportingServicePoint -SiteSystemServerName $ServerFQDN
        if (-not $installed) {
            Write-DscStatus "Reporting Point Role not detected on $ServerFQDN. Adding Reporting Point role using DB Server [$SqlServerName], DB Name [$DatabaseName], UserName [$UserName]"
            Add-CMReportingServicePoint -SiteCode $ServerSiteCode -SiteSystemServerName $ServerFQDN -UserName $UserName -DatabaseServerName $SqlServerName -DatabaseName $DatabaseName -ReportServerInstance "PBIRS" *>&1 | Write-StatusLogEntry
            $installed = Wait-CMRoleRegistered -RoleName 'Reporting Point' -ServerFQDN $ServerFQDN -TimeoutSeconds 30 `
                -Probe { Get-CMReportingServicePoint -SiteSystemServerName $ServerFQDN }
        }
        else {
            Write-DscStatus "Reporting Point Role detected on $ServerFQDN"
            $installed = $true
        }

        if ($i -eq 5) {
            try {
                Get-Service -Name SMS_EXECUTIVE | Restart-Service
            }
            catch {}
        }
        if ($i -gt 10) {
            Write-DscStatus "No Progress for Reporting Point Role after $i tries, Giving up."
            $installFailure = $true
        }

        if (-not $installed -and -not $installFailure) {
            Start-Sleep -Seconds 10
        }

    } until ($installed -or $installFailure)

    return (-not $installFailure)
}

function Write-ScriptWorkFlowData {
    param (
        [object]
        $Configuration,
        [string]
        $ConfigurationFile
    )

    $mtx = $null
    try {
        $mtx = New-Object System.Threading.Mutex($false, "ScriptWorkflow")
        [void]$mtx.WaitOne()
    }
    catch {
        # Mutex creation can fail after snapshot restore if a stale kernel
        # object exists with a different security context.  Proceed without
        # synchronization — ScriptWorkflow runs sequentially.
        $mtx = $null
    }
    try {
        $Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force
    }
    finally {
        if ($mtx) {
            [void]$mtx.ReleaseMutex()
            [void]$mtx.Dispose()
        }
    }
}

function Get-UpdatePack {

    [CmdletBinding()]
    param (
        [Parameter()]
        [string]
        $UpdateVersion
    )

    Write-DscStatus "Get CM Update..." -NoStatus
    $updatepack = ""
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Scope = 'Function')]
    $CMPSSuppressFastNotUsedCheck = $true

    $updatepacklist = Get-CMSiteUpdate | Where-Object { $_.State -ne 196612 -and $_.Name -eq "Configuration Manager $UpdateVersion" } # filter hotfixes
    $doneUpdates = Get-CMSiteUpdate | Where-Object { $_.State -eq 196612 -and $_.Name -eq "Configuration Manager $UpdateVersion" }
    if ($doneUpdates.Count -ge 1 -and $updatepacklist.Count -eq 0) {
        Write-DscStatus "$UpdateVersion Update already installed. Skipping."
        return $updatepack
    }
    $getupdateretrycount = 0
    while ($updatepacklist.Count -eq 0) {

        if ($getupdateretrycount -eq 3) {
            break
        }

        Write-DscStatus "No update found. Running Invoke-CMSiteUpdateCheck and waiting for 2 mins..." -NoStatus
        $getupdateretrycount++

        Invoke-CMSiteUpdateCheck -ErrorAction Ignore *>&1 | Write-StatusLogEntry
        Start-Sleep 120

        $updatepacklist = Get-CMSiteUpdate | Where-Object { $_.State -ne 196612 -and $_.Name -eq "Configuration Manager $UpdateVersion" } # filter hotfixes
    }

   

    if ($updatepacklist.Count -eq 0) {
        # No updates
    }
    elseif ($updatepacklist.Count -eq 1) {
        # Single update
        $updatepack = $updatepacklist
    }
    else {
        # Multiple updates. Sort numerically, not lexically: CM fullversion is 5.00.NNNN.NNNN
        # and a string sort only agrees with a version sort while the build stays 4 digits.
        # At build 10000, "5.00.10000.1000" sorts BELOW "5.00.9999.1000" and we would pick the
        # older pack. Cast per-item rather than casting the property so an unexpected value
        # floors instead of throwing.
        $updatepack = ($updatepacklist | Sort-Object -Property @{ Expression = { try { [version]$_.fullversion } catch { [version]'0.0' } } })[-1]
    }

    return $updatepack
}

function Test-WsusBaselineImportSuccess {
    # Returns $true when import.log tail shows a successful wsusutil completion.
    # wsusutil writes the same final line on success regardless of the cab size.
    param([string]$ImportLog)
    if (-not (Test-Path $ImportLog)) { return $false }
    try {
        $tail = Get-Content $ImportLog -Tail 25 -ErrorAction Stop
    } catch { return $false }
    if (-not $tail) { return $false }
    $joined = ($tail -join "`n")
    if ($joined -match 'Successfully imported metadata' -or $joined -match 'Import .* (succeeded|completed)') {
        return $true
    }
    return $false
}

function Get-WsusTaxonomyCategoryCount {
    # Lightweight count of the WSUS UpdateCategories taxonomy. Used to gauge
    # whether a cab import landed (postinstall=~17, healthy cab=~400+).
    #
    # This runs ON the WSUS host, so prefer the LOCAL AdminProxy API, which is
    # port/SSL-independent. On a PKI WSUS the ApiRemoting30 endpoint is set to
    # Require SSL, so a Get-WsusServer call on 8530 (HTTP) returns 403 and the
    # old code returned -1 even when the taxonomy was fully populated -- which
    # made Wait-WsusBaselineImport conclude the cab "did not complete", retry,
    # and log the spurious "Baseline import retry ended exit=, TaxonomyCats=-1"
    # warning on every PKI lab. Fall back to the remoting API (requested HTTP
    # port, then the 8531 SSL endpoint) only if the local API is unavailable.
    param([string]$ServerName = $env:COMPUTERNAME, [int]$PortNumber = 8530)
    $isLocal = ($ServerName -eq $env:COMPUTERNAME) -or ($ServerName -eq 'localhost') -or ($ServerName -eq '.')
    if ($isLocal) {
        try {
            [void][System.Reflection.Assembly]::LoadWithPartialName('Microsoft.UpdateServices.Administration')
            $ws = [Microsoft.UpdateServices.Administration.AdminProxy]::GetUpdateServer()
            if ($ws) { return @($ws.GetUpdateCategories()).Count }
        } catch {}
    }
    try {
        $w = Get-WsusServer -Name $ServerName -PortNumber $PortNumber -ErrorAction Stop
        if ($w) { return @($w.GetUpdateCategories()).Count }
    } catch {}
    try {
        $w = Get-WsusServer -Name $ServerName -PortNumber 8531 -UseSsl -ErrorAction Stop
        if ($w) { return @($w.GetUpdateCategories()).Count }
    } catch {}
    return -1
}

function Get-WsusTaxonomyCategoryCountBounded {
    param(
        [string]$ServerName = $env:COMPUTERNAME,
        [int]$PortNumber = 8530,
        [int]$TimeoutSeconds = 30,
        [scriptblock]$ProbeScript
    )

    if (-not $ProbeScript) {
        $ProbeScript = {
            param($probeServerName, $probePortNumber)
            $isLocal = ($probeServerName -eq $env:COMPUTERNAME) -or ($probeServerName -eq 'localhost') -or ($probeServerName -eq '.')
            if ($isLocal) {
                try {
                    [void][System.Reflection.Assembly]::LoadWithPartialName('Microsoft.UpdateServices.Administration')
                    $ws = [Microsoft.UpdateServices.Administration.AdminProxy]::GetUpdateServer()
                    if ($ws) { return @($ws.GetUpdateCategories()).Count }
                }
                catch {}
            }
            try {
                $ws = Get-WsusServer -Name $probeServerName -PortNumber $probePortNumber -ErrorAction Stop
                if ($ws) { return @($ws.GetUpdateCategories()).Count }
            }
            catch {}
            try {
                $ws = Get-WsusServer -Name $probeServerName -PortNumber 8531 -UseSsl -ErrorAction Stop
                if ($ws) { return @($ws.GetUpdateCategories()).Count }
            }
            catch {}
            return -1
        }
    }

    $started = Get-Date
    $process = $null
    $stdoutPath = [System.IO.Path]::GetTempFileName()
    $stderrPath = [System.IO.Path]::GetTempFileName()
    try {
        $probeText = $ProbeScript.ToString()
        $probeBase64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probeText))
        $serverBase64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($ServerName))
        $childCommand = @"
`$probeText = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('$probeBase64'))
`$serverName = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('$serverBase64'))
`$probe = [scriptblock]::Create(`$probeText)
& `$probe `$serverName $PortNumber
"@
        $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childCommand))
        $enginePath = $null
        try { $enginePath = (Get-Process -Id $PID -ErrorAction Stop).Path } catch {}
        if (-not $enginePath) {
            $engineName = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
            $enginePath = Join-Path $PSHOME $engineName
        }
        $process = Start-Process -FilePath $enginePath `
            -ArgumentList @('-NoProfile', '-NonInteractive', '-EncodedCommand', $encodedCommand) `
            -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -WindowStyle Hidden -PassThru -ErrorAction Stop

        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill() } catch {}
            try { [void]$process.WaitForExit(2000) } catch {}
            return [pscustomobject]@{
                Count      = -1
                ElapsedSec = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)
                TimedOut   = $true
                Error      = ''
            }
        }
        $process.WaitForExit()
        $process.Refresh()
        $exitCode = [int]$process.ExitCode

        $count = -1
        foreach ($value in @([System.IO.File]::ReadAllLines($stdoutPath))) {
            $parsed = 0
            if ([int]::TryParse("$value".Trim(), [ref]$parsed)) { $count = $parsed }
        }
        $stderr = ([System.IO.File]::ReadAllText($stderrPath)).Trim()
        return [pscustomobject]@{
            Count      = $count
            ElapsedSec = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)
            TimedOut   = $false
            Error      = $(if ($exitCode -ne 0) { "probe process exit=${exitCode}: $stderr" } else { '' })
        }
    }
    catch {
        return [pscustomobject]@{
            Count      = -1
            ElapsedSec = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)
            TimedOut   = $false
            Error      = $_.Exception.Message
        }
    }
    finally {
        if ($process) { try { $process.Dispose() } catch {} }
        Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
    }
}

function Start-WsusBaselineImportBackground {
    # Launch `wsusutil import` against C:\staging\wsus\WsusCategoriesBaseline.cab
    # in the background and persist PID + start time + expected-count to a
    # state file for Wait-WsusBaselineImport to consume. Owns the entire cab
    # lifecycle (previously this was split across WSUSSync DSC + perfloading
    # and a post-Phase-7 reboot could kill wsusutil mid-import, leaving a
    # partial taxonomy that the next CM sync would fail on).
    #
    # No-op when the cab is absent, wsusutil is missing, the taxonomy is
    # already populated (count >= ExpectedCount), or a launch already
    # produced a state file with a still-running PID.
    #
    # Returns one of: 'launched', 'already-running', 'already-imported',
    # 'no-cab', 'no-wsusutil', 'fast-fail', 'error'.
    param(
        [string]$Tag = '[WSUS]',
        [int]$MaxWaitMinutes = 30,
        [int]$ExpectedCount = 100   # taxonomy threshold above which we consider the cab "landed"
    )

    $cabPath   = 'C:\staging\wsus\WsusCategoriesBaseline.cab'
    $stateFile = 'C:\staging\wsus\WsusCategoriesBaseline.import.state.json'
    $importLog = 'C:\staging\wsus\WsusCategoriesBaseline.import.log'

    if (-not (Test-Path $cabPath)) {
        Write-DscStatus "$Tag Baseline cab not present at $cabPath - skipping import (Phase 7 MU fire-and-forget sync should populate taxonomy instead)."
        return 'no-cab'
    }

    # NEVER import the cab into a DOWNSTREAM / replica WSUS. `wsusutil import`
    # is valid ONLY for a top-level WSUS that syncs from Microsoft Update -- the
    # cab is generated from an MU-sourced catalog, so importing it into a WSUS
    # configured to sync from an UPSTREAM WSUS server (a child primary's or
    # secondary's SUP -> the CAS/parent SUP) corrupts the local sync anchor and
    # the very next upstream sync fails with UssInternalError ("updates pipeline
    # broken"). Downstream SUPs get their categories via replication from the
    # upstream, not via import. Skip only on a POSITIVE downstream determination
    # (SyncFromMicrosoftUpdate=false AND an upstream server name set) so an
    # unconfigured / genuinely top-level SUP still imports.
    try {
        [void][System.Reflection.Assembly]::LoadWithPartialName('Microsoft.UpdateServices.Administration')
        $wsusCfgChk = [Microsoft.UpdateServices.Administration.AdminProxy]::GetUpdateServer().GetConfiguration()
        if ((-not $wsusCfgChk.SyncFromMicrosoftUpdate) -and $wsusCfgChk.UpstreamWsusServerName) {
            Write-DscStatus "$Tag WSUS is a downstream/replica (syncs from upstream '$($wsusCfgChk.UpstreamWsusServerName)') - skipping cab import; categories replicate from the upstream (importing would break the sync with UssInternalError)."
            return 'downstream-skip'
        }
    } catch {}

    # Skip if a prior pass already imported a healthy taxonomy.
    $preCount = Get-WsusTaxonomyCategoryCount
    if ($preCount -ge $ExpectedCount) {
        Write-DscStatus "$Tag Baseline cab already imported (TaxonomyCats=$preCount >= $ExpectedCount). Skipping re-import."
        if (Test-Path $stateFile) { Remove-Item $stateFile -Force -ErrorAction SilentlyContinue }
        return 'already-imported'
    }

    # Honor an in-flight import from a previous pass (idempotent re-entry).
    if (Test-Path $stateFile) {
        try {
            $existing = Get-Content $stateFile -Raw -ErrorAction Stop | ConvertFrom-Json
            $exPid = [int]$existing.ProcessId
            $exName = if ($existing.ProcessName) { [string]$existing.ProcessName } else { 'WsusUtil' }
            $exProc = Get-Process -Id $exPid -ErrorAction SilentlyContinue
            if ($exProc -and $exProc.ProcessName -ieq $exName) {
                Write-DscStatus "$Tag Baseline import already running (pid=$exPid). Not relaunching."
                return 'already-running'
            }
        } catch {}
        Remove-Item $stateFile -Force -ErrorAction SilentlyContinue
    }

    $wsusUtil = Join-Path $env:ProgramFiles 'Update Services\Tools\WsusUtil.exe'
    if (-not (Test-Path $wsusUtil)) {
        Write-DscStatus "$Tag WsusUtil.exe not found at $wsusUtil - cab import skipped."
        return 'no-wsusutil'
    }

    try {
        # Rotate the import log so we don't confuse Test-WsusBaselineImportSuccess
        # with tail lines from a prior partial run.
        if (Test-Path $importLog) {
            try { Move-Item -Path $importLog -Destination "$importLog.prev" -Force -ErrorAction SilentlyContinue } catch {}
        }

        Write-DscStatus "$Tag Launching wsusutil import (cab=$([math]::Round((Get-Item $cabPath).Length/1MB,1)) MB, pre-TaxonomyCats=$preCount, max wait $MaxWaitMinutes min)..."
        $proc = Start-Process -FilePath $wsusUtil -ArgumentList @('import', $cabPath, $importLog) -PassThru -NoNewWindow -ErrorAction Stop
        Start-Sleep -Seconds 2

        if ($proc.HasExited -and $proc.ExitCode -ne 0) {
            $tail = ''
            if (Test-Path $importLog) {
                $tailLines = Get-Content $importLog -Tail 5 -ErrorAction SilentlyContinue
                if ($tailLines) { $tail = ($tailLines -join ' | ') }
            }
            Write-DscStatus "$Tag WARN: wsusutil import fast-failed (exit=$($proc.ExitCode)). Tail: $tail"
            return 'fast-fail'
        }

        $state = [PSCustomObject]@{
            ProcessId       = $proc.Id
            ProcessName     = $proc.ProcessName
            StartTimeUtc    = (Get-Date).ToUniversalTime().ToString('o')
            CabPath         = $cabPath
            ImportLog       = $importLog
            MaxWaitMinutes  = $MaxWaitMinutes
            ExpectedCount   = $ExpectedCount
            PreTaxonomyCats = $preCount
        }
        try {
            $state | ConvertTo-Json | Set-Content -Path $stateFile -Encoding UTF8 -Force
        }
        catch {
            Write-DscStatus "$Tag WARN: failed to persist baseline import state ($($_.Exception.Message)). Wait-WsusBaselineImport will be unable to verify."
        }
        Write-DscStatus "$Tag wsusutil import running in background (pid=$($proc.Id))."
        return 'launched'
    }
    catch {
        Write-DscStatus "$Tag WARN: wsusutil import launch threw: $($_.Exception.Message)"
        return 'error'
    }
}

function Wait-WsusBaselineImport {
    # Wait for a previously-launched `wsusutil import` (see
    # Start-WsusBaselineImportBackground) to finish AND verify success via
    # three checks before allowing a CM-side sync to proceed on top of it:
    #   1. import.log tail shows a wsusutil completion marker
    #   2. WSUS taxonomy count >= ExpectedCount (default 100)
    #   3. If neither (1) nor (2) holds, the import is partial; retry once
    #      synchronously, then surface a WARN and proceed.
    #
    # No-op when the state file is absent (cab path wasn't used, or a
    # previous Wait already cleared it). Bounded to MaxWaitMinutes from
    # the import's original StartTimeUtc so a long Phase 8/9 doesn't
    # extend the deadline. Removes the state file on terminal exit so a
    # later perfloading Wait call is a clean no-op.
    param(
        [string]$Tag = '[WSUS]',
        [int]$RetryOnPartial = 1
    )

    $stateFile = 'C:\staging\wsus\WsusCategoriesBaseline.import.state.json'
    $importLog = 'C:\staging\wsus\WsusCategoriesBaseline.import.log'
    if (-not (Test-Path $stateFile)) { return }

    try {
        $state = Get-Content $stateFile -Raw -ErrorAction Stop | ConvertFrom-Json
    }
    catch {
        Write-DscStatus "$Tag Baseline import state file unreadable ($($_.Exception.Message)). Proceeding without wait."
        Remove-Item $stateFile -Force -ErrorAction SilentlyContinue
        return
    }

    $importPid = 0
    try { $importPid = [int]$state.ProcessId } catch {}
    $expectedName  = if ($state.ProcessName) { [string]$state.ProcessName } else { 'WsusUtil' }
    $maxMinutes    = 30
    try { if ($state.MaxWaitMinutes) { $maxMinutes = [int]$state.MaxWaitMinutes } } catch {}
    $expectedCount = 100
    try { if ($state.ExpectedCount)  { $expectedCount = [int]$state.ExpectedCount } } catch {}
    if ($state.ImportLog) { $importLog = [string]$state.ImportLog }
    $startTimeUtc = [DateTime]::UtcNow
    try { $startTimeUtc = ([DateTime]::Parse($state.StartTimeUtc)).ToUniversalTime() } catch {}
    $deadlineUtc  = $startTimeUtc.AddMinutes($maxMinutes)

    # Poll until the wsusutil process exits or we hit the deadline.
    if ($importPid -gt 0) {
        $proc = Get-Process -Id $importPid -ErrorAction SilentlyContinue
        if ($proc -and ($expectedName -and $proc.ProcessName -ieq $expectedName)) {
            $remainingSec = ($deadlineUtc - [DateTime]::UtcNow).TotalSeconds
            if ($remainingSec -gt 0) {
                Write-DscStatus "$Tag Waiting for in-flight WSUS baseline import (pid=$importPid, up to $([math]::Round($remainingSec/60,1)) min remaining)..."
                $lastLogUtc = [DateTime]::UtcNow
                while ($true) {
                    $p = Get-Process -Id $importPid -ErrorAction SilentlyContinue
                    if (-not $p -or ($expectedName -and $p.ProcessName -ine $expectedName)) { break }
                    if ([DateTime]::UtcNow -ge $deadlineUtc) {
                        Write-DscStatus "$Tag WARN: Baseline import (pid=$importPid) exceeded $maxMinutes-min deadline. Proceeding anyway; sync may fail."
                        Remove-Item $stateFile -Force -ErrorAction SilentlyContinue
                        return
                    }
                    Start-Sleep -Seconds 5
                    if (([DateTime]::UtcNow - $lastLogUtc).TotalSeconds -ge 60) {
                        $remSec = [math]::Max(0, ($deadlineUtc - [DateTime]::UtcNow).TotalSeconds)
                        $liveProbe = Get-WsusTaxonomyCategoryCountBounded
                        $probeState = if ($liveProbe.TimedOut) { 'timeout' } elseif ($liveProbe.Error) { "error=$($liveProbe.Error)" } else { 'ok' }
                        Write-DscStatus "$Tag Baseline import still running (pid=$importPid, TaxonomyCats=$($liveProbe.Count), TaxonomyProbe=$($liveProbe.ElapsedSec)s/$probeState, $([math]::Round($remSec/60,1)) min remaining)..."
                        $lastLogUtc = [DateTime]::UtcNow
                    }
                }
            }
        }
    }

    # Verify the import actually completed (not just "process gone").
    $elapsedMin   = [math]::Round(([DateTime]::UtcNow - $startTimeUtc).TotalMinutes, 1)
    $logProbeStart = Get-Date
    $logSuccess   = Test-WsusBaselineImportSuccess -ImportLog $importLog
    $logProbeSec  = [math]::Round(((Get-Date) - $logProbeStart).TotalSeconds, 1)
    $postProbe    = Get-WsusTaxonomyCategoryCountBounded
    $postCount    = $postProbe.Count
    $countLanded  = ($postCount -ge $expectedCount)
    $probeTiming  = "logProbe=${logProbeSec}s taxonomyProbe=$($postProbe.ElapsedSec)s"

    if ($logSuccess -and $countLanded) {
        Write-DscStatus "$Tag Baseline import verified (elapsed=${elapsedMin}min, TaxonomyCats=$postCount, log='Successfully imported metadata', $probeTiming)."
        Remove-Item $stateFile -Force -ErrorAction SilentlyContinue
        return
    }

    if ($countLanded -and -not $logSuccess) {
        Write-DscStatus "$Tag Baseline import looks landed (TaxonomyCats=$postCount >= $expectedCount) but no success marker in $importLog ($probeTiming). Proceeding."
        Remove-Item $stateFile -Force -ErrorAction SilentlyContinue
        return
    }

    if ($postProbe.TimedOut -or $postProbe.Error) {
        $probeFailure = if ($postProbe.TimedOut) { 'timed out' } else { "failed: $($postProbe.Error)" }
        Write-DscStatus "$Tag WARN: Baseline import process ended but the taxonomy verification probe $probeFailure after $($postProbe.ElapsedSec)s (logSuccess=$logSuccess, $probeTiming). The taxonomy is UNKNOWN, not absent; not launching a duplicate import."
        Remove-Item $stateFile -Force -ErrorAction SilentlyContinue
        return
    }

    # Partial import (process ended without populating the taxonomy).
    Write-DscStatus "$Tag WARN: Baseline import did not complete (elapsed=${elapsedMin}min, TaxonomyCats=$postCount, expected>=$expectedCount, logSuccess=$logSuccess, $probeTiming). Likely killed by reboot or wsusutil error."

    if ($RetryOnPartial -gt 0) {
        Write-DscStatus "$Tag Retrying wsusutil import synchronously (one shot)..."
        Remove-Item $stateFile -Force -ErrorAction SilentlyContinue
        $wsusUtil = Join-Path $env:ProgramFiles 'Update Services\Tools\WsusUtil.exe'
        $cabPath  = if ($state.CabPath) { [string]$state.CabPath } else { 'C:\staging\wsus\WsusCategoriesBaseline.cab' }
        if (-not (Test-Path $wsusUtil)) {
            Write-DscStatus "$Tag WARN: WsusUtil.exe missing at $wsusUtil. Cannot retry."
            return
        }
        if (-not (Test-Path $cabPath)) {
            Write-DscStatus "$Tag WARN: Cab missing at $cabPath. Cannot retry."
            return
        }
        try {
            if (Test-Path $importLog) {
                try { Move-Item -Path $importLog -Destination "$importLog.partial" -Force -ErrorAction SilentlyContinue } catch {}
            }
            $retryDeadlineMin = 20
            $retry = Start-Process -FilePath $wsusUtil -ArgumentList @('import', $cabPath, $importLog) -PassThru -NoNewWindow -ErrorAction Stop
            Write-DscStatus "$Tag wsusutil import retry running (pid=$($retry.Id), up to $retryDeadlineMin min)..."
            $retryDeadline = (Get-Date).AddMinutes($retryDeadlineMin)
            while (-not $retry.HasExited -and (Get-Date) -lt $retryDeadline) {
                Start-Sleep -Seconds 10
            }
            if (-not $retry.HasExited) {
                try { $retry.Kill() } catch {}
                Write-DscStatus "$Tag WARN: wsusutil import retry exceeded $retryDeadlineMin min and was killed. Proceeding with whatever taxonomy is loaded."
                return
            }
            $finalProbe = Get-WsusTaxonomyCategoryCountBounded
            $finalCount = $finalProbe.Count
            if ($retry.ExitCode -eq 0 -and $finalCount -ge $expectedCount) {
                Write-DscStatus "$Tag Baseline import retry succeeded (exit=0, TaxonomyCats=$finalCount, taxonomyProbe=$($finalProbe.ElapsedSec)s)."
            }
            else {
                Write-DscStatus "$Tag WARN: Baseline import retry ended exit=$($retry.ExitCode), TaxonomyCats=$finalCount, taxonomyProbe=$($finalProbe.ElapsedSec)s$(if ($finalProbe.TimedOut) { '/timeout' } else { '' }). Proceeding; CM sync may need extra cycles to populate categories."
            }
        }
        catch {
            Write-DscStatus "$Tag WARN: wsusutil import retry threw: $($_.Exception.Message). Proceeding."
        }
    }
}

