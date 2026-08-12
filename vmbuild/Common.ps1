# This file must be saved with UTF-8 BOM. createGuestDscZip.ps1 loads it under PS 5.1, which needs the BOM to parse Unicode.
# Common.ps1
[CmdletBinding()]
param (
    [Parameter()]
    [switch]$InJob,
    [Parameter()]
    [switch]$VerboseEnabled,
    [Parameter()]
    [switch]$DevBranch,
    [Parameter()]
    [switch]$GetLatestHotfixVersion,
    [Parameter()]
    [ValidateSet("Default", "Fast", "Full", "RemoveOnly")]
    [string]$StartupProfile = "Default",
    [Parameter()]
    [switch]$FastInit,
    [Parameter()]
    [switch]$SkipStorageInit,
    [Parameter()]
    [switch]$SkipMaintenanceRefresh,
    [Parameter()]
    [switch]$SkipVmCacheRefresh,
    [Parameter()]
    [switch]$SkipEnvironmentDetection,
    [Parameter()]
    [switch]$SkipHostPreparation,
    [Parameter()]
    [switch]$WarmVmCacheInBackground,
    [Parameter()]
    [switch]$DisableInitContextCache,
    [Parameter()]
    # IsAzureVM / CorpNet detection effectively never changes for a given host,
    # so cache it for 30 days (43200 min). A short TTL caused Phase 10 child
    # jobs (InJob path) to read an expired cache, default IsAzureVM to $false,
    # and silently drop Azure-gated fixes like Fix_ActivateWindows.
    [ValidateRange(1, 525600)]
    [int]$InitContextCacheMinutes = 43200,
    [Parameter()]
    [switch]$DisableHotfixCache,
    [Parameter()]
    [ValidateRange(1, 1440)]
    [int]$HotfixCacheMinutes = 60,
    [Parameter()]
    [switch]$DisableGitBranchCache,
    [Parameter()]
    [ValidateRange(1, 1440)]
    [int]$GitBranchCacheMinutes = 5
    ,
    [Parameter()]
    [switch]$DisableSupportedOptionsCache
)

########################
### Common Functions ###
########################

Function Write-ProgressElapsed {
    param(
        [Parameter(Mandatory = $true)]
        [object]$StopWatch,
        [Parameter(Mandatory = $true)]
        [object]$TimeSpan,
        [Parameter(Mandatory = $true)]
        [String]$text,
        [Parameter(Mandatory = $false)]
        [switch]$showTimeout,
        [Parameter(Mandatory = $false)]
        [string]$FailCount,
        [Parameter(Mandatory = $false)]
        [string]$FailCountMax


    )
    try {
        $percent = [Math]::Min(($stopWatch.ElapsedMilliseconds / $timespan.TotalMilliseconds * 100), 100)
        $msg = ""
        if ($showTimeout) {
            $msg = "Waiting $TimeSpan  "
        }
        $msg = $msg + "Elapsed: $($stopWatch.Elapsed.ToString("hh\:mm\:ss"))"
        if ($FailCount) {
            $msg = $msg + " Failed $FailCount / $FailCountMax"
        }
        Write-Progress2 $msg -Status $text -PercentComplete $percent -force
    }
    catch {
        Write-Exception $_
        Write-Progress2 "Exception" -Status $_ -force
    }
}

# Lightweight diagnostic logger for the progress-bar investigation. Gated by
# $global:ProgressDiag so it is a no-op in normal runs. Writes to a dedicated
# progressdiag.log (next to the build log) so it never pollutes VMBuild.log.
# Safe to call from parent and child-job processes; concurrent-write failures
# are swallowed since this is diagnostic-only.
Function Write-ProgressDiagLog {
    param([string]$Message)
    if (-not $global:ProgressDiag) { return }
    try {
        $diagPath = $global:ProgressDiagPath
        if (-not $diagPath) {
            if ($Common -and $Common.LogPath) {
                $base = Split-Path $Common.LogPath -Parent
            }
            else {
                $base = $env:TEMP
            }
            $diagPath = Join-Path $base "progressdiag.log"
            $global:ProgressDiagPath = $diagPath
        }
        $line = "{0} [pid:{1}] {2}`r`n" -f (Get-Date -Format "HH:mm:ss.fff"), $PID, $Message
        [System.IO.File]::AppendAllText($diagPath, $line)
    }
    catch {}
}

#Main wrapper for Write-Progress.  This allows all params, and catches any errors
Function Write-Progress2 {

    try {
        # write-host -NoNewline "$hideCursor"
        Write-Progress2Impl @Args @PSBoundParameters | out-null
    }
    catch {
        Write-Exception -ExceptionInfo $_
        write-Log "Write-Progress $args $_"
    }
}

#Sub Wrapper for Write-Progress.  This allows PercentComplete to be modified, and can log the activity in verbose
#We can also add additional params here if needed. (eg -NoLog)
Function Write-Progress2Impl {
    [CmdletBinding(HelpUri = 'https://go.microsoft.com/fwlink/?LinkID=2097036', RemotingCapability = 'None')]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]
        ${Activity},

        [Parameter(Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string]
        ${Status},

        [Parameter(Position = 2)]
        [ValidateRange(0, 2147483647)]
        [int]
        ${Id},

        #[ValidateRange(-1, 100)]
        [int]
        ${PercentComplete},

        [int]
        ${SecondsRemaining},

        [string]
        ${CurrentOperation},

        [ValidateRange(-1, 2147483647)]
        [int]
        ${ParentId},

        [switch]
        ${Completed},

        [int]
        ${SourceId},

        [switch]
        ${force},

        [switch]
        ${log}
    )
    dynamicparam {

        try {
            $targetCmd = $ExecutionContext.InvokeCommand.GetCommand('Microsoft.PowerShell.Utility\Write-Progress', [System.Management.Automation.CommandTypes]::Cmdlet, $PSBoundParameters)
            $dynamicParams = @($targetCmd.Parameters.GetEnumerator() | Microsoft.PowerShell.Core\Where-Object { $_.Value.IsDynamic })
            if ($dynamicParams.Length -gt 0) {
                $paramDictionary = [Management.Automation.RuntimeDefinedParameterDictionary]::new()
                foreach ($param in $dynamicParams) {
                    $param = $param.Value

                    if (-not $MyInvocation.MyCommand.Parameters.ContainsKey($param.Name)) {
                        $dynParam = [Management.Automation.RuntimeDefinedParameter]::new($param.Name, $param.ParameterType, $param.Attributes)
                        $paramDictionary.Add($param.Name, $dynParam)
                    }
                }

                return $paramDictionary
            }
        }
        catch {
            throw
        }

    }
    begin {

        try {
            $Percent = $null
            if ($PSBoundParameters.TryGetValue('PercentComplete', [ref]$Percent)) {
                if ($Percent -le 1) {
                    $Percent = 1
                }
                if ($Percent -ge 100) {
                    $Percent = 99
                }
                $PSBoundParameters['PercentComplete'] = $percent
            }
            $outBuffer = $null
            if ($PSBoundParameters.TryGetValue('OutBuffer', [ref]$outBuffer)) {
                $PSBoundParameters['OutBuffer'] = 1
            }

            $forcevalue = $null
            if ($force -or $PSBoundParameters.TryGetValue('force', [ref]$forcevalue)) {
                $PSBoundParameters.remove("force")
                $force = $true

                # Diagnostic: count how often the -force path runs (i.e. how often
                # progress is rendered with ProgressPreference set to 'Continue').
                if ($global:ProgressDiag) {
                    if (-not $global:ProgressForceFlips) { $global:ProgressForceFlips = 0 }
                    $global:ProgressForceFlips++
                    Write-ProgressDiagLog ("[ForceFlip] tid={0} useLocalPref={1} Activity={2}" -f [System.Threading.Thread]::CurrentThread.ManagedThreadId, ($global:ProgressForceUseLocalPref -ne $false), $Activity)
                }

                # Root-cause fix for Phase 2 orphan progress bars: PS7 auto-renders a
                # background job's RAW progress records whenever the PARENT session's
                # $Global:ProgressPreference is 'Continue'. The old code flipped $Global
                # to 'Continue' to render our managed bar, which opened a race where any
                # child-job DataAdded callback surfaced an orphan bar (no VM-name prefix)
                # at the bottom of the screen. Setting a FUNCTION-LOCAL $ProgressPreference
                # instead lets the steppable Write-Progress (invoked in this scope) render
                # our bar while $Global stays 'SilentlyContinue', so the auto-render path
                # never fires. Set $global:ProgressForceUseLocalPref = $false to restore
                # the old global-flip behavior (used for A/B repro of the orphan bug).
                if ($global:ProgressForceUseLocalPref -ne $false) {
                    $ProgressPreference = 'Continue'
                }
                else {
                    $OriginalProgressPreference = $Global:ProgressPreference
                    $Global:ProgressPreference = 'Continue'
                }
            }

            $logvalue = $null
            $writeLog = $false
            if ($log -eq $true -or $PSBoundParameters.TryGetValue('log', [ref]$logvalue)) {
                $PSBoundParameters.remove("log")
                $writeLog = $true
            }

            $Activityvalue = $null
            if ($PSBoundParameters.TryGetValue('Activity', [ref]$Activityvalue)) {
                $Activityvalue = $Activity.Trim()
                $Activityvalue = "  " + $Activityvalue
                $PSBoundParameters['Activity'] = $Activityvalue
            }

            $StatusValue = $null
            if ($PSBoundParameters.TryGetValue('Status', [ref]$StatusValue)) {
                if ([string]::IsNullOrWhiteSpace($StatusValue)) {
                    # A whitespace-only Status (e.g. PS remoting's built-in
                    # "Preparing modules for first use." record forwarded by
                    # Invoke-VmCommand) trims to an empty string, which the wrapped
                    # Write-Progress rejects via ValidateNotNullOrEmpty and throws on
                    # every record. Status is optional, so drop it instead of failing.
                    $PSBoundParameters.Remove('Status') | Out-Null
                    $Status = $null
                }
                else {
                    $StatusValue = $StatusValue.TrimEnd()
                    $PSBoundParameters['Status'] = $StatusValue
                }
            }

            if ($writeLog) {
                Write-Log "Activity: $Activity  Status: $Status" -LogOnly
            }
            else {
                if ($Global:LastStatus -ne $Status + $Percent) {
                    Write-Log "Write-Status: Activity: $Activity  Status: $Status Percent: $Percent" -verbose -LogOnly
                    $Global:LastStatus = $Status + $Percent
                }
            }

            $wrappedCmd = $ExecutionContext.InvokeCommand.GetCommand('Microsoft.PowerShell.Utility\Write-Progress', [System.Management.Automation.CommandTypes]::Cmdlet)
            $scriptCmd = { & $wrappedCmd @PSBoundParameters }
            $steppablePipeline = $scriptCmd.GetSteppablePipeline($myInvocation.CommandOrigin)
            $steppablePipeline.Begin($PSCmdlet)
        }
        catch {
            throw
        }

    }
    process {

        try {
            if ($Activity) {
                $Activity = $Activity.TrimEnd()
                if ($Activity.Contains("`n")) {
                    Write-Log "$Activity contains new-line"
                }
            }
            if ($Status) {
                $Status = $Status.TrimEnd()
                if ($Status.Contains("`n")) {
                    Write-Log "$Status contains new-line"
                }
            }

            if ($PercentComplete -le 1) {
                $PercentComplete = 1
            }
            if ($PercentComplete -ge 100) {
                $PercentComplete = 99
            }

            if ($force) {
                $steppablePipeline.Process($_)
                # Only the global-flip path needs restoring; the function-local
                # $ProgressPreference path is discarded automatically at function exit.
                if ($global:ProgressForceUseLocalPref -eq $false) {
                    $Global:ProgressPreference = $OriginalProgressPreference
                }
            }
            else {
                $steppablePipeline.Process($_)
            }
        }
        catch {
            throw
        }

    }
    end {

        try {
            $steppablePipeline.End()
        }
        catch {
            throw
        }

    }
}

# ---------------------------------------------------------------------------
# Buffered logging + rotation
# ---------------------------------------------------------------------------
# Write-Log historically opened/closed a file handle on every call (Out-File
# -Append). With the genconfig menu redraw loop firing dozens of Write-Log
# calls per refresh, that's the dominant cost. We now batch lines per-process
# into an in-memory StringBuilder and flush them in larger chunks via
# [System.IO.File]::AppendAllText. Rotation keeps a bounded history so the
# file doesn't grow without bound between sessions.
#
# Tunables (chosen to keep menu work in-memory while still surfacing useful
# data quickly when something goes wrong):
$Script:LogBufferMaxBytes      = 16KB    # flush after this much pending text
$Script:LogBufferMaxAgeSeconds = 2       # flush at least this often
$Script:LogRotateMaxBytes      = 2MB     # rotate when log exceeds this size
$Script:LogRotateKeep          = 3       # number of historical .1/.2/.3 files
$Script:LogRotateCheckEverySec = 5       # don't stat the file more than this
$Script:LogBufferHardCapBytes  = 8MB     # give up buffering past this (leaves a marker)
$Script:LogRotateExitRegistered = $false
# Buffer state lives in $global: so the engine-exit Action scriptblock (which
# runs in its own scope) can still see and flush it.
if (-not $global:LogBuffers) { $global:LogBuffers = @{} }

# --- Structured JSON log sidecar (<logbase>.jsonl) -------------------------
# Alongside the CMTrace .log (kept for CMTrace / OneTrace / the memlabs log
# viewer), we emit a lean newline-delimited JSON file that is trivial for AI /
# grep / jq to consume. It carries ONLY the non-redundant fields: the CMTrace
# line's split date+time collapse to a single ISO-8601 UTC 't', and its
# duplicated component/context/file fields collapse to one 'comp' (+ 'at'
# file:line on non-INFO lines only). See Write-Log for the exact schema.
# Enabled by default; set $env:MEMLABS_JSON_LOG=0 (or 'false'/'off') to disable.
$Script:JsonLogEnabled = -not ($env:MEMLABS_JSON_LOG -in @('0', 'false', 'False', 'off'))
# One run id per process, tagged onto every line so an agent can group a run.
# Honors an inherited $env:MEMLABS_RUN_ID so child job processes can share it.
if (-not $global:MemLabsRunId) {
    $global:MemLabsRunId = $env:MEMLABS_RUN_ID
    if (-not $global:MemLabsRunId) {
        $global:MemLabsRunId = '{0:yyyyMMdd-HHmmss}-{1}' -f (Get-Date), $PID
    }
}

function Get-JsonLogEscaped {
    # Minimal RFC-8259 string escaping for a single JSON value. The text has
    # already been stripped of control/non-ASCII chars (except TAB) upstream in
    # Write-Log, so in practice this only escapes ", \ and TAB -- but it stays
    # correct for any residual control char.
    param([string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return '' }
    $sb = [System.Text.StringBuilder]::new($Value.Length + 8)
    foreach ($ch in $Value.ToCharArray()) {
        switch ($ch) {
            '"' { [void]$sb.Append('\"') }
            '\' { [void]$sb.Append('\\') }
            "`n" { [void]$sb.Append('\n') }
            "`r" { [void]$sb.Append('\r') }
            "`t" { [void]$sb.Append('\t') }
            default {
                if ([int]$ch -lt 32) { [void]$sb.Append(('\u{0:x4}' -f [int]$ch)) }
                else { [void]$sb.Append($ch) }
            }
        }
    }
    return $sb.ToString()
}

function Get-LogBufferEntry {
    param([string]$Path)
    if (-not $global:LogBuffers.ContainsKey($Path)) {
        $global:LogBuffers[$Path] = [PSCustomObject]@{
            Builder      = [System.Text.StringBuilder]::new()
            LastFlushUtc = [DateTime]::UtcNow
            LastRotateCheckUtc = [DateTime]::MinValue
        }
    }
    return $global:LogBuffers[$Path]
}

function Add-LogBufferText {
    # The Builder is the lock object shared with Flush-LogBuffer and the C#
    # MemLabs.LogFlusher timer callback. StringBuilder is not thread-safe, and an
    # Append landing between the flusher's ToString() and its clear used to vanish.
    param([object]$Entry, [string]$Text)
    [System.Threading.Monitor]::Enter($Entry.Builder)
    try { [void]$Entry.Builder.Append($Text) }
    finally { [System.Threading.Monitor]::Exit($Entry.Builder) }
}

function Add-LogTextToFile {
    # Keep AppendAllText's exclusive FileShare.Read. Opening with FileShare.ReadWrite
    # lets several job processes append at once, and FileMode.Append fixes each
    # writer's offset at OPEN time, so they overwrite each other with no exception --
    # measured 144 records silently clobbered across 8 writers. Let the OS reject the
    # second writer and retry: a sharing violation must cost latency, not a record.
    param([string]$Path, [string]$Text, [int]$Attempts = 12)
    for ($i = 1; $i -le $Attempts; $i++) {
        try {
            [System.IO.File]::AppendAllText($Path, $Text, [System.Text.Encoding]::UTF8)
            return
        }
        catch [System.IO.IOException] {
            if ($i -eq $Attempts) { throw }
            Start-Sleep -Milliseconds (10 * $i)
        }
    }
}

function Invoke-LogRotateIfNeeded {
    param([string]$Path)
    # Only rotate the base VMBuild.log (menu log). Domain-specific deploy
    # logs (VMBuild.<domain>.log) get a fresh file per deployment via the
    # timestamp-rename in New-Lab.ps1 and should never be split mid-build.
    if ($Path -notmatch '[/\\]VMBuild\.(log|jsonl)$') { return }
    try {
        $entry = $global:LogBuffers[$Path]
        if ($entry) {
            $age = ([DateTime]::UtcNow - $entry.LastRotateCheckUtc).TotalSeconds
            if ($age -lt $Script:LogRotateCheckEverySec) { return }
            $entry.LastRotateCheckUtc = [DateTime]::UtcNow
        }
        $fi = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
        if (-not $fi -or $fi.Length -lt $Script:LogRotateMaxBytes) { return }
        $keep = $Script:LogRotateKeep
        $oldest = "$Path.$keep"
        if (Test-Path -LiteralPath $oldest) {
            Remove-Item -LiteralPath $oldest -Force -ErrorAction SilentlyContinue
        }
        for ($i = $keep - 1; $i -ge 1; $i--) {
            $src = "$Path.$i"
            $dst = "$Path.$($i + 1)"
            if (Test-Path -LiteralPath $src) {
                Move-Item -LiteralPath $src -Destination $dst -Force -ErrorAction SilentlyContinue
            }
        }
        Move-Item -LiteralPath $Path -Destination "$Path.1" -Force -ErrorAction SilentlyContinue
    }
    catch {
        # Concurrent writers from background jobs may race here; ignore.
    }
}

function Flush-LogBuffer {
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '',
        Justification = 'Established internal helper name; renaming would touch many call sites across the codebase.')]
    param(
        [Parameter(ParameterSetName = 'Path')]
        [string]$Path,
        [Parameter(ParameterSetName = 'All')]
        [switch]$All
    )
    if ($All.IsPresent) {
        foreach ($p in @($global:LogBuffers.Keys)) {
            Flush-LogBuffer -Path $p
        }
        return
    }
    if ([string]::IsNullOrEmpty($Path)) { return }
    if (-not $global:LogBuffers.ContainsKey($Path)) { return }
    $entry = $global:LogBuffers[$Path]
    if ($entry.Builder.Length -eq 0) { return }
    # Hold the lock across drain AND write. Releasing before the write would let the
    # timer thread and the main thread interleave chunks out of order, and clearing
    # before the write is what silently lost records: on a sharing violation the text
    # was already gone. Clear ONLY after the append succeeds.
    [System.Threading.Monitor]::Enter($entry.Builder)
    try {
        if ($entry.Builder.Length -eq 0) { return }
        $text = $entry.Builder.ToString()
        $written = $text.Length
        try {
            Invoke-LogRotateIfNeeded -Path $Path
            Add-LogTextToFile -Path $Path -Text $text
            # Remove only what was written, not Length=0: the C# timer callback cannot
            # take this lock (Add-Type has no System.Threading) so it may have drained
            # part of the buffer concurrently.
            if ($written -gt $entry.Builder.Length) { $written = $entry.Builder.Length }
            [void]$entry.Builder.Remove(0, $written)
            $entry.LastFlushUtc = [DateTime]::UtcNow
        }
        catch {
            # Keep the text buffered so the next flush retries it. Only a hard cap
            # discards, and it leaves a marker so the gap is visible in the file
            # itself once writes resume -- a dropped chunk must never be silent.
            if ($entry.Builder.Length -gt $Script:LogBufferHardCapBytes) {
                $lost = $entry.Builder.Length
                $entry.Builder.Length = 0
                [void]$entry.Builder.AppendLine(
                    "*** MemLabs logging DROPPED $lost buffered chars for $Path : $($_.Exception.Message) ***")
                $entry.LastFlushUtc = [DateTime]::UtcNow
            }
        }
    }
    finally { [System.Threading.Monitor]::Exit($entry.Builder) }
}

function Register-LogBufferExitFlush {
    # Global, NOT $Script:. New-Lab.ps1 dot-sources Common.ps1 from its OWN script
    # scope and Start-Test invokes New-Lab once per test in a single shell, so a
    # $Script: flag is fresh every build and the guard never fires -- verified
    # accumulating 1 subscriber per invocation in temp/probe-exitevent-accumulation.ps1.
    # Each leaked subscriber costs ~0.3MB and shows up in Get-Job as a PSEventJob.
    if ($global:MemLabsExitFlushRegistered) { return }
    try {
        Register-EngineEvent -SourceIdentifier ([System.Management.Automation.PsEngineEvent]::Exiting) -Action {
            try {
                # Stop the verbose tail window
                if ($global:Common.VerboseTailProcess -and -not $global:Common.VerboseTailProcess.HasExited) {
                    try { $global:Common.VerboseTailProcess.Kill() } catch { }
                    $global:Common.VerboseTailProcess = $null
                }
                # Stop the background flush timer before final flush
                if ($global:LogFlushTimer) {
                    $global:LogFlushTimer.Dispose()
                    $global:LogFlushTimer = $null
                }
                foreach ($p in @($global:LogBuffers.Keys)) {
                    $entry = $global:LogBuffers[$p]
                    if ($entry -and $entry.Builder.Length -gt 0) {
                        try {
                            [System.Threading.Monitor]::Enter($entry.Builder)
                            try {
                                Add-LogTextToFile -Path $p -Text $entry.Builder.ToString()
                                $entry.Builder.Length = 0
                            }
                            finally { [System.Threading.Monitor]::Exit($entry.Builder) }
                        } catch { }
                    }
                }
            } catch { }
        } | Out-Null
        $global:MemLabsExitFlushRegistered = $true
    }
    catch {
        # Non-fatal; we still flush at size/age thresholds and on important
        # messages, so worst case is a few buffered lines lost on abrupt exit.
    }

    # Start a background timer that flushes log buffers on a threadpool thread.
    # This ensures entries reach disk even when the main thread is blocked in a
    # long-running CIM call (Get-VM, Get-VMNetworkAdapter, Set-VM, etc.).
    # IMPORTANT: The callback must be pure .NET (no PowerShell ScriptBlocks) —
    # threadpool threads have no Runspace and will crash the process otherwise.
    # NOTE: Skip on PS5 — the TimerCallback cast from a static method doesn't
    # work reliably, and this is not needed for short-lived DSC zip generation.
    if (-not $global:LogFlushTimer -and $PSVersionTable.PSVersion.Major -ge 7) {
        # Compile a tiny C# class that holds the flush logic. This runs on the
        # threadpool without needing a PowerShell Runspace.
        if (-not ([System.Management.Automation.PSTypeName]'MemLabs.LogFlusher').Type) {
            $smaAssembly = [System.Management.Automation.PSObject].Assembly.Location
            Add-Type -Language CSharp -ReferencedAssemblies @($smaAssembly) -TypeDefinition @'
using System;
using System.Collections;
using System.IO;
using System.Management.Automation;
using System.Text;

namespace MemLabs {
    public static class LogFlusher {
        public static void Flush(object state) {
            try {
                var buffers = state as Hashtable;
                if (buffers == null) return;
                // Snapshot keys to avoid modification during enumeration
                var keys = new object[buffers.Count];
                buffers.Keys.CopyTo(keys, 0);
                foreach (var key in keys) {
                    var path = key as string;
                    if (path == null) continue;
                    var pso = buffers[key] as PSObject;
                    if (pso == null) continue;
                    var builderProp = pso.Properties["Builder"];
                    if (builderProp == null) continue;
                    var sb = builderProp.Value as StringBuilder;
                    if (sb == null || sb.Length == 0) continue;
                    // This callback cannot lock (Add-Type's reference set has no
                    // System.Threading), so it must never race the PowerShell flush:
                    // both draining the same text duplicates records -- measured 205
                    // dupes across 20 writers. Its only job is getting data out when the
                    // main thread is wedged, and PowerShell flushes every couple of
                    // seconds, so act only on a buffer that has gone stale. In normal
                    // operation this never fires.
                    var lastProp = pso.Properties["LastFlushUtc"];
                    if (lastProp == null || !(lastProp.Value is DateTime)) continue;
                    if ((DateTime.UtcNow - (DateTime)lastProp.Value).TotalSeconds < 30) continue;
                    string text = sb.ToString();
                    int written = text.Length;
                    try {
                        // Exclusive append (FileShare.Read). Sharing FileShare.ReadWrite
                        // makes concurrent appenders clobber one another silently.
                        File.AppendAllText(path, text, Encoding.UTF8);
                        // Remove only what was written: an append landing mid-flush sits
                        // past this index and must survive.
                        if (written > sb.Length) written = sb.Length;
                        sb.Remove(0, written);
                        lastProp.Value = DateTime.UtcNow;
                    } catch {
                        // Contended: leave it buffered, the PowerShell path retries.
                    }
                }
            } catch { }
        }
    }
}
'@
        }
        [System.Threading.TimerCallback]$flushCallback = [MemLabs.LogFlusher]::Flush
        $global:LogFlushTimer = [System.Threading.Timer]::new(
            $flushCallback,
            $global:LogBuffers,  # state object passed to callback
            2000,                # initial delay (ms)
            2000                 # period (ms) — flush every 2 seconds
        )
    }
}

function Start-VerboseTailWindow {
    <#
    .SYNOPSIS
    Spawns a secondary PowerShell window that tails the log file for verbose entries.
    #>
    if (-not $Common.LogPath -or -not (Test-Path $Common.LogPath)) {
        Write-Log "Cannot start verbose tail window: log file not found." -Warning
        return
    }
    if ($Common.VerboseTailProcess -and -not $Common.VerboseTailProcess.HasExited) {
        Write-Log "Verbose tail window is already running (PID $($Common.VerboseTailProcess.Id))." -Verbose
        return
    }

    $logPath = $Common.LogPath
    # Build a self-contained script that tails the log and extracts verbose
    # entries from the CMTrace XML format (type="0").
    $tailScript = @"
`$host.UI.RawUI.WindowTitle = 'MemLabs Verbose Output'
Write-Host 'Tailing verbose entries from:' -ForegroundColor Cyan
Write-Host '  $logPath' -ForegroundColor Cyan
Write-Host ('  Started: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) -ForegroundColor Cyan
Write-Host ''
Get-Content -LiteralPath '$logPath' -Wait -Tail 0 | ForEach-Object {
    if (`$_ -match 'type="0"' -and `$_ -match '<!\[LOG\[(.+?)\]LOG\]') {
        `$msg = `$Matches[1]
        `$ts = if (`$_ -match 'time="([^"]+)"') { `$Matches[1].Substring(0,12) } else { '' }
        `$comp = if (`$_ -match 'component="([^"]+)"') { `$Matches[1] } else { '' }
        Write-Host "`$ts [`$comp] `$msg" -ForegroundColor DarkGray
    }
}
"@
    $tempScript = Join-Path $env:TEMP "memlabs-verbose-tail.ps1"
    Set-Content -LiteralPath $tempScript -Value $tailScript -Encoding UTF8 -Force

    $psExe = if ($Common.PS7) { "pwsh.exe" } else { "powershell.exe" }
    $Common.VerboseTailProcess = Start-Process $psExe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$tempScript`"" `
        -PassThru -ErrorAction SilentlyContinue

    if ($Common.VerboseTailProcess) {
        Write-Log "Started verbose tail window (PID $($Common.VerboseTailProcess.Id))." -LogOnly
    }
    else {
        Write-Log "Failed to start verbose tail window." -Warning
    }
}

function Stop-VerboseTailWindow {
    <#
    .SYNOPSIS
    Stops the secondary verbose tail window if it is still running.
    #>
    if ($Common.VerboseTailProcess -and -not $Common.VerboseTailProcess.HasExited) {
        try {
            $Common.VerboseTailProcess.Kill()
            $Common.VerboseTailProcess = $null
        }
        catch { }
    }
    # Clean up temp script
    $tempScript = Join-Path $env:TEMP "memlabs-verbose-tail.ps1"
    if (Test-Path $tempScript) {
        Remove-Item -LiteralPath $tempScript -Force -ErrorAction SilentlyContinue
    }
}

function ConvertTo-MemLabsVersion {
    <#
    .SYNOPSIS
        Normalise a MemLabs / hotfix version string into something that compares numerically.
    .DESCRIPTION
        These versions are yymmdd with an optional .n counter, and they were being compared and
        sorted as STRINGS. That is right up to nine builds in a day and wrong from the tenth:
        "260811.10" -lt "260811.9" is $true lexically, so the newer build looks older.

        A plain [version] cast is not the fix -- it throws on the bare yymmdd form, which is 11
        of the 15 FixVersion values in the tree. Pad to major.minor first, then cast.

        Anything absent or unparseable floors to 0.0 so it sorts below every real version. That
        keeps today's behaviour for a VM note with no recorded version: it looks older than the
        fix and therefore still gets the work, rather than silently being treated as current.
    #>
    param([string]$Version)

    if ([string]::IsNullOrWhiteSpace($Version)) { return [version]'0.0' }
    $candidate = $Version.Trim()
    if ($candidate -notmatch '^\d+(\.\d+)*$') { return [version]'0.0' }
    if ($candidate -notmatch '\.') { $candidate = "$candidate.0" }
    try { return [version]$candidate } catch { return [version]'0.0' }
}

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Text,
        [Parameter(Mandatory = $false)]
        [switch]$Warning,
        [Parameter(Mandatory = $false)]
        [switch]$Failure,
        [Parameter(Mandatory = $false)]
        [switch]$Success,
        [Parameter(Mandatory = $false)]
        [switch]$Activity,
        [Parameter(Mandatory = $false)]
        [switch]$NoNewLine,
        [Parameter(Mandatory = $false)]
        [switch]$Highlight,
        [Parameter(Mandatory = $false)]
        [switch]$SubActivity,
        [Parameter(Mandatory = $false)]
        [switch]$LogOnly,
        [Parameter(Mandatory = $false)]
        [switch]$OutputStream,
        [Parameter(Mandatory = $false)]
        [switch]$HostOnly,
        [Parameter(Mandatory = $false)]
        [switch]$NoIndent,
        [Parameter(Mandatory = $false)]
        [switch]$ShowNotification
    )

    $HashArguments = @{}

    $info = $true
    $logLevel = 1    # 0 = Verbose, 1 = Info, 2 = Warning, 3 = Error

    # Fast path: if this is a -Verbose call and verbose logging is disabled, do nothing.
    # Skipping here avoids two Get-PSCallStack walks plus Text/string formatting per call,
    # which is significant in hot paths like menu rendering where Write-Log -Verbose is
    # invoked dozens of times per redraw. -ShowNotification still needs to fire even when
    # verbose is off, so don't short-circuit when it's set.
    if ($MyInvocation.BoundParameters["Verbose"].IsPresent `
            -and -not $Common.VerboseEnabled `
            -and -not $ShowNotification.IsPresent `
            -and -not $OutputStream.IsPresent) {
        return
    }

    # Get caller function name and add it to Text
    try {
        $caller = (Get-PSCallStack | Select-Object Command, Location, Arguments)[1].Command
        if ($caller -and $caller -like "*.ps1") { $caller = $caller -replace ".ps1", "" }
        if (-not $caller) { $caller = "<Script>" }
    }
    catch {
        $caller = "<Script>"
    }

    if ($caller -eq "<ScriptBlock>") {
        if ($global:ScriptBlockName) {
            $caller = $global:ScriptBlockName
        }
    }

    if ($Text -is [string]) { $Text = $Text.ToString().Trim() }
    # $Text = "[$caller] $Text"

    if ($ShowNotification.IsPresent) {
        Show-Notification -ToastText $Text
    }

    # Is Verbose?
    $IsVerbose = $false
    if ($MyInvocation.BoundParameters["Verbose"].IsPresent) {
        $IsVerbose = $true
    }

    If ($Success.IsPresent) {
        $info = $false
        $TextOutput = "  SUCCESS: $Text"
        # $Text = "SUCCESS: $Text"
        $HashArguments.Add("ForegroundColor", "Chartreuse")
    }

    If ($Activity.IsPresent) {
        $info = $false
        Set-TitleBar $Text
        if ($NoNewLine.IsPresent) {
            $Text = "$($common.ActivityHeader) $Text"
        }
        else {
            Write-Host
            $Text = "$($common.ActivityHeader) $Text`r`n"
        }

        $HashArguments.Add("ForegroundColor", "DeepSkyBlue")
    }

    If ($SubActivity.IsPresent -and -not $Activity.IsPresent) {
        $info = $false
        $Text = "  $($common.SubActivityHeader) $Text"

        $HashArguments.Add("ForegroundColor", "LightSkyBlue")
    }

    If ($Warning.IsPresent) {
        $info = $false
        $logLevel = 2
        $TextOutput = "  WARNING: $Text"
        # $Text = "WARNING: $Text"
        $HashArguments.Add("ForegroundColor", "Yellow")

    }

    If ($Failure.IsPresent) {
        $info = $false
        $logLevel = 3
        $TextOutput = "  ERROR: $Text"
        # $Text = "ERROR: $Text"
        $HashArguments.Add("ForegroundColor", "Red")

    }

    If ($IsVerbose) {
        $info = $false
        $logLevel = 0
        #callstack = Get-PSCallStack
        $TextOutput = "  VERBOSE: $Text"
        # $Text = "VERBOSE: $Text"
    }

    If ($Highlight.IsPresent) {
        $info = $false
        Write-Host
        if ($Common.PS7) {
            $Text = "  ╱╱╱ $Text"
        }
        else {
            $Text = "  +++ $Text"
        }
        $HashArguments.Add("ForegroundColor", "DeepSkyBlue")
    }

    if ($info) {
        $HashArguments.Add("ForegroundColor", "White")
        $TextOutput = "  $Text"
        #$Text = "INFO: $Text"
    }

    # Write to output stream
    if ($OutputStream.IsPresent) {
        $Output = [PSCustomObject]@{
            Text     = $text
            Loglevel = $logLevel
        }
        if ($HashArguments) {
            foreach ($arg in $HashArguments.Keys) {
                $Output | Add-Member -MemberType NoteProperty -Name $arg -Value $HashArguments[$arg] -Force
            }
        }

        Write-Output $Output
    }

    # Write progress if output stream and failure present
    if ($OutputStream.IsPresent -and $Failure.IsPresent) {
        Write-Error $Text
        Write-Progress -Activity $Text -Status "Failed :-(" -Completed
    }

    # Write to console, if not logOnly and not OutputStream
    $writeHost = $false
    If (-not $LogOnly.IsPresent -and -not $OutputStream.IsPresent -and -not $IsVerbose) {
        $writeHost = $true
    }

    # Always log verbose to host, if VerboseEnabled and not suppressed for menus
    if ($IsVerbose -and $Common.VerboseEnabled -and -not $Common.VerboseToLogOnly) {
        $writeHost = $true
    }

    # Suppress write-host when in-job
    if ($InJob.IsPresent) {
        $writeHost = $false
    }

    if ($writeHost) {
        if ($TextOutput) {
            if ($NoIndent.IsPresent) {
                $TextOutput = $TextOutput.Trim()
            }
            Write-Host2 $TextOutput @HashArguments
        }
        else {
            Write-Host2 $Text @HashArguments
        }
    }

    # Write to log, non verbose entries
    $write = $false
    if (-not $HostOnly.IsPresent -and -not $IsVerbose) {
        $write = $true
    }

    # Write verbose entries, if verbose logging enabled
    if ($IsVerbose -and $Common.VerboseEnabled) {
        $write = $true
    }

    if ($write) {
        $Text = $Text.ToString().Trim()

        # Strip non-printable / non-ASCII characters (emoji, box-drawing, etc.)
        # before writing to the log. Some upstream output paths (e.g. captured
        # stdout from native processes, or Out-String through a non-UTF8 host)
        # convert these to literal '?' chars, which then show up as runs like
        # "?????????" in the log viewer. Drop them entirely, then collapse any
        # remaining '?' runs that resulted from earlier lossy conversions.
        # Single '?' in normal prose (e.g. "Continue?") is preserved.
        $Text = [System.Text.RegularExpressions.Regex]::Replace($Text, '[^\x09\x20-\x7E]', '')
        $Text = [System.Text.RegularExpressions.Regex]::Replace($Text, '\?{2,}', '')
        $Text = $Text.Trim()

        try {
            $CallingFunction = Get-PSCallStack | Select-Object -first 2 | select-object -last 1
            $context = $CallingFunction.Command
            $file = $CallingFunction.Location
            $tid = [System.Threading.Thread]::CurrentThread.ManagedThreadId
            $date = Get-Date -Format 'MM-dd-yyyy'
            $time = Get-Date -Format 'HH:mm:ss.fff'

            $logText = "<![LOG[$Text]LOG]!><time=""$time"" date=""$date"" component=""$caller"" context=""$context"" type=""$logLevel"" thread=""$tid"" file=""$file"">"

            # Buffer instead of opening the file per-call. The buffer is flushed
            # on size/age thresholds, on important messages (Warning/Failure/
            # Activity/SubActivity/Highlight) so users see them promptly even
            # before a crash, and on engine exit.
            $logPath = $Common.LogPath
            if ($logPath) {
                $entry = Get-LogBufferEntry -Path $logPath
                Add-LogBufferText -Entry $entry -Text ($logText + [Environment]::NewLine)

                $forceFlush = $Warning.IsPresent -or $Failure.IsPresent `
                    -or $Activity.IsPresent -or $SubActivity.IsPresent `
                    -or $Highlight.IsPresent
                $sizeFlush = $entry.Builder.Length -ge $Script:LogBufferMaxBytes
                $ageFlush = ([DateTime]::UtcNow - $entry.LastFlushUtc).TotalSeconds `
                    -ge $Script:LogBufferMaxAgeSeconds

                if ($forceFlush -or $sizeFlush -or $ageFlush) {
                    Flush-LogBuffer -Path $logPath
                }

                # Lean JSON sidecar line (<logbase>.jsonl). Reuses the same
                # buffer + flush machinery keyed by the .jsonl path, so the
                # size/age/force/exit flush and Flush-LogBuffer -All all cover
                # it for free. Only non-redundant fields are emitted; 'at' is
                # added just for WARN/ERROR/VERBOSE (the lines you investigate)
                # so bulk INFO stays compact.
                if ($Script:JsonLogEnabled) {
                    $jsonPath = [System.IO.Path]::ChangeExtension($logPath, '.jsonl')
                    $lvlName = switch ($logLevel) { 0 { 'VERBOSE' } 2 { 'WARN' } 3 { 'ERROR' } default { 'INFO' } }
                    $domVal = $null
                    $leaf = [System.IO.Path]::GetFileName($logPath)
                    if ($leaf -match '^VMBuild\.(.+)\.log$') { $domVal = $Matches[1] }
                    $jb = [System.Text.StringBuilder]::new(192)
                    [void]$jb.Append('{"t":"').Append([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')).Append('"')
                    [void]$jb.Append(',"lvl":"').Append($lvlName).Append('"')
                    [void]$jb.Append(',"comp":"').Append((Get-JsonLogEscaped $caller)).Append('"')
                    if ($domVal) { [void]$jb.Append(',"dom":"').Append((Get-JsonLogEscaped $domVal)).Append('"') }
                    [void]$jb.Append(',"run":"').Append($global:MemLabsRunId).Append('"')
                    if ($tid -and $tid -ne 1) { [void]$jb.Append(',"tid":').Append($tid) }
                    if ($logLevel -ne 1 -and $file) {
                        $atVal = ($file -replace ':\s*line\s*', ':').Trim()
                        if ($atVal) { [void]$jb.Append(',"at":"').Append((Get-JsonLogEscaped $atVal)).Append('"') }
                    }
                    [void]$jb.Append(',"msg":"').Append((Get-JsonLogEscaped $Text)).Append('"}')

                    $jsonEntry = Get-LogBufferEntry -Path $jsonPath
                    Add-LogBufferText -Entry $jsonEntry -Text ($jb.ToString() + "`n")
                    $jsonAge = ([DateTime]::UtcNow - $jsonEntry.LastFlushUtc).TotalSeconds
                    if ($forceFlush -or $jsonEntry.Builder.Length -ge $Script:LogBufferMaxBytes -or $jsonAge -ge $Script:LogBufferMaxAgeSeconds) {
                        Flush-LogBuffer -Path $jsonPath
                    }
                }
            }
        }
        catch {
            try {
                # Last-resort direct append; ignore failure.
                if ($logText -and $Common -and $Common.LogPath) {
                    $logText | Out-File -LiteralPath $Common.LogPath -Append -ErrorAction SilentlyContinue -Encoding utf8
                }
            }
            catch {
                # ignore
            }
        }
    }
}

function Show-Notification {
    [cmdletbinding()]
    Param (
        [string]
        $ToastTitle = "MEMLabs VMBuild",
        [string]
        [parameter(ValueFromPipeline)]
        $ToastText,
        [string]
        [parameter(ValueFromPipeline)]
        $ToastTag = "VMBuild"
    )

    if ($Common.PS7) { return } # Not supported on PS7

    [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] > $null
    $Template = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)

    $RawXml = [xml] $Template.GetXml()
    ($RawXml.toast.visual.binding.text | Where-Object { $_.id -eq "1" }).AppendChild($RawXml.CreateTextNode($ToastTitle)) > $null
    ($RawXml.toast.visual.binding.text | Where-Object { $_.id -eq "2" }).AppendChild($RawXml.CreateTextNode($ToastText)) > $null

    $SerializedXml = New-Object Windows.Data.Xml.Dom.XmlDocument
    $SerializedXml.LoadXml($RawXml.OuterXml)

    $Toast = [Windows.UI.Notifications.ToastNotification]::new($SerializedXml)
    $Toast.Tag = $ToastTag
    $Toast.Group = "VMBuild"
    $Toast.ExpirationTime = [DateTimeOffset]::Now.AddMinutes(1)

    $Notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("PowerShell")
    $Notifier.Show($Toast);
}

function Write-Exception {
    [CmdletBinding()]
    param (
        [Parameter()]
        $ExceptionInfo,
        [Parameter()]
        $AdditionalInfo
    )

    $guid = (New-Guid).Guid
    $crashFile = Join-Path $Common.CrashLogsPath "$guid.txt"

    $sb = [System.Text.StringBuilder]::new()

    $parentFunctionName = (Get-PSCallStack)[1].FunctionName
    $msg = "`n=== $parentFunctionName`: An error occurred: $ExceptionInfo"
    [void]$sb.AppendLine($msg)
    Write-Host2 $msg -ForegroundColor Red

    $msg = "`n=== Exception.ScriptStackTrace:`n"
    [void]$sb.AppendLine($msg)
    Write-Host2 $msg -ForegroundColor Red
    Write-Log -LogOnly $msg -Failure

    $msg = $ExceptionInfo.ScriptStackTrace
    [void]$sb.AppendLine($msg)
    $msg | Out-Host
    Write-Log -LogOnly $msg -Failure

    $msg = "`n=== Get-PSCallStack:`n"
    [void]$sb.AppendLine($msg)
    Write-Host2 $msg -ForegroundColor Red
    Write-Log -LogOnly $msg -Failure

    $msg = (Get-PSCallStack | Select-Object Command, Location, Arguments | Format-Table | Out-String).Trim()
    [void]$sb.AppendLine($msg)
    $msg | Out-Host
    Write-Log -LogOnly $msg -Failure
    if ($AdditionalInfo) {
        $msg = "`n=== Additional Information:`n"
        [void]$sb.AppendLine($msg)
        Write-Host2 "$msg" -ForegroundColor Red
        Write-Host "Dumped to $crashFile"
        Write-Log -LogOnly $msg -Failure
        Write-Log -LogOnly  "Dumped to $crashFile" -Failure
        $msg = ($AdditionalInfo | Out-String).Trim()
        [void]$sb.AppendLine($msg)
        Write-Log -LogOnly $msg -Failure
    }

    $sb.ToString() | Out-File -FilePath $crashFile -Force
    Write-Host
}

function Get-File {
    param(
        [Parameter(Mandatory = $false)]
        $Source,
        [Parameter(Mandatory = $false)]
        $Destination,
        [Parameter(Mandatory = $false)]
        $DisplayName,
        [Parameter(Mandatory = $false)]
        [ValidateSet("Downloading", "Copying")]
        $Action,
        [Parameter(Mandatory = $false)]
        [switch]$Silent,
        [Parameter(Mandatory = $false)]
        [switch]$RemoveIfPresent,
        [Parameter(Mandatory = $false)]
        [switch]$ForceDownload,
        [Parameter(Mandatory = $false)]
        [switch]$ResumeDownload,
        [Parameter(Mandatory = $false)]
        [switch]$UseCDN,
        [Parameter(Mandatory = $false)]
        [switch]$UseBITS,
        [Parameter(Mandatory = $false, ParameterSetName = "WhatIf")]
        [switch]$WhatIf
    )

    # Display name for source
    $sourceDisplay = $Source

    # ---- Add auth if source is a storage URL ----
    if ($Source -and $StorageConfig.StorageLocation -and $Source -like "$($StorageConfig.StorageLocation)*") {
        $sourceDisplay = Split-Path $sourceDisplay -Leaf

        # SAS auth — append token as query string
        $Source = "$Source`?$($StorageConfig.StorageToken)"

        if ($UseCDN.IsPresent) {
            $Source = $Source.Replace("blob.core.windows.net", "azureedge.net")
        }
    }

    # ---- WhatIf ----
    if ($WhatIf -and -not $Silent) {
        Write-Log "WhatIf: $Action $sourceDisplay file to $Destination"
        return $true
    }

    # ---- Parameter validation ----
    # Not mandatory to allow WhatIf to work with null values
    if (-not $Source -and -not $Destination) {
        Write-Log "Get-File: Source and Destination parameters must be specified." -Failure
        return $false
    }

    if (-not $Action) {
        Write-Log "Get-File: Action must be specified." -Failure
        return $false
    }

    # ---- Build transfer arguments ----
    $destinationFile = Split-Path $Destination -Leaf
    $isVhdxCopy = ($Action -eq "Copying") -and (
        ($Source -is [string] -and $Source.ToLower().EndsWith(".vhdx")) -or
        ($Destination -is [string] -and $Destination.ToLower().EndsWith(".vhdx"))
    )

    $HashArguments = @{
        Source      = $Source
        Destination = $Destination
        Description = "$Action $destinationFile"
    }

    if ($DisplayName) { $HashArguments["DisplayName"] = $DisplayName }

    if (-not $Silent) {
        Write-Log "$Action $sourceDisplay to $Destination... "
        if ($DisplayName) { Write-Log "$DisplayName" -LogOnly }
    }

    # ---- Remove existing file if requested ----
    if ($RemoveIfPresent.IsPresent -and (Test-Path $Destination)) {
        Remove-Item -Path $Destination -Force -Confirm:$false -WhatIf:$WhatIf -ProgressAction SilentlyContinue
    }

    # ---- Create destination directory if needed ----
    $destinationDirectory = Split-Path $Destination -Parent
    if (-not (Test-Path $destinationDirectory)) {
        New-Item -Path $destinationDirectory -ItemType Directory -Force | Out-Null
    }

    $OriginalProgressPreference = $Global:ProgressPreference
    $Global:ProgressPreference = 'Continue'

    try {
        $timedOut = $false

        # ---- Wait for any existing curl process to finish ----
        if ($Action -eq "Downloading") {
            $i = 0
            while (Get-Process -Name "curl" -ErrorAction SilentlyContinue) {
                Write-Log "Download for '$sourceDisplay' waiting on an existing download. Checking again in 2 minutes..." -Warning
                Start-Sleep -Seconds 120
                $i++
                if ($i -gt 5) {
                    Write-Log "Get-File: Timed out while waiting to download '$sourceDisplay'." -Failure
                    $timedOut = $true
                    break
                }
            }
        }

        if ($timedOut) {
            return $false
        }

        # ---- Skip re-download if file exists and no force/resume flags set ----
        if ($Action -eq "Downloading" -and (Test-Path $Destination) -and -not $ForceDownload.IsPresent -and -not $ResumeDownload.IsPresent) {
            Write-Log "Get-File: Download skipped. $Destination already exists." -LogOnly
            return $true
        }

        # ---- Perform transfer ----
        if ($Action -eq "Downloading") {
            if ($UseBITS) {
                try {
                    Start-BitsTransfer @HashArguments -Priority Foreground -ErrorAction Stop
                }
                catch {
                    Write-Log "Get-File: Start-BitsTransfer failed: $_" -LogOnly
                    if ($_ -match "the module could not be loaded") {
                        Write-Log "Get-File: Could not invoke Start-BitsTransfer due to load failure. Please close all PowerShell windows and retry." -Failure
                    }
                }
            }
            else {
                $worked = Start-CurlTransfer @HashArguments -Silent:$Silent
                if (-not $worked) {
                    Write-Log "Get-File: Failed to download '$sourceDisplay' using curl." -Failure
                    return $false
                }
            }
        }
        else {
            # Copying — always uses BITS
            # For VHDX files, verify we have enough free space on the destination drive.
            if ($isVhdxCopy) {
                if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
                    Write-Log "Get-File: Source VHDX '$Source' was not found." -Failure
                    return $false
                }

                try {
                    $requiredBytes = [int64](Get-Item -LiteralPath $Source -ErrorAction Stop).Length
                    $destinationDrive = Get-PSDrive -Name (Get-Item -LiteralPath $destinationDirectory -ErrorAction Stop).PSDrive.Name -ErrorAction Stop
                    $freeBytes = [int64]$destinationDrive.Free

                    $minimumRemainingBytes = 8GB
                    $requiredWithReserveBytes = $requiredBytes + $minimumRemainingBytes

                    if ($freeBytes -lt $requiredWithReserveBytes) {
                        $requiredGb = [Math]::Round(($requiredBytes / 1GB), 2)
                        $reserveGb = [Math]::Round(($minimumRemainingBytes / 1GB), 2)
                        $requiredWithReserveGb = [Math]::Round(($requiredWithReserveBytes / 1GB), 2)
                        $freeGb = [Math]::Round(($freeBytes / 1GB), 2)
                        Write-Log "Get-File: Not enough disk space to copy '$sourceDisplay' while keeping ${reserveGb}GB free. File requires ${requiredGb}GB, total required ${requiredWithReserveGb}GB, available ${freeGb}GB on drive '$($destinationDrive.Name):'." -Failure
                        return $false
                    }
                }
                catch {
                    Write-Log "Get-File: Failed to validate free space for '$Destination'. $_" -Failure
                    return $false
                }
            }

            # --- Resilient copy loop for local files (especially VHDX) ---
            # Strategy: use unbuffered robocopy first, then BITS as fallback,
            # with increasing backoff.
            # Only give up on non-recoverable errors (source missing, disk
            # full, access denied). Transient I/O errors under heavy load
            # are retried indefinitely.
            if (-not $isVhdxCopy) {
                # Non-VHDX: single BITS attempt, no retry loop
                Start-BitsTransfer @HashArguments -Priority Foreground -ErrorAction Stop
                if (Test-Path $Destination) { return $true }
                Write-Log "Get-File: Transfer appeared to succeed but '$Destination' does not exist." -Failure
                return $false
            }

            # VHDX copy — keep trying until it works or we hit a fatal error
            $maxRounds = 10          # 10 rounds × (robocopy + BITS) = 20 total attempts
            $lastError = $null
            for ($round = 1; $round -le $maxRounds; $round++) {

                # Check for non-recoverable conditions before each round
                if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
                    Write-Log "Get-File: Source '$sourceDisplay' no longer exists. Cannot retry." -Failure
                    return $false
                }
                try {
                    $drvName = (Split-Path $Destination -Qualifier).TrimEnd(':')
                    $drv = Get-PSDrive -Name $drvName -ErrorAction Stop
                    $srcSize = (Get-Item -LiteralPath $Source -ErrorAction Stop).Length
                    if ([int64]$drv.Free -lt ($srcSize + 1GB)) {
                        $freeGb = [Math]::Round($drv.Free / 1GB, 2)
                        $needGb = [Math]::Round(($srcSize + 1GB) / 1GB, 2)
                        Write-Log "Get-File: Destination drive '$drvName':\ has only ${freeGb}GB free (need ${needGb}GB). Cannot retry." -Failure
                        return $false
                    }
                }
                catch {
                    Write-Log "Get-File: Could not check free space: $($_.ToString().Trim())" -Warning
                }

                # --- Try robocopy first ---
                # Foreground BITS copies of multi-GB VHDX files can leave the
                # calling pwsh worker with a multi-GB reclaimable working set.
                # /J uses unbuffered I/O and avoids consuming the memory needed
                # to start the newly cloned VMs.
                $roboSrc = Split-Path $Source -Parent
                $roboDst = Split-Path $Destination -Parent
                $roboFile = Split-Path $Source -Leaf
                $destFile = Split-Path $Destination -Leaf
                $needsRename = $roboFile -ne $destFile
                $tempCopy = if ($needsRename) { Join-Path $roboDst $roboFile } else { $Destination }

                foreach ($partialPath in @($Destination, $tempCopy) | Select-Object -Unique) {
                    if (Test-Path $partialPath) {
                        Remove-Item -LiteralPath $partialPath -Force -ErrorAction SilentlyContinue
                    }
                }

                # /J = unbuffered I/O; /R:2 /W:10 = bounded internal retries;
                # /NP = no progress percentage.
                $roboArgs = @($roboSrc, $roboDst, $roboFile, '/J', '/R:2', '/W:10', '/NP')
                Write-Log "Get-File: robocopy (round $round/$maxRounds) $($roboArgs -join ' ')" -LogOnly
                $roboResult = & robocopy @roboArgs 2>&1
                $roboExit = $LASTEXITCODE

                if ($roboExit -lt 8) {
                    if ($needsRename -and (Test-Path $tempCopy)) {
                        Rename-Item -LiteralPath $tempCopy -NewName $destFile -Force -ErrorAction Stop
                    }
                    if (Test-Path $Destination) {
                        Write-Log "Get-File: robocopy succeeded (round $round, exit $roboExit)."
                        return $true
                    }
                }

                $roboTail = ($roboResult | Select-Object -Last 3) -join " | "
                $lastError = "robocopy exit $roboExit : $roboTail"
                Write-Log "Get-File: robocopy failed (round $round, exit $roboExit): $roboTail. Trying BITS..." -Warning
                foreach ($partialPath in @($Destination, $tempCopy) | Select-Object -Unique) {
                    if (Test-Path $partialPath) {
                        Remove-Item -LiteralPath $partialPath -Force -ErrorAction SilentlyContinue
                    }
                }

                # --- Try BITS fallback ---
                $bitsError = $null
                try {
                    Write-Log "Get-File: BITS fallback attempt (round $round/$maxRounds) for '$sourceDisplay'" -LogOnly
                    Start-BitsTransfer @HashArguments -Priority Foreground -ErrorAction Stop
                }
                catch {
                    $bitsError = $_
                    if (Test-Path $Destination) {
                        Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
                    }
                }

                if (-not $bitsError -and (Test-Path $Destination)) {
                    return $true
                }

                if ($bitsError) {
                    $lastError = $bitsError
                    # Check for access-denied / permission errors — non-recoverable
                    $errMsg = $bitsError.ToString()
                    if ($errMsg -match 'Access is denied|0x80070005') {
                        Write-Log "Get-File: BITS access denied for '$sourceDisplay'. Cannot retry." -Failure
                        throw $bitsError
                    }
                    Write-Log "Get-File: BITS fallback failed (round $round): $($errMsg.Trim())." -Warning
                }
                else {
                    Write-Log "Get-File: BITS fallback reported success but '$Destination' is missing (round $round)." -Warning
                }

                # Backoff before next round — cap at 60s
                if ($round -lt $maxRounds) {
                    $delay = [Math]::Min(60, 15 * $round)
                    Write-Log "Get-File: Copy of '$sourceDisplay' failed (round $round/$maxRounds). Retrying in ${delay}s..." -Warning
                    Start-Sleep -Seconds $delay
                }
            }

            # All rounds exhausted
            Write-Log "Get-File: Copy of '$sourceDisplay' failed after $maxRounds rounds of robocopy + BITS. Last error: $lastError" -Failure

            # If the SOURCE is a cached azureFiles file (e.g. a base-image VHDX) the copy
            # may have failed because the cached file rotted on disk (bad sector). Confirm
            # by fully reading the source ONCE here -- this cost is only paid when a copy
            # has ALREADY failed (rare), never on healthy deploys. If the source is
            # genuinely corrupt, purge it + its .MD5 hash marker so the NEXT deploy's
            # download/verify pass re-downloads a clean copy from Azure, then tell the
            # operator to re-run. We do NOT re-download inline (multi-GB, and parallel
            # Phase 1 jobs share the source), and we do NOT delete a good source when the
            # copy failed for other reasons (destination full/flaky, contention).
            if (($Source -is [string]) -and $Common.AzureFilesPath -and ($Source -like "$($Common.AzureFilesPath)*") -and (Test-Path -LiteralPath $Source -PathType Leaf)) {
                if (-not (Test-FileEdgeReadable -Path $Source -FullScan)) {
                    $srcLeaf = Split-Path $Source -Leaf
                    Write-Log "Get-File: Cached source '$srcLeaf' is CORRUPT on disk (bad sector). Purging it and its .MD5 hash marker." -Failure
                    try { Remove-Item -LiteralPath $Source -Force -Confirm:$false -ErrorAction SilentlyContinue | Out-Null } catch {}
                    foreach ($mk in @("$Source.MD5", "$Source.md5")) {
                        if (Test-Path -LiteralPath $mk) { try { Remove-Item -LiteralPath $mk -Force -Confirm:$false -ErrorAction SilentlyContinue | Out-Null } catch {} }
                    }
                    Write-Log "Get-File: ACTION REQUIRED -- re-run the deployment. The purged file will be re-downloaded from Azure and verified before Phase 1." -Failure
                }
            }

            if ($lastError -is [System.Management.Automation.ErrorRecord]) { throw $lastError }
            return $false
        }

        # ---- Verify destination exists after transfer (downloads) ----
        if (Test-Path $Destination) {
            return $true
        }
        else {
            Write-Log "Get-File: Transfer appeared to succeed but '$Destination' does not exist." -Failure
            return $false
        }

    }
    catch {
        Write-Log "Get-File: $Action '$sourceDisplay' failed. Error: $($_.ToString().Trim())" -Failure
        Write-Log "Get-File: $Action '$sourceDisplay' failed. StackTrace: $($_.ScriptStackTrace)" -LogOnly
        return $false
    }
    finally {
        $Global:ProgressPreference = $OriginalProgressPreference
    }
}

function Write-CopyStallDiag {
    <#
    .SYNOPSIS
    Explain WHY a PSDirect file copy into a guest stopped making progress.

    .DESCRIPTION
    The tools-bundle copy stalls on the SQL VM of every large lab (CS2-PS3SQL,
    CS4-CS1SQL, CS6-PS1SQL -- always the same ~tools-*.zip, always the remote-SQL
    node) and twice burned the full 1800s hard cap, which cost CS4 its tools
    injection and, downstream, the run. The existing log says only "no growth
    (16 MB at C:\Windows\Temp\tools-bundle.zip)" -- it proves the copy is dead
    but says nothing about why, so there has never been anything to act on.

    Captures the four candidate causes at the moment of the stall:
      host    -- is Hyper-V starving this VM (dynamic-memory pressure / CPU)?
      guest   -- is it out of memory, out of disk, or pegged?
      job     -- did the background copy job actually fault?
      source  -- is the host-side source file readable and how big is it?

    Best-effort; never throws, never blocks the caller's retry path.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $VMName,
        [string] $VMDomainName,
        [string] $SourcePath,
        [string] $GuestPath,
        $Job,
        [string] $Reason = 'stall'
    )

    function Write-CopyDiagLine { param([string]$Text) Write-Log "[Copy-ItemSafe] [$VMName] stall-diag ($Reason): $Text" -LogOnly }

    # --- host view of the VM: dynamic memory pressure is the leading suspect --
    try {
        $v = Get-VM2 -Name $VMName -ErrorAction SilentlyContinue
        if ($v) {
            $demand = 0; $assigned = 0
            try { $demand = [math]::Round($v.MemoryDemand / 1MB) } catch { }
            try { $assigned = [math]::Round($v.MemoryAssigned / 1MB) } catch { }
            $pressure = 'n/a'
            if ($assigned -gt 0) { $pressure = [math]::Round(($demand / $assigned) * 100) }
            Write-CopyDiagLine "vm cpu=$($v.CPUUsage)% memAssigned=${assigned}MB memDemand=${demand}MB pressure=${pressure}% memStatus='$($v.MemoryStatus)' dynamic=$($v.DynamicMemoryEnabled) min=$([math]::Round($v.MemoryMinimum/1MB))MB max=$([math]::Round($v.MemoryMaximum/1MB))MB state=$($v.State) heartbeat=$($v.Heartbeat) uptime=$([int]$v.Uptime.TotalMinutes)m"
            if ("$($v.MemoryStatus)" -match 'Low|Warning') {
                Write-CopyDiagLine "vm MemoryStatus='$($v.MemoryStatus)' -- Hyper-V is NOT satisfying this guest's demand. A starved guest pages, and a PSDirect copy (which materializes each chunk in the guest's PowerShell host) is one of the first things to crawl. LIKELY CAUSE."
            }
        }
    }
    catch { }

    # --- host memory headroom overall -----------------------------------------
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
        if ($os) {
            Write-CopyDiagLine "host freePhysical=$([math]::Round($os.FreePhysicalMemory/1KB))MB totalVisible=$([math]::Round($os.TotalVisibleMemorySize/1KB))MB"
        }
    }
    catch { }

    # --- source file on the host ----------------------------------------------
    try {
        if ($SourcePath -and (Test-Path $SourcePath)) {
            $srcItem = Get-Item -LiteralPath $SourcePath -ErrorAction SilentlyContinue
            if ($srcItem -and -not $srcItem.PSIsContainer) {
                Write-CopyDiagLine "source '$SourcePath' size=$([math]::Round($srcItem.Length/1MB,1))MB lastWrite=$($srcItem.LastWriteTime)"
            }
        }
        else { Write-CopyDiagLine "source '$SourcePath' NOT PRESENT on host" }
    }
    catch { }

    # --- the copy job itself ---------------------------------------------------
    try {
        if ($Job) {
            Write-CopyDiagLine "job state=$($Job.State) hasMoreData=$($Job.HasMoreData)"
            foreach ($cj in @($Job.ChildJobs)) {
                if ($cj.JobStateInfo -and $cj.JobStateInfo.Reason) { Write-CopyDiagLine "job child reason: $($cj.JobStateInfo.Reason)" }
                foreach ($e in @($cj.Error | Select-Object -Last 3)) { Write-CopyDiagLine "job child error: $e" }
                foreach ($w in @($cj.Warning | Select-Object -Last 3)) { Write-CopyDiagLine "job child warning: $w" }
            }
        }
    }
    catch { }

    # --- guest view ------------------------------------------------------------
    if ($VMDomainName) {
        try {
            $g = Invoke-VmCommand -VmName $VMName -VmDomainName $VMDomainName -DisplayName 'CopyStallDiag' -SuppressLog `
                -AsJob -TimeoutSeconds 60 -ArgumentList @($GuestPath) -ScriptBlock {
                param($target)
                $lines = @()
                try {
                    $os = Get-CimInstance Win32_OperatingSystem
                    $lines += "guest freePhysical=$([math]::Round($os.FreePhysicalMemory/1KB))MB total=$([math]::Round($os.TotalVisibleMemorySize/1KB))MB freeVirtual=$([math]::Round($os.FreeVirtualMemory/1KB))MB"
                }
                catch { }
                try {
                    $drive = 'C'
                    if ($target -and $target.Length -gt 1 -and $target[1] -eq ':') { $drive = $target.Substring(0, 1) }
                    $d = Get-PSDrive -Name $drive -ErrorAction SilentlyContinue
                    if ($d) { $lines += "guest drive ${drive}: free=$([math]::Round($d.Free/1GB,1))GB used=$([math]::Round($d.Used/1GB,1))GB" }
                }
                catch { }
                try {
                    if ($target -and (Test-Path $target)) {
                        $it = Get-Item -LiteralPath $target -ErrorAction SilentlyContinue
                        $lines += "guest target '$target' size=$([math]::Round($it.Length/1MB,1))MB lastWrite=$($it.LastWriteTime)"
                    }
                    else { $lines += "guest target '$target' does not exist yet" }
                }
                catch { }
                try {
                    $top = Get-Process -ErrorAction SilentlyContinue | Sort-Object -Property CPU -Descending | Select-Object -First 5
                    foreach ($p in @($top)) { $lines += "guest proc $($p.ProcessName) cpu=$([math]::Round($p.CPU,1))s ws=$([math]::Round($p.WorkingSet64/1MB))MB" }
                }
                catch { }
                try {
                    # Hard page faults are the signature of a memory-starved guest.
                    $pf = Get-Counter '\Memory\Pages/sec', '\Processor(_Total)\% Processor Time' -ErrorAction SilentlyContinue
                    foreach ($s in @($pf.CounterSamples)) { $lines += "guest counter $($s.Path) = $([math]::Round($s.CookedValue,1))" }
                }
                catch { }
                return ($lines -join "`n")
            }
            if ($g -and $g.ScriptBlockOutput -and -not $g.ScriptBlockFailed) {
                foreach ($line in ("$($g.ScriptBlockOutput)" -split "`r?`n")) {
                    if ($line.Trim()) { Write-CopyDiagLine $line.Trim() }
                }
            }
            else {
                Write-CopyDiagLine "guest probe returned nothing (failed=$($g.ScriptBlockFailed) timedOut=$($g.TimedOut) channelBroken=$($g.ChannelBroken)) -- if the guest cannot even answer a 60s probe, the copy is not slow, the VM is wedged."
            }
        }
        catch { Write-CopyDiagLine "guest probe threw: $($_.Exception.Message)" }
    }
}

function Copy-ItemSafe {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $Path,
        [Parameter(Mandatory = $true)]
        [string] $Destination,
        [Parameter(Mandatory = $true)]
        [string] $VMName,
        [Parameter(Mandatory = $true)]
        [string] $VMDomainName,
        [Parameter(Mandatory = $false)]
        [switch] $Recurse,
        [Parameter(Mandatory = $false)]
        [switch] $Container,
        [Parameter(Mandatory = $false)]
        [switch] $WhatIf,
        [Parameter(Mandatory = $false)]
        [switch]$Force
    )
    #$PSScriptRoot = $using:PSScriptRoot
    $location = $PSScriptRoot
    $testpath = Join-Path $location "Common.ps1"
    if (-not (Test-Path -PathType Leaf $testpath)) {
        Write-Log "Could not find $testpath" -LogOnly
        $location = Split-Path $location -Parent
        $testpath = Join-Path $location "Common.ps1"
        if (-not (Test-Path -PathType Leaf $testpath)) {
            Write-Log "Could not find $testpath" -LogOnly
            return $false
        }
    }
    $enableVerbose = $false
    $CopyItemScript = {
        try {
            #Write-Host "CopyItemScript starting"
            # Dot source common
            $rootPath = $using:location
            #Write-Host "Loading common: . $rootPath\Common.ps1 -InJob -VerboseEnabled:$using:enableVerbose"
            . $rootPath\Common.ps1 -InJob -VerboseEnabled:$using:enableVerbose -DevBranch:$using:Common.DevBranch

            # Dot-sourcing Common.ps1 -InJob resets $Common.LogPath to the base
            # VMBuild.log. Re-point it to the domain-specific log (same pattern as
            # the phase workers in Common.ScriptBlocks.ps1) so this nested job's
            # entries land in VMBuild.<domain>.log, not VMBuild.log.
            $domainNameForLogging = $using:VMDomainName
            if (-not $domainNameForLogging -or $domainNameForLogging -eq "WORKGROUP") {
                try { $domainNameForLogging = (Get-VMNote -VMName $using:VMName).domain } catch { }
            }
            if ($domainNameForLogging) {
                $Common.LogPath = $Common.LogPath -replace "VMBuild\.log", "VMBuild.$domainNameForLogging.log"
            }

            $ps = Get-VmSession -VmName $using:VMName -VmDomainName $using:VMDomainName

            if ($ps) {
                Write-Log "[Copy-ItemSafe] [$($using:VMName)] Copying $($using:Path) to $($using:Destination) WhatIf:$($using:WhatIF)" -LogOnly
                Copy-Item -ToSession $ps -Path $using:Path -Destination $using:Destination -Recurse:$using:Recurse -Container:$using:Container -Force:$using:Force -verbose:$using:enableVerbose -WhatIf:$using:WhatIF
            }
            else {
                Write-Log "[Copy-ItemSafe] Failed to get Powershell Session for $using:VMName" -Failure
                return $false
            }
        }
        catch {
            write-log $_
            return $false
        }
        return $true
    }

    write-log "[Copy-ItemSafe] location: $location enableVerbose: $enableVerbose VMName:$VMName Path:$Path Destination:$Destination WhatIF:$WhatIF Recurse:$Recurse Container:$Container  Force:$Force" -LogOnly

    # Scale timeouts based on concurrent VM load. More VMs = more PSDirect
    # contention = slower copies. Avoid adding heartbeat probe load too often.
    $runningVmCount = @(Get-VM -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Running' }).Count
    $extraVms = [Math]::Max(0, $runningVmCount - 8)

    $pollIntervalSeconds = 30
    $stallTimeoutSeconds = 30 + ($extraVms * 5)    # 30s base + 5s per VM over 8
    $maxTotalSeconds = 1800                         # Hard cap: 30 minutes per attempt
    $guestHeartbeatIntervalSeconds = 120 + ($extraVms * 5)  # 120s base + 5s per VM over 8

    Write-Log "[Copy-ItemSafe] [$VMName] $runningVmCount running VMs: stallTimeout=${stallTimeoutSeconds}s, heartbeatInterval=${guestHeartbeatIntervalSeconds}s" -LogOnly

    # Derive the guest-side check path for heartbeat size monitoring
    $guestCheckPath = $Destination
    if ($Recurse) {
        # Recursive copy: source folder lands as a subfolder of Destination
        $guestCheckPath = Join-Path $Destination (Split-Path $Path -Leaf)
    }

    $retries = 3
    while ($retries -gt 0) {
        $existingChildProcessIds = @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $PID AND Name = 'pwsh.exe'" -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty ProcessId)
        $job = Start-Job -ScriptBlock $CopyItemScript
        $copyJobProcessId = Get-CimInstance Win32_Process -Filter "ParentProcessId = $PID AND Name = 'pwsh.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $existingChildProcessIds -notcontains $_.ProcessId } |
            Sort-Object CreationDate -Descending |
            Select-Object -First 1 -ExpandProperty ProcessId
        $attemptStart = Get-Date
        $lastProgressFingerprint = ''
        $lastProgressTime = $attemptStart
        $timedOut = $false
        $lastGuestHeartbeatTime = [datetime]::MinValue
        $lastGuestSize = -1

        # On the last retry, skip stall detection and allow the full hard cap.
        # Earlier retries use stall detection to fail fast and retry sooner.
        $isLastRetry = $retries -eq 1

        # Poll loop: check every $pollIntervalSeconds whether the copy is making progress
        while ($job.State -eq "Running") {
            $null = Wait-Job -Timeout $pollIntervalSeconds -Job $job
            if ($job.State -ne "Running") { break }

            $elapsedSeconds = [int]((Get-Date) - $attemptStart).TotalSeconds

            # Hard cap safety net
            if ($elapsedSeconds -ge $maxTotalSeconds) {
                Write-Log "[Copy-ItemSafe] [$VMName] Copy hit hard cap of ${maxTotalSeconds}s copying $Path. Retries left: $($retries - 1)" -Warning
                Write-CopyStallDiag -VMName $VMName -VMDomainName $VMDomainName -SourcePath $Path -GuestPath $guestCheckPath -Job $job -Reason 'hard-cap'
                $timedOut = $true
                break
            }

            # Check progress via the job's Progress stream.
            # Copy-Item emits ProgressRecords: Count increases per new file,
            # and PercentComplete/StatusDescription update per chunk within a file.
            # Track a fingerprint of (Count + latest record state) so both
            # new-file progress AND byte-level progress on large files (ISOs) are detected.
            $progressStream = if ($job.ChildJobs.Count -gt 0) { $job.ChildJobs[0].Progress } else { $job.Progress }
            $currentCount = $progressStream.Count
            $fingerprint = "$currentCount"
            $progressDetail = ''
            if ($currentCount -gt 0) {
                $latestRecord = $progressStream[$currentCount - 1]
                $fingerprint = "$currentCount|$($latestRecord.PercentComplete)|$($latestRecord.StatusDescription)"
                $progressDetail = "$currentCount items, $($latestRecord.PercentComplete)%"
                if ($latestRecord.CurrentOperation) {
                    # Trim long paths to just the filename for log readability
                    $progressDetail += " ($([System.IO.Path]::GetFileName($latestRecord.CurrentOperation)))"
                }
            }

            if ($fingerprint -ne $lastProgressFingerprint) {
                # Copy is making progress (new file started, or bytes advancing on current file)
                if ($progressDetail) {
                    Write-Log "[Copy-ItemSafe] [$VMName] Progress: $progressDetail (${elapsedSeconds}s elapsed)" -LogOnly
                }
                $lastProgressFingerprint = $fingerprint
                $lastProgressTime = Get-Date
            }
            else {
                # No progress from the Progress stream. Check if we should do a guest heartbeat.
                $latestPercent = if ($currentCount -gt 0) { $progressStream[$currentCount - 1].PercentComplete } else { 0 }
                $isIndeterminate = $currentCount -gt 0 -and $latestPercent -eq -1
                $stallSeconds = [int]((Get-Date) - $lastProgressTime).TotalSeconds

                # Guest heartbeat: check actual file size on the VM to detect real progress
                # that the Progress stream doesn't report.
                $heartbeatAlive = $false
                $secsSinceHeartbeat = ((Get-Date) - $lastGuestHeartbeatTime).TotalSeconds
                if ($stallSeconds -ge $stallTimeoutSeconds -and $secsSinceHeartbeat -ge $guestHeartbeatIntervalSeconds) {
                    $lastGuestHeartbeatTime = Get-Date
                    try {
                        $checkSession = Get-VmSession -VmName $VMName -VmDomainName $VMDomainName -MaxRetries 1 -Quiet
                        if ($checkSession) {
                            $currentGuestSize = Invoke-Command -Session $checkSession -ScriptBlock {
                                param($p)
                                if (Test-Path $p) {
                                    $item = Get-Item $p -EA SilentlyContinue
                                    if ($item.PSIsContainer) {
                                        (Get-ChildItem $p -Recurse -File -EA SilentlyContinue | Measure-Object Length -Sum -EA SilentlyContinue).Sum
                                    }
                                    else { $item.Length }
                                }
                                else { 0 }
                            } -ArgumentList $guestCheckPath -ErrorAction SilentlyContinue
                            if ($null -eq $currentGuestSize) { $currentGuestSize = 0 }

                            if ($currentGuestSize -gt $lastGuestSize -and $lastGuestSize -ge 0) {
                                $deltaMB = [Math]::Round(($currentGuestSize - $lastGuestSize) / 1MB, 1)
                                $totalMB = [Math]::Round($currentGuestSize / 1MB, 1)
                                Write-Log "[Copy-ItemSafe] [$VMName] Guest heartbeat: +${deltaMB} MB (${totalMB} MB total at $guestCheckPath, ${elapsedSeconds}s elapsed)" -LogOnly
                                $lastProgressTime = Get-Date  # copy IS alive, reset stall timer
                                $heartbeatAlive = $true
                            }
                            else {
                                $totalMB = [Math]::Round([Math]::Max($currentGuestSize, 0) / 1MB, 1)
                                Write-Log "[Copy-ItemSafe] [$VMName] Guest heartbeat: no growth (${totalMB} MB at $guestCheckPath, ${elapsedSeconds}s elapsed)" -LogOnly
                            }
                            $lastGuestSize = $currentGuestSize
                        }
                    }
                    catch {
                        Write-Log "[Copy-ItemSafe] [$VMName] Guest heartbeat failed: $_" -LogOnly
                    }
                }

                if (-not $heartbeatAlive -and -not $isLastRetry) {
                    if (-not $isIndeterminate -and $stallSeconds -ge $stallTimeoutSeconds) {
                        $stallDetail = if ($progressDetail) { " (last: $progressDetail)" } else { '' }
                        Write-Log "[Copy-ItemSafe] [$VMName] Copy stalled for ${stallSeconds}s with no progress${stallDetail} copying $Path. Retries left: $($retries - 1)" -Warning
                        Write-CopyStallDiag -VMName $VMName -VMDomainName $VMDomainName -SourcePath $Path -GuestPath $guestCheckPath -Job $job -Reason "stalled-${stallSeconds}s"
                        $timedOut = $true
                        break
                    }
                    else {
                        $indeterminateTag = if ($isIndeterminate) { " [indeterminate]" } else { "" }
                        Write-Log "[Copy-ItemSafe] [$VMName] No new progress for ${stallSeconds}s (${elapsedSeconds}s total)${indeterminateTag}" -LogOnly
                    }
                }
                elseif (-not $heartbeatAlive -and $isLastRetry) {
                    Write-Log "[Copy-ItemSafe] [$VMName] Last retry: no new progress for ${stallSeconds}s, waiting up to ${maxTotalSeconds}s (${elapsedSeconds}s elapsed)" -LogOnly
                }
            }
        }

        if ($timedOut) {
            # Stop-Job can block forever when Copy-Item -ToSession is wedged.
            # Kill this process job's worker first, then let PowerShell observe
            # the exit before removing the job and starting the next attempt.
            try {
                if ($copyJobProcessId) {
                    Stop-Process -Id $copyJobProcessId -Force -ErrorAction SilentlyContinue
                }
            }
            catch { }
            try { $job.StopJobAsync() } catch { }
            if ($job.State -ne 'Running') {
                Write-VmJobLedger -Op 'disposed' -Job $job -VmName $VMName -DisplayName 'Copy-ItemSafe' -Detail 'reason=copy-timeout-terminal'
                Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
            }
            else {
                Write-Log "[Copy-ItemSafe] [$VMName] Abandoning stale job object after terminating stalled copy worker PID $copyJobProcessId." -LogOnly
            }
            $retries--
            continue
        }

        if ($job.State -eq "Completed") {
            $result = Receive-Job $job
            Write-Log "[Copy-ItemSafe] returned: $result" -LogOnly
            Write-VmJobLedger -Op 'disposed' -Job $job -VmName $VMName -DisplayName 'Copy-ItemSafe' -Detail 'reason=copy-completed'
            Remove-Job $job | Out-Null
            if ($result -eq $false) {
                Write-Log "[Copy-ItemSafe] [$VMName] Job completed but scriptblock returned failure. Retries left: $($retries - 1)" -Warning
                $retries--
                continue
            }
            return $true
        }
        else {
            Write-Log "[Copy-ItemSafe] [$VMName] Job ended with state '$($job.State)' copying $Path. Retries left: $($retries - 1)" -Warning
            Stop-Job $job | Out-Null
            Write-VmJobLedger -Op 'disposed' -Job $job -VmName $VMName -DisplayName 'Copy-ItemSafe' -Detail "reason=copy-ended-$($job.State)"
            Remove-Job -Job $job | Out-Null
            $retries--
        }
    }
    return $false

}

function Test-URL {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $url,
        [string] $name
    )

    $curlPaths = @(Get-CurlExecutablePaths)
    if (-not $curlPaths -or $curlPaths.Count -eq 0) {
        Write-Log "Curl was not found." -Failure
        return $false
    }

    try {
        #$output = & $curlPath --retry 8 --retry-delay 4 --retry-max-time 45 -s -L --head -f $url
        $result = Invoke-CurlWithFallback -CurlArguments @("--retry", "8", "--retry-delay", "4", "--retry-max-time", "45", "-s", "-L", "--head", "-f", $url) -CaptureOutput
        $output = $result.Output
        $lastexit = $result.ExitCode
        if ($result.Success) {
            if ($output -match 'Location: https://www.bing.com') {
                Write-Log -LogOnly "[$name] $url (Redirects to bing)" -Failure
                Write-RedX "[$name] $url (Redirects to bing)"
                return $false
            }
            Write-GreenCheck "[$name] $url"
            Write-Log -LogOnly "[$name] $url Successful"
            return $true
        }
        else {
            if ($lastexit -eq 60) {
                write-log "Curl failed($lastexit): $output"
            }
            #ipconfig /flushdns
            Clear-DnsClientCache
            start-sleep -seconds 30
            write-log "Curl retrying.. Last failure Exit code $lastexit $output" -LogOnly
            $result = Invoke-CurlWithFallback -CurlArguments @("--retry", "16", "--retry-delay", "10", "--retry-max-time", "160", "-s", "-L", "--head", "-f", $url) -CaptureOutput
            $output = $result.Output
            $lastexit = $result.ExitCode

            if (-not $result.Success) {
                Write-RedX "[$name] curl -s -L --head $url returned $lastexit"
                Write-Log -LogOnly "[$name] curl -s -L --head $url returned $lastexit $output" -Failure
                return $false
            }
        }
    }
    catch {
        Write-RedX "[$name] An error occurred while testing the URL: $url $_"
        Write-Log "An error occurred while testing the URL: $url $_" -Failure
        return $false
    }
}
function Start-CurlTransfer {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $Source,
        [Parameter(Mandatory = $true)]
        [string] $Destination,
        [Parameter(Mandatory = $false)]
        [string] $Description,
        [Parameter(Mandatory = $false)]
        [string] $DisplayName,
        [Parameter(Mandatory = $false)]
        [switch]$Silent
    )

    # ---- Find curl ----
    $curlPaths = @(Get-CurlExecutablePaths)
    if (-not $curlPaths -or $curlPaths.Count -eq 0) {
        $systemCurlPath = Join-Path $env:WINDIR "System32\curl.exe"
        if (Test-Path $systemCurlPath) {
            Write-Log "Start-CurlTransfer: System32 curl exists at '$systemCurlPath'. Skipping chocolatey curl install." -LogOnly
        }
        else {
            Write-Log "Start-CurlTransfer: curl.exe not found, attempting to install via chocolatey..." -Warning
            & choco install curl -y | Out-Null
        }
        $curlPaths = @(Get-CurlExecutablePaths)
    }

    if (-not $curlPaths -or $curlPaths.Count -eq 0) {
        Write-Log "Start-CurlTransfer: curl.exe was not found and could not be installed." -Failure
        return $false
    }

    $maxRetries = 10
    $retryCount = 0
    $success = $false

    if (-not $Silent) { Write-Host }

    do {
        $retryCount++

        $curlArguments = @("-L", "-C", "-")
        if ($Silent) {
            $curlArguments = @("-s") + $curlArguments
        }
        $curlArguments += @("-o", $Destination, "$Source")

        $result = Invoke-CurlWithFallback -CurlArguments $curlArguments

        switch ($result.ExitCode) {
            0 {
                # Success
                $success = $true
                if (-not $Silent) { Write-Host }
                break
            }
            33 {
                # Range request not satisfied — partial file is likely corrupt or already complete
                # Delete and restart from scratch
                if (-not $Silent) { Write-Host }
                Write-Log "Start-CurlTransfer: Resume failed (exit 33) for '$Source'. Removing partial file and restarting." -Warning
                Remove-Item -Path $Destination -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 2
            }
            default {
                # When -Silent (e.g. the optional download cache, which falls through
                # to a direct download on any miss), a transient failure that's about to
                # be retried logs NOTHING -- only a genuine give-up (all retries
                # exhausted, below) is worth recording. The interactive path keeps its
                # on-console retry message and spacing.
                if (-not $Silent) {
                    Write-Host
                    Write-Log "Start-CurlTransfer: Download '$Source' failed with exit code $($result.ExitCode). Will retry $(($maxRetries - $retryCount)) more time(s)."
                    Write-Host
                }
                Start-Sleep -Seconds 5
            }
        }

    } while (-not $success -and $retryCount -le $maxRetries)

    if (-not $success) {
        Write-Log "Start-CurlTransfer: Download '$Source' failed after $retryCount attempt(s)." -Failure
    }

    return $success
}

function Get-CurlExecutablePaths {
    [CmdletBinding()]
    param ()

    $curlPaths = @()
    $systemCurlPath = Join-Path $env:WINDIR "System32\curl.exe"
    $resolvedCurlPath = Get-Command "curl.exe" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source
    $chocoCurlPath = "C:\ProgramData\chocolatey\bin\curl.exe"

    foreach ($candidate in @($systemCurlPath, $resolvedCurlPath, $chocoCurlPath)) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path $candidate) -and ($candidate -notin $curlPaths)) {
            $curlPaths += $candidate
        }
    }

    return $curlPaths
}

function Invoke-CurlWithFallback {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string[]] $CurlArguments,
        [Parameter(Mandatory = $false)]
        [switch] $CaptureOutput
    )

    $curlPaths = @(Get-CurlExecutablePaths)
    if (-not $curlPaths -or $curlPaths.Count -eq 0) {
        return [PSCustomObject]@{
            Success  = $false
            ExitCode = $null
            Output   = $null
            Path     = $null
        }
    }

    $lastResult = [PSCustomObject]@{
        Success  = $false
        ExitCode = $null
        Output   = $null
        Path     = $null
    }

    for ($index = 0; $index -lt $curlPaths.Count; $index++) {
        $curlPath = $curlPaths[$index]
        if ($CaptureOutput) {
            $output = & $curlPath @CurlArguments 2>&1
        }
        else {
            & $curlPath @CurlArguments
            $output = $null
        }

        $lastResult = [PSCustomObject]@{
            Success  = ($LASTEXITCODE -eq 0)
            ExitCode = $LASTEXITCODE
            Output   = $output
            Path     = $curlPath
        }

        if ($lastResult.Success) {
            return $lastResult
        }

        if ($index -lt ($curlPaths.Count - 1)) {
            Write-Log "Invoke-CurlWithFallback: '$curlPath' failed with exit code $($lastResult.ExitCode). Trying fallback curl path." -LogOnly
        }
    }

    return $lastResult
}
function New-Directory {
    param(
        $DirectoryPath
    )

    if (-not (Test-Path -Path $DirectoryPath)) {
        New-Item -Path $DirectoryPath -ItemType Directory -Force | Out-Null
    }

    return $DirectoryPath
}

# https://stackoverflow.com/questions/61231739/set-the-position-of-powershell-window
Function Set-Window {
    <#
        .SYNOPSIS
            Sets the window size (height,width) and coordinates (x,y) of
            a process window.
        .DESCRIPTION
            Sets the window size (height,width) and coordinates (x,y) of
            a process window.

        .PARAMETER ProcessID
            ID of the process to determine the window characteristics

        .PARAMETER X
            Set the position of the window in pixels from the top.

        .PARAMETER Y
            Set the position of the window in pixels from the left.

        .PARAMETER Width
            Set the width of the window.

        .PARAMETER Height
            Set the height of the window.

        .PARAMETER Passthru
            Display the output object of the window.

        .NOTES
            Name: Set-Window
            Author: Boe Prox
            Version History
                1.0//Boe Prox - 11/24/2015
                    - Initial build

        .OUTPUT
            System.Automation.WindowInfo

        .EXAMPLE
            Get-Process powershell | Set-Window -X 2040 -Y 142 -Passthru

            ProcessName Size     TopLeft  BottomRight
            ----------- ----     -------  -----------
            powershell  1262,642 2040,142 3302,784

            Description
            -----------
            Set the coordinates on the window for the process PowerShell.exe

    #>
    [OutputType('System.Automation.WindowInfo')]
    [cmdletbinding()]
    Param (
        [parameter(ValueFromPipelineByPropertyName = $True)]
        $ProcessID,
        [int]$X,
        [int]$Y,
        [int]$Width,
        [int]$Height,
        [switch]$Passthru
    )
    Begin {
        Try {
            # Verify the type exists AND has the FindWindow method (may be stale from prior session)
            [void][Window]
            if (-not [Window].GetMethod('FindWindow')) { throw "stale" }
        }
        Catch {
            # Type doesn't exist or is stale - define it. Guard with -ErrorAction to suppress
            # "type already exists" warnings when Common.ps1 is dot-sourced multiple times.
            try {
                Add-Type -ErrorAction SilentlyContinue @"
              using System;
              using System.Runtime.InteropServices;
              public class Window {
                [DllImport("user32.dll")]
                [return: MarshalAs(UnmanagedType.Bool)]
                public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

                [DllImport("user32.dll")]
                public extern static bool MoveWindow(IntPtr handle, int x, int y, int width, int height, bool redraw);

                [DllImport("user32.dll")]
                [return: MarshalAs(UnmanagedType.Bool)]
                public static extern bool IsWindowVisible(IntPtr hWnd);

                [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
                public static extern IntPtr FindWindow(string lpClassName, string lpWindowName);

                [DllImport("kernel32.dll")]
                public static extern IntPtr GetConsoleWindow();
              }
              public struct RECT
              {
                public int Left;        // x position of upper-left corner
                public int Top;         // y position of upper-left corner
                public int Right;       // x position of lower-right corner
                public int Bottom;      // y position of lower-right corner
              }
"@
            }
            catch {
                # Type already exists and can't be replaced in this session - that's OK,
                # FindWindow strategy will gracefully fall through to other strategies.
            }
        }
    }
    Process {
        $Rectangle = New-Object RECT
        $Handle = (Get-Process -id $ProcessID).MainWindowHandle
        if ($Handle -eq [IntPtr]::Zero) {
            # Console apps (cmd/pwsh) don't own their window - conhost.exe does.
            # GetConsoleWindow() returns the console window handle.
            $Handle = [Window]::GetConsoleWindow()
            if ($Handle -eq [IntPtr]::Zero) {
                Write-Log "Set-Window: PID $ProcessID has no MainWindowHandle and GetConsoleWindow returned 0. Skipping." -LogOnly -Warning
                return
            }
            # On Windows 11 with default terminal = Windows Terminal, GetConsoleWindow
            # returns the HIDDEN pseudoconsole (conpty) window. MoveWindow on it corrupts
            # state (window becomes undraggable) without any visible effect.
            if (-not [Window]::IsWindowVisible($Handle)) {
                Write-Log "Set-Window: PID $ProcessID GetConsoleWindow handle=$Handle is NOT visible (pseudoconsole). Skipping MoveWindow." -LogOnly -Warning
                return
            }
            Write-Log "Set-Window: PID $ProcessID MainWindowHandle=0, using GetConsoleWindow handle=$Handle (visible=true)" -LogOnly
        }

        $Return = [Window]::GetWindowRect($Handle, [ref]$Rectangle)
        $beforeW = $Rectangle.Right - $Rectangle.Left
        $beforeH = $Rectangle.Bottom - $Rectangle.Top
        Write-Log "Set-Window: PID $ProcessID Handle=$Handle BEFORE=${beforeW}x${beforeH} at ($($Rectangle.Left),$($Rectangle.Top))" -LogOnly
        If (-NOT $PSBoundParameters.ContainsKey('Width')) {
            $Width = $Rectangle.Right - $Rectangle.Left
        }
        If (-NOT $PSBoundParameters.ContainsKey('Height')) {
            $Height = $Rectangle.Bottom - $Rectangle.Top
        }
        Write-Log "Set-Window: PID $ProcessID requesting MoveWindow($Handle, $X, $Y, $Width, $Height)" -LogOnly
        If ($Return) {
            $Return = [Window]::MoveWindow($Handle, $x, $y, $Width, $Height, $True)
            if (-not $Return) {
                Write-Log "Set-Window: MoveWindow returned FALSE for PID $ProcessID (Handle=$Handle). LastError=$([System.Runtime.InteropServices.Marshal]::GetLastWin32Error())" -LogOnly -Warning
            }
            else {
                # Verify the window actually moved
                $VerifyRect = New-Object RECT
                $null = [Window]::GetWindowRect($Handle, [ref]$VerifyRect)
                $afterW = $VerifyRect.Right - $VerifyRect.Left
                $afterH = $VerifyRect.Bottom - $VerifyRect.Top
                Write-Log "Set-Window: PID $ProcessID AFTER=${afterW}x${afterH} at ($($VerifyRect.Left),$($VerifyRect.Top))" -LogOnly
                if ($afterW -eq $beforeW -and $afterH -eq $beforeH) {
                    Write-Log "Set-Window: WARNING - window dimensions unchanged after MoveWindow! Window may be locked or handle is stale." -LogOnly -Warning
                }
            }
        }
        else {
            Write-Log "Set-Window: GetWindowRect failed for PID $ProcessID (Handle=$Handle)." -LogOnly -Warning
        }
        If ($PSBoundParameters.ContainsKey('Passthru')) {
            $Rectangle = New-Object RECT
            $Return = [Window]::GetWindowRect($Handle, [ref]$Rectangle)
            If ($Return) {
                $Height = $Rectangle.Bottom - $Rectangle.Top
                $Width = $Rectangle.Right - $Rectangle.Left
                $Size = New-Object System.Management.Automation.Host.Size -ArgumentList $Width, $Height
                $TopLeft = New-Object System.Management.Automation.Host.Coordinates -ArgumentList $Rectangle.Left, $Rectangle.Top
                $BottomRight = New-Object System.Management.Automation.Host.Coordinates -ArgumentList $Rectangle.Right, $Rectangle.Bottom
                If ($Rectangle.Top -lt 0 -AND $Rectangle.LEft -lt 0) {
                    Write-Warning "Window is minimized! Coordinates will not be accurate."
                }
                $Object = [PSCustomObject]@{
                    ProcessID   = $ProcessID
                    Size        = $Size
                    TopLeft     = $TopLeft
                    BottomRight = $BottomRight
                }
                $Object.PSTypeNames.insert(0, 'System.Automation.WindowInfo')
                $Object
            }
        }
    }
}


function Restore-TerminalFocus {
    <#
    .SYNOPSIS
        Restores foreground focus to the calling terminal window.
    .DESCRIPTION
        After launching GUI apps (RDCMan, mRemoteNG) that steal foreground,
        call this once to pull focus back. Uses keybd_event Alt trick +
        AttachThreadInput to bypass Windows' SetForegroundWindow restriction.
    #>
    try {
        $focusApi = Add-Type -MemberDefinition @"
            [DllImport("kernel32.dll")]
            public static extern IntPtr GetConsoleWindow();
            [DllImport("user32.dll")]
            public static extern bool SetForegroundWindow(IntPtr hWnd);
            [DllImport("user32.dll")]
            public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
            [DllImport("user32.dll")]
            public static extern IntPtr GetForegroundWindow();
            [DllImport("user32.dll")]
            public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
            [DllImport("kernel32.dll")]
            public static extern uint GetCurrentThreadId();
            [DllImport("user32.dll")]
            public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
            [DllImport("user32.dll")]
            public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
"@ -Name "FocusApi" -Namespace Win32 -PassThru -ErrorAction SilentlyContinue

        $ourWindow = $focusApi::GetConsoleWindow()
        if (-not $ourWindow -or $ourWindow -eq [IntPtr]::Zero) {
            $ourWindow = $focusApi::GetForegroundWindow()
        }
        if (-not $ourWindow -or $ourWindow -eq [IntPtr]::Zero) { return }

        # Synthesize Alt press/release so Windows grants us foreground-set privilege
        $focusApi::keybd_event(0x12, 0, 0, [UIntPtr]::Zero)
        $focusApi::keybd_event(0x12, 0, 0x2, [UIntPtr]::Zero)

        # Attach to the current foreground thread (belt-and-suspenders)
        $fg = $focusApi::GetForegroundWindow()
        $fgPid = [uint32]0
        $fgThread = $focusApi::GetWindowThreadProcessId($fg, [ref]$fgPid)
        $ourThread = $focusApi::GetCurrentThreadId()
        $attached = $false
        if ($fgThread -ne 0 -and $fgThread -ne $ourThread) {
            $attached = $focusApi::AttachThreadInput($ourThread, $fgThread, $true)
        }
        $focusApi::ShowWindow($ourWindow, 9) | Out-Null   # SW_RESTORE
        $focusApi::SetForegroundWindow($ourWindow) | Out-Null
        if ($attached) {
            $focusApi::AttachThreadInput($ourThread, $fgThread, $false) | Out-Null
        }
    }
    catch {
        # Best-effort; don't fail the caller.
    }
}

# Test-NetworkFastPath
#
# In-memory check against pre-fetched network state.  Returns $true when
# the switch, host-side IP, NAT rule, and DHCP scope for a network all
# exist already — skipping the dozens of per-network WMI calls that the
# full Add-SwitchAndDhcp / Test-NetworkSwitch / Test-DHCPScope path makes.
#
# Callers populate $Cache once with bulk queries (Get-VMSwitch, Get-NetNat,
# Get-NetAdapter, Get-NetIPAddress, Get-DhcpServerv4Scope) and pass it in.
# When $Cache is $null or any check fails, returns $false so the caller
# falls through to Add-SwitchAndDhcp which has full retry/recovery logic.
function Test-NetworkFastPath {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$NetworkName,
        [Parameter(Mandatory = $true)]
        [string]$NetworkSubnet,
        [Parameter(Mandatory = $false)]
        [hashtable]$Cache
    )

    if (-not $Cache) { return $false }

    # 1. VM switch exists?  (replicates Get-VMSwitch2 -like match)
    $sw = $Cache.Switches | Where-Object { $_.Name -like "*$NetworkName*" } | Select-Object -First 1
    if (-not $sw) {
        Write-Log "  Fast-path miss: switch '$NetworkName' not in cache." -LogOnly
        return $false
    }

    # 2. Host adapter has the correct .200 IP?
    $adapter = $Cache.Adapters | Where-Object { $_.Name -like "*$NetworkName*" } | Select-Object -First 1
    if (-not $adapter) {
        Write-Log "  Fast-path miss: adapter for '$NetworkName' not in cache." -LogOnly
        return $false
    }
    $desiredIp = $NetworkSubnet.Substring(0, $NetworkSubnet.LastIndexOf(".")) + ".200"
    $hasIp = $Cache.IPs | Where-Object { $_.InterfaceAlias -eq $adapter.InterfaceAlias -and $_.IPAddress -eq $desiredIp }
    if (-not $hasIp) {
        Write-Log "  Fast-path miss: adapter '$($adapter.InterfaceAlias)' missing IP $desiredIp." -LogOnly
        return $false
    }

    # 3. NAT rule exists?
    $hasNat = $Cache.Nats | Where-Object { $_.Name -eq $NetworkSubnet }
    if (-not $hasNat) {
        Write-Log "  Fast-path miss: NAT '$NetworkSubnet' not in cache." -LogOnly
        return $false
    }

    # 4. DHCP scope exists? (skip for switches that intentionally have no DHCP)
    if ($NetworkName -ne 'ClusterV2') {
        $hasScope = $Cache.Scopes | Where-Object { $_.ScopeId.IPAddressToString -eq $NetworkSubnet }
        if (-not $hasScope) {
            Write-Log "  Fast-path miss: DHCP scope '$NetworkSubnet' not in cache." -LogOnly
            return $false
        }
    }

    # All checks passed — emit the same log lines the full path would.
    Write-Log "HyperV Network switch for '$NetworkName' already exists."
    if ($NetworkName -ne 'ClusterV2') {
        Write-GreenCheck "'$NetworkSubnet ($NetworkName)' scope is already present in DHCP."
    }
    return $true
}

function Add-SwitchAndDhcp {
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Network Name.")]
        [string]$NetworkName,
        [Parameter(Mandatory = $true, HelpMessage = "Network Subnet.")]
        [string]$NetworkSubnet,
        [Parameter(Mandatory = $false, HelpMessage = "Domain Name.")]
        [string]$DomainName,
        [Parameter(Mandatory = $false, HelpMessage = "Override DNS.")]
        [string]$DNSServer,
        [Parameter(Mandatory = $false, HelpMessage = "What If?")]
        [switch]$WhatIf
    )


    if ($WhatIf.IsPresent) {
        Write-Log "[What-If] Will create/verify Hyper-V switch and DHCP scopes."
        return $true
    }

    Write-Log "Creating/verifying Hyper-V switch and DHCP Scopes for '$NetworkName' network." -Activity

    # This is the host-side networking chokepoint (runs once per network at the
    # start of a deploy) and the first thing it does is call CDXML cmdlets that
    # auto-load their module: Get-NetNat (NetNat), the vSwitch cmdlets, and
    # Get/Remove-DhcpServerv4Scope. Each generates a remoteIpMoProxy_* proxy in
    # %TEMP%, so if that dir was wiped mid-session the very first Get-NetNat
    # below would throw "Could not find a part of the path ...format.ps1xml"
    # before we ever reach Start-DHCP. Repair the temp dir up front so the whole
    # switch/NAT/DHCP creation flow is covered, not just the DhcpServer import.
    # Reset any stale cached compat proxy if the dir was recreated OR an
    # already-loaded proxy points at a now-deleted folder (Test-CimProxyStale).
    $needReset = Repair-CimProxyTempPath
    if ($needReset -or (Test-CimProxyStale)) {
        Reset-CimProxyModuleState | Out-Null
    }

    # ── NetNat scavenge ─────────────────────────────────────────────────────
    # Too many NetNat entries can cause WinNAT to silently drop traffic.
    # If the count exceeds the threshold, remove orphans automatically
    # before creating new networking.
    $natCount = @(Get-NetNat -ErrorAction SilentlyContinue).Count
    if ($natCount -ge 20) {
        Write-Log "NetNat count is $natCount (threshold 20). Scavenging orphans..." -Warning
        Remove-OrphanedNetNats
        $newCount = @(Get-NetNat -ErrorAction SilentlyContinue).Count
        if ($newCount -lt $natCount) {
            Write-Log "Scavenged $($natCount - $newCount) orphaned NAT(s). Remaining: $newCount." -Warning
        }
    }

    # ── Stale-networking safeguard ──────────────────────────────────────────
    # If the vSwitch exists but NO Hyper-V VMs are connected to it, the
    # switch/NAT/DHCP are left over from a failed removal of a previous
    # deployment.  Remove them so they get cleanly recreated below.
    # Skip shared switches (Internet, Cluster, External) — they are not
    # domain-specific and may legitimately have zero VMs temporarily.
    $isSharedSwitch = $NetworkName -in @('Internet', 'Cluster', 'ClusterV2', 'External')
    if (-not $isSharedSwitch) {
        $existingSwitch = Get-VMSwitch2 -NetworkName $NetworkName
        if ($existingSwitch) {
            $attachedVMs = @(Get-VM | Get-VMNetworkAdapter -ErrorAction SilentlyContinue |
                Where-Object { $_.SwitchName -eq $existingSwitch.Name })
            if ($attachedVMs.Count -eq 0) {
                Write-Log "Switch '$NetworkName' exists but no VMs are connected. Cleaning up stale networking." -Warning

                # Remove DHCP scope
                $dhcpScope = Get-DhcpServerv4Scope -ScopeID $NetworkSubnet -ErrorAction SilentlyContinue
                if ($dhcpScope) {
                    Write-Log "  Removing stale DHCP scope '$($dhcpScope.Name)' [$NetworkSubnet]" -Warning
                    $dhcpScope | Remove-DhcpServerv4Scope -Force -ErrorAction SilentlyContinue
                }

                # Remove NAT entry
                $nat = Get-NetNat -Name $NetworkSubnet -ErrorAction SilentlyContinue
                if ($nat) {
                    Write-Log "  Removing stale NAT '$NetworkSubnet'" -Warning
                    Remove-NetNat -Name $NetworkSubnet -Confirm:$false -ErrorAction SilentlyContinue
                }

                # Remove the switch itself
                Write-Log "  Removing stale switch '$($existingSwitch.Name)'" -Warning
                $existingSwitch | Remove-VMSwitch -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 3
            }
        }
    }

    $switch = Test-NetworkSwitch -NetworkName $NetworkName -NetworkSubnet $NetworkSubnet -DomainName $DomainName
    if (-not $switch) {
        Write-Log "Failed to verify/create Hyper-V switch for $NetworkName network ($NetworkSubnet). Exiting." -Failure
        return $false
    }

    # Test if DHCP scope exists, if not create it.
    # Test-DHCPScope handles starting the DHCP service internally via
    # Start-DHCP, so no preemptive service check is needed here.
    # If it fails (e.g. DHCP crashed), restart the service and retry once.
    $worked = Test-DHCPScope -ScopeID $NetworkSubnet -ScopeName $NetworkName -DomainName $DomainName -DNSServer $DNSServer
    if (-not $worked) {
        Write-Log "DHCP scope check failed for '$NetworkName'. Restarting DHCPServer and retrying..." -Warning
        Stop-Service "DHCPServer" -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        $dhcpOk = Start-DHCP
        if ($dhcpOk) {
            $worked = Test-DHCPScope -ScopeID $NetworkSubnet -ScopeName $NetworkName -DomainName $DomainName -DNSServer $DNSServer
        }
    }
    if (-not $worked) {
        Write-Log "Failed to verify/create DHCP Scope for the '$NetworkName' network. ($NetworkSubnet) Exiting." -Failure
        return $false
    }
    return $true
}

function Add-SwitchNoDhcp {
    # Creates a Hyper-V Internal switch with a host adapter IP but no DHCP
    # scope and no NAT. Used for the ClusterV2 heartbeat network where VMs
    # get static IPs and only need to reach each other on the same host.
    param (
        [Parameter(Mandatory = $true)]
        [string]$NetworkName,
        [Parameter(Mandatory = $true)]
        [string]$NetworkSubnet,
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf
    )

    if ($WhatIf.IsPresent) {
        Write-Log "[What-If] Will create/verify Hyper-V switch '$NetworkName' (no DHCP/NAT)."
        return $true
    }

    Write-Log "Creating/verifying Hyper-V switch '$NetworkName' (no DHCP, no NAT)." -Activity

    $switch = Test-NetworkSwitch -NetworkName $NetworkName -NetworkSubnet $NetworkSubnet
    if (-not $switch) {
        Write-Log "Failed to verify/create Hyper-V switch for $NetworkName network ($NetworkSubnet). Exiting." -Failure
        return $false
    }
    return $true
}

function Test-NetworkSwitch {
    param (
        [Parameter(Mandatory = $true, HelpMessage = "Network Name.")]
        [string]$NetworkName,
        [Parameter(Mandatory = $true, HelpMessage = "Network Subnet.")]
        [string]$NetworkSubnet,
        [Parameter(Mandatory = $false, HelpMessage = "Domain Name.")]
        [string]$DomainName
    )

    $mutexName = "networkswitch"

    $mtx = New-Object System.Threading.Mutex($false, $mutexName)
    write-log "Attempting to acquire '$mutexName' Mutex" -LogOnly
    [void]$mtx.WaitOne()
    write-log "acquired '$mutexName' Mutex" -LogOnly

    $notes = $DomainName
    $doNotRecreate = $false
    if (-not $notes) {
        $notes = $NetworkName
        if ($NetworkName -eq "Cluster") {
            $notes = "Cluster network shared by all domains"
            $doNotRecreate = $true
        }
        if ($NetworkName -eq "ClusterV2") {
            $notes = "Cluster heartbeat network shared by all domains (no DHCP)"
            $doNotRecreate = $true
        }
        if ($NetworkName -eq "Internet") {
            $notes = "Internet network shared by all domains"
            $doNotRecreate = $true
        }
    }

    if ([String]::IsNullOrWhiteSpace($DomainName)) {
        $notes = "Unknown network"        
    }
    if ($NetworkName -eq "External") {
        $notes = "External network shared by all domains"
        $doNotRecreate = $true
    }
    if ($notes -eq "Unknown network") {
        $doNotRecreate = $true
    }   

    try {
        $retries = 10
        $count = 0

        while ($count -lt $retries) {
            $count++
            $exists = Get-VMSwitch2 -NetworkName $NetworkName
            if ($exists) {
                if ([String]::IsNullOrWhiteSpace($exists.Notes)) {
                    if ($doNotRecreate -and $notes -ne "Unknown network") {
                        try {
                            Set-VMSwitch -VMSwitch $exists -Notes $notes -ErrorAction Stop | Out-Null
                            $exists = Get-VMSwitch2 -NetworkName $NetworkName
                            Write-Log "Updated notes on shared HyperV switch '$NetworkName' to '$notes'." -LogOnly
                        }
                        catch {
                            Write-Log "Failed to update notes on shared HyperV switch '$NetworkName'." -LogOnly
                            Write-Log "$($_.Exception.Message)" -LogOnly
                        }
                    }

                    if ([String]::IsNullOrWhiteSpace($exists.Notes)) {
                        Write-Log "HyperV Network switch for '$NetworkName' already exists but has no notes. Please verify this network is not in use by another domain." -LogOnly
                        Write-Log "Current Notes are: $($exists.Notes) but we expected $notes"  -LogOnly
                        $doNotRecreate = $true
                    }
                }

                if ($exists.Notes -eq "Unknown network") {
                    if ($doNotRecreate -and $notes -ne "Unknown network") {
                        try {
                            Set-VMSwitch -VMSwitch $exists -Notes $notes -ErrorAction Stop | Out-Null
                            $exists = Get-VMSwitch2 -NetworkName $NetworkName
                            Write-Log "Updated notes on shared HyperV switch '$NetworkName' from 'Unknown network' to '$notes'." -LogOnly
                        }
                        catch {
                            Write-Log "Failed to update notes on shared HyperV switch '$NetworkName'." -LogOnly
                            Write-Log "$($_.Exception.Message)" -LogOnly
                        }
                    }

                    if ($exists.Notes -eq "Unknown network") {
                        Write-Log "HyperV Network switch for '$NetworkName' already exists but is Unknown. Please verify this network is not in use by another domain." -LogOnly
                        Write-Log "Current Notes are: $($exists.Notes) but we expected $notes"  -LogOnly
                        $doNotRecreate = $true
                    }
                }

                if ($exists.Notes -eq $notes -or $doNotRecreate) {
                    Write-Log "HyperV Network switch for '$NetworkName' already exists."
                    break
                }
                else {
                    Write-Log "HyperV Network switch for '$NetworkName' already exists. Please verify this network is not in use by another domain."
                    Write-Log "Current Notes are: $($exists.Notes) but we expected $notes"  
                    return $false                              
                }
            }
            Write-Log "HyperV Network switch for '$NetworkName' not found. Creating a new one."
            try {
                New-VMSwitch -Name $NetworkName -SwitchType Internal -Notes $notes -ErrorAction Stop | Out-Null
            }
            catch {
                Write-Log "Failed to create HyperV Network switch for $NetworkName. Trying again in 30 seconds"
                start-sleep -seconds 30
                New-VMSwitch -Name $NetworkName -SwitchType Internal -Notes $notes -ErrorAction Continue | Out-Null
            }
            Start-Sleep -Seconds 5 # Sleep to make sure network adapter is present
            $exists = Get-VMSwitch2 -NetworkName $NetworkName
            if ($exists) {
                break
            }
        }

        try {
            $adapter = Get-NetAdapter | Where-Object { $_.Name -like "*$NetworkName*" }
            if ($null -ne $Common.CorpNetInterfaceIndex) {
                Set-DnsClient -InterfaceIndex $adapter.InterfaceIndex -RegisterThisConnectionsAddress $false -ErrorAction SilentlyContinue
            }
        }
        catch {
            Write-log "Get-NetAdapter $_" -LogOnly
            if ($_ -Match "the module could not be loaded" ) {
                Write-Log -Failure "Could not invoke Get-NetAdapter due to load failure.  Please close all powershell windows and retry."
            }
        }

        if (-not $adapter) {
            Write-Log "Network adapter for '$NetworkName' switch was not found."
            return $false
        }

        $interfaceAlias = $adapter.InterfaceAlias
        $desiredIp = $NetworkSubnet.Substring(0, $NetworkSubnet.LastIndexOf(".")) + ".200"

        $currentIps = @(Get-NetIPAddress -AddressFamily IPv4 -InterfaceAlias $interfaceAlias -ErrorAction SilentlyContinue)
        $hasDesired = $currentIps | Where-Object { $_.IPAddress -eq $desiredIp }
        if (-not $hasDesired) {
            Write-Log "$interfaceAlias IP is '$($currentIps.IPAddress -join ', ')'. Changing it to $desiredIp."
            # Remove any existing IPv4 addresses first; New-NetIPAddress cannot
            # replace an existing address on the same subnet and would either
            # fail or leave two IPs that confuse later validation.
            foreach ($staleIp in $currentIps) {
                Remove-NetIPAddress -InterfaceAlias $interfaceAlias -IPAddress $staleIp.IPAddress -Confirm:$false -ErrorAction SilentlyContinue
            }
            New-NetIPAddress -InterfaceAlias $interfaceAlias -IPAddress $desiredIp -PrefixLength 24 -ErrorAction SilentlyContinue | Out-Null
            Start-Sleep -Seconds 5 # Sleep to make sure IP changed
        }

        $currentIps = @(Get-NetIPAddress -AddressFamily IPv4 -InterfaceAlias $interfaceAlias -ErrorAction SilentlyContinue)
        $hasDesired = $currentIps | Where-Object { $_.IPAddress -eq $desiredIp }
        if (-not $hasDesired) {
            Write-Log "Unable to set IP for '$interfaceAlias' network adapter to $desiredIp."
            return $false
        }

        # Set vEthernet adapter to Private so the host firewall is less
        # restrictive for lab traffic. NLA classifies internal-switch adapters
        # as Public by default.
        $currentProfile = Get-NetConnectionProfile -InterfaceIndex $adapter.InterfaceIndex -ErrorAction SilentlyContinue
        if ($currentProfile -and $currentProfile.NetworkCategory -ne 'Private') {
            Write-Log "Setting '$interfaceAlias' network profile from '$($currentProfile.NetworkCategory)' to 'Private'."
            Set-NetConnectionProfile -InterfaceIndex $adapter.InterfaceIndex -NetworkCategory Private -ErrorAction SilentlyContinue
        }

        # Ensure a single host-wide rule allows inbound ICMPv4 Echo Request
        # from any RFC 1918 address. Windows Server disables the built-in
        # ICMP rule even on Private profile, so VMs cannot ping the host
        # .200 gateway without this. One rule covers all lab subnets.
        $icmpRuleName = 'MemLabs-ICMPv4-Echo-Private'
        $icmpRule = Get-NetFirewallRule -Name $icmpRuleName -ErrorAction SilentlyContinue
        if (-not $icmpRule) {
            Write-Log "Adding host firewall rule '$icmpRuleName' to allow inbound ICMPv4 Echo Request from private subnets."
            New-NetFirewallRule -Name $icmpRuleName -DisplayName 'MemLabs - Allow ICMPv4 Echo (Private Subnets)' `
                -Direction Inbound -Action Allow -Protocol ICMPv4 -IcmpType 8 `
                -RemoteAddress @('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16') `
                -Profile Any -Enabled True -ErrorAction SilentlyContinue | Out-Null
        }
        elseif ($icmpRule.Enabled -ne 'True') {
            Enable-NetFirewallRule -Name $icmpRuleName -ErrorAction SilentlyContinue
        }

        # Enable per-interface IPv4 forwarding so the host routes between lab
        # subnets (required for multi-subnet domains, e.g. a DC on one subnet
        # and clients on another). A vEthernet switch created AFTER the last
        # boot comes up with Forwarding=Disabled and is NOT retroactively
        # enabled by the global IpEnableRouter=1 flag until the next reboot,
        # so a host that created this switch mid-session (without rebooting)
        # would silently drop cross-subnet traffic at the .200 gateway. Set it
        # explicitly here so routing works on every host, every time, without a
        # reboot. ClusterV2 is intentionally excluded (heartbeat-only segment
        # that must never route); it short-circuits before this point.
        if ($NetworkName -ne 'ClusterV2') {
            $fwd = Get-NetIPInterface -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
            if ($fwd -and $fwd.Forwarding -ne 'Enabled') {
                Write-Log "Enabling IPv4 forwarding on '$interfaceAlias' (was '$($fwd.Forwarding)')."
                Set-NetIPInterface -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4 -Forwarding Enabled -ErrorAction SilentlyContinue
            }
        }

        # ClusterV2 is a pure internal switch — no NAT needed (heartbeat only)
        if ($NetworkName -eq 'ClusterV2') {
            return $true
        }

        $valid = Test-NetworkNat -NetworkSubnet $NetworkSubnet
        return $valid
    }
    finally {
        [void]$mtx.ReleaseMutex()
        [void]$mtx.Dispose()
    }
}

function Test-NoRRAS {

    $skiprrastxt = Join-Path $Common.ConfigPath "skipnoRRAS.txt"
    if (test-path $skiprrastxt) {
        Write-Log "Skipping No RRAS check."
        $natValid = Test-Networks
        if (-not $natValid) {
            exit 1
        }
        return
    }

    $router = (Get-ItemProperty -Path HKLM:\system\CurrentControlSet\services\Tcpip\Parameters).IpEnableRouter
    $routingFeatureInstalled = $false

    # Cache the Get-WindowsFeature result — ServerManager cmdlets ("Collecting
    # data...") can block for 30-120s on every invocation. The Routing feature
    # state only changes after explicit install/uninstall, so a cached result
    # is safe until the next reboot or feature change.
    $rrasCacheFile = Join-Path $Common.CachePath "rras-feature-state.json"
    $rrasCacheValid = $false
    if (Test-Path $rrasCacheFile) {
        try {
            $rrasCache = Get-Content $rrasCacheFile -ErrorAction SilentlyContinue | ConvertFrom-Json
            if ($rrasCache -and $null -ne $rrasCache.RoutingInstalled) {
                $rrasCacheAge = ((Get-Date) - [DateTime]::Parse($rrasCache.CheckedUtc)).TotalHours
                if ($rrasCacheAge -le 24) {
                    $routingFeatureInstalled = [bool]$rrasCache.RoutingInstalled
                    $rrasCacheValid = $true
                    Write-Log "Test-NoRRAS: Using cached Routing feature state (installed=$routingFeatureInstalled, age=$([Math]::Round($rrasCacheAge,1))h)." -LogOnly
                }
            }
        }
        catch {
            Write-Log "Test-NoRRAS: Failed reading RRAS cache: $_" -LogOnly
        }
    }

    if (-not $rrasCacheValid) {
        if (Get-Command -Name "Get-WindowsFeature" -ErrorAction SilentlyContinue) {
            try {
                Write-Log "Test-NoRRAS: Calling Get-WindowsFeature Routing (ServerManager — can be slow)..." -LogOnly
                $routingFeatureInstalled = [bool](Get-WindowsFeature Routing).Installed
                Write-Log "Test-NoRRAS: Get-WindowsFeature returned. Routing installed = $routingFeatureInstalled" -LogOnly
                # Cache the result
                try {
                    [PSCustomObject]@{
                        CheckedUtc       = (Get-Date).ToUniversalTime().ToString("o")
                        RoutingInstalled = $routingFeatureInstalled
                    } | ConvertTo-Json | Set-Content -Path $rrasCacheFile -Encoding UTF8
                }
                catch {}
            }
            catch {
                Write-Log "Test-NoRRAS: Get-WindowsFeature failed; continuing with router-state checks only. $_" -Warning
            }
        }
        else {
            Write-Log "Test-NoRRAS: Get-WindowsFeature is unavailable; continuing with router-state checks only." -Warning
        }
    }

    if ($routingFeatureInstalled -or $router -eq 0) {
        Set-ItemProperty -Path HKLM:\system\CurrentControlSet\services\Tcpip\Parameters -Name IpEnableRouter -Value 1
        if (Get-Command -Name "Uninstall-WindowsFeature" -ErrorAction SilentlyContinue) {
            Uninstall-WindowsFeature 'Routing', 'DirectAccess-VPN' -Confirm:$false -IncludeManagementTools -ErrorAction SilentlyContinue
        }
        else {
            Write-Log "Test-NoRRAS: Uninstall-WindowsFeature is unavailable; skipping RRAS feature removal." -Warning
        }
        try {
            Remove-VMSwitch2 -NetworkName "External"
        }
        catch {}
        $response = Read-YesOrNoWithTimeout -Prompt "Reboot needed after RRAS removal and IpEnableRouter TCP Value. Reboot now? (Y/n)" -HideHelp -Default "y" -timeout 300
        if ($response -eq "n") {
            Write-log "Please Reboot."
            Exit 1
        }
        Write-Log "Rebooting computer. Please re-run vmbuild.cmd when it comes up."
        Restart-Computer -Force
        Exit
    }
    else {
        # RRAS not found, test NAT
        $natValid = Test-Networks
        if (-not $natValid) {
            exit 1
        }
    }
}

function Test-Networks {

    # Self-heal IPv4 forwarding on every lab vEthernet switch (except ClusterV2,
    # a heartbeat-only segment that must never route). A switch created after the
    # last boot comes up Forwarding=Disabled and is NOT retroactively enabled by
    # the global IpEnableRouter=1 flag until the next reboot, which silently breaks
    # cross-subnet routing for multi-subnet domains. Add-SwitchAndDhcp enables it
    # per-switch at create/verify time; this sweep additionally fixes switches from
    # OTHER domains not in the current deploy, so an already-affected host recovers
    # on the next launch without a reboot. Runs every Test-Networks pass and is a
    # no-op once all switches are already Enabled.
    try {
        $fwdToFix = @(Get-NetIPInterface -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.InterfaceAlias -like 'vEthernet (*' -and $_.InterfaceAlias -ne 'vEthernet (ClusterV2)' -and $_.Forwarding -ne 'Enabled' })
        foreach ($iface in $fwdToFix) {
            Write-Log "Enabling IPv4 forwarding on '$($iface.InterfaceAlias)' (was '$($iface.Forwarding)')."
            Set-NetIPInterface -InterfaceIndex $iface.InterfaceIndex -AddressFamily IPv4 -Forwarding Enabled -ErrorAction SilentlyContinue
        }
    }
    catch {
        Write-Log "IPv4 forwarding self-heal sweep failed: $_" -LogOnly
    }

    $invalidNetworks = @()
    $networkList = Get-List -Type UniqueNetwork
    foreach ($network in $networkList) {
        $valid = Test-NetworkNat -NetworkSubnet $network
        if (-not $valid) {
            $invalidNetworks += $network
        }
    }

    $internetSubnet = "172.31.250.0"
    $valid = Test-NetworkNat -NetworkSubnet $internetSubnet
    if (-not $valid) {
        $invalidNetworks += $internetSubnet
    }

    # ClusterV2 is a pure internal switch (heartbeat only) — no NAT needed.
    # Remove any stale NAT left over from previous runs that incorrectly
    # created one; do not recreate it.
    $clusterNetwork = "10.250.250.0"
    $staleClusterNat = Get-NetNat -Name $clusterNetwork -ErrorAction SilentlyContinue
    if ($staleClusterNat) {
        Write-Log "Removing stale NAT '$clusterNetwork' (cluster network does not use NAT)." -Warning
        Remove-NetNat -Name $clusterNetwork -Confirm:$false -ErrorAction SilentlyContinue
    }

    if ($invalidNetworks.Count -gt 0) {
        Write-Log "Failed to verify whether following networks exist in NAT: $($invalidNetworks -join ', ')" -Failure
        return $false
    }

    return $true

}

function Test-NetworkNat {

    param (
        [Parameter(Mandatory = $false, HelpMessage = "Network Subnet.")]
        [string]$NetworkSubnet

    )

    $expectedPrefix = "$($NetworkSubnet)/24"
    $exists = Get-NetNat -Name $NetworkSubnet -ErrorAction SilentlyContinue
    if ($exists) {
        # Validate the existing NAT is healthy: correct prefix and the
        # internal interface still exists.  A partial removal of a
        # previous deployment can leave a stale NAT that has the right
        # name but references a deleted adapter, breaking all outbound
        # traffic for VMs on that subnet.
        $healthy = $true
        if ($exists.InternalIPInterfaceAddressPrefix -ne $expectedPrefix) {
            Write-Log "NAT '$NetworkSubnet' has wrong prefix '$($exists.InternalIPInterfaceAddressPrefix)' (expected '$expectedPrefix'). Recreating." -Warning
            $healthy = $false
        }
        if ($healthy) {
            # Check that the NAT's internal interface is reachable:
            # there should be a host adapter with an IP on this subnet.
            $subnetBase = $NetworkSubnet.Substring(0, $NetworkSubnet.LastIndexOf("."))
            $hostIp = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.IPAddress -like "$subnetBase.*" }
            if (-not $hostIp) {
                Write-Log "NAT '$NetworkSubnet' exists but no host adapter has an IP on $subnetBase.x. Recreating." -Warning
                $healthy = $false
            }
        }
        if ($healthy) {
            Write-Log "'$NetworkSubnet' is already present in NAT." -Verbose
            return $true
        }
        # Stale NAT — remove before recreating
        Write-Log "Removing stale NAT '$NetworkSubnet'..." -Warning
        Remove-NetNat -Name $NetworkSubnet -Confirm:$false -ErrorAction SilentlyContinue
    }

    try {
        Write-OrangePoint "'$NetworkSubnet' not found in NAT. Adding it."
        $skiprrastxt = Join-Path $Common.ConfigPath "skipnoRRAS.txt"
        if (test-path $skiprrastxt) {
            Write-WhiteI "Restarting RRAS service"
            Restart-Service RemoteAccess -ErrorAction Stop -WarningAction SilentlyContinue
        }

        New-NetNat -Name $NetworkSubnet -InternalIPInterfaceAddressPrefix $expectedPrefix -ErrorAction Stop
        return $true
    }
    catch {
        Write-Log "New-NetNat -Name $NetworkSubnet -InternalIPInterfaceAddressPrefix `"$expectedPrefix`" failed with error: $_" -Failure
        return $false
    }

}


function Repair-CimProxyTempPath {
    # CDXML/CIM-based modules (DhcpServer, ServerManager/Install-WindowsFeature,
    # NetTCPIP, etc.) generate temporary proxy module files
    # (remoteIpMoProxy_*.format.ps1xml) under the process TEMP directory at
    # import time. If that directory has been deleted mid-session -- e.g. a
    # cleanup task clearing %TEMP%, Storage Sense, or another process wiping
    # the user's temp folder -- Import-Module fails hard with:
    #   "Could not find a part of the path '...remoteIpMoProxy_...format.ps1xml'".
    # The module files themselves are still on disk, so -ListAvailable lies and
    # says everything's fine. Ensure every temp path the proxy generator might
    # use actually exists, recreating any that vanished. Returns $true if it had
    # to recreate at least one directory (i.e. a retry is worthwhile).
    #
    # NOTE: a FULL temp dir is NOT this failure (that surfaces as an
    # IOException / "not enough space on the disk"). But every CIM/CDXML import
    # LEAKS a remoteIpMoProxy_* folder here, and on a long-lived lab host these
    # accumulate into the thousands -- bloating enumeration and raising the odds
    # of a name collision during proxy generation. So we also opportunistically
    # prune stale leaked proxy folders (age-gated so an in-flight import is
    # never touched).
    $recreated = $false
    $tempPaths = @(
        ([System.IO.Path]::GetTempPath()),
        $env:TEMP,
        $env:TMP
    ) | Where-Object { $_ } | Select-Object -Unique

    foreach ($tp in $tempPaths) {
        try {
            if (-not (Test-Path -LiteralPath $tp)) {
                New-Item -ItemType Directory -Path $tp -Force -ErrorAction Stop | Out-Null
                Write-Log "Repair-CimProxyTempPath: Recreated missing temp directory '$tp' (CIM proxy module generation needs it)." -Warning
                $recreated = $true
                continue   # freshly created -- nothing to prune
            }

            # Hygiene: prune leaked CIM proxy folders older than 1 hour. The
            # 1-hour age gate guarantees we never delete the proxy folder of a
            # currently-running import (those are minutes old at most), so this
            # is safe to run unconditionally before every import. Only acts when
            # the leak has actually built up (>200 folders) to keep it cheap.
            $leaked = @(Get-ChildItem -LiteralPath $tp -Directory -Filter 'remoteIpMoProxy_*' -ErrorAction SilentlyContinue)
            if ($leaked.Count -gt 200) {
                $cutoff = (Get-Date).AddHours(-1)
                $stale = @($leaked | Where-Object { $_.LastWriteTime -lt $cutoff })
                $pruned = 0
                foreach ($dir in $stale) {
                    try {
                        Remove-Item -LiteralPath $dir.FullName -Recurse -Force -ErrorAction Stop
                        $pruned++
                    }
                    catch {
                        # In-use / locked folder -- skip it, it'll age out later.
                    }
                }
                if ($pruned -gt 0) {
                    Write-Log "Repair-CimProxyTempPath: Pruned $pruned stale leaked CIM proxy folder(s) from '$tp' ($($leaked.Count) total)." -LogOnly
                }
            }
        }
        catch {
            Write-Log "Repair-CimProxyTempPath: Failed to ensure/clean temp directory '$tp': $_" -Warning
        }
    }

    return $recreated
}

function Reset-CimProxyModuleState {
    # Companion to Repair-CimProxyTempPath for the case where recreating the temp
    # dir alone does NOT fix the "...remoteIpMoProxy_...format.ps1xml could not be
    # found" error (telltale sign: the SAME proxy GUID reappears on every retry).
    #
    # Under PowerShell 7 the Windows-only modules we need (ServerManager ->
    # Install-WindowsFeature, and DhcpServer when it's pulled in alongside it)
    # cannot load natively, so PS7 imports them through the Windows PowerShell
    # Compatibility feature: it spins up a loopback "WinPSCompatSession" and
    # generates an implicit-remoting PROXY module (remoteIpMoProxy_*_<guid>) under
    # %TEMP%. BOTH the session and that generated proxy module are cached in the
    # LIVE PS7 process. If the proxy's temp folder is later wiped (cleanup task /
    # Storage Sense), every subsequent import keeps pointing at the now-deleted
    # cached path and throws -- recreating the empty temp dir can't restore the
    # format.ps1xml inside the GUID folder. The cached session + module must be
    # torn down so the proxy is REGENERATED from scratch on the next import.
    # Returns $true if it tore anything down.
    $didReset = $false

    # 1. Unload any in-memory implicit-remoting proxy modules AND the real
    #    Windows modules, so a fresh import regenerates them cleanly.
    try {
        Get-Module |
            Where-Object { $_.Name -like 'remoteIpMoProxy_*' -or ($_.Path -and $_.Path -like '*remoteIpMoProxy_*') } |
            ForEach-Object {
                try { Remove-Module -ModuleInfo $_ -Force -ErrorAction Stop; $didReset = $true } catch { }
            }
    }
    catch { }
    foreach ($m in @('DhcpServer', 'ServerManager')) {
        if (Get-Module -Name $m -ErrorAction SilentlyContinue) {
            try { Remove-Module -Name $m -Force -ErrorAction Stop; $didReset = $true } catch { }
        }
    }

    # 2. Tear down the cached WinPS compatibility session(s) so the next import
    #    builds a brand-new proxy in the (repaired) temp dir instead of reusing
    #    the stale cached one.
    try {
        $compat = @(Get-PSSession -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like 'WinPSCompatSession*' })
        if ($compat.Count -gt 0) {
            $compat | Remove-PSSession -ErrorAction SilentlyContinue
            $didReset = $true
        }
    }
    catch { }

    if ($didReset) {
        Write-Log "Reset-CimProxyModuleState: Tore down cached WinPS-compat session/proxy modules so the CIM proxy regenerates on next import." -LogOnly
    }
    return $didReset
}

function Test-CimProxyStale {
    # Returns $true when PS7 has a WinPS-compat proxy cached in-process whose
    # backing %TEMP% folder has been DELETED -- the exact precondition for the
    # "remoteIpMoProxy_...format.ps1xml could not be found" failure. Letting the
    # proactive guard detect this lets it reset the stale session BEFORE the
    # first import is attempted, so the (recoverable but alarming) warning never
    # prints. Cheap and side-effect-free: it only inspects already-loaded
    # modules -- no Import-Module, no session creation, no temp writes -- so it's
    # safe to call on every Start-DHCP / Add-SwitchAndDhcp pass. A healthy
    # session (proxy folder still present) returns $false, so nothing is torn
    # down needlessly.
    try {
        $proxies = @(Get-Module | Where-Object {
                $_.Name -like 'remoteIpMoProxy_*' -or
                (($_.Name -in @('DhcpServer', 'ServerManager')) -and $_.Path -and $_.Path -like '*remoteIpMoProxy_*')
            })
        foreach ($m in $proxies) {
            if ($m.Path) {
                $dir = Split-Path -Parent $m.Path
                if ($dir -and -not (Test-Path -LiteralPath $dir)) {
                    return $true
                }
            }
        }
    }
    catch { }
    return $false
}

function Start-DHCP {
    # Install DHCP, if not found
    param (
        [Parameter(Mandatory = $false)]
        [switch]$Restart
    )

    if (-not (Get-Command -Name "Get-Service" -ErrorAction SilentlyContinue)) {
        Write-Log "Start-DHCP: Get-Service cmdlet is unavailable; skipping DHCP initialization." -Warning
        return $false
    }

    $dhcp = Get-Service -Name DHCPServer -ErrorAction SilentlyContinue
    if (-not $dhcp) {
        Write-OrangePoint "DHCP is not installed. Installing..."

        if (-not (Get-Command -Name "Install-WindowsFeature" -ErrorAction SilentlyContinue)) {
            Write-Log "Start-DHCP: Install-WindowsFeature is unavailable on this host. DHCP will not be installed automatically." -Warning
            return $false
        }

        $installed = Install-WindowsFeature 'DHCP' -Confirm:$false -IncludeAllSubFeature -IncludeManagementTools -ErrorAction SilentlyContinue

        if (-not $installed -or -not $installed.Success) {
            $exitCode = $null
            if ($installed) {
                $exitCode = $installed.ExitCode
            }
            Write-RedX "DHCP Installation failed $exitCode. Install DHCP windows feature manually, and try again." -Failure
            return $false
        }

        $dhcp = Get-Service -Name DHCPServer -ErrorAction SilentlyContinue
        if (-not $dhcp) {
            Write-Log "Start-DHCP: DHCP service is still unavailable after installation attempt." -Warning
            return $false
        }
    }

    if ($dhcp.Status -ne 'Running') {
        Start-Service "DHCPServer" -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 5
    }
    else {
        if ($Restart) {
            Restart-Service "DHCPServer" -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 5
        }
    }

    $dhcp = Get-Service -Name DHCPServer -ErrorAction SilentlyContinue
    if (-not $dhcp) {
        Write-Log "Start-DHCP: DHCP service is unavailable after start/restart attempt." -Warning
        return $false
    }

    if ($dhcp.Status -ne 'Running') {
        Start-Sleep -Seconds 10
        Start-Service "DHCPServer" -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 30
        $dhcp = Get-Service -Name DHCPServer -ErrorAction SilentlyContinue
        if (-not $dhcp -or $dhcp.Status -ne 'Running') {
            Write-Log "Start-DHCP: DHCP service failed to reach Running state." -Warning
            return $false
        }
    }

    # Verify the DhcpServer PowerShell module actually loads. Don't just
    # check -ListAvailable (files on disk) — the module is CDXML-based and
    # depends on the WMI/CIM service. If winmgmt is wedged the files exist
    # but Import-Module fails with "module could not be loaded".
    #
    # Proactively ensure the temp dir the CIM proxy generator writes to exists
    # (and prune any leaked proxy folders) BEFORE importing, so the common
    # "Could not find a part of the path '...remoteIpMoProxy_...format.ps1xml'"
    # failure is avoided outright rather than only handled after it throws.
    # Reset the cached WinPS-compat proxy if EITHER the temp dir had to be
    # recreated OR a proxy already loaded in-process points at a now-deleted
    # folder (Test-CimProxyStale) -- the latter is the common case where the
    # parent temp dir still exists but the GUID proxy subfolder was wiped, so a
    # dir-recreate alone wouldn't fire. Resetting here pre-empts the first-import
    # failure (and its alarming-but-recoverable warning) entirely.
    $needReset = Repair-CimProxyTempPath
    if ($needReset -or (Test-CimProxyStale)) {
        Reset-CimProxyModuleState | Out-Null
    }

    $moduleLoaded = $false
    try {
        Import-Module DhcpServer -Force -SkipEditionCheck -ErrorAction Stop
        $moduleLoaded = $true
    }
    catch {
        $importError = $_
        Write-Log "Start-DHCP: DhcpServer module failed to load: $importError" -Warning

        # First, classify the "missing temp path" failure explicitly. This is
        # the remoteIpMoProxy_*.format.ps1xml case: the module IS on disk, so
        # the -ListAvailable branch below would mis-route it to a pointless
        # winmgmt restart. Recreate the temp dir and retry before anything else.
        if ("$importError" -match 'remoteIpMoProxy|Could not find a part of the path') {
            Write-Log "Start-DHCP: Failure is a missing CIM-proxy temp path, not a WMI fault. Repairing temp directory + resetting cached compat proxy, then retrying..." -Warning
            # Recreate the temp dir AND tear down the cached WinPS-compat session
            # / proxy module. Recreating the dir alone is insufficient when PS7
            # has the (now-stale) implicit-remoting proxy cached in-process --
            # the reset forces the proxy to regenerate into the repaired dir.
            Repair-CimProxyTempPath | Out-Null
            Reset-CimProxyModuleState | Out-Null
            try {
                Import-Module DhcpServer -Force -SkipEditionCheck -ErrorAction Stop
                $moduleLoaded = $true
                Write-GreenCheck "DhcpServer module loaded after repairing the CIM-proxy temp directory and resetting the cached compat proxy."
            }
            catch {
                Write-Log "Start-DHCP: Module still won't load after temp-path repair + compat reset: $_" -Warning
            }
        }

        # Diagnose: are the module files even on disk?
        $moduleOnDisk = [bool](Get-Module DhcpServer -ListAvailable -ErrorAction SilentlyContinue)

        if (-not $moduleLoaded -and $moduleOnDisk) {
            # Files present but module won't load — likely WMI/CIM service
            # is in a bad state (CDXML modules use CIM under the hood).
            Write-Log "Start-DHCP: Module files exist on disk but won't load. Restarting WMI service (winmgmt)..." -Warning
            Restart-Service winmgmt -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 5
            # DHCP service depends on WMI; restarting winmgmt may stop it.
            Start-Service DHCPServer -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 3
            try {
                Import-Module DhcpServer -Force -SkipEditionCheck -ErrorAction Stop
                $moduleLoaded = $true
                Write-GreenCheck "DhcpServer module loaded after WMI service restart."
            }
            catch {
                Write-Log "Start-DHCP: Module still won't load after WMI restart: $_" -Failure
                Write-Log "Start-DHCP: A host reboot may be required. Original error: $importError" -Failure
            }
        }
        elseif (-not $moduleLoaded) {
            # Module files missing — RSAT tools were stripped (e.g. by a Windows Update).
            Write-OrangePoint "DhcpServer module is not installed. Reinstalling DHCP management tools..."
            if (Get-Command -Name "Install-WindowsFeature" -ErrorAction SilentlyContinue) {
                $installed = Install-WindowsFeature 'RSAT-DHCP' -Confirm:$false -ErrorAction SilentlyContinue
                if (-not $installed -or -not $installed.Success) {
                    $installed = Install-WindowsFeature 'DHCP' -Confirm:$false -IncludeAllSubFeature -IncludeManagementTools -ErrorAction SilentlyContinue
                }
                if ($installed -and $installed.Success) {
                    Import-Module DhcpServer -Force -SkipEditionCheck -ErrorAction SilentlyContinue
                    $moduleLoaded = $true
                    Write-GreenCheck "DHCP management tools reinstalled."
                }
                else {
                    Write-Log "Start-DHCP: Failed to reinstall DHCP management tools. Run 'Install-WindowsFeature RSAT-DHCP' manually." -Failure
                }
            }
            else {
                Write-Log "Start-DHCP: DhcpServer module is missing and Install-WindowsFeature is unavailable. Install RSAT-DHCP manually." -Failure
            }
        }
    }

    if (-not $moduleLoaded) {
        return $false
    }

    return $true
}

function Test-DHCPScope {
    param (
        [Parameter(Mandatory = $true, HelpMessage = "DHCP Scope ID.")]
        [string]$ScopeID,
        [Parameter(Mandatory = $true, HelpMessage = "DHCP Scope Name.")]
        [string]$ScopeName,
        [Parameter(Mandatory = $false, HelpMessage = "DHCP Domain Name option.")]
        [string]$DomainName,
        [Parameter(Mandatory = $false, HelpMessage = "Override DNS Server")]
        [string]$DNSServer
    )
    try {

        write-log -logonly "Test-DHCPScope called with ScopeID: $ScopeID ScopeName: $ScopeName DomainName: $DomainName DNSSERVER: $DNSServer"
        # Define Lease Time. Use 365 days for all scopes -- lab VMs on
        # small subnets rarely churn, and Linux VMs (which lack LLMNR) are
        # referenced by IP in RDCMan, so a short lease would break those
        # entries when the IP changes.
        $leaseTimespan = New-TimeSpan -Days 365
        $DomainScope = [bool]$DomainName

        # Install DHCP, if not found


        $dhcp = Start-DHCP
        if (-not $dhcp) {
            Write-Log "DHCP Could not be started" -Failure
            return $false
        }

        # Define scope options
        $DHCPDNSAddress = $null
        $network = $ScopeID.Substring(0, $ScopeID.LastIndexOf("."))
        if ($ScopeName -notin ("cluster", "Internet")) {
            if ($DNSServer) {
                $DHCPDNSAddress = $DNSServer
            }
            else {
                $DC = get-list -type VM -domain $DomainName | Where-Object { $_.Role -eq "DC" }
                if ($DC) {
                    $DHCPDNSAddress = ($DC.Network.Substring(0, $DC.Network.LastIndexOf(".")) + ".1")
                }
                else {
                    $DHCPDNSAddress = $network + ".1"
                }
            }
        }


        # Check if scope exists
        $createScope = $false
        $updateOptions = $false
        $scope = Get-DhcpServerv4Scope -ScopeId $scopeID -ErrorAction SilentlyContinue
        if ($scope) {
            if ($DHCPDNSAddress) {
                $scopeOptions = get-DhcpServerv4OptionValue -scopeID $scopeID -ErrorAction SilentlyContinue
                $currentDNS = ($scopeOptions | Where-Object OptionID -eq 6).Value
                if ($currentDNS -ne $DHCPDNSAddress) {
                    Write-OrangePoint "'$ScopeID ($ScopeName)' scope DNS ($currentDNS) does not match preferred ($DHCPDNSAddress) — updating options in-place"
                    $updateOptions = $true
                }
                else {
                    Write-GreenCheck "'$ScopeID ($ScopeName)' scope is already present in DHCP."
                }
            }
            else {
                Write-GreenCheck "'$ScopeID ($ScopeName)' scope is already present in DHCP."
            }
        }
        else {
            Write-OrangePoint "'$ScopeID ($ScopeName)' scope is not present in DHCP. Creating new scope"
            $createScope = $true
        }

        $dhcp = Start-DHCP
        if (-not $dhcp) {
            Write-Log "DHCP Could not be started" -Failure
            return $false
        }

        $DHCPDefaultGateway = $network + ".200"
        # Proxy VM (Linux) gets a static .2 via cloud-init; not in the DHCP pool.
        $DHCPScopeStart = $network + ".20"
        $DHCPScopeEnd = $network + ".199"

        $scope = $null
        # Create scope, if needed
        $maxRetries = 3
        $retry = 0
        if ($createScope) {

            Write-WhiteI "Creating '$ScopeID ($ScopeName)' scope with DHCPDefaultGateway: $DHCPDefaultGateway DHCPScopeStart: $DHCPScopeStart DHCPScopeEnd: $DHCPScopeEnd DNSServer: $DHCPDNSAddress "
            while (-not $scope) {
                try {
                    if ($retry -gt 0) {
                        if ($retry -ge $maxRetries) {
                            Write-Log "Max Retries Exceeded. Failed to add '$ScopeID ($ScopeName)' to DHCP." -Failure
                            return $false
                        }
                        $dhcp = Start-DHCP
                        if (-not $dhcp) {
                            Write-Log "DHCP Could not be started" -Failure
                            return $false
                        }
                    }
                    $retry++
                    Add-DhcpServerv4Scope -Name $ScopeName -StartRange $DHCPScopeStart -EndRange $DHCPScopeEnd -SubnetMask 255.255.255.0 -LeaseDuration $leaseTimespan -ErrorAction Stop -ErrorVariable ScopeErr
                    $scope = Get-DhcpServerv4Scope -ScopeId $ScopeID -ErrorVariable ScopeErr -ErrorAction Stop
                    if ($scope) {
                        Write-GreenCheck "'$ScopeID ($ScopeName)' scope added to DHCP."
                    }
                    else {
                        Write-Log "Failed to add '$ScopeID ($ScopeName)' to DHCP. $ScopeErr" -Failure
                    }
                }
                catch {
                    Write-Log "Exception: Failed to add '$ScopeID ($ScopeName)' to DHCP. $_" -Failure
                    if ($_ -like '*Failed to get version of the DHCP server*') {
                        write-log -Failure "DHCP service is not connectable.  Please reboot your LABHOST VM."
                        return $false
                    }
                    $dhcp = Start-DHCP -restart
                    if (-not $dhcp) {
                        Write-Log "DHCP Could not be started" -Failure
                        return $false
                    }
                }
            }
        }

        # After creating a new scope, rebuild DHCP reservations from existing
        # VM notes and MAC addresses. This restores reservations for Linux VMs
        # (which rely on stable IPs for SSH/mRemoteNG) and any other VMs that
        # had reservations before the scope was lost.
        if ($createScope -and $DomainScope) {
            try {
                $existingVms = Get-List -Type VM -DomainName $DomainName -ErrorAction SilentlyContinue
                if ($existingVms) {
                    $rebuilt = 0
                    foreach ($evm in $existingVms) {
                        $vmNote = Get-VMNote -VMName $evm.vmName -ErrorAction SilentlyContinue
                        if (-not $vmNote -or -not $vmNote.LastKnownIP) { continue }
                        $ip = $vmNote.LastKnownIP
                        # Only rebuild if the IP falls within this scope's range
                        if ($ip -notlike "$network.*") { continue }
                        $vmnet = Get-VM2 -Name $evm.vmName -ErrorAction SilentlyContinue | Get-VMNetworkAdapter -ErrorAction SilentlyContinue
                        if (-not $vmnet -or -not $vmnet.MacAddress) { continue }
                        try {
                            Add-DhcpServerv4Reservation -ScopeId $scopeID -IPAddress $ip -ClientId $vmnet.MacAddress `
                                -Description "Reservation for $($evm.vmName) (rebuilt)" -ErrorAction Stop | Out-Null
                            $rebuilt++
                            Write-Log "Rebuilt DHCP reservation: $($evm.vmName) $ip -> $($vmnet.MacAddress)" -Verbose
                        }
                        catch {
                            Write-Log "Could not rebuild DHCP reservation for $($evm.vmName) ($ip): $_" -Warning
                        }
                    }
                    if ($rebuilt -gt 0) {
                        Write-Log "Rebuilt $rebuilt DHCP reservation(s) for scope '$scopeID' from VM notes" -Verbose
                    }
                }
            }
            catch {
                Write-Log "Failed to rebuild DHCP reservations for scope '$scopeID': $_" -Warning
            }
        }

        # Set or update scope options (for new scopes AND existing scopes
        # whose DNS option needs updating). Updating in-place preserves
        # all existing leases and reservations.
        if ($createScope -or $updateOptions) {
            try {
                if (-not $DomainScope) {
                    if ($ScopeName -eq "cluster") {
                        # Cluster/heartbeat NICs must not have a default gateway,
                        # DNS, or any other DHCP options. Just the scope is enough.
                        Write-GreenCheck "Cluster scope '$ScopeID' created (no DHCP options needed)."
                        return $true
                    }
                    else {
                        $HashArguments = @{
                            ScopeId   = $ScopeID
                            Router    = $DHCPDefaultGateway
                            DnsServer = @("4.4.4.4", "8.8.8.8")
                        }
                    }
                }
                else {
                    $HashArguments = @{
                        ScopeId    = $ScopeID
                        Router     = $DHCPDefaultGateway
                        DnsDomain  = $DomainName
                        WinsServer = $DHCPDNSAddress
                        DnsServer  = $DHCPDNSAddress
                    }
                }

                Set-DhcpServerv4OptionValue @HashArguments -Force -ErrorAction Stop
                Write-GreenCheck "Added/updated scope options for '$ScopeID ($ScopeName)' scope in DHCP."
                return $true
            }
            catch {
                Write-Log "Failed to add/update scope options for '$ScopeID ($ScopeName)' scope in DHCP. $_" -Failure
                Write-Log "$($_.ScriptStackTrace)" -LogOnly
                return $false
            }
        }
        return $true
    }
    catch {
        Write-Log $_
        Write-Exception -ExceptionInfo $_
        return $false
    }
}

function New-VmNote {
    param (
        [Parameter(Mandatory = $true)]
        [string]$VmName,
        [Parameter(Mandatory = $false)]
        [object]$DeployConfig,
        [Parameter(Mandatory = $false)]
        [bool]$Successful,
        [Parameter(Mandatory = $false)]
        [bool]$InProgress,
        [Parameter(Mandatory = $false)]
        [int]$Phase,
        [Parameter(Mandatory = $false)]
        [switch]$UpdateVersion,
        [Parameter(Mandatory = $false)]
        [bool]$Force = $false
    )

    try {
        $ProgressPreference = 'SilentlyContinue'

        $ThisVM = $DeployConfig.virtualMachines | Where-Object { $_.vmName -eq $VmName }

        $network = $DeployConfig.vmOptions.network
        if ($ThisVm.network) {
            $network = $ThisVm.network
        }

        $vmNote = [PSCustomObject]@{
            inProgress           = $InProgress
            success              = $Successful
            role                 = $ThisVM.role
            deployedOS           = $ThisVM.operatingSystem
            domain               = $DeployConfig.vmOptions.domainName
            domainNetBiosName    = $DeployConfig.vmOptions.domainNetBiosName
            adminName            = $DeployConfig.vmOptions.adminName
            network              = $network
            prefix               = $DeployConfig.vmOptions.prefix
            memLabsDeployVersion = $Common.MemLabsVersion
        }

        # Track the highest phase that has ever completed successfully on this VM.
        # Monotonic: a -StartPhase N re-run must not drop the value from (say) 11
        # down to N, because the Phase 8 auto-snapshot guard reads this as
        # "has this CAS/Primary ever finished Phase 8?" (lastPhaseComplete >= 8).
        $existingNote = Get-VMNote -VMName $VmName
        $existingMax = if ($existingNote -and $existingNote.lastPhaseComplete) { [int]$existingNote.lastPhaseComplete } else { 0 }
        if ($Successful -and $Phase -gt 0) {
            $newMax = [Math]::Max($existingMax, [int]$Phase)
            $vmNote | Add-Member -MemberType NoteProperty -Name "lastPhaseComplete" -Value $newMax -Force
        }
        elseif ($existingMax -gt 0) {
            $vmNote | Add-Member -MemberType NoteProperty -Name "lastPhaseComplete" -Value $existingMax -Force
        }

        if ($UpdateVersion.IsPresent) {
            $vmNote | Add-Member -MemberType NoteProperty -Name "memLabsVersion" -Value $Common.MemLabsVersion -Force
        }

        foreach ($prop in $ThisVM.PSObject.Properties) {
            if ($prop.Name -eq "thisParams" -or $prop.Name -eq "SQLAO") {
                continue
            }
            $vmNote | Add-Member -MemberType NoteProperty -Name $prop.Name -Value $prop.Value -Force
        }

        Write-Log "Checking if we can write out domainDefaults" -Verbose
        if ($null -ne $DeployConfig.domainDefaults -and $ThisVm.role -eq "DC") {
            Write-Log "Writing out domainDefaults Value: $($DeployConfig.domainDefaults.DeploymentType)"
            $vmNote | Add-Member -MemberType NoteProperty -Name "domainDefaults" -Value $($DeployConfig.domainDefaults) -Force
        }

        # Store pkiOptions on the DC so new deployments to this domain can detect PKI state
        if ($null -ne $DeployConfig.pkiOptions -and $ThisVm.role -eq "DC") {
            Write-Log "Writing out pkiOptions on DC (EnablePKI: $($DeployConfig.pkiOptions.EnablePKI))"
            $vmNote | Add-Member -MemberType NoteProperty -Name "pkiOptions" -Value $($DeployConfig.pkiOptions) -Force
        }

        # Store cmOptions on the top-level site server (CAS or standalone Primary) so new
        # deployments to this domain can detect features like EnableBLM from the VM note.
        if ($null -ne $DeployConfig.cmOptions -and $ThisVm.role -in @('CAS', 'Primary') -and -not $ThisVm.parentSiteCode) {
            Write-Log "Writing out cmOptions on top-level site server (EnableBLM: $($DeployConfig.cmOptions.EnableBLM))"
            $vmNote | Add-Member -MemberType NoteProperty -Name "cmOptions" -Value $($DeployConfig.cmOptions) -Force
        }

        Set-VMNote -vmName $vmName -vmNote $vmNote -force:$Force

    }
    catch {
        Write-Log "Failed to add a note to the VM '$VmName' in Hyper-V. $_" -Failure
        Write-Log "$($_.ScriptStackTrace)" -LogOnly
    }
    finally {
        $ProgressPreference = 'Continue'
    }
}

function Get-VMNote {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$VMName
    )

    $vm = Get-VM2 -Name $VMName -Fallback

    if (-not $vm) {
        # VM not found is a normal condition (e.g. Phase 1 pre-allocation queries
        # notes for VMs that don't exist yet). Log quietly without a bogus
        # "Error:" suffix -- there's no exception in scope here, so $_ is blank.
        Write-Log "$VMName`: VM not found in Hyper-V; no VM Note to read." -Verbose -LogOnly
        return $null
    }

    $vmNoteObject = $null
    try {
        if ($vm.Notes -like "*lastUpdate*") {
            try {
                $vmNoteObject = $vm.Notes | ConvertFrom-Json
            }
            catch {
                return $null
            }

            if (-not $vmNoteObject.adminName) {
                # we renamed this property, read as "adminName" if it exists
                $vmNoteObject | Add-Member -MemberType NoteProperty -Name "adminName" -Value $vmNoteObject.domainAdmin  -Force
            }

            return $vmNoteObject
        }
        else {
            Write-Log "$VMName`: VM Properties do not contain values. Assume this was not deployed by vmbuild. $_" -Verbose -LogOnly -Warning
            return $null
        }
    }
    catch {
        Write-Log "Failed to get VM Properties for '$($vm.Name)'. $_" -Failure
        Write-Log "$($_.ScriptStackTrace)" -LogOnly
        return $null
    }
}

function Get-DomainNetbiosName {
    <#
    .SYNOPSIS
        Resolve the authoritative NetBIOS domain name for a MemLabs domain from its
        persisted VM notes -- NEVER derived from the DNS FQDN (wrong in a disjoint
        namespace where the NetBIOS name differs from the DNS first label).
    .DESCRIPTION
        Set-VMNote stamps domainNetBiosName (the value the domain was actually created
        with, i.e. deployConfig.vmOptions.domainNetBiosName -> Phase 2 ADDomain
        DomainNetBiosName) onto every VM note of the domain. This reads it back so a
        CROSS-domain caller (e.g. a forest-trust peer) can get the correct NetBIOS name
        of another domain on the host by reading that domain's notes instead of guessing
        from its FQDN. Returns $null when no note carries the value (caller may then fall
        back to the DNS label with a warning).
    .PARAMETER DomainName
        DNS/FQDN of the domain whose NetBIOS name is wanted.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$DomainName
    )
    try {
        $vms = @(Get-List -Type VM -DomainName $DomainName -SmartUpdate | Where-Object { $_.domainNetBiosName })
        if ($vms.Count -eq 0) { return $null }
        # Prefer the DC's note (the canonical per-domain record); else any VM in the domain.
        $dc = @($vms | Where-Object { $_.role -eq 'DC' } | Select-Object -First 1)
        $pick = if ($dc) { $dc } else { @($vms | Select-Object -First 1) }
        if ($pick -and $pick.domainNetBiosName) { return [string]$pick.domainNetBiosName }
    }
    catch {
        Write-Log "Get-DomainNetbiosName failed for '$DomainName': $($_.Exception.Message)" -LogOnly -Verbose
    }
    return $null
}

function Set-VMNote {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, ParameterSetName = "VMNote")]
        [Parameter(Mandatory = $true, ParameterSetName = "VMVersion")]
        [Parameter(Mandatory = $true, ParameterSetName = "FixOnly")]
        [string]$vmName,
        [Parameter(Mandatory = $true, ParameterSetName = "VMNote")]
        [Parameter(Mandatory = $false, ParameterSetName = "VMVersion")]
        [object]$vmNote,
        [Parameter(Mandatory = $false, ParameterSetName = "VMNote")]
        [Parameter(Mandatory = $true, ParameterSetName = "VMVersion")]
        [string]$vmVersion,
        [Parameter(Mandatory = $false)]
        [switch]$forceVersionUpdate,
        [Parameter(Mandatory = $false)]
        [bool]$force,
        [Parameter(Mandatory = $true, ParameterSetName = "FixOnly")]
        [Parameter(Mandatory = $false, ParameterSetName = "VMNote")]
        [Parameter(Mandatory = $false, ParameterSetName = "VMVersion")]
        [string]$FixApplied,
        [Parameter(Mandatory = $false)]
        [string]$FixAppliedVersion
    )

    if (-not $vmNote) {
        $vmNote = Get-VMNote -VMName $vmName
    }
    if ($force -eq $false) {
        #If we are not forcing an overwrite, use the new note to update the contents of the old note.
        #Old Note may have more properties than the new note, and we do not want to lose those.
        $oldvmNote = Get-VMNote -VMName $vmName
        if ($oldvmNote) {
            foreach ($note in $vmNote.PSObject.Properties) {
                $oldvmNote | Add-Member -MemberType NoteProperty -Name $note.Name -Value $note.Value -Force
            }
            $vmNote = $oldvmNote
        }
    }

    $vmVersionUpdated = $false
    if ($vmVersion -and ((ConvertTo-MemLabsVersion $vmNote.memLabsVersion) -lt (ConvertTo-MemLabsVersion $vmVersion) -or $forceVersionUpdate.IsPresent)) {
        $vmNote | Add-Member -MemberType NoteProperty -Name "memLabsVersion" -Value $vmVersion -Force
        $vmVersionUpdated = $true
    }

    # Per-fix tracking: record individual fix application in appliedFixes dictionary
    if ($FixApplied) {
        $appliedFixes = @{}
        if ($vmNote.PSObject.Properties.Name -contains 'appliedFixes' -and $vmNote.appliedFixes) {
            foreach ($prop in $vmNote.appliedFixes.PSObject.Properties) {
                $appliedFixes[$prop.Name] = $prop.Value
            }
        }
        $appliedFixes[$FixApplied] = $FixAppliedVersion
        $vmNote | Add-Member -MemberType NoteProperty -Name "appliedFixes" -Value ([PSCustomObject]$appliedFixes) -Force
    }

    $vmNote | Add-Member -MemberType NoteProperty -Name "lastUpdate" -Value (Get-Date -format "MM/dd/yyyy HH:mm") -Force
    $vmNoteJson = ($vmNote | ConvertTo-Json) -replace "`r`n", "" -replace "    ", " " -replace "  ", " "
    $vm = Get-VM2 $VmName -Fallback
    if ($vm) {
        # Skip the Set-VM -Notes round trip when nothing meaningful changed.
        # Set-VM is a CIM call into vmms.exe and serializes behind whatever the
        # VMMS is doing for this VM (state transitions, integration services
        # handshakes, checkpoint merges, replication, etc.). On a healthy host
        # it's cheap, but if vmms is stalled on one VM, every Set-VMNote in the
        # init-time Update-VMInformation loop will block for seconds-to-minutes
        # each. Most callers just want the in-memory note refreshed; only
        # lastUpdate differs between successive calls, so compare the JSON with
        # lastUpdate stripped and skip the write when it matches.
        $stripLastUpdate = { param($s) if ($s) { ($s -replace '"lastUpdate"\s*:\s*"[^"]*"\s*,?\s*', '') } else { $s } }
        $newNoteForCompare = & $stripLastUpdate $vmNoteJson
        $existingNoteForCompare = & $stripLastUpdate $vm.Notes
        if ($newNoteForCompare -eq $existingNoteForCompare -and -not $vmVersionUpdated) {
            Write-Log "Skipping Set-VM -Notes for $vmName; notes unchanged." -LogOnly
            return
        }

        if ($vmVersionUpdated) {
            Write-Log "Setting VM Note for $vmName (version $vmVersion)" -LogOnly
        }
        else {
            Write-Log "Setting VM Note for $vmName to $vmNoteJson" -LogOnly
        }

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $vm | Set-VM -Notes $vmNoteJson -ErrorAction Stop
        }
        finally {
            $sw.Stop()
            if ($sw.Elapsed.TotalSeconds -ge 5) {
                Write-Log "Set-VM -Notes for $vmName took $([Math]::Round($sw.Elapsed.TotalSeconds,1))s (vmms may be busy)." -Warning
            }
        }
    }
    else {
        Write-Log "Failed to get VM from Hyper-V. Cannot set VM Note for $vmName" -Verbose
    }
}

function Update-VMNoteVersion {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$vmName,
        [Parameter(Mandatory = $false)]
        [string]$vmVersion
    )

    $vmNote = Get-VMNote -VMName $VmName
    $vmNote | Add-Member -MemberType NoteProperty -Name "memLabsVersion" -Value $vmVersion -Force
    Set-VMNote -vmName $VmName -vmNote $vmNote
}

function Update-VMNoteProperty {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$VmName,
        [Parameter(Mandatory = $true)]
        [string]$PropertyName,
        [Parameter(Mandatory = $true)]
        [string]$PropertyValue
    )

    $vmNote = Get-VMNote -VMName $VmName
    $vmNote | Add-Member -MemberType NoteProperty -Name $PropertyName -Value $PropertyValue -Force
    Set-VMNote -vmName $VmName -vmNote $vmNote
}

function Remove-DnsRecord {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$DCName,
        [Parameter(Mandatory = $true)]
        [string]$Domain,
        [Parameter(Mandatory = $true)]
        [string]$RecordToDelete
    )

    # Write-Host "DCName $DCName, Domain $Domain, RecordToDelete $RecordToDelete"

    $scriptBlock1 = {
        #Get-ADComputer -Identity $using:RecordToDelete -ErrorAction SilentlyContinue | Remove-ADObject -Recursive -ErrorAction SilentlyContinue -Confirm:$False
        Get-DnsServerResourceRecord -ZoneName $using:Domain -Node $using:RecordToDelete -RRType A
    }

    $scriptBlock2 = {
        $NodeDNS = Get-DnsServerResourceRecord -ZoneName $using:Domain -Node $using:RecordToDelete -RRType A -ErrorAction SilentlyContinue
        if ($NodeDNS) {
            Remove-DnsServerResourceRecord -ZoneName $using:Domain -InputObject $NodeDNS -Force -ErrorAction SilentlyContinue
        }
    }

    $result = Invoke-VmCommand -VmName $DCName -VmDomainName $Domain -ScriptBlock $scriptBlock1 -SuppressLog
    if ($result.ScriptBlockFailed) {
        Write-Log "DNS resource record for $RecordToDelete was not found." -LogOnly
    }
    else {
        $result = Invoke-VmCommand -VmName $DCName -VmDomainName $Domain -ScriptBlock $scriptBlock2 -SuppressLog
        if ($result.ScriptBlockFailed) {
            Write-OrangePoint "Failed to remove DNS resource record for $RecordToDelete. Please remove the record manually."
        }
        else {
            Write-GreenCheck "Removed DNS resource record for $RecordToDelete"
        }
    }
}

function Get-DhcpScopeDescription {
    param (
        [Parameter(Mandatory = $true, HelpMessage = "DHCP Scope ID.")]
        [string]$ScopeId
    )

    try {
        $scope = Get-DhcpServerv4Scope -ScopeId $ScopeId -ErrorAction Stop
        $scopeDescObject = $scope.Description | ConvertFrom-Json
        return $scopeDescObject

    }
    catch {
        Write-Log "Failed to get description for '$ScopeId' scope in DHCP. $_" -Failure
        Write-Log "$($_.ScriptStackTrace)" -LogOnly
        return $null
    }
}

function Invoke-IsolatedCim {
    <#
    .SYNOPSIS
    Runs a scriptblock containing CIM-based cmdlets (DhcpServer, Hyper-V) in a
    reused, throwaway in-process runspace, isolated from the caller's runspace.

    .DESCRIPTION
    PowerShell 7 begins auto-forwarding (and draining) a Start-Job child's
    Progress stream the instant a CIM cmdlet that emits progress (e.g. the
    DhcpServer CDXML cmdlets) runs in that child's runspace. Once that happens
    the child's .Progress collection stops accumulating the managed per-VM
    progress records that Write-JobProgress renders in Wait-Phase, so the
    per-VM progress bars collapse into a single forwarded bar. The damage is
    permanent for the lifetime of the runspace -- even synthetic Write-Progress
    records stop accumulating after a single CIM call.

    Running the CIM cmdlet in a SEPARATE in-process runspace attaches that
    auto-forward/drain to the throwaway runspace instead, leaving the caller's
    (child job's) own .Progress stream clean so the managed bars keep rendering.

    The isolated runspace is created fresh for each call and disposed before
    returning. It must NOT be cached/reused for the lifetime of the child job:
    a persistent isolated runspace keeps a Hyper-V / DhcpServer CIM connection
    open in-process, which interferes with the PowerShell Direct sessions
    Phase 1 uses for disk init (the in-guest Storage cmdlets hang). The CIM
    cmdlets here run only a handful of times per VM, so the per-call module
    import cost is negligible. The scriptblock runs in a fresh session state:
    it sees only native cmdlets/modules and whatever is passed via
    -ArgumentList (declare a matching param() block). It does NOT see the
    caller's functions (Write-Log, Get-VM2, etc.) or variables.

    .PARAMETER ScriptBlock
    The scriptblock to execute in isolation. Use only native cmdlets inside it.

    .PARAMETER ArgumentList
    Positional arguments passed to the scriptblock's param() block.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock] $ScriptBlock,
        [object[]] $ArgumentList
    )

    # Create a FRESH throwaway runspace for this call and dispose it in the
    # finally below. Do NOT cache/reuse a global runspace: a lingering isolated
    # runspace holds a Hyper-V / DhcpServer CIM connection open in-process for
    # the whole life of the child job, and that interferes with the PowerShell
    # Direct sessions Phase 1 uses for disk init (in-guest Storage cmdlets hang).
    $ps = [System.Management.Automation.PowerShell]::Create()
    try {
        $null = $ps.AddScript($ScriptBlock.ToString())
        if ($ArgumentList) {
            foreach ($arg in $ArgumentList) { $null = $ps.AddArgument($arg) }
        }

        # Invoke() throws for terminating errors (e.g. -ErrorAction Stop inside
        # the scriptblock), which preserves the caller's existing try/catch
        # semantics. The results are materialized before the finally disposes
        # the runspace, so returning them is safe.
        return $ps.Invoke()
    }
    finally {
        try { $ps.Runspace.Close() } catch {}
        try { $ps.Dispose() } catch {}
    }
}

# Return the (primary) NIC MAC for a VM, looked up in an isolated runspace so
# the Hyper-V CIM query never poisons the caller's progress stream. When
# -ExcludeCluster is set, SQLAO Cluster heartbeat NICs are filtered out.
function Get-VMMacIsolated {
    param(
        [Parameter(Mandatory = $true)][string] $VmName,
        [switch] $ExcludeCluster
    )
    return Invoke-IsolatedCim -ArgumentList $VmName, $ExcludeCluster.IsPresent -ScriptBlock {
        param($vmName, $excludeCluster)
        $nic = Get-VM -Name $vmName -ErrorAction Stop | Get-VMNetworkAdapter
        if ($excludeCluster) {
            $nic = $nic | Where-Object { -not $_.SwitchName -or $_.SwitchName -notmatch 'Cluster' }
        }
        $nic = $nic | Select-Object -First 1
        if ($nic) { [string]$nic.MacAddress } else { $null }
    }
}

# Return the IP of an existing DHCP reservation matching $Mac in $ScopeId, or
# $null. Runs the DhcpServer CIM query in an isolated runspace.
function Get-DHCPReservationIPForMac {
    param(
        [Parameter(Mandatory = $true)][string] $ScopeId,
        [Parameter(Mandatory = $true)][string] $Mac
    )
    return Invoke-IsolatedCim -ArgumentList $ScopeId, $Mac -ScriptBlock {
        param($scopeId, $mac)
        $r = Get-DhcpServerv4Reservation -ScopeId $scopeId -ErrorAction SilentlyContinue |
            Where-Object { ($_.ClientId -replace '-', '') -eq $mac }
        # Do NOT use $r.IPAddress.IPAddressToString here. In the fresh
        # [PowerShell]::Create() runspace the DhcpServer CDXML cmdlet is
        # visible but its types.ps1xml adapter (which turns .IPAddress into a
        # [System.Net.IPAddress]) is not applied, so .IPAddress is the raw CIM
        # string "x.x.x.x" and .IPAddressToString is $null -> empty string.
        # That made the Phase 11 audit see an empty IP and flag EVERY VM as
        # "no DHCP reservation". [string]$r.IPAddress is correct whether
        # .IPAddress is an [ipaddress] (ToString gives the dotted quad) or a
        # plain string.
        if ($r) { [string]$r.IPAddress } else { $null }
    }
}

function Write-DhcpLeaseFailureDiag {
    <#
    .SYNOPSIS
    Emit everything needed to tell WHY one VM failed to get a DHCP lease.

    .DESCRIPTION
    The pre-existing Phase 2 diagnostics (host NIC binding, scope state, scope
    stats, reservation, guest ipconfig) fired correctly on both APIPA failures
    (CT3-W10Client1 / CT5-W10Client1) and proved every one of them HEALTHY:
    NIC connected to the right switch, scope Active with 172 free, a matching
    reservation, DHCP enabled in the guest, and nine sibling VMs leased on the
    same subnet. So the answer is not in any of those -- it is in the four
    places nothing was looking:

      1. DHCP SERVER BINDINGS. Bindings are per-interface and a vEthernet
         adapter created mid-session can come up unbound. (Both failures
         followed a "vEthernet (x) IP is '169.254.x'. Changing it to x.200"
         line -- i.e. a freshly created switch.)
      2. THE SERVER AUDIT LOG. The only artifact that says whether a DISCOVER
         from this MAC ever reached the server, and what the server did with
         it (offer / NACK / decline / "IP found in use" / scope full).
      3. THE GUEST DHCP CLIENT EVENT LOG. The client's own verdict --
         no-server-response vs address-conflict vs adapter not ready.
      4. THE LEASE CENSUS. Whether the server is currently serving anyone on
         this subnet, which separates "server broken for the whole scope" from
         "broken for this one VM".

    All steps are individually guarded; this never throws and never blocks the
    caller's failure path.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $VmName,
        [Parameter(Mandatory = $true)][string] $ScopeId,
        [string] $Mac,
        [string] $VmDomainName,
        [string] $Tag = 'DIAG',
        [switch] $Quiet
    )

    function Write-DhcpDiagLine {
        param([string]$Text)
        if ($Quiet) { Write-Log "$Tag $VmName`: $Text" -LogOnly } else { Write-Log "$Tag $VmName`: $Text" -OutputStream }
    }

    # --- 1. DHCP server service + per-interface bindings ---------------------
    try {
        $svc = Get-Service -Name DHCPServer -ErrorAction SilentlyContinue
        Write-DhcpDiagLine "dhcp service: Status=$($svc.Status) StartType=$($svc.StartType)"
    }
    catch { }
    try {
        $expectedAlias = "vEthernet ($ScopeId)"
        $expectedIp = ($ScopeId -replace '\.\d+$', '.200')
        $bindings = Invoke-IsolatedCim -ScriptBlock {
            Get-DhcpServerv4Binding -ErrorAction SilentlyContinue |
                ForEach-Object { "$($_.InterfaceAlias)|$($_.IPAddress)|$($_.BindingState)" }
        }
        $matched = $false
        foreach ($b in @($bindings)) {
            $parts = $b -split '\|'
            if ($parts[0] -eq $expectedAlias -or $parts[1] -eq $expectedIp) {
                $matched = $true
                if ($parts[2] -ne 'True') {
                    Write-DhcpDiagLine "dhcp binding NOT ENABLED for '$($parts[0])' ($($parts[1])) -- the server never answers DISCOVERs on this subnet. ROOT CAUSE."
                }
                else {
                    Write-DhcpDiagLine "dhcp binding OK for '$($parts[0])' ($($parts[1])) BindingState=$($parts[2])"
                }
            }
        }
        if (-not $matched) {
            Write-DhcpDiagLine "dhcp has NO binding entry for '$expectedAlias'/$expectedIp. All bindings: $(@($bindings) -join ' ; ')"
        }
    }
    catch { }

    # --- 2. Host vEthernet adapter for this subnet ---------------------------
    try {
        $alias = "vEthernet ($ScopeId)"
        $hostAdapter = Get-NetAdapter -Name $alias -ErrorAction SilentlyContinue
        if ($hostAdapter) {
            $hostIps = @(Get-NetIPAddress -AddressFamily IPv4 -InterfaceAlias $alias -ErrorAction SilentlyContinue | ForEach-Object { $_.IPAddress })
            Write-DhcpDiagLine "host vNIC '$alias' Status=$($hostAdapter.Status) Up=$($hostAdapter.MediaConnectionState) IPs=[$($hostIps -join ',')]"
        }
        else {
            Write-DhcpDiagLine "host vNIC '$alias' NOT FOUND."
        }
    }
    catch { }

    # --- 3. Lease census: is the server serving anyone else on this subnet? --
    try {
        $leases = Invoke-IsolatedCim -ArgumentList $ScopeId -ScriptBlock {
            param($scope)
            Get-DhcpServerv4Lease -ScopeId $scope -ErrorAction SilentlyContinue |
                ForEach-Object { "$($_.IPAddress)|$($_.ClientId)|$($_.AddressState)|$($_.LeaseExpiryTime)" }
        }
        Write-DhcpDiagLine "scope $ScopeId currently holds $(@($leases).Count) lease(s)."
        foreach ($lease in @($leases)) { Write-Log "$Tag $VmName`:   lease $lease" -LogOnly }
    }
    catch { }

    # --- 4. Server audit log: did a DISCOVER from this MAC ever arrive? ------
    # THE decisive artifact. Event IDs: 10=new lease, 11=renew, 12=release,
    # 13=IP already in use on the network, 14=request could not be satisfied
    # (scope exhausted), 15=NACK, 16=DECLINE, 00/01=service start/stop.
    try {
        $auditCfg = Invoke-IsolatedCim -ScriptBlock {
            $a = Get-DhcpServerAuditLog -ErrorAction SilentlyContinue
            if ($a) { "$($a.Enable)|$($a.Path)" } else { $null }
        }
        if (-not $auditCfg) {
            Write-DhcpDiagLine "dhcp audit log config unavailable."
        }
        else {
            $auditParts = "$auditCfg" -split '\|'
            $auditEnabled = $auditParts[0]
            $auditPath = $auditParts[1]
            Write-DhcpDiagLine "dhcp audit log Enabled=$auditEnabled Path='$auditPath'"
            if ($auditEnabled -eq 'True' -and (Test-Path $auditPath)) {
                $macKey = ($Mac -replace '[-:]', '')
                $todayFile = Join-Path $auditPath ("DhcpSrvLog-" + (Get-Date).ToString('ddd') + ".log")
                $ydayFile = Join-Path $auditPath ("DhcpSrvLog-" + (Get-Date).AddDays(-1).ToString('ddd') + ".log")
                $hits = @()
                foreach ($af in @($ydayFile, $todayFile)) {
                    if (-not (Test-Path $af)) { continue }
                    # Copy first: the service holds the live file open with a
                    # share mode that Select-String can still read, but a copy
                    # is safe against a mid-write rotation.
                    $tmp = Join-Path $env:TEMP ("dhcpaudit-" + [guid]::NewGuid().ToString('N') + ".log")
                    try {
                        Copy-Item -LiteralPath $af -Destination $tmp -Force -ErrorAction SilentlyContinue
                        if (Test-Path $tmp) {
                            $hits += @(Select-String -Path $tmp -Pattern $macKey -SimpleMatch -ErrorAction SilentlyContinue |
                                    Select-Object -Last 25 | ForEach-Object { $_.Line.Trim() })
                        }
                    }
                    finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
                }
                if ($hits.Count -eq 0) {
                    Write-DhcpDiagLine "dhcp audit log has NO entry for MAC $macKey -- the server never saw a DISCOVER from this VM. The packet is being lost between the guest NIC and the host vSwitch port, NOT in DHCP."
                }
                else {
                    Write-DhcpDiagLine "dhcp audit log entries for MAC $macKey (last $($hits.Count)):"
                    foreach ($h in $hits) { Write-DhcpDiagLine "  audit $h" }
                }
            }
            elseif ($auditEnabled -ne 'True') {
                Write-DhcpDiagLine "dhcp audit logging is DISABLED -- enable it (Set-DhcpServerAuditLog -Enable `$true) to capture the next occurrence."
            }
        }
    }
    catch { }

    # --- 5. Guest-side: adapter, DHCP client service, client event log -------
    if ($VmDomainName) {
        try {
            $guest = Invoke-VmCommand -VmName $VmName -VmDomainName $VmDomainName -DisplayName "DiagDhcpClient" -ScriptBlock {
                $out = @()
                try {
                    foreach ($a in @(Get-NetAdapter -ErrorAction SilentlyContinue)) {
                        $out += "adapter '$($a.Name)' Status=$($a.Status) Media=$($a.MediaConnectionState) Speed=$($a.LinkSpeed) MAC=$($a.MacAddress)"
                    }
                }
                catch { }
                try {
                    foreach ($i in @(Get-NetIPInterface -AddressFamily IPv4 -ErrorAction SilentlyContinue)) {
                        $out += "ipinterface '$($i.InterfaceAlias)' Dhcp=$($i.Dhcp) ConnState=$($i.ConnectionState) Store=$($i.Store)"
                    }
                }
                catch { }
                try {
                    $svc = Get-Service -Name Dhcp -ErrorAction SilentlyContinue
                    $out += "dhcp client service Status=$($svc.Status) StartType=$($svc.StartType)"
                }
                catch { }
                foreach ($logName in @('Microsoft-Windows-Dhcp-Client/Admin', 'Microsoft-Windows-Dhcp-Client/Operational', 'System')) {
                    try {
                        $filter = @{ LogName = $logName; StartTime = (Get-Date).AddMinutes(-30) }
                        if ($logName -eq 'System') { $filter['ProviderName'] = 'Microsoft-Windows-Dhcp-Client' }
                        $evts = Get-WinEvent -FilterHashtable $filter -MaxEvents 15 -ErrorAction SilentlyContinue
                        foreach ($e in @($evts)) {
                            $out += "event [$logName] $($e.TimeCreated.ToString('HH:mm:ss')) id=$($e.Id) lvl=$($e.LevelDisplayName) $(($e.Message -replace '\s+', ' '))"
                        }
                    }
                    catch { }
                }
                return ($out -join "`n")
            }
            if ($guest -and $guest.ScriptBlockOutput -and -not $guest.ScriptBlockFailed) {
                foreach ($gline in ("$($guest.ScriptBlockOutput)" -split "`r?`n")) {
                    if ($gline.Trim()) { Write-DhcpDiagLine "guest $($gline.Trim())" }
                }
            }
        }
        catch { }
    }
}

# Return a hashtable of vmName -> domain-NIC MAC for EVERY VM on the host, all
# in ONE isolated runspace (single Hyper-V module import). This is the batched
# counterpart to Get-VMMacIsolated: callers that need MACs for many VMs (e.g.
# the Phase 11 DHCP audit) should use this instead of calling Get-VMMacIsolated
# in a loop, which spawns a fresh runspace -- and re-imports the Hyper-V module
# (~seconds) -- per VM. When -ExcludeCluster is set, SQLAO Cluster heartbeat
# NICs are filtered out, matching Get-VMMacIsolated. MACs are projected to plain
# strings inside the isolated runspace so no type adapter is needed by the
# caller.
function Get-AllVMMacsIsolated {
    param(
        [switch] $ExcludeCluster
    )
    $results = Invoke-IsolatedCim -ArgumentList $ExcludeCluster.IsPresent -ScriptBlock {
        param($excludeCluster)
        # One Get-VMNetworkAdapter for the whole host, not one per VM. Each call is a separate
        # WMI round trip, so the per-VM loop cost ~15s for 23 VMs on the Phase 2/3 critical path
        # before any VM job is dispatched.
        $byVm = @{}
        foreach ($nic in (Get-VMNetworkAdapter -VMName * -ErrorAction SilentlyContinue)) {
            if ($excludeCluster -and $nic.SwitchName -and $nic.SwitchName -match 'Cluster') { continue }
            if (-not $byVm.ContainsKey($nic.VMName)) { $byVm[$nic.VMName] = [string]$nic.MacAddress }
        }
        $out = [System.Collections.Generic.List[object]]::new()
        foreach ($vm in (Get-VM -ErrorAction SilentlyContinue)) {
            $name = [string]$vm.Name
            $mac = if ($byVm.ContainsKey($name)) { $byVm[$name] } else { $null }
            $out.Add([pscustomobject]@{ VmName = $name; Mac = $mac })
        }
        $out.ToArray()
    }
    $map = @{}
    foreach ($r in $results) { $map[$r.VmName] = $r.Mac }
    return $map
}

function Get-VMMacAndDhcpIsolated {
    <#
    .SYNOPSIS
    Both the VM MAC map and every DHCP reservation, from ONE isolated runspace.

    .DESCRIPTION
    The Phase 2 preamble needs both back to back and was paying a full Invoke-IsolatedCim
    setup for each. This is still one FRESH throwaway runspace, which is what
    Invoke-IsolatedCim requires -- it just does both queries inside it.
    #>
    param(
        [switch] $ExcludeCluster,
        [string[]] $VmNames
    )
    $scopedNames = @($VmNames | Where-Object { $_ })
    $results = Invoke-IsolatedCim -ArgumentList $ExcludeCluster.IsPresent, $scopedNames -ScriptBlock {
        param($excludeCluster, $vmNames)
        $swAll = [Diagnostics.Stopwatch]::StartNew()
        # Enumerating every VM on the host costs the same whether the deploy has 3 VMs or 30,
        # so ask only for the ones the caller will actually look up.
        $names = if ($vmNames -and $vmNames.Count -gt 0) { $vmNames } else { '*' }
        $byVm = @{}
        foreach ($nic in (Get-VMNetworkAdapter -VMName $names -ErrorAction SilentlyContinue)) {
            if ($excludeCluster -and $nic.SwitchName -and $nic.SwitchName -match 'Cluster') { continue }
            if (-not $byVm.ContainsKey($nic.VMName)) { $byVm[$nic.VMName] = [string]$nic.MacAddress }
        }
        $vms = if ($vmNames -and $vmNames.Count -gt 0) {
            Get-VM -Name $vmNames -ErrorAction SilentlyContinue
        }
        else {
            Get-VM -ErrorAction SilentlyContinue
        }
        $macs = [System.Collections.Generic.List[object]]::new()
        foreach ($vm in $vms) {
            $name = [string]$vm.Name
            $mac = if ($byVm.ContainsKey($name)) { $byVm[$name] } else { $null }
            $macs.Add([pscustomobject]@{ VmName = $name; Mac = $mac })
        }
        $macMs = $swAll.Elapsed.TotalMilliseconds
        $res = [System.Collections.Generic.List[object]]::new()
        foreach ($scope in (Get-DhcpServerv4Scope -ErrorAction SilentlyContinue)) {
            $sid = [string]$scope.ScopeId
            foreach ($r in (Get-DhcpServerv4Reservation -ScopeId $sid -ErrorAction SilentlyContinue)) {
                $res.Add([pscustomobject]@{ ScopeId = $sid; Mac = ($r.ClientId -replace '-', ''); Ip = [string]$r.IPAddress })
            }
        }
        [pscustomobject]@{
            Macs         = $macs.ToArray()
            Reservations = $res.ToArray()
            MacMs        = [int]$macMs
            DhcpMs       = [int]($swAll.Elapsed.TotalMilliseconds - $macMs)
            Scoped       = ($vmNames -and $vmNames.Count -gt 0)
        }
    }
    # Tolerate the isolated call handing back a 1-element array rather than the bare object.
    $snapshot = @($results) | Select-Object -First 1
    $map = @{}
    foreach ($r in $snapshot.Macs) { $map[$r.VmName] = $r.Mac }
    return [pscustomobject]@{
        MacMap       = $map
        Reservations = @($snapshot.Reservations)
        MacMs        = $snapshot.MacMs
        DhcpMs       = $snapshot.DhcpMs
        Scoped       = $snapshot.Scoped
    }
}

# Return every DHCP reservation across every scope as an array of objects with
# ScopeId / Mac (dashes stripped) / Ip, all in ONE isolated runspace (single
# DhcpServer module import). This is the batched counterpart to
# Get-DHCPReservationIPForMac: callers verifying many VMs (e.g. the Phase 11
# audit) should build a lookup from this once instead of calling
# Get-DHCPReservationIPForMac per VM, which re-imports the DhcpServer module in
# a fresh runspace each time. Ip is projected to a plain string inside the
# isolated runspace (the CDXML .IPAddress type adapter is NOT applied there --
# see Get-DHCPReservationIPForMac for the full rationale).
function Get-AllDHCPReservationsIsolated {
    return Invoke-IsolatedCim -ScriptBlock {
        $out = @()
        foreach ($scope in (Get-DhcpServerv4Scope -ErrorAction SilentlyContinue)) {
            $sid = [string]$scope.ScopeId
            foreach ($r in (Get-DhcpServerv4Reservation -ScopeId $sid -ErrorAction SilentlyContinue)) {
                $out += [pscustomobject]@{
                    ScopeId = $sid
                    Mac     = ($r.ClientId -replace '-', '')
                    Ip      = [string]$r.IPAddress
                }
            }
        }
        $out
    }
}

# Host-wide named mutex serializing every DHCP server write/read-for-write op.
# The DhcpServer CDXML cmdlets call into the DHCP RPC interface and parallel
# Phase 1 VM-create jobs hitting Add-DhcpServerv4Reservation /
# Get-DhcpServerv4FreeIPAddress + Add-DhcpServerv4ExclusionRange against the
# same scope produced intermittent "Failed to reserve IP address ... in scope
# ... on DHCP server ..." errors that swallowed all root-cause detail. The
# Global\ prefix makes the mutex visible across PowerShell processes / jobs
# on the host (matches the pattern used by Global\MemlabsImapi2fsLock in
# Common.Linux.ps1). Failures to acquire fall through after the ceiling so a
# single stuck holder can't deadlock a whole deploy -- the operation runs
# anyway and any race-induced error gets caught/retried by the caller.
#
# $TimeoutSeconds is a REPORTING interval, not the give-up point. A 25-VM
# Phase 1 legitimately queues every VM behind this one mutex, and each holder
# spends ~3s per Invoke-IsolatedCim just creating a runspace and autoloading
# the DhcpServer CDXML module -- so one expired WaitOne means "the queue is
# long", not "a holder is stuck". Treating it as give-up ran the DHCP writes
# UNSERIALIZED, which is the exact race this mutex exists to prevent (32-40
# such fall-throughs per 25-VM run, i.e. the mutex was silently off for most
# of Phase 1). Keep waiting to $CeilingSeconds instead.
function Invoke-WithDhcpMutex {
    param(
        [Parameter(Mandatory = $true)] [scriptblock] $ScriptBlock,
        [int] $TimeoutSeconds = 120,
        [int] $CeilingSeconds = 900
    )
    $mtx = $null
    $acquired = $false
    $waitSw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        try {
            $mtx = [System.Threading.Mutex]::new($false, 'Global\MemLabs_DHCP')
        }
        catch {
            # Mutex creation itself failed (rare: ACL / WaitHandleCannotBeOpenedException
            # under unusual session conditions). Run unguarded rather than fail the deploy.
            Write-Log "Invoke-WithDhcpMutex: mutex unavailable, running unguarded ($($_.Exception.GetType().FullName)): $($_.Exception.Message)" -LogOnly
        }
        if ($mtx) {
            # The wait loop gets its own try/catch: folding it into the creation
            # catch above would misreport any failure here as "mutex unavailable".
            $ceiling = [TimeSpan]::FromSeconds([Math]::Max($CeilingSeconds, $TimeoutSeconds))
            while (-not $acquired -and $waitSw.Elapsed -lt $ceiling) {
                try {
                    $acquired = $mtx.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds))
                }
                catch [System.Threading.AbandonedMutexException] {
                    # Prior holder died without releasing; ownership is now ours.
                    $acquired = $true
                }
                if (-not $acquired) {
                    Write-Log "Invoke-WithDhcpMutex: still queued after $([int]$waitSw.Elapsed.TotalSeconds)s (ceiling $([int]$ceiling.TotalSeconds)s)" -LogOnly
                }
            }
            if (-not $acquired) {
                Write-Log "Invoke-WithDhcpMutex: gave up after $([int]$waitSw.Elapsed.TotalSeconds)s; proceeding without serialization" -Warning
            }
        }
        $waitSw.Stop()
        $holdSw = [System.Diagnostics.Stopwatch]::StartNew()
        try { & $ScriptBlock }
        finally {
            $holdSw.Stop()
            # Hold time is the only number that explains queue depth; log it when it
            # is large enough to matter so the next sweep can attribute the wait.
            if ($holdSw.Elapsed.TotalSeconds -ge 10) {
                Write-Log "Invoke-WithDhcpMutex: held the mutex for $([int]$holdSw.Elapsed.TotalSeconds)s (waited $([int]$waitSw.Elapsed.TotalSeconds)s)" -LogOnly
            }
        }
    }
    finally {
        if ($mtx) {
            if ($acquired) { try { $mtx.ReleaseMutex() } catch {} }
            try { $mtx.Dispose() } catch {}
        }
    }
}

# Create a DHCP reservation, running the DhcpServer CIM cmdlet in an isolated
# runspace. Serialized across the host via Global\MemLabs_DHCP and retried on
# failure with exponential backoff so transient RPC contention from parallel
# Phase 1 VM-create jobs doesn't surface as a permanent reservation failure.
# Pre-cleans an orphaned reservation on the same IP under a different MAC --
# left over from a partial prior deploy this is the most common cause of the
# bare cmdlet failing. Throws with full exception chain detail (type, message,
# every InnerException) on final failure so the caller's log line carries the
# actual root cause instead of a stringified ErrorRecord.
#
# -PurgeMacFirst drops any OTHER reservation this MAC holds (in any scope)
# before adding. That used to be a separate Remove-DHCPReservation call, i.e. a
# second mutex acquisition and a second Invoke-IsolatedCim -- and each isolated
# runspace costs ~3s just to autoload the DhcpServer CDXML module, all of it
# spent holding the host-wide mutex. Folding it in here halves the mutex traffic
# per VM and closes the window where a parallel job could take the IP between
# our remove and our add.
function ConvertTo-IpSortable {
    # IPv4 as a comparable UInt32; $null when the text is not a v4 address.
    param([string] $IPAddress)
    $parsed = [System.Net.IPAddress]::None
    if (-not [System.Net.IPAddress]::TryParse($IPAddress, [ref]$parsed)) { return $null }
    $bytes = $parsed.GetAddressBytes()
    if ($bytes.Length -ne 4) { return $null }
    return ([uint32]$bytes[0] -shl 24) -bor ([uint32]$bytes[1] -shl 16) -bor ([uint32]$bytes[2] -shl 8) -bor [uint32]$bytes[3]
}

function Add-DHCPReservationIsolated {
    param(
        [Parameter(Mandatory = $true)][string] $ScopeId,
        [Parameter(Mandatory = $true)][string] $IPAddress,
        [Parameter(Mandatory = $true)][string] $Mac,
        [string] $Description,
        [int] $MaxAttempts = 4,
        [string] $LogContext,
        [switch] $PurgeMacFirst
    )

    $tag = if ($LogContext) { "$LogContext`: " } else { '' }
    $purgeMac = $PurgeMacFirst.IsPresent
    $attempt = 0
    $lastError = $null
    while ($attempt -lt $MaxAttempts) {
        $attempt++
        try {
            $outcome = Invoke-WithDhcpMutex -ScriptBlock {
                Invoke-IsolatedCim -ArgumentList $ScopeId, $IPAddress, $Mac, $Description, $purgeMac -ScriptBlock {
                    param($scopeId, $ip, $mac, $desc, $purgeMac)

                    # Every branch records why it fired, and the whole set is returned to the
                    # caller to log. The success path used to be completely silent, so a
                    # reservation logged as "created" that was absent minutes later left no
                    # evidence of which branch ran or of what the server did with it.
                    $notes = [System.Collections.Generic.List[string]]::new()

                    # Drop stale reservations this MAC still holds elsewhere (a VM that
                    # moved subnets, or a rerun against a changed config). Anything already
                    # pointing at $ip is left alone -- the add below is idempotent for it.
                    if ($purgeMac) {
                        foreach ($s in @((Get-DhcpServerv4Scope -ErrorAction SilentlyContinue).ScopeId)) {
                            if (-not $s) { continue }
                            $stale = $null
                            try { $stale = Get-DhcpServerv4Reservation -ScopeId $s -ClientId $mac -ErrorAction SilentlyContinue } catch { }
                            foreach ($one in @($stale)) {
                                if (-not $one) { continue }
                                $staleIp = [string]$one.IPAddress
                                if ($staleIp -eq $ip) { continue }
                                Remove-DhcpServerv4Reservation -ScopeId $s -ClientId $mac -ErrorAction SilentlyContinue | Out-Null
                                try { Remove-DhcpServerv4Lease -IPAddress $staleIp -ErrorAction SilentlyContinue | Out-Null } catch { }
                                $notes.Add("purged our MAC's stale reservation $staleIp in scope $s")
                            }
                        }
                    }

                    # Pre-clean: a reservation OR active lease already sitting on
                    # this IP under a DIFFERENT client is the most common cause of
                    # Add-DhcpServerv4Reservation throwing "Failed to reserve IP
                    # address ... in scope ...". Such an occupant is either:
                    #   (a) an ORPHAN  -- left by a deleted VM, or held by a VM that
                    #       now lives on a different vSwitch (e.g. a capture box) --
                    #       in which case we safely reclaim the IP; or
                    #   (b) a LIVE VM currently attached to THIS scope's switch --
                    #       a genuine in-lab IP collision -- in which case stealing
                    #       it would break a working VM, so we refuse and surface it.
                    # The scope id equals the vSwitch name (the switch is created as
                    # New-VMSwitch -Name <network>), so "legitimately owns this IP"
                    # == "MAC is attached to the switch named $scopeId". Membership
                    # is resolved lazily (only when a conflict must be adjudicated)
                    # so the common no-conflict path does no Get-VM enumeration.
                    $ourMac = ($mac -replace '[-:]', '').ToLower()
                    $switchMacs = $null
                    $resolveSwitchMacs = {
                        $m = @{}
                        try {
                            Get-VM | Get-VMNetworkAdapter -ErrorAction SilentlyContinue |
                                Where-Object { $_.SwitchName -eq $scopeId -and $_.MacAddress -and $_.MacAddress -ne '000000000000' } |
                                ForEach-Object { $m[($_.MacAddress -replace '[-:]', '').ToLower()] = $_.VMName }
                        }
                        catch { }
                        $m
                    }

                    # Ask the SCOPE, never the address. Get-DhcpServerv4Reservation -IPAddress
                    # returns the DHCP client record at that address whether or not it is a
                    # reservation, so an ordinary dynamic lease reads back as one. That is
                    # what made Phase 1 log "reservation created" for CT5-W10Client1 .25 and
                    # CT5-W11Client2 .26 while four scope enumerations over 4.5 hours never
                    # listed them: each guest had simply leased its own AssignedIP first, the
                    # idempotent branch believed it, and no reservation was ever created.
                    # The scope enumeration is the only query that lists reservations alone.
                    $findReservation = {
                        param($addr)
                        foreach ($r in @(Get-DhcpServerv4Reservation -ScopeId $scopeId -ErrorAction SilentlyContinue)) {
                            if ($r -and ([string]$r.IPAddress) -eq $addr) { return $r }
                        }
                        return $null
                    }

                    $existing = $null
                    try { $existing = & $findReservation $ip } catch { }
                    if ($existing) {
                        $existingMac = ($existing.ClientId -replace '[-:]', '').ToLower()
                        if ($existingMac -eq $ourMac) {
                            # Reservation already exists with our MAC -- idempotent success.
                            $notes.Add("already reserved to our MAC; left unchanged")
                            return ($notes.ToArray() -join '; ')
                        }
                        if ($null -eq $switchMacs) { $switchMacs = & $resolveSwitchMacs }
                        if ($switchMacs.ContainsKey($existingMac)) {
                            throw "DHCP in-lab IP collision: $ip on scope $scopeId is already reserved to live switch member '$($switchMacs[$existingMac])' (MAC $existingMac); refusing to reassign it to MAC $mac. Fix the IP assignment for one of these VMs."
                        }
                        # Orphan reservation -- reclaim the IP (drop any matching lease too).
                        Remove-DhcpServerv4Reservation -IPAddress $ip -ErrorAction SilentlyContinue | Out-Null
                        try { Remove-DhcpServerv4Lease -IPAddress $ip -ErrorAction SilentlyContinue | Out-Null } catch { }
                        $notes.Add("reclaimed orphan reservation on $ip from MAC $existingMac")
                    }
                    else {
                        # No reservation, but a lease already sitting on this address will
                        # make the Add fail with "Failed to reserve IP address". $ip is this
                        # VM's own AssignedIP, so any lease here that is not ours is transient
                        # and its holder will renew onto its own reserved address -- unlike a
                        # reservation, which is a real ownership claim and is refused above.
                        $lease = $null
                        try { $lease = Get-DhcpServerv4Lease -IPAddress $ip -ErrorAction SilentlyContinue } catch { }
                        if ($lease) {
                            $leaseMac = ($lease.ClientId -replace '[-:]', '').ToLower()
                            if ($leaseMac -ne $ourMac) {
                                if ($null -eq $switchMacs) { $switchMacs = & $resolveSwitchMacs }
                                $holder = if ($switchMacs.ContainsKey($leaseMac)) { "live switch member '$($switchMacs[$leaseMac])'" } else { 'a non-member client' }
                                try { Remove-DhcpServerv4Lease -IPAddress $ip -ErrorAction SilentlyContinue | Out-Null } catch { }
                                $notes.Add("cleared lease on $ip held by $holder (MAC $leaseMac)")
                            }
                        }
                    }

                    Add-DhcpServerv4Reservation -ScopeId $scopeId -IPAddress $ip -ClientId $mac -Description $desc -ErrorAction Stop | Out-Null

                    # Read the reservation back before reporting success, from the scope
                    # rather than the address, for the reason given at $findReservation.
                    $verify = $null
                    try { $verify = & $findReservation $ip } catch { }
                    if (-not $verify) {
                        throw "post-add read-back found NO reservation at $ip in scope $scopeId, although Add-DhcpServerv4Reservation reported success"
                    }
                    $verifyMac = ([string]$verify.ClientId -replace '[-:]', '').ToLower()
                    if ($verifyMac -ne $ourMac) {
                        throw "post-add read-back found $ip in scope $scopeId reserved to MAC $verifyMac, not $ourMac"
                    }
                    $notes.Add("added and read back $ip")

                    # A lease this MAC still holds at ANOTHER address in the same scope is
                    # the one condition that can quietly undo the reservation afterwards:
                    # the guest booted and leased before the reservation existed, and keeps
                    # renewing the older client record. Nothing else in the run can see it.
                    $ourLeases = @()
                    try { $ourLeases = @(Get-DhcpServerv4Lease -ScopeId $scopeId -ClientId $mac -ErrorAction SilentlyContinue) } catch { }
                    foreach ($l in $ourLeases) {
                        if (-not $l) { continue }
                        $lIp = [string]$l.IPAddress
                        if ($lIp -and $lIp -ne $ip) {
                            $notes.Add("WARNING our MAC also holds lease $lIp in scope $scopeId (state $($l.AddressState))")
                        }
                    }

                    $notes.ToArray() -join '; '
                }
            }
            $summary = @($outcome | Where-Object { $_ -is [string] -and $_ }) | Select-Object -Last 1
            if ($summary) {
                Write-Log "${tag}Add-DHCPReservationIsolated: $IPAddress (Scope=$ScopeId, MAC=$Mac): $summary" -LogOnly
            }
            if ($attempt -gt 1) {
                Write-Log "${tag}Add-DHCPReservationIsolated: succeeded for $IPAddress on attempt $attempt/$MaxAttempts (Scope=$ScopeId, MAC=$Mac)" -LogOnly
            }
            return
        }
        catch {
            $lastError = $_
            $exType = $_.Exception.GetType().FullName
            $exMsg = $_.Exception.Message
            $inner = $_.Exception.InnerException
            $innerStr = ''
            while ($inner) {
                $innerStr += " >> [$($inner.GetType().FullName)] $($inner.Message)"
                $inner = $inner.InnerException
            }
            Write-Log "${tag}Add-DHCPReservationIsolated: attempt $attempt/$MaxAttempts failed for $IPAddress (Scope=$ScopeId, MAC=$Mac): [$exType] $exMsg$innerStr" -LogOnly

            # An address outside the scope's pool can never be reserved, so retrying is
            # provably pointless -- prove it once and stop. The DC sits on <network>.1 by
            # convention (thisParams.DCIPAddress, set statically by Phase2DC) while the pool
            # is .20-.199, so every re-run of any lab with a DC burned 4 attempts and ~20s
            # here and then logged a WARN that nothing could ever act on.
            if ($attempt -eq 1) {
                $scopeBounds = $null
                try {
                    $scopeBounds = Invoke-IsolatedCim -ArgumentList $ScopeId -ScriptBlock {
                        param($sid)
                        $s = Get-DhcpServerv4Scope -ScopeId $sid -ErrorAction SilentlyContinue
                        if ($s) { "$($s.StartRange)|$($s.EndRange)" }
                    }
                }
                catch { }
                $bounds = @("$scopeBounds" -split '\|')
                if ($bounds.Count -eq 2) {
                    $ipVal = ConvertTo-IpSortable $IPAddress
                    $loVal = ConvertTo-IpSortable $bounds[0]
                    $hiVal = ConvertTo-IpSortable $bounds[1]
                    if ($null -ne $ipVal -and $null -ne $loVal -and $null -ne $hiVal -and
                        ($ipVal -lt $loVal -or $ipVal -gt $hiVal)) {
                        Write-Log ("${tag}Add-DHCPReservationIsolated: $IPAddress is OUTSIDE scope $ScopeId's pool " +
                            "($($bounds[0]) - $($bounds[1])), so no reservation is possible and retrying cannot help. " +
                            "A VM addressed outside the pool is statically configured; skipping the reservation.") -LogOnly
                        return
                    }
                }
            }

            if ($attempt -lt $MaxAttempts) {
                # 500ms, 1s, 2s
                Start-Sleep -Milliseconds ([int](500 * [math]::Pow(2, $attempt - 1)))
            }
        }
    }

    # All attempts failed -- rethrow with full diagnostic context so the
    # caller's catch logs the real root cause instead of a stringified $_.
    $exType = $lastError.Exception.GetType().FullName
    $exMsg = $lastError.Exception.Message
    $inner = $lastError.Exception.InnerException
    $innerStr = ''
    while ($inner) {
        $innerStr += " >> [$($inner.GetType().FullName)] $($inner.Message)"
        $inner = $inner.InnerException
    }
    throw "Add-DHCPReservationIsolated: all $MaxAttempts attempts failed for $IPAddress (Scope=$ScopeId, MAC=$Mac). Final error: [$exType] $exMsg$innerStr"
}

function Remove-DHCPReservation {
    param(
        [string] $ip,
        [string] $mac,
        [string] $vmName
    )

    # The DhcpServer CDXML cmdlets emit CIM progress that permanently poisons
    # the calling runspace's Progress stream (collapsing the managed per-VM
    # progress bars when this runs inside a Phase job). Run the entire
    # lookup/removal in an isolated in-process runspace so the poison lands on
    # the throwaway runspace instead. Removal is synchronous here (the prior
    # -AsJob was itself a progress-isolation workaround that's now unnecessary).
    # Wrapped in Invoke-WithDhcpMutex so parallel Phase 1 jobs don't fight the
    # add path -- a remove on scope X racing an add on scope X has produced
    # spurious "Failed to reserve" errors in the past.
    $logLines = Invoke-WithDhcpMutex -ScriptBlock {
        Invoke-IsolatedCim -ArgumentList $ip, $mac, $vmName -ScriptBlock {
            param($ip, $mac, $vmName)
            $out = @()
            $scopes = (Get-DhcpServerv4Scope).ScopeID

            if ($ip) {
                $out += "$vmName Checking for Reservation for $ip"
                if (Get-DhcpServerv4Reservation -IPAddress $ip -ErrorAction SilentlyContinue) {
                    $out += "$vmName Removing Reservation for $ip"
                    Remove-DhcpServerv4Reservation -IPAddress $ip -ErrorAction SilentlyContinue
                }
                # Also drop any active lease so the IP is fully released, not just
                # the reservation (an orphan lease can still block a later Add).
                try { Remove-DhcpServerv4Lease -IPAddress $ip -ErrorAction SilentlyContinue } catch { }
            }

            if ($mac) {
                $out += "$vmName Checking for Reservation for $mac"
                foreach ($scope in $scopes) {
                    $reservation = Get-DhcpServerv4Reservation -ScopeId $scope -ClientId $mac -ErrorAction SilentlyContinue
                    if ($reservation) {
                        $out += "$vmName Removing Reservation for $mac"
                        Remove-DhcpServerv4Reservation -ScopeId $scope -ClientId $mac -ErrorAction SilentlyContinue
                        try { Remove-DhcpServerv4Lease -IPAddress $reservation.IPAddress -ErrorAction SilentlyContinue } catch { }
                        break
                    }
                }
            }

            if (-not $ip -and -not $mac) {
                $out += "$vmName Checking for Reservation for $vmName"
                foreach ($scope in $scopes) {
                    $reservation = Get-DhcpServerv4Reservation -ScopeId $scope -ErrorAction SilentlyContinue | Where-Object { $_.Name -like $vmName + ".*" }
                    if ($reservation) {
                        $out += "$vmName Removing Reservation for $vmName"
                        Remove-DhcpServerv4Reservation -IPAddress $reservation.IPAddress -ErrorAction SilentlyContinue
                        try { Remove-DhcpServerv4Lease -IPAddress $reservation.IPAddress -ErrorAction SilentlyContinue } catch { }
                        break
                    }
                }
            }
            return $out
        }
    }

    foreach ($line in $logLines) {
        Write-Log -Verbose $line
    }
}

<#
.SYNOPSIS
Creates a new virtual machine.

.DESCRIPTION
The New-VirtualMachine function creates a new virtual machine with the specified parameters.

.PARAMETER VmName
The name of the virtual machine.

.PARAMETER VmPath
The path where the virtual machine will be created.

.PARAMETER SourceDiskPath
The path of the source disk to be used for the virtual machine.

.PARAMETER Memory
The amount of memory to allocate for the virtual machine.

.PARAMETER Processors
The number of processors to allocate for the virtual machine.

.PARAMETER Generation
The generation of the virtual machine.

.PARAMETER SwitchName
The name of the virtual switch to connect the virtual machine to.

.PARAMETER DiskControllerType
The type of disk controller to use for the virtual machine. Default value is "SCSI".

.PARAMETER AdditionalDisks
Additional disks to attach to the virtual machine.

.PARAMETER ForceNew
Forces the creation of a new virtual machine, even if a virtual machine with the same name already exists.

.PARAMETER DeployConfig
The deployment configuration for the virtual machine.

.PARAMETER OSDClient
Specifies whether the virtual machine is an OSD client.

.PARAMETER tpmEnabled
Specifies whether the virtual machine has TPM enabled.

.PARAMETER Migrate
Specifies whether to migrate the virtual machine.

.PARAMETER WhatIf
Shows what would happen if the command runs.

.EXAMPLE
New-VirtualMachine -VmName "MyVM" -VmPath "C:\VMs" -Memory "4GB" -Processors 2 -Generation 2 -SwitchName "VirtualSwitch"

This example creates a new virtual machine named "MyVM" with 4GB of memory, 2 processors, generation 2, and connects it to the "VirtualSwitch" virtual switch.

#>

function Set-SQLAOHeartbeatIPs {
    <#
    .SYNOPSIS
        Allocate the SQLAO cluster heartbeat IP (10.250.251.x) for every SQLAO node
        ONCE, single-threaded, right before the parallel Phase 5 jobs fan out.
    .DESCRIPTION
        Only Phase 5 needs these IPs, so they are allocated here -- on the main
        thread, before any Phase 5 job starts -- in a single pass: gather every IP
        already in use, work out how many nodes still need one, grab that many free
        addresses, and dole them out. Because it is serial there is no race and NO
        mutex (and the per-node Add-VMNetworkAdapter in the Phase 5 job acts on
        distinct VMs, so it doesn't need one either).

        The heartbeat subnet (10.250.251.0/24) has no DHCP scope, so collision
        avoidance is purely this in-memory dedup over .20-.199. A node's existing IP
        (deployConfig or VM Note) is reused when unique; a node with no IP -- or whose
        stored IP collides with another node (a bad config from an older build) -- is
        handed the next free address. The result is stamped on the deployConfig (so
        the per-job copies inherit it) AND written to every SQLAO VM Note at once (so
        reruns / -StartPhase 5 reuse it).

        ClusterV2 (10.250.251.0/24) is a SINGLE host-internal switch SHARED by every
        domain on the host, so two SQLAO clusters in DIFFERENT domains share the same
        L2 segment. The in-use scan below therefore enumerates EVERY VM on the host
        (no -DomainName filter) -- a heartbeat IP held by a node in another domain is
        just as much a collision as one in this domain.
    #>
    param(
        [Parameter(Mandatory)]
        [object]$DeployConfig
    )

    $sqlaoVMs = @($DeployConfig.virtualMachines | Where-Object { $_.role -eq 'SQLAO' -and -not $_.hidden })
    if ($sqlaoVMs.Count -eq 0) { return }

    $subnet = '10.250.251'
    $rangeStart = 20
    $rangeEnd = 199

    # 1. Collect every heartbeat IP already in use ACROSS ALL DOMAINS on the host --
    #    ClusterV2 is one shared L2 segment, so an SQLAO node in any domain holding a
    #    10.250.251.x is a real collision. Exclude this config's own VMs (matched by
    #    vmName, which is prefix-unique host-wide) so a node never counts its own IP
    #    as someone else's on a -StartPhase 5 rerun.
    $cfgNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($v in $sqlaoVMs) { if ($v.vmName) { $null = $cfgNames.Add($v.vmName) } }
    $used = [System.Collections.Generic.HashSet[string]]::new()
    try {
        foreach ($evm in (Get-List -Type VM -SmartUpdate | Where-Object { $_.ClusterHeartbeatIP -and (-not $cfgNames.Contains($_.vmName)) })) {
            $null = $used.Add($evm.ClusterHeartbeatIP)
        }
    }
    catch {}

    # 2. Reuse each node's existing IP when it's unique; everything else (missing or a
    #    duplicate) goes in $needIP to be (re)allocated below.
    $needIP = [System.Collections.Generic.List[object]]::new()
    foreach ($v in $sqlaoVMs) {
        $cur = $v.ClusterHeartbeatIP
        if (-not $cur) {
            $note = $null
            try { $note = Get-VMNote -VMName $v.vmName -ErrorAction SilentlyContinue } catch {}
            if ($note -and $note.ClusterHeartbeatIP) { $cur = $note.ClusterHeartbeatIP }
        }
        if ($cur -and -not $used.Contains($cur)) {
            $null = $used.Add($cur)
            $v | Add-Member -MemberType NoteProperty -Name ClusterHeartbeatIP -Value $cur -Force
        }
        else {
            if ($cur) { Write-Log "$($v.vmName): SQLAO: heartbeat IP $cur is a duplicate -- reallocating" -Warning }
            $needIP.Add($v)
        }
    }

    # 3. Grab one free IP per node that needs one and dole them out.
    foreach ($v in $needIP) {
        $ip = $null
        for ($o = $rangeStart; $o -le $rangeEnd; $o++) {
            $cand = "$subnet.$o"
            if (-not $used.Contains($cand)) { $ip = $cand; break }
        }
        if (-not $ip) {
            Write-Log "$($v.vmName): SQLAO: no free heartbeat IP in $subnet.$rangeStart-$rangeEnd (range exhausted)" -Failure
            continue
        }
        $null = $used.Add($ip)
        $v | Add-Member -MemberType NoteProperty -Name ClusterHeartbeatIP -Value $ip -Force
        Write-Log "$($v.vmName): SQLAO: assigned heartbeat IP $ip" -LogOnly
    }

    # 4. Persist to every SQLAO VM Note at once so reruns reuse the same IPs.
    foreach ($v in $sqlaoVMs) {
        if ($v.ClusterHeartbeatIP) {
            New-VmNote -VmName $v.vmName -DeployConfig $DeployConfig -InProgress $true
        }
    }
}

function Set-DeployConfigIPAddresses {
    <#
    .SYNOPSIS
        Pre-allocate DHCP IPs for every VM before Phase 1 starts.
    .DESCRIPTION
        Iterates all non-hidden VMs in the deploy config, determines
        the correct DHCP scope, and assigns a stable IP:
        - CAS -> .5, Primary -> .10, Secondary -> .15 (fixed well-known)
        - Proxy (Linux) -> .2 (static cloud-init)
        - DC -> .1 (set by DSC, but reserve it here)
        - All others -> Get-DhcpServerv4FreeIPAddress from the scope

        Stamps $vm.AssignedIP on each VM's config object. New-VirtualMachine
        and New-LinuxVirtualMachine use this to create the DHCP reservation
        immediately after VM creation (before boot), so every VM boots
        with a deterministic, reserved IP.

        This runs serially on the main thread before parallel Phase 1
        jobs start, so no mutex is needed for IP allocation.
    #>
    param (
        [Parameter(Mandatory)]
        [object]$DeployConfig
    )

    $defaultNetwork = $DeployConfig.vmOptions.network
    if (-not $defaultNetwork) {
        Write-Log "Set-DeployConfigIPAddresses: No default network in vmOptions. Cannot allocate IPs." -Failure
        return
    }

    # Verify DHCP service is running before we try to allocate
    $dhcpService = Get-Service DHCPServer -ErrorAction SilentlyContinue
    if (-not $dhcpService -or $dhcpService.Status -ne 'Running') {
        Write-Log "Set-DeployConfigIPAddresses: DHCP service is not running. Starting..." -Warning
        $dhcp = Start-DHCP
        if (-not $dhcp) {
            Write-Log "Set-DeployConfigIPAddresses: Could not start DHCP service. IP pre-allocation will be skipped." -Failure
            return
        }
    }

    # Track IPs we've allocated to prevent duplicates within this run
    $allocatedIps = [System.Collections.Generic.HashSet[string]]::new()
    $vmCount = 0
    $skipCount = 0
    $reuseCount = 0
    $fixedCount = 0
    $dynamicCount = 0
    $failCount = 0

    # Collect all scopes we'll use and verify they exist
    $scopesNeeded = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($vm in $DeployConfig.virtualMachines) {
        if ($vm.hidden -or $vm.role -eq 'OSDClient') { continue }
        $sid = if ($vm.role -in 'InternetClient', 'AADClient') { '172.31.250.0' } else { if ($vm.network) { $vm.network } else { $defaultNetwork } }
        $null = $scopesNeeded.Add($sid)
    }
    foreach ($sid in $scopesNeeded) {
        $scope = Get-DhcpServerv4Scope -ScopeId $sid -ErrorAction SilentlyContinue
        if (-not $scope) {
            Write-Log "Set-DeployConfigIPAddresses: DHCP scope $sid does not exist! VMs on this scope will not get pre-assigned IPs." -Warning
        }
        else {
            $stats = Get-DhcpServerv4ScopeStatistics -ScopeId $sid -ErrorAction SilentlyContinue
            if ($stats) {
                Write-Log "Set-DeployConfigIPAddresses: Scope $sid ($($scope.Name)): $($stats.Free) free, $($stats.InUse) in use, $($stats.Reserved) reserved" -LogOnly
            }
        }
    }

    # Sweep orphaned DHCP reservations for THIS domain before allocating anything.
    #
    # A reservation goes orphaned when its VM is deleted (failed Phase 1 VM that was
    # removed, or a prior teardown whose DHCP cleanup didn't run) or recreated with a
    # new MAC. Get-DhcpServerv4FreeIPAddress treats a reservation with no active lease
    # as FREE, so it can hand a stale-reservation IP to a new VM, whose own reservation
    # Add then fails (the IP is already reserved) -- the same collision class that broke
    # Phase 5 SQLAO. Clearing orphans up front frees those IPs for clean reuse.
    #
    # Ownership is scoped strictly to this domain so we never touch another domain's or
    # a manually-created reservation: a reservation is removable only when its MAC is
    # NOT held by any live VM AND it is positively attributable to this domain (FQDN
    # ending in .<domain>, a hostname/Description naming one of this domain's VMs, or --
    # for the domain's own exclusive subnet -- a MemLabs 'Reservation for X' signature).
    $domainName = $DeployConfig.vmOptions.domainName
    if ($domainName) {
        $validMacs = [System.Collections.Generic.HashSet[string]]::new()
        $domainVmNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

        $existingDomainVMs = @()
        try { $existingDomainVMs = @(Get-List -Type VM -DomainName $domainName -SmartUpdate) } catch {}
        foreach ($evm in $existingDomainVMs) {
            if ($evm.vmName) { $null = $domainVmNames.Add($evm.vmName) }
        }
        foreach ($cvm in $DeployConfig.virtualMachines) {
            if ($cvm.vmName) { $null = $domainVmNames.Add($cvm.vmName) }
        }

        # Live NIC MACs for VMs that still exist (the only legitimate reservation owners).
        foreach ($evm in $existingDomainVMs) {
            try {
                $liveVm = Get-VM2 -Name $evm.vmName -ErrorAction SilentlyContinue
                if (-not $liveVm) { continue }
                foreach ($nic in ($liveVm | Get-VMNetworkAdapter -ErrorAction SilentlyContinue)) {
                    if ($nic.MacAddress -and $nic.MacAddress -ne '000000000000') {
                        $null = $validMacs.Add(($nic.MacAddress -replace '-', '').ToUpper())
                    }
                }
            }
            catch {}
        }

        $orphansRemoved = 0
        foreach ($sid in $scopesNeeded) {
            $isSharedScope = ($sid -eq '172.31.250.0')
            $resv = @()
            try { $resv = @(Get-DhcpServerv4Reservation -ScopeId $sid -ErrorAction SilentlyContinue) } catch {}
            foreach ($r in $resv) {
                $rMac = ($r.ClientId -replace '-', '').ToUpper()
                if (-not $rMac) { continue }
                if ($validMacs.Contains($rMac)) { continue }   # held by a live VM -- keep

                $rName = [string]$r.Name
                $rDesc = [string]$r.Description
                $rHost = if ($rName) { ($rName -split '\.')[0] } else { '' }

                $ownedByDomain = $false
                if ($rName -and $rName -like "*.$domainName") {
                    # FQDN registered into this domain -- strongest signal, safe even on
                    # the shared internet scope.
                    $ownedByDomain = $true
                }
                elseif (-not $isSharedScope) {
                    # The domain's own /24 is exclusive to this domain, so a MemLabs
                    # reservation here that no live VM owns is ours to clear.
                    if ($rHost -and $domainVmNames.Contains($rHost)) {
                        $ownedByDomain = $true
                    }
                    elseif ($rDesc -match '^Reservation for (.+)$') {
                        # Linux VM reservations carry a " (Linux)" suffix in the Description
                        # (Common.Linux.ps1: "Reservation for <vm> (Linux)"). Strip it before
                        # matching the bare VM name, otherwise the proxy's fixed-role reservation
                        # (e.g. .2) -- which also has no FQDN Name yet (its DNS A-record is
                        # deferred to Phase 2) -- can NEVER be attributed to the domain and is
                        # never swept. A surviving stale .2 reservation then gets inherited by a
                        # later VM that Hyper-V hands the proxy's recycled MAC, booting it onto
                        # .2 and colliding with the proxy.
                        $resvVmName = $Matches[1].Trim() -replace '\s*\(Linux\)$', ''
                        if ($domainVmNames.Contains($resvVmName)) {
                            $ownedByDomain = $true
                        }
                    }
                }
                if (-not $ownedByDomain) { continue }   # unknown / other domain -- never touch

                $rIp = $r.IPAddress.IPAddressToString
                Write-Log "Set-DeployConfigIPAddresses: Removing orphaned DHCP reservation $rIp (Name='$rName', MAC=$rMac, scope $sid) -- no live VM owns this MAC" -LogOnly
                # Remove-DhcpServerv4Reservation's -IPAddress and -ScopeId belong to
                # different parameter sets (IPAddress uniquely identifies the
                # reservation; ScopeId pairs with ClientId). Passing both can't
                # resolve a set, and that binding error is terminating -- it bypasses
                # -ErrorAction SilentlyContinue. Identify the reservation by IP only.
                Remove-DhcpServerv4Reservation -IPAddress $rIp -ErrorAction SilentlyContinue
                $orphansRemoved++
            }
        }
        if ($orphansRemoved -gt 0) {
            Write-Log "Set-DeployConfigIPAddresses: Cleaned up $orphansRemoved orphaned DHCP reservation(s) for domain $domainName"
        }
    }

    # Pre-allocate SQLAO virtual IPs (cluster VIP + AG listener) up front, alongside
    # every other VM, so they are reserved BEFORE the per-VM free-IP picks below.
    #
    # These were previously allocated lazily in New-VirtualMachine's 2nd-NIC code
    # during Phase 1. That allocator runs in a parallel child job and only consults
    # live DHCP (active leases + exclusions). A regular VM's pre-assigned IP is held
    # only by a temporary exclusion that THIS function removes at the end -- its
    # durable DHCP reservation isn't created until the VM is started, seconds later.
    # In that window a SQLAO node's cluster allocator could pick a regular VM's
    # in-flight IP (and vice-versa), producing a Phase 5 'IP Address is already used'
    # collision (seen on wacky.sandwich.lab: ZZ-FRIES ClusterIP 172.19.77.83 collided
    # with ZZ-TURNIP's AssignedIP .83).
    #
    # Allocating here -- single-threaded, before any Phase 1 job starts, and seeding
    # the shared dedup set used for every VM -- closes that race. Cluster/AG IPs are
    # drawn from .201-.254, ABOVE the DHCP pool, so the pool allocator can never
    # collide with them. On rerun, existing values in deployConfig or the VM Note are
    # restored and kept instead of being reallocated.

    # Allocate a SQLAO cluster/AG virtual IP from the TOP of the subnet (.201-.254),
    # ABOVE the DHCP dynamic pool (.20-.199) and the .200 gateway. Keeping cluster
    # virtual IPs out of the pool means Get-DhcpServerv4FreeIPAddress (which only
    # ever returns pool addresses) can NEVER hand a regular VM an address that is
    # also a cluster VIP -- structurally eliminating the Phase 5 'IP Address is
    # already used' collision class. The chosen IP is seeded into the dedup set so
    # neither the next cluster's pick nor the per-VM pool loop can return it again.
    function Get-SqlaoFreeIP {
        param([string]$ScopeId, [string]$VmName, [string]$Label)
        $base = (($ScopeId.Split('.') | Select-Object -First 3) -join '.')

        # Walk the cluster range .201-.254 (ABOVE the .20-.199 pool) and return the
        # first address not already taken. $allocatedIps holds every IP claimed this
        # run -- pool picks plus every cluster/AG IP seeded from existing clusters in
        # step 2 -- so this naturally skips IPs owned by other clusters in the domain.
        # No DHCP exclusion is added: these IPs are outside the scope's lease range,
        # so the pool allocator can never return them and an exclusion can't even be
        # created there.
        for ($octet = 201; $octet -le 254; $octet++) {
            $candidate = "$base.$octet"
            if ($allocatedIps.Contains($candidate)) { continue }
            # Defensive: a reservation should never exist above the .199 pool, but
            # skip the address if one somehow does.
            $existingResv = $null
            try { $existingResv = Get-DhcpServerv4Reservation -IPAddress $candidate -ErrorAction SilentlyContinue } catch {}
            if ($existingResv) { continue }

            $null = $allocatedIps.Add($candidate)
            $null = $sqlaoIps.Add($candidate)
            return $candidate
        }

        Write-Log "$VmName`: SQLAO: No free $Label IP in $base.201-.254 (cluster IP range exhausted)" -Warning
        return $null
    }

    $sqlaoIps = [System.Collections.Generic.HashSet[string]]::new()

    # 1. Collect every cluster/AG IP already known (deployConfig + VM Notes, all nodes).
    #    For owner nodes, restore note values back onto the config object so a rerun
    #    keeps the original IPs instead of picking new ones in step 3.
    foreach ($sqlaoVm in ($DeployConfig.virtualMachines | Where-Object { $_.role -eq 'SQLAO' })) {
        $note = $null
        try { $note = Get-VMNote -VMName $sqlaoVm.vmName -ErrorAction SilentlyContinue } catch {}
        foreach ($prop in 'ClusterIPAddress', 'AGIPAddress') {
            if ($sqlaoVm.OtherNode -and -not $sqlaoVm.$prop -and $note -and $note.$prop) {
                $sqlaoVm | Add-Member -MemberType NoteProperty -Name $prop -Value ($note.$prop) -Force
            }
            foreach ($src in @($sqlaoVm.$prop, $note.$prop)) {
                if ($src) { $null = $sqlaoIps.Add(($src -replace '/.+$', '')) }
            }
        }
    }

    # 1b. Pull in cluster/AG IPs from every OTHER cluster already in the domain
    #     (existing SQLAO VMs not part of this deployConfig). A new cluster must not
    #     reuse an IP a pre-existing cluster already owns.
    if ($DeployConfig.vmOptions.domainName) {
        $existingSqlaoVMs = @()
        try { $existingSqlaoVMs = @(Get-List -Type VM -DomainName $DeployConfig.vmOptions.domainName -SmartUpdate | Where-Object { $_.role -eq 'SQLAO' }) } catch {}
        foreach ($evm in $existingSqlaoVMs) {
            foreach ($prop in 'ClusterIPAddress', 'AGIPAddress') {
                if ($evm.$prop) { $null = $sqlaoIps.Add(($evm.$prop -replace '/.+$', '')) }
            }
        }
    }

    # 2. Seed every known cluster/AG IP into the shared dedup set so neither another
    #    cluster's allocation nor the per-VM pool loop can hand it out again. These
    #    live ABOVE the DHCP pool (.201-.254), so no exclusion is needed -- and one
    #    can't be created (an exclusion must fall inside the scope's lease range).
    #    The lone exception: a legacy cluster IP from before this scheme that still
    #    sits inside the .20-.199 pool DOES need an exclusion so a regular VM's
    #    free-IP pick can't grab it.
    foreach ($sqlaoIp in $sqlaoIps) {
        $parsed = $null
        if (-not [System.Net.IPAddress]::TryParse($sqlaoIp, [ref]$parsed)) { continue }
        $null = $allocatedIps.Add($sqlaoIp)
        $lastOctet = [int]($sqlaoIp.Split('.')[-1])
        if ($lastOctet -ge 20 -and $lastOctet -le 199) {
            $sqlaoScope = (($sqlaoIp.Split('.') | Select-Object -First 3) -join '.') + '.0'
            if ($scopesNeeded.Contains($sqlaoScope)) {
                Add-DhcpServerv4ExclusionRange -ScopeId $sqlaoScope -StartRange $sqlaoIp -EndRange $sqlaoIp -ErrorAction SilentlyContinue | Out-Null
                Write-Log "Set-DeployConfigIPAddresses: Excluded legacy in-pool SQLAO IP $sqlaoIp on scope $sqlaoScope" -LogOnly
            }
        }
        else {
            Write-Log "Set-DeployConfigIPAddresses: Reserved SQLAO virtual IP $sqlaoIp (above pool, no exclusion needed)" -LogOnly
        }
    }

    # 3. For each cluster-owner node still missing a cluster/AG IP, allocate one now
    #    from the domain scope. Both IPs must live on the domain subnet so they are
    #    reachable by clients (the heartbeat network is cluster-only / Role 1).
    foreach ($ownerVm in ($DeployConfig.virtualMachines | Where-Object { $_.role -eq 'SQLAO' -and $_.OtherNode -and -not $_.hidden })) {
        # Allocate from the node's OWN network, not the domain default. A SQLAO
        # node placed on a secondary network (e.g. a child Primary's site network)
        # has its domain NIC -- and therefore its only gateway-bearing
        # ClusterAndClient network -- on that subnet. Allocating the cluster/AG
        # virtual IPs from $defaultNetwork instead lands them on a subnet the node
        # can't host, so New-Cluster -StaticAddress fails with "no appropriate
        # ClusterAndClient network was found to host it". Mirror the per-VM main-NIC
        # rule ($vm.network ?? $defaultNetwork).
        $domainScopeId = if ($ownerVm.network) { $ownerVm.network } else { $defaultNetwork }
        if (-not $scopesNeeded.Contains($domainScopeId)) {
            Write-Log "$($ownerVm.vmName): SQLAO: domain scope $domainScopeId not available; cluster/AG IPs will be allocated in Phase 1." -Warning
            continue
        }
        $ownerSubnet = (($domainScopeId.Split('.') | Select-Object -First 3) -join '.') + '.'
        foreach ($prop in 'ClusterIPAddress', 'AGIPAddress') {
            $existing = $ownerVm.$prop
            if ($existing) {
                $clean = $existing -replace '/.+$', ''
                # Self-heal: a value restored from a note/config that was allocated
                # against the WRONG subnet (e.g. an earlier build that drew cluster
                # IPs from the domain default network instead of this node's own
                # network) would make New-Cluster fail forever. Discard it so it gets
                # reallocated from $domainScopeId below.
                if ($clean -notlike "$ownerSubnet*") {
                    Write-Log "$($ownerVm.vmName): SQLAO: discarding $prop $clean -- not on node subnet $ownerSubnet* (reallocating from scope $domainScopeId)" -Warning
                    $null = $sqlaoIps.Remove($clean)
                    $ownerVm.$prop = $null
                    $existing = $null
                }
                else {
                    # Already set and on the correct subnet -- keep it, strip any /suffix.
                    if ($clean -ne $existing) { $ownerVm | Add-Member -MemberType NoteProperty -Name $prop -Value $clean -Force }
                    continue
                }
            }
            $label = if ($prop -eq 'ClusterIPAddress') { 'Cluster' } else { 'AG listener' }
            $newIp = Get-SqlaoFreeIP -ScopeId $domainScopeId -VmName $ownerVm.vmName -Label $label
            if (-not $newIp) { continue }
            $null = $sqlaoIps.Add($newIp)
            $ownerVm | Add-Member -MemberType NoteProperty -Name $prop -Value $newIp -Force
            Write-Log "$($ownerVm.vmName): SQLAO: Pre-assigned $label IP $newIp (domain scope $domainScopeId)" -LogOnly
        }
        if ($ownerVm.ClusterIPAddress -and $ownerVm.AGIPAddress -and $ownerVm.ClusterIPAddress -eq $ownerVm.AGIPAddress) {
            Write-Log "$($ownerVm.vmName): SQLAO: Cluster and AG IP are identical ($($ownerVm.ClusterIPAddress)). Domain scope $domainScopeId may be exhausted." -Failure
        }
    }

    foreach ($vm in $DeployConfig.virtualMachines) {
        if ($vm.hidden) { $skipCount++; continue }
        if ($vm.role -eq 'OSDClient') { $skipCount++; continue }
        $vmCount++

        # Determine the DHCP scope for this VM
        if ($vm.role -in 'InternetClient', 'AADClient') {
            $scopeId = '172.31.250.0'
        }
        else {
            $scopeId = if ($vm.network) { $vm.network } else { $defaultNetwork }
        }
        $base = ($scopeId.Split('.') | Select-Object -First 3) -join '.'
        $ip = $null
        $ipSource = 'none'

        # Check if a DHCP reservation already exists for this VM's MAC
        # (from a previous deploy). If so, reuse it instead of allocating
        # a new IP — avoids clobbering a working reservation on rerun.
        try {
            $existingVm = Get-VM2 -Name $vm.vmName -ErrorAction SilentlyContinue
            if ($existingVm) {
                $vmnet = $existingVm | Get-VMNetworkAdapter |
                    Where-Object { $_.SwitchName -and $_.SwitchName -notmatch 'Cluster' } |
                    Select-Object -First 1
                if ($vmnet -and $vmnet.MacAddress) {
                    $reservation = Get-DhcpServerv4Reservation -ScopeId $scopeId -ErrorAction SilentlyContinue |
                        Where-Object { ($_.ClientId -replace '-','') -eq $vmnet.MacAddress }
                    if ($reservation) {
                        $ip = $reservation.IPAddress.IPAddressToString
                        $ipSource = 'existing-reservation'
                        $reuseCount++
                    }
                    else {
                        Write-Log "$($vm.vmName): VM exists (MAC=$($vmnet.MacAddress)) but no DHCP reservation found in scope $scopeId" -LogOnly
                    }
                }
                else {
                    Write-Log "$($vm.vmName): VM exists but has no domain NIC or MAC" -LogOnly
                }
            }
        }
        catch {
            Write-Log "$($vm.vmName): Error checking existing VM/reservation: $($_.Exception.Message)" -LogOnly
        }

        # Fixed well-known IPs (outside the DHCP pool .20-.199)
        if (-not $ip) {
            switch ($vm.role) {
                'DC'        { $ip = "$base.1"; $ipSource = 'fixed-role' }
                'BDC'       { $ip = "$base.3"; $ipSource = 'fixed-role' }
                'CAS'       { $ip = "$base.5"; $ipSource = 'fixed-role' }
                'Primary'   { $ip = "$base.10"; $ipSource = 'fixed-role' }
                'Secondary' { $ip = "$base.15"; $ipSource = 'fixed-role' }
                'Proxy'     { $ip = "$base.2"; $ipSource = 'fixed-role' }
            }
            if ($ipSource -eq 'fixed-role') { $fixedCount++ }
        }

        # Dynamic allocation from the DHCP pool
        if (-not $ip) {
            try {
                # Get-DhcpServerv4FreeIPAddress + Add-DhcpServerv4ExclusionRange
                # is a read-then-write race when multiple Phase 1 jobs allocate
                # against the same scope. Serialize host-wide via the DHCP mutex
                # so two parallel allocations can't both pick the same address
                # before either one excludes it.
                $allocResult = Invoke-WithDhcpMutex -ScriptBlock {
                    $freeIP = Get-DhcpServerv4FreeIPAddress -ScopeId $scopeId -ErrorAction Stop
                    if ($freeIP) {
                        # Exclude it immediately so the next call can't return the same address
                        Add-DhcpServerv4ExclusionRange -ScopeId $scopeId -StartRange $freeIP -EndRange $freeIP -ErrorAction SilentlyContinue | Out-Null
                    }
                    $freeIP
                }
                if ($allocResult) {
                    $ip = $allocResult.ToString()
                    $ipSource = 'dhcp-pool'
                    $dynamicCount++
                }
                else {
                    Write-Log "$($vm.vmName): DHCP scope $scopeId returned no free IPs (scope may be exhausted)" -Warning
                    $failCount++
                    continue
                }
            }
            catch {
                Write-Log "$($vm.vmName): Failed to get free IP from scope ${scopeId}: $($_.Exception.Message)" -Warning
                $failCount++
                continue
            }
        }

        # Validate the IP is well-formed
        $parsedIP = $null
        if (-not [System.Net.IPAddress]::TryParse($ip, [ref]$parsedIP)) {
            Write-Log "$($vm.vmName): IP '$ip' is not a valid IPv4 address (source=$ipSource). Skipping." -Warning
            $failCount++
            continue
        }

        if (-not $allocatedIps.Add($ip)) {
            Write-Log "$($vm.vmName): DUPLICATE — IP $ip already allocated to another VM in this deploy! (source=$ipSource)" -Warning
        }

        $vm | Add-Member -MemberType NoteProperty -Name 'AssignedIP' -Value $ip -Force
        Write-Log "$($vm.vmName): Pre-assigned IP $ip (scope $scopeId, role $($vm.role), source $ipSource)" -LogOnly
    }

    # Clean up exclusion ranges we added — the DHCP reservations (created
    # in New-VirtualMachine after New-VM) will prevent reuse. Exclusions
    # block the entire IP even from reservations on some DHCP versions.
    $cleanedExclusions = 0
    foreach ($vm in $DeployConfig.virtualMachines) {
        if ($vm.hidden -or -not $vm.AssignedIP) { continue }
        if ($vm.role -in 'DC', 'BDC', 'CAS', 'Primary', 'Secondary', 'Proxy', 'OSDClient') { continue }
        $scopeId = if ($vm.role -in 'InternetClient', 'AADClient') { '172.31.250.0' } else { if ($vm.network) { $vm.network } else { $defaultNetwork } }
        $removed = Remove-DhcpServerv4ExclusionRange -ScopeId $scopeId -StartRange $vm.AssignedIP -EndRange $vm.AssignedIP -ErrorAction SilentlyContinue -PassThru
        if ($removed) { $cleanedExclusions++ }
    }

    Write-Log "Pre-allocated IPs for $vmCount VM(s): $dynamicCount dynamic, $fixedCount fixed-role, $reuseCount reused, $failCount failed, $skipCount skipped. Cleaned $cleanedExclusions temp exclusions."
}

function New-VirtualMachine {
    param (
        [Parameter(Mandatory = $true)]
        [string]$VmName,
        [Parameter(Mandatory = $true)]
        [string]$VmPath,
        [Parameter(Mandatory = $false)]
        [string]$SourceDiskPath,
        [Parameter(Mandatory = $true)]
        [string]$Memory,
        [Parameter(Mandatory = $false)]
        [string]$dynamicMinRam,
        [Parameter(Mandatory = $false)]
        [string]$role,
        [Parameter(Mandatory = $true)]
        [int]$Processors,
        [Parameter(Mandatory = $true)]
        [int]$Generation,
        [Parameter(Mandatory = $true)]
        [string]$SwitchName,
        [Parameter(Mandatory = $false)]
        [string]$DiskControllerType = "SCSI",
        [Parameter(Mandatory = $false)]
        [object]$AdditionalDisks,
        [Parameter(Mandatory = $false)]
        [switch]$ForceNew,
        [Parameter(Mandatory = $false)]
        [PsCustomObject] $DeployConfig,
        [Parameter(Mandatory = $false)]
        [switch]$OSDClient,
        [Parameter(Mandatory = $false)]
        [switch]$tpmEnabled,
        [Parameter(Mandatory = $false)]
        [switch]$Migrate,
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf
    )

    $OriginalProgressPreference = $Global:ProgressPreference
    $Global:ProgressPreference = 'SilentlyContinue'
    $Activity = "Creating Virtual Machine"
    try {
        # WhatIf
        if ($WhatIf) {
            Write-Log "WhatIf: Will create VM $VmName in $VmPath using VHDX $SourceDiskPath, Memory: $Memory, Processors: $Processors, Generation: $Generation, AdditionalDisks: $AdditionalDisks, SwitchName: $SwitchName, ForceNew: $ForceNew"
            return $true
        }


        Write-Log "$VmName`: $Activity"
        Write-Progress2 $Activity -Status "Starting" -percentcomplete 0 -force
        # Test if source file exists
        if (-not (Test-Path $SourceDiskPath) -and (-not $OSDClient.IsPresent)) {
            Write-Log "$VmName`: $SourceDiskPath not found. Cannot create new VM." -failure
            return $false
        }

        # VM Exists
        $vmTest = Get-VM -Name $VmName -ErrorAction SilentlyContinue
        if ($vmTest -and $ForceNew.IsPresent) {
            Write-Log "$VmName`: Virtual machine already exists. ForceNew switch is present."
            if ($vmTest.State -ne "Off") {
                Write-Log "$VmName`: Turning the VM off forcefully..."
                $vmTest | Stop-VM -TurnOff -Force -WarningAction SilentlyContinue
            }
            $vmTest | Remove-VM -Force
            Write-Log "$VmName`: Purging $($vmTest.Path) folder..."
            if ($Common.PS7) {
                Remove-Item -Path $($vmTest.Path) -Force -Recurse -ProgressAction SilentlyContinue | out-null
            }
            else {
                Remove-Item -Path $($vmTest.Path) -Force -Recurse | out-null
            }
            Write-Log "$VmName`: Purge complete."
            Get-List -FlushCache | Out-Null # flush cache
        }

        if ($vmTest -and -not $ForceNew.IsPresent) {
            Write-Log "$VmName`: Virtual machine already exists. ForceNew switch is NOT present. Exit."
            return $false
        }

        if (-not $Migrate) {
            # Make sure Existing VM Path is gone!
            $VmSubPath = Join-Path $VmPath $VmName
            if (Test-Path -Path $VmSubPath) {
                Write-Log "$VmName`: Found existing directory for $VmName. Purging $VmSubPath folder..."
                if ($Common.PS7) {
                    Remove-Item -Path $VmSubPath -Force -Recurse -ProgressAction SilentlyContinue | out-null
                }
                else {
                    Remove-Item -Path $VmSubPath -Force -Recurse | out-null
                }
                Write-Log "$VmName`: Purge complete."
            }

            # Retry if its not gone.
            if (Test-Path -Path $VmSubPath) {
                Start-Sleep -Seconds 30
                Write-Log "$VmName`: (Retry) Found existing directory for $VmName. Purging $VmSubPath folder..."
                if ($Common.PS7) {
                    Remove-Item -Path $VmSubPath -Force -Recurse -ProgressAction SilentlyContinue | out-null
                }
                else {
                    Remove-Item -Path $VmSubPath -Force -Recurse | out-null
                }
                Write-Log "$VmName`: Purge complete."
            }

            #Fail if its not gone.
            if (Test-Path -Path $VmSubPath) {
                Write-Log "$VmName`: Could not delete $VmSubPath folder... Exit."
                return $false
            }
        }



        Write-Progress2 $Activity -Status "Creating VM in Hyper-V" -percentcomplete 5 -force
        # Create new VM
        try {
            $vm = New-VM -Name $vmName -Path $VmPath -Generation $Generation -MemoryStartupBytes ($Memory / 1) -SwitchName $SwitchName -ErrorAction Stop
            if ($dynamicMinRam -and ($dynamicMinRam / 1) -ne 0 -and (($dynamicMinRam / 1) -lt ($Memory / 1))) {
                $priority = 25
                $buffer = 10
                if ($role -in ("DC", "SqlServer", "Primary", "SQLAO", "CAS")) {
                    $priority = 50
                    $buffer = 20
                }
                if (($dynamicMinRam / 1) -gt 40MB) {
                    Write-log -logonly "$VmName` Setting Dynamic Ram to $dynamicMinRam / $Memory"
                    $vm | Set-VMMemory -DynamicMemoryEnabled $true -MinimumBytes ($dynamicMinRam / 1) -maximumbytes ($Memory / 1) -startupbytes ($Memory / 1) -Priority $priority -buffer $buffer -ErrorAction Stop
                }
                else {
                    Write-log -logonly "$VmName` Not Setting Dynamic Ram to $dynamicMinRam / $Memory"
                }
            }
        }
        catch {
            Write-Log "$VmName`: Failed to create new VM. $_ with command 'New-VM -Name $vmName -Path $VmPath -Generation $Generation -MemoryStartupBytes ($Memory / 1) -SwitchName $SwitchName -ErrorAction Stop'"
            Write-Log "$($_.ScriptStackTrace)" -LogOnly
            return $false
        }

        Write-Progress2 $Activity -Status "Hyper-V VM Object created. Waiting for Disk Creation" -percentcomplete 30 -force
        # Add VMNote as soon as VM is created
        if ($DeployConfig) {
            New-VmNote -VmName $VmName -DeployConfig $DeployConfig -InProgress $true
        }

        # Create DHCP reservation now that the MAC is available.
        # AssignedIP was stamped on the VM config by Set-DeployConfigIPAddresses
        # before Phase 1 started, so every VM boots with a deterministic IP.
        # Skip if a reservation already exists for this MAC (rerun scenario).
        if ($DeployConfig -and -not $OSDClient.IsPresent) {
            $thisVmConfig = $DeployConfig.virtualMachines | Where-Object { $_.vmName -eq $VmName } | Select-Object -First 1
            if ($thisVmConfig -and $thisVmConfig.AssignedIP) {
                # DHCP CIM cmdlets run in an isolated runspace (Invoke-IsolatedCim
                # via the Get-VMMacIsolated / *DHCPReservation* helpers) so their
                # CIM progress never poisons this job's managed progress bars.
                try {
                    $vmMac = Get-VMMacIsolated -VmName $VmName
                    if ($vmMac -and $vmMac -ne '000000000000') {
                        $assignedIP = $thisVmConfig.AssignedIP
                        $scopeId = if ($thisVmConfig.role -in 'InternetClient', 'AADClient') {
                            '172.31.250.0'
                        } else {
                            # Scope must be the /24 that contains AssignedIP -- a VM on a
                            # secondary subnet must reserve in its own scope, not vmOptions.network.
                            $ipOctets = ([string]$assignedIP).Split('.')
                            if ($ipOctets.Count -eq 4) { "$($ipOctets[0]).$($ipOctets[1]).$($ipOctets[2]).0" }
                            elseif ($thisVmConfig.network) { $thisVmConfig.network } else { $DeployConfig.vmOptions.network }
                        }
                        # Check if a reservation already exists for this MAC.
                        # Only KEEP it when it points at this VM's AssignedIP; a reservation
                        # for this MAC at a DIFFERENT IP is stale (e.g. left over pointing at
                        # another VM's fixed-role IP) and MUST be corrected, or the VM boots
                        # onto the wrong address and collides with the IP's rightful owner.
                        $existing = Get-DHCPReservationIPForMac -ScopeId $scopeId -Mac $vmMac
                        if ($existing -and $existing -eq $assignedIP) {
                            Write-Log "$VmName`: DHCP reservation already exists: $existing (MAC=$vmMac); keeping" -LogOnly
                        }
                        else {
                            if ($existing) {
                                Write-Log "$VmName`: DHCP reservation for MAC=$vmMac points to $existing but AssignedIP is $assignedIP; correcting to avoid an address collision" -LogOnly
                            }
                            Add-DHCPReservationIsolated -ScopeId $scopeId -IPAddress $assignedIP -Mac $vmMac -Description "Reservation for $VmName" -LogContext $VmName -PurgeMacFirst
                            Write-Log "$VmName`: DHCP reservation created: $assignedIP (MAC=$vmMac, Scope=$scopeId)" -LogOnly
                        }
                    }
                }
                catch {
                    Write-Log "$VmName`: Could not create DHCP reservation for $($thisVmConfig.AssignedIP). $_" -Warning
                }
            }
        }

        # Copy sysprepped image to VM location
        $osDiskName = "$($VmName)_OS.vhdx"
        $osDiskPath = Join-Path $vm.Path $osDiskName

        if (-not $Migrate) {
            if (-not $OSDClient.IsPresent) {
                $worked = Get-File -Source $SourceDiskPath -Destination $osDiskPath -DisplayName "Making a copy of base image in $osDiskPath" -Action "Copying"
                if (-not $worked) {
                    Write-Log "$VmName`: Failed to copy $SourceDiskPath to $osDiskPath. Exiting."
                    return $false
                }
            }
            else {
                Write-Progress2 $Activity -Status "Creating new 127GB C: Drive" -percentcomplete 32 -force
                $worked = New-VHD -Path $osDiskPath -SizeBytes 127GB
                if (-not $worked) {
                    Write-Log "$VmName`: Failed to create new VMD $osDiskPath for OSDClient. Exiting."
                    return $false
                }
            }
        }

        if (-not (Test-Path $osDiskPath)) {
            Write-Log "Could not find file $osDiskPath" -Failure
            return
        }


        Write-Log "$VmName`: Enabling Hyper-V Guest Services"
        Write-Progress2 $Activity -Status "Enabling Hyper-V Guest Services" -percentcomplete 35 -force
        Enable-VMIntegrationService -VMName $VmName -Name "Guest Service Interface" -ErrorAction SilentlyContinue | out-null

        if ($Generation -eq "2" -and $tpmEnabled) {
            $mutexName = "TPM"
            $mtx = New-Object System.Threading.Mutex($false, $mutexName)
            Write-Progress2 $Activity -Status "Waiting to enable TPM" -percentcomplete 40 -force
            write-log "Attempting to acquire '$mutexName' Mutex" -LogOnly
            [void]$mtx.WaitOne()
            write-log "acquired '$mutexName' Mutex" -LogOnly
            try {
                Write-Progress2 $Activity -Status "Enabling TPM" -percentcomplete 50 -force
                if ($null -eq (Get-HgsGuardian -Name MemLabsGuardian -ErrorAction SilentlyContinue)) {
                    New-HgsGuardian -Name "MemLabsGuardian" -GenerateCertificates | out-null
                    New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\HgsClient" -Name "LocalCACertSupported" -Value 1 -PropertyType DWORD -Force -ErrorAction SilentlyContinue | Out-Null
                }

                $localCASupported = Get-ItemPropertyValue -Path "HKLM:\SOFTWARE\Microsoft\HgsClient" -Name "LocalCACertSupported"
                if ($localCASupported -eq 1) {
                    Write-Log "$VmName`: Enabling TPM"
                    $HGOwner = Get-HgsGuardian MemLabsGuardian
                    $KeyProtector = New-HgsKeyProtector -Owner $HGOwner -AllowUntrustedRoot
                    if (-not $KeyProtector -or -not ($KeyProtector.RawData)) {
                        Write-Log "$VmName`: New-HgsKeyProtector failed"
                        return $false
                    }
                    Set-VMKeyProtector -VMName $VmName -KeyProtector $KeyProtector.RawData | out-null
                    Enable-VMTPM $VmName -ErrorAction Stop | out-null ## Only required for Win11
                }
                else {
                    Write-Log "$VmName`: Skipped enabling TPM since HKLM:\SOFTWARE\Microsoft\HgsClient\LocalCACertSupported is not set."
                }
            }
            catch {
                Write-Log "$VmName`: TPM failed $_"
                return $false
            }
            finally {
                [void]$mtx.ReleaseMutex()
                [void]$mtx.Dispose()
            }
        }

        Write-Progress2 $Activity -Status "Setting VM to save on stop" -percentcomplete 60 -force
        Write-Log "$VmName`: Setting VM to Save on stop"
        Set-VMSecurity -VmName $vmName -EncryptStateAndVmMigrationTraffic $false
        Set-VMSecurity -VmName $vmName -VirtualizationBasedSecurityOptOut $true
        Set-VM -Name $vmName -AutomaticStopAction Save | out-null

        Write-Progress2 $Activity -Status "Setting Processors" -percentcomplete 62 -force
        Write-Log "$VmName`: Setting Processor count to $Processors"
        Set-VM -Name $vmName -ProcessorCount $Processors | out-null

        Write-Progress2 $Activity -Status "Adding OS Disk to VM" -percentcomplete 65 -force
        # Gen 1 VMs can only boot from IDE; force the OS disk onto IDE 0 regardless of $DiskControllerType.
        $osDiskController = if ($Generation -eq 1) { "IDE" } else { $DiskControllerType }
        Write-Log "$VmName`: Adding virtual disk $osDiskPath (controller: $osDiskController)"
        Add-VMHardDiskDrive -VMName $VmName -Path $osDiskPath -ControllerType $osDiskController -ControllerNumber 0 | out-null

        Write-Progress2 $Activity -Status "Adding DVD disk to VM" -percentcomplete 70 -force
        Write-Log "$VmName`: Adding a DVD drive"
        Add-VMDvdDrive -VMName $VmName | out-null

        Write-Progress2 $Activity -Status "Changing Boot Order" -percentcomplete 75 -force
        Write-Log "$VmName`: Changing boot order"
        # Get-VMFirmware / Set-VMFirmware are Gen 2 only. Gen 1 uses BIOS boot
        # order (CD, IDE, LegacyNetworkAdapter, Floppy) which is correct by default
        # once the OS disk is on IDE.
        $f = if ($Generation -eq 2) { Get-VM2 -Fallback -Name $VmName | Get-VMFirmware } else { $null }
        $f_file = $f.BootOrder | Where-Object { $_.BootType -eq "File" }
        $f_net = $f.BootOrder | Where-Object { $_.BootType -eq "Network" }
        $f_hd = $f.BootOrder | Where-Object { $_.BootType -eq "Drive" -and $_.Device -is [Microsoft.HyperV.PowerShell.HardDiskDrive] }
        $f_dvd = $f.BootOrder | Where-Object { $_.BootType -eq "Drive" -and $_.Device -is [Microsoft.HyperV.PowerShell.DvdDrive] }

        # Add additional disks
        if ($AdditionalDisks) {
            $count = 0
            $label = "DATA"
            Write-Progress2 $Activity -Status "Adding Additional Disks" -percentcomplete 80 -force -log
            foreach ($disk in $AdditionalDisks.psobject.properties) {
                $newDiskName = "$VmName`_$label`_$count.vhdx"
                $newDiskPath = Join-Path $vm.Path $newDiskName
                Write-Log "$VmName`: Adding $newDiskPath"
                if (-not $Migrate) {
                    New-VHD -Path $newDiskPath -SizeBytes ($disk.Value / 1) -Dynamic | out-null
                }
                if (-not (Test-Path $newDiskPath)) {
                    Write-Log "Failed to find $newDiskPath" -Failure
                    return
                }
                Add-VMHardDiskDrive -VMName $VmName -Path $newDiskPath | out-null
                $count++
            }
        }

        Write-Progress2 $Activity -Status "Setting Firmware" -percentcomplete 85 -force
        # Set-VMFirmware is Gen 2 only. Gen 1 BIOS boot order is fine by default.
        if ($Generation -eq 2) {
            # 'File' firmware is not present on new VM, seems like it's created after Windows setup.
            if ($null -ne $f_file) {
                if (-not $OSDClient.IsPresent) {
                    Set-VMFirmware -VMName $VmName -BootOrder $f_file, $f_dvd, $f_hd, $f_net | out-null
                }
                else {
                    Set-VMFirmware -VMName $VmName -BootOrder $f_file, $f_dvd, $f_net, $f_hd | out-null
                }
            }
            else {
                if (-not $OSDClient.IsPresent) {
                    Set-VMFirmware -VMName $VmName -BootOrder $f_dvd, $f_hd, $f_net | out-null
                }
                else {
                    Set-VMFirmware -VMName $VmName -BootOrder $f_dvd, $f_net, $f_hd | out-null
                }
            }
        }

        Write-Progress2 $Activity -Status "Starting VM" -percentcomplete 86 -force
        Write-Log "$VmName`: Starting virtual machine"
        $started = Start-VM2 -Name $VmName -Passthru
        if (-not $started) {
            Write-Log "$VmName`: VM Not Started."
            return $false
        }

        # Create DHCP reservation now that the VM is started and has a real MAC.
        # Before Start-VM2, Hyper-V reports MAC as 000000000000 (dynamic MAC
        # not yet assigned). After start, the real MAC is available.
        if ($DeployConfig -and -not $OSDClient.IsPresent) {
            $thisVmConfig2 = $DeployConfig.virtualMachines | Where-Object { $_.vmName -eq $VmName } | Select-Object -First 1
            if ($thisVmConfig2 -and $thisVmConfig2.AssignedIP -and -not $thisVmConfig2.ReservationCreated) {
                # DHCP/Hyper-V CIM cmdlets run isolated (see Get-VMMacIsolated /
                # *DHCPReservation* helpers) so they don't poison the managed bars.
                try {
                    $vmMac2 = Get-VMMacIsolated -VmName $VmName -ExcludeCluster
                    if ($vmMac2 -and $vmMac2 -ne '000000000000') {
                        $scopeId2 = if ($thisVmConfig2.role -in 'InternetClient', 'AADClient') {
                            '172.31.250.0'
                        } else {
                            # Scope must be the /24 that contains AssignedIP -- a VM on a
                            # secondary subnet must reserve in its own scope, not vmOptions.network.
                            $ipOctets2 = ([string]$thisVmConfig2.AssignedIP).Split('.')
                            if ($ipOctets2.Count -eq 4) { "$($ipOctets2[0]).$($ipOctets2[1]).$($ipOctets2[2]).0" }
                            elseif ($thisVmConfig2.network) { $thisVmConfig2.network } else { $DeployConfig.vmOptions.network }
                        }
                        # Only KEEP an existing reservation for this MAC when it points at the
                        # VM's AssignedIP; a reservation at a different IP is stale and would put
                        # the VM on the wrong address (and collide with that IP's rightful owner).
                        $existing2 = Get-DHCPReservationIPForMac -ScopeId $scopeId2 -Mac $vmMac2
                        if ($existing2 -and $existing2 -eq $thisVmConfig2.AssignedIP) {
                            Write-Log "$VmName`: DHCP reservation already exists: $existing2 (MAC=$vmMac2); keeping" -LogOnly
                        }
                        else {
                            if ($existing2) {
                                Write-Log "$VmName`: DHCP reservation for MAC=$vmMac2 points to $existing2 but AssignedIP is $($thisVmConfig2.AssignedIP); correcting to avoid an address collision" -LogOnly
                            }
                            Add-DHCPReservationIsolated -ScopeId $scopeId2 -IPAddress $thisVmConfig2.AssignedIP -Mac $vmMac2 -Description "Reservation for $VmName" -LogContext $VmName -PurgeMacFirst
                            Write-Log "$VmName`: DHCP reservation created post-start: $($thisVmConfig2.AssignedIP) (MAC=$vmMac2, Scope=$scopeId2)" -LogOnly
                        }
                        $thisVmConfig2 | Add-Member -MemberType NoteProperty -Name 'ReservationCreated' -Value $true -Force
                    }
                }
                catch {
                    # Add-DHCPReservationIsolated already logs each attempt and rethrows
                    # with the full exception chain on final failure; surface a concise
                    # WARN here plus the script stack for diagnostic completeness.
                    $exType = $_.Exception.GetType().FullName
                    $exMsg  = $_.Exception.Message
                    Write-Log "$VmName`: Could not create DHCP reservation post-start for $($thisVmConfig2.AssignedIP) [$exType]: $exMsg" -Warning
                    if ($_.ScriptStackTrace) { Write-Log "$VmName`: DHCP reservation failure stack: $($_.ScriptStackTrace)" -LogOnly }
                }
            }
        }

        # The SQLAO cluster heartbeat (2nd) NIC and its heartbeat/cluster/AG IPs are no
        # longer added here. They are provisioned at the start of Phase 5 (see the
        # "$Phase -eq 5 -and role -eq SQLAO" block in Common.ScriptBlocks.ps1), which is
        # both faster (host has settled past the Phase 1 parallel-OOBE storm) and
        # convergent (safe to re-run).

        Write-Progress2 $Activity -Status "VM Created in Hyper-V successfully" -percentcomplete 100 -force -Completed
        return $true
    }
    catch {
        Write-Exception $_
        Write-Progress2 $Activity -Status $_ -percentcomplete 100 -force -Completed
        Start-Sleep -Seconds 3
        Write-Log "Create VM failed with $_"
        return $false
    }
    finally {
        $Global:ProgressPreference = $OriginalProgressPreference
    }
}

function Get-AvailableMemoryGB {
    param(
        [Parameter(Mandatory = $false)]
        [string[]]$ExcludeVMs
    )

    # Base capacity on live available RAM so root-partition and host-process
    # usage is included. Total physical RAM minus VM-assigned memory assumes
    # all non-VM usage fits inside the fixed reserve, which can substantially
    # overstate capacity on a loaded Hyper-V host.
    $availableBytes = $null
    try {
        $availableBytes = (Get-Counter '\Memory\Available MBytes' -ErrorAction Stop).CounterSamples[0].CookedValue * 1MB
    }
    catch {
        $availableBytes = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).FreePhysicalMemory * 1KB
    }

    # The caller's total includes its already-running VMs. Credit their current
    # assigned memory back so rerun validation does not count it twice.
    $runningVMs = Get-VM | Where-Object { $_.State -eq "Running" }
    if ($ExcludeVMs) {
        $excludedRunningMemory = ($runningVMs | Where-Object { $_.Name -in $ExcludeVMs } | Measure-Object -Property MemoryAssigned -Sum).Sum
    }
    if (-not $excludedRunningMemory) { $excludedRunningMemory = 0 }

    $availableMemory = [Math]::Round(($availableBytes + $excludedRunningMemory - 8GB) / 1GB, 2)
    if ($availableMemory -lt 0) {
        $availableMemory = 0
    }
    return $availableMemory
}

function Wait-ForVm {

    param (
        [Parameter(Mandatory = $true)]
        [string]$VmName,
        [Parameter(Mandatory = $true, ParameterSetName = "VmState")]
        [string]$VmState,
        [Parameter(Mandatory = $false, ParameterSetName = "OobeComplete")]
        [switch]$OobeComplete,
        [Parameter(Mandatory = $false, ParameterSetName = "OobeStarted")]
        [switch]$OobeStarted,
        [Parameter(Mandatory = $false, ParameterSetName = "VmTestPath")]
        [string]$PathToVerify,
        [Parameter(Mandatory = $false)]
        [int]$TimeoutMinutes = 30,
        [Parameter(Mandatory = $false)]
        [int]$WaitSeconds = 10,
        [Parameter(Mandatory = $false, HelpMessage = "Domain Name to use for creating domain creds")]
        [string]$VmDomainName = "WORKGROUP",
        [Parameter(Mandatory = $false)]
        [switch]$Quiet,
        [Parameter(Mandatory = $false)]
        [switch]$SkipDiskTest,
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf
    )

    if ($WhatIf) {
        Write-Log "WhatIf: Will wait for $VmName for $TimeoutMinutes minutes to become ready" -Warning
        return $true
    }

    $ready = $false

    $stopWatch = New-Object -TypeName System.Diagnostics.Stopwatch
    $timeSpan = New-TimeSpan -Minutes $TimeoutMinutes
    $stopWatch.Start()
    $vmTest = Get-VM2 -Name $VmName -Fallback
    if ($VmState) {
        Write-Log "$VmName`: Waiting for VM to enter $VmState state..."
        do {
            try {
                $vmTest = Get-VM2 -Name $VmName -Fallback
                if (-not $vmTest) {
                    Write-Progress2 -Activity  "Could not find VM" -Status "Could not find VM" -PercentComplete 100 -Completed -force
                    Write-Log -Failure "Could not find VM $VMName"
                    return
                }

                try {
                    Write-ProgressElapsed -showTimeout -stopwatch $stopWatch -timespan $timespan -text "Waiting for VM to enter '$VmState' state. Current State: $($vmTest.State)"
                }
                catch {

                }
                $ready = $vmTest.State -eq $VmState
                Start-Sleep -Seconds 5
            }
            catch {
                $ready = $false
            }
        } until ($ready -or ($stopWatch.Elapsed -ge $timeSpan))
        if (-not $ready -and ($vmState -eq "Off")) {
            stop-vm2 -name $VMName
        }
    }

    if ($OobeComplete.IsPresent) {
        $originalStatus = "Waiting for OOBE to complete for $vmName "
        Write-Log "$VmName`: $originalStatus"
        try {
            Write-ProgressElapsed -showTimeout -stopwatch $stopWatch -timespan $timespan -text $originalStatus
        }
        catch {}
        $readyOobe = $false
        $wwahostrunning = $false
        $readySmb = $false

        # Sysprep-settle tracking for the OOBE gate (see readiness check below).
        $lastOobeName = $null
        $oobeCompleteFirstSeen = $null
        [int]$oobeSettleCapSeconds = 180

        [int]$failures = 0
        [int]$maxFailures = 40  # ~10 min at ~15s per failure increment (power-cycle threshold, independent of total timeout)
        [int]$powerCycles = 0
        [int]$maxPowerCycles = 3
        # SuppressLog for all Invoke-VmCommand calls here since we're in a loop.
        do {
            # Check OOBE complete registry key
            $oobeStatusText = "Testing HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State\ImageState = IMAGE_STATE_COMPLETE"
            if ($powerCycles -gt 0) {
                $oobeStatusText += " (power-cycled $powerCycles/$maxPowerCycles)"
            }

            try {
                Write-ProgressElapsed -showTimeout -stopwatch $stopWatch -timespan $timespan -text $oobeStatusText
            }
            catch {}

            $stopwatch2 = [System.Diagnostics.Stopwatch]::new()
            $stopwatch2.Start()
            $out = Invoke-VmCommand -VmName $VmName -VmDomainName $VmDomainName -AsJob -SuppressLog -SkipDomainFallback -SessionMaxRetries 1 -ScriptBlock { Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty ImageState }
            $stopwatch2.Stop()
            Write-Log "$VmName`: $out" -Verbose
            if ($null -eq $out.ScriptBlockOutput -and -not $readyOobe) {
                try {
                    if ($failures -gt ([int]$TimeoutMinutes * 2)) {
                        Write-ProgressElapsed -showTimeout -stopwatch $stopWatch -timespan $timespan -text $originalStatus -failcount $failures -failcountMax $maxFailures
                    }
                    else {
                        Write-ProgressElapsed -showTimeout -stopwatch $stopWatch -timespan $timespan -text $originalStatus
                    }
                }
                catch {

                }
                Start-Sleep -Seconds 5
                if ($stopwatch2.elapsed.TotalSeconds -gt 15) {
                    [int]$failures = $failures + ([math]::Round($stopwatch2.elapsed.TotalSeconds / 15, 0))
                }
                else {
                    [int]$failures++
                }
                if ($failures -ge $maxFailures) {
                    # Before power-cycling, check if the VM is running but has no heartbeat.
                    # NoContact after 2+ min means no OS loaded (boot failure).
                    # OkApplicationsUnknown/OkApplicationsHealthy = OS is booting normally.
                    $vmCheck = Get-VM2 -Name $VmName -ErrorAction SilentlyContinue
                    if ($vmCheck -and $vmCheck.State -eq "Running" -and $vmCheck.Uptime.TotalMinutes -ge 2 -and $vmCheck.Heartbeat -eq "NoContact") {
                        Write-Log "$VmName`: VM is Running (uptime $([int]$vmCheck.Uptime.TotalMinutes)min) with heartbeat NoContact — possible boot failure. Check VM console: vmconnect localhost $VmName" -Warning
                    }
                    $powerCycles++
                    if ($powerCycles -gt $maxPowerCycles) {
                        Write-Log "$VmName`: OOBE not responding after $maxPowerCycles power-cycles ($([int]$stopWatch.Elapsed.TotalMinutes) min elapsed). Giving up." -Warning
                        break
                    }
                    Write-Log "$VmName`: OOBE not responding after $failures poll failures. Power-cycling VM (attempt $powerCycles/$maxPowerCycles)." -Warning
                    $vmState = if ($vmCheck) { $vmCheck.State } else { "Unknown" }
                    Write-Log "$VmName`: VM state before power-cycle: $vmState" -Warning
                    $stopOk = stop-vm2 -name $VmName -TurnOff -Passthru
                    start-sleep -seconds 8

                    # Stop-VM2 swallows a vmms fault and returns false. Under a loaded
                    # host it does throw ("statusDescription cannot be null or empty",
                    # "Object reference not set"), and without this check the VM was
                    # never cycled at all -- the wedged guest then sat until the next
                    # poll threshold, ~21min later, with nothing saying the recovery
                    # had been a no-op.
                    $postStop = Get-VM -Name $VmName -ErrorAction SilentlyContinue
                    if (-not $stopOk -or ($postStop -and $postStop.State -ne 'Off')) {
                        Write-Log "$VmName`: power-cycle FAILED to stop the VM (state=$(if ($postStop) { $postStop.State } else { 'unknown' })); retrying once." -Warning
                        $null = stop-vm2 -name $VmName -TurnOff -Passthru
                        start-sleep -seconds 8
                        $postStop = Get-VM -Name $VmName -ErrorAction SilentlyContinue
                        if ($postStop -and $postStop.State -ne 'Off') {
                            Write-Log "$VmName`: VM is still $($postStop.State) after two stop attempts -- Hyper-V is refusing to stop it, so this power-cycle recovered nothing." -Failure
                        }
                    }

                    # After the first power-cycle, if heartbeat was NoContact (OS never
                    # loaded into a usable state), attempt an offline registry fix for
                    # the "The computer restarted unexpectedly" Windows Setup error.
                    # This happens when the specialize pass reboots at the wrong moment
                    # (common under heavy disk I/O with many parallel VM creations).
                    # The fix sets setup.exe ChildCompletion from 1 (in-progress) to 3
                    # (success) so Setup skips the failed specialize step on next boot.
                    if ($powerCycles -ge 2 -and $vmCheck -and $vmCheck.Heartbeat -eq "NoContact") {
                        try {
                            $osDisk = (Get-VMHardDiskDrive -VMName $VmName -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "*_OS.vhdx" } | Select-Object -First 1).Path
                            if ($osDisk -and (Test-Path $osDisk)) {
                                Write-Log "$VmName`: Heartbeat NoContact after power-cycle — attempting offline registry repair for 'unexpected restart' Setup loop" -Warning
                                $mountResult = Mount-VHD -Path $osDisk -Passthru -ErrorAction Stop
                                $driveLetter = ($mountResult | Get-Disk | Get-Partition | Where-Object { $_.Type -eq 'Basic' -and $_.Size -gt 1GB } | Get-Volume | Sort-Object SizeRemaining -Descending | Select-Object -First 1).DriveLetter
                                if ($driveLetter) {
                                    # Capture Setup/Sysprep logs while the disk is mounted.
                                    # These are overwritten once OOBE succeeds, so this is
                                    # the only chance to see what went wrong.
                                    $pantherLogs = @(
                                        "${driveLetter}:\Windows\Panther\setuperr.log",
                                        "${driveLetter}:\Windows\Panther\UnattendGC\setuperr.log",
                                        "${driveLetter}:\Windows\System32\Sysprep\Panther\setuperr.log"
                                    )
                                    foreach ($pLog in $pantherLogs) {
                                        if (Test-Path $pLog) {
                                            $logLabel = $pLog.Replace("${driveLetter}:", '')
                                            $tail = Get-Content $pLog -Tail 15 -ErrorAction SilentlyContinue
                                            if ($tail) {
                                                Write-Log "$VmName`: $logLabel (last 15 lines):" -Warning
                                                foreach ($pLine in $tail) { Write-Log "  $pLine" -LogOnly }
                                            }
                                        }
                                    }
                                    # Also grab the last 5 lines of setupact.log for context
                                    $setupActPath = "${driveLetter}:\Windows\Panther\setupact.log"
                                    if (Test-Path $setupActPath) {
                                        $actTail = Get-Content $setupActPath -Tail 5 -ErrorAction SilentlyContinue
                                        if ($actTail) {
                                            Write-Log "$VmName`: \Windows\Panther\setupact.log (last 5 lines):" -LogOnly
                                            foreach ($aLine in $actTail) { Write-Log "  $aLine" -LogOnly }
                                        }
                                    }

                                    $hivePath = "${driveLetter}:\Windows\System32\config\SYSTEM"
                                    if (Test-Path $hivePath) {
                                        $regKey = "HKLM\VMBUILD_OFFLINE_SYSTEM"
                                        & reg load $regKey $hivePath 2>&1 | Out-Null
                                        try {
                                            $childCompPath = "$regKey\Setup\Status\ChildCompletion"
                                            $currentVal = & reg query $childCompPath /v "setup.exe" 2>&1
                                            Write-Log "$VmName`: ChildCompletion\setup.exe current value: $($currentVal -join ' ')" -LogOnly
                                            & reg add $childCompPath /v "setup.exe" /t REG_DWORD /d 3 /f 2>&1 | Out-Null
                                            Write-Log "$VmName`: Set ChildCompletion\setup.exe = 3 (specialize complete)" -Warning
                                        }
                                        finally {
                                            Start-Sleep -Milliseconds 500
                                            [gc]::Collect()
                                            & reg unload $regKey 2>&1 | Out-Null
                                        }
                                    }
                                    else {
                                        Write-Log "$VmName`: Could not find SYSTEM hive at $hivePath" -Warning
                                    }
                                }
                                else {
                                    Write-Log "$VmName`: Could not determine drive letter after mounting VHDX" -Warning
                                }
                                Dismount-VHD -Path $osDisk -ErrorAction SilentlyContinue
                                Start-Sleep -Seconds 2
                            }
                        }
                        catch {
                            Write-Log "$VmName`: Offline registry repair failed: $_" -Warning
                            try { Dismount-VHD -Path $osDisk -ErrorAction SilentlyContinue } catch {}
                        }
                    }

                    Start-vm2 -name $VmName
                    Start-Sleep -Seconds 8
                    [int]$failures = 0
                }
            }
            else {
                [int]$failures = 0
                $text = $($originalStatus + ": " + $out.ScriptBlockOutput)
                Write-ProgressElapsed -showTimeout -stopwatch $stopWatch -timespan $timespan -text $text
            }

            # Wait until OOBE is ready
            if ($null -ne $out.ScriptBlockOutput -and -not $readyOobe) {
                Write-Log "$VmName`: OOBE State is $($out.ScriptBlockOutput)"
                $status = $originalStatus
                $status += "Current State: $($out.ScriptBlockOutput)"
                if ("IMAGE_STATE_COMPLETE" -ne $out.ScriptBlockOutput) {
                    $readyOobe = $false
                }
                else {
                    # IMAGE_STATE_COMPLETE flips BEFORE Setup finalizes the specialize
                    # pass. Under heavy host disk I/O (many parallel VM creates) specialize
                    # can be interrupted and re-armed, re-randomizing the computer name on a
                    # later boot -- which then collides with DSC's rename/pagefile reboots and
                    # kicks off a rename loop (the FAB-W10CLIENT2 failure). Before declaring
                    # the VM ready, confirm sysprep has actually settled: SetupType=0 +
                    # OOBEInProgress=0, and the computer name hasn't changed since the prior
                    # COMPLETE read. This is bounded and best-effort by design so it can NEVER
                    # fail or meaningfully delay a healthy VM: a settled box passes immediately,
                    # a not-yet-settled box is accepted anyway after $oobeSettleCapSeconds, and
                    # if the probe can't run we fall back to trusting IMAGE_STATE_COMPLETE.
                    $settle = Invoke-VmCommand -VmName $VmName -VmDomainName $VmDomainName -AsJob -SuppressLog -SkipDomainFallback -SessionMaxRetries 1 -ScriptBlock {
                        $s = Get-ItemProperty "HKLM:\SYSTEM\Setup" -Name SetupType, OOBEInProgress -ErrorAction SilentlyContinue
                        [pscustomobject]@{ SetupType = [int]$s.SetupType; OOBE = [int]$s.OOBEInProgress; Name = $env:COMPUTERNAME }
                    }
                    if ($null -eq $oobeCompleteFirstSeen) { $oobeCompleteFirstSeen = [DateTime]::UtcNow }
                    if ($settle.ScriptBlockOutput -and $settle.ScriptBlockOutput.Name) {
                        $so = $settle.ScriptBlockOutput
                        if ($lastOobeName -and ($so.Name -ne $lastOobeName)) {
                            # Name changed since the last COMPLETE read -> specialize is
                            # re-running (re-randomizing). Restart the settle clock.
                            Write-Log "$VmName`: computer name changed ($lastOobeName -> $($so.Name)) after IMAGE_STATE_COMPLETE -- sysprep specialize is re-running; waiting for it to finalize before DSC." -Warning
                            $oobeCompleteFirstSeen = [DateTime]::UtcNow
                        }
                        $lastOobeName = $so.Name
                        $oobeSettled = ($so.SetupType -eq 0) -and ($so.OOBE -eq 0)
                        $waitedSettleSecs = ([DateTime]::UtcNow - $oobeCompleteFirstSeen).TotalSeconds
                        if ($oobeSettled) {
                            $readyOobe = $true
                        }
                        elseif ($waitedSettleSecs -ge $oobeSettleCapSeconds) {
                            Write-Log "$VmName`: ImageState COMPLETE but sysprep still not settled (SetupType=$($so.SetupType) OOBEInProgress=$($so.OOBE)) after $([int]$waitedSettleSecs)s -- accepting anyway." -Warning
                            $readyOobe = $true
                        }
                        else {
                            $readyOobe = $false
                            Write-Log "$VmName`: ImageState COMPLETE but sysprep not settled yet (SetupType=$($so.SetupType) OOBEInProgress=$($so.OOBE) Name=$($so.Name)); waiting for specialize to finalize before DSC."
                        }
                    }
                    else {
                        # Settle probe unavailable -> preserve prior behavior.
                        $readyOobe = $true
                    }
                }
                try {
                    Write-ProgressElapsed -showTimeout -stopwatch $stopWatch -timespan $timespan -text $status
                }
                catch {

                }
                Start-Sleep -Seconds 5
            }

            # Wait until \\localhost\c$ is accessible
            if (-not $readySmb -and $readyOobe) {

                Write-ProgressElapsed -showTimeout -stopwatch $stopWatch -timespan $timespan -text "OOBE complete. Checking SMB access"
                Start-Sleep -Seconds 3
                $out = Invoke-VmCommand -VmName $VmName -AsJob -VmDomainName $VmDomainName -SuppressLog -SkipDomainFallback -SessionMaxRetries 1 -ScriptBlock { Test-Path -Path "\\localhost\c$" -ErrorAction SilentlyContinue }
                if ($null -ne $out.ScriptBlockOutput -and -not $readySmb) { Write-Log "$VmName`: OOBE complete. \\localhost\c$ access result is $($out.ScriptBlockOutput)" }
                $readySmb = $true -eq $out.ScriptBlockOutput
                if ($readySmb) { Start-Sleep -Seconds 10 } # Extra wait to ensure wwahost has had a chance to start
            }

            # Wait until wwahost.exe is not found, or not longer running
            if ($readySmb) {
                $wwahost = Invoke-VmCommand -VmName $VmName -VmDomainName $VmDomainName -AsJob -SuppressLog -SkipDomainFallback -SessionMaxRetries 1 -ScriptBlock { Get-Process wwahost -ErrorAction SilentlyContinue }

                if ($wwahost.ScriptBlockOutput) {
                    $wwahostrunning = $true
                    Write-Log "$VmName`: OOBE complete. WWAHost (PID $($wwahost.ScriptBlockOutput.Id)) is running." -Verbose
                    Write-ProgressElapsed -showTimeout -stopwatch $stopWatch -timespan $timespan -text  "OOBE complete, and SMB available. Waiting for WWAHost (PID $($wwahost.ScriptBlockOutput.Id)) to stop before continuing"
                    Start-Sleep -Seconds 15
                }
                else {
                    Write-Log "$VmName`: OOBE complete. WWAHost not running."
                    $wwahostrunning = $false
                }
            }

            # OOBE and SMB ready, buffer wait to ensure we're at login screen. Bad things happen if you reboot the machine before it really finished OOBE.
            if (-not $wwahostrunning -and $readySmb) {
                Write-Log "$VmName`: VM is ready. Waiting $WaitSeconds seconds before continuing."
                Write-ProgressElapsed -showTimeout -stopwatch $stopWatch -timespan $timespan -text "VM is ready. Waiting $WaitSeconds seconds before continuing"
                Start-Sleep -Seconds $WaitSeconds
                $ready = $true
            }
        } until ($ready -or ($stopWatch.Elapsed -ge $timeSpan))

        if (-not $ready) {
            # Try the command one more time, to get real error in logs
            $lastAttempt = Invoke-VmCommand -VmName $VmName -VmDomainName $VmDomainName -AsJob -ScriptBlock { Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty ImageState } -ShowVMSessionError

            # Log a detailed failure summary so the root cause is visible without scrolling
            $elapsedMin = [int]$stopWatch.Elapsed.TotalMinutes
            $vmCheck = Get-VM2 -Name $VmName -ErrorAction SilentlyContinue
            $vmState = if ($vmCheck) { $vmCheck.State } else { "NotFound" }
            $vmHb = if ($vmCheck) { $vmCheck.Heartbeat } else { "N/A" }
            $vmUptime = if ($vmCheck -and $vmCheck.State -eq "Running") { "$([int]$vmCheck.Uptime.TotalMinutes)min" } else { "N/A" }
            $lastOobeState = if ($lastAttempt.ScriptBlockOutput) { $lastAttempt.ScriptBlockOutput } else { "PSDirect failed" }
            $lastError = if ($lastAttempt.ScriptBlockFailed -and $lastAttempt.ErrorDetails) { ($lastAttempt.ErrorDetails -join '; ') } else { $null }

            $reason = if (-not $readyOobe) {
                "OOBE never completed (ImageState='$lastOobeState')"
            } elseif (-not $readySmb) {
                "OOBE done but SMB (\\localhost\c$) never became accessible"
            } else {
                "OOBE+SMB done but WWAHost never stopped"
            }

            Write-Log "$VmName`: OOBE FAILURE SUMMARY: $reason | Elapsed=${elapsedMin}min | PowerCycles=$powerCycles/$maxPowerCycles | VM=$vmState | Heartbeat=$vmHb | Uptime=$vmUptime" -Warning
            if ($lastError) {
                Write-Log "$VmName`: Last PSDirect error: $lastError" -Warning
            }
        }
    }

    if ($OobeStarted.IsPresent) {
        $status = "Waiting for OOBE to start "
        Write-Log "$VmName`: $status"
        Write-ProgressElapsed -showTimeout -stopwatch $stopWatch -timespan $timespan -text $status

        [int]$powerCycles = 0
        [int]$maxPowerCycles = 1
        [bool]$powerCycleEligible = $false

        do {
            $wwahost = Invoke-VmCommand -VmName $VmName -VmDomainName $VmDomainName -AsJob -SuppressLog -SkipDomainFallback -SessionMaxRetries 1 -ScriptBlock { Get-Process wwahost, oobelauncher, UserOOBEBroker -ErrorAction SilentlyContinue }

            if ($wwahost.ScriptBlockOutput) {
                $ready = $true
                $oobeProcName = ($wwahost.ScriptBlockOutput | Select-Object -First 1).ProcessName
                Write-Log "$VmName`: OOBE Started. $oobeProcName (PID $($wwahost.ScriptBlockOutput[0].Id)) is running." -Verbose
                Write-ProgressElapsed -showTimeout -stopwatch $stopWatch -timespan $timespan -text "OOBE Started. $oobeProcName is running"
            }
            elseif ($wwahost.ScriptBlockFailed) {
                # PSDirect session failed — after sysprep /generalize, the local
                # admin account is wiped so PSDirect can't authenticate. If the VM
                # heartbeat is OK, this means OOBE is active (the only time the
                # VM is running but has no usable local accounts).
                $hbCheck = (Get-VM2 -Name $VmName -ErrorAction SilentlyContinue).Heartbeat
                if ($hbCheck -and $hbCheck -match 'Ok') {
                    $ready = $true
                    Write-Log "$VmName`: OOBE detected via auth failure (post-sysprep, heartbeat=$hbCheck). Local accounts wiped — VM is at OOBE." -Verbose
                    Write-ProgressElapsed -showTimeout -stopwatch $stopWatch -timespan $timespan -text "OOBE detected (auth failure + heartbeat OK)"
                }
                else {
                    Write-Log "$VmName`: OOBE hasn't started yet. Session failed, heartbeat=$hbCheck."
                    $ready = $false
                    Start-Sleep -Seconds $WaitSeconds
                }
            }
            else {
                Write-Log "$VmName`: OOBE hasn't started yet. No OOBE process running."
                $ready = $false
                Start-Sleep -Seconds $WaitSeconds

                # After half the timeout has elapsed with NoContact heartbeat,
                # try one power-cycle as a last resort.
                if (-not $powerCycleEligible -and $stopWatch.Elapsed.TotalMinutes -ge ($TimeoutMinutes / 2)) {
                    $vmCheck = Get-VM2 -Name $VmName -ErrorAction SilentlyContinue
                    if ($vmCheck -and $vmCheck.State -eq "Running" -and $vmCheck.Heartbeat -eq "NoContact") {
                        $powerCycleEligible = $true
                    }
                    elseif ($vmCheck -and $vmCheck.State -eq "Running") {
                        Write-Log "$VmName`: VM is Running (uptime $([int]$vmCheck.Uptime.TotalMinutes)min) with heartbeat $($vmCheck.Heartbeat) — OS is still booting, continuing to wait." -Warning
                    }
                }

                if ($powerCycleEligible -and $powerCycles -lt $maxPowerCycles) {
                    $powerCycles++
                    $powerCycleEligible = $false
                    $vmCheck = Get-VM2 -Name $VmName -ErrorAction SilentlyContinue
                    $vmState = if ($vmCheck) { $vmCheck.State } else { "Unknown" }
                    Write-Log "$VmName`: OOBE not starting after $([int]$stopWatch.Elapsed.TotalMinutes) min with heartbeat NoContact. Power-cycling VM (attempt $powerCycles/$maxPowerCycles). VM state: $vmState" -Warning
                    stop-vm2 -name $VmName -TurnOff | Out-Null
                    start-sleep -seconds 8
                    Start-vm2 -name $VmName | Out-Null
                    Start-Sleep -Seconds 30
                }
            }
        } until ($ready -or ($stopWatch.Elapsed -ge $timeSpan))

        if (-not $ready) {
            # Try the command one more time, to get real error in logs
            $lastAttempt = Invoke-VmCommand -VmName $VmName -VmDomainName $VmDomainName -AsJob -SuppressLog -ScriptBlock { Get-Process wwahost -ErrorAction SilentlyContinue } -ShowVMSessionError

            # Log a detailed failure summary
            $elapsedMin = [int]$stopWatch.Elapsed.TotalMinutes
            $vmCheck = Get-VM2 -Name $VmName -ErrorAction SilentlyContinue
            $vmState = if ($vmCheck) { $vmCheck.State } else { "NotFound" }
            $vmHb = if ($vmCheck) { $vmCheck.Heartbeat } else { "N/A" }
            $vmUptime = if ($vmCheck -and $vmCheck.State -eq "Running") { "$([int]$vmCheck.Uptime.TotalMinutes)min" } else { "N/A" }
            $lastError = if ($lastAttempt.ScriptBlockFailed -and $lastAttempt.ErrorDetails) { ($lastAttempt.ErrorDetails -join '; ') } else { $null }

            Write-Log "$VmName`: OOBE-START FAILURE SUMMARY: WWAHost never appeared | Elapsed=${elapsedMin}min | PowerCycles=$powerCycles/$maxPowerCycles | VM=$vmState | Heartbeat=$vmHb | Uptime=$vmUptime" -Warning
            if ($lastError) {
                Write-Log "$VmName`: Last PSDirect error: $lastError" -Warning
            }
        }
    }

    if ($PathToVerify) {

        if (-not $SkipDiskTest.IsPresent) {
            #If we already copied a DSC at least once, Disks are valid. Run if this is the first time.
            Write-Progress2 "Testing Disks" -Status "Testing Disks" -percentcomplete 0 -force
            if ((Get-VMHardDiskDrive -VMName $VmName).Count -eq 0) {
                Write-Log "[Phase $Phase]: $($currentItem.vmName): VM has no disks attached." -Failure
                return $false
            }
        }

        if ($PathToVerify -eq "C:\Users") {
            $msg = "Waiting for VM to respond"
        }
        else {
            $msg = "Waiting for $PathToVerify to exist"
        }

        $vmTest = Get-VM2 -Fallback -Name $VmName
        if ($vmTest.State -ne "Running") {
            start-vm2 -name $vmName
            start-sleep -seconds 15
        }
        if (-not $vmTest) {
            Write-Progress2 -Activity  "Could not find VM" -Status "Could not find VM" -PercentComplete 100 -Completed -force
            Write-Log -Failure "Could not find VM $VMName"
            return
        }
        if (-not $Quiet.IsPresent) { Write-Log "$VmName`: $msg..." }
        $count = 0
        [int]$restartCount = 0
        [int]$maxRestarts = 2
        [int]$channelBrokenCount = 0
        [bool]$psdirectRebootDone = $false
        do {
            $count++
            if ($count -gt 1) {
                Start-Sleep -Seconds 3
            }
            try {
                Write-ProgressElapsed -showTimeout -stopwatch $stopWatch -timespan $timespan -text $msg
            }
            catch {}
            # Only check VM state every 3rd iteration or on first attempt
            if ($count -eq 1 -or $count % 3 -eq 0) {
                $vmTest = Get-VM2 -Fallback -Name $VmName
                if ($vmTest.State -ne "Running") {
                    stop-vm2 -name $vmName -TurnOff | Out-Null
                    start-sleep -seconds 10
                    start-vm2 -name $vmName | Out-Null
                    Wait-ForHeartbeat -VmName $VmName -Stopwatch $stopWatch -Timespan $timeSpan | Out-Null
                }
            }

            # Single round-trip: probe the readiness marker AND C:\ (liveness)
            # together so the "channel alive but path not present yet" branch
            # below no longer needs a SECOND PSDirect call per poll -- this loop
            # runs on every VM boot wait, so halving the round-trips while the
            # path is still appearing adds up. SuppressLog since we're in a loop.
            # -SessionMaxRetries 1: the outer do/until loop already retries, and
            # 3 retries x 3 credentials x 30s timeout = 4.5 min per call freezes the
            # progress display and starves the timeout check.
            $out = Invoke-VmCommand -VmName $VmName -VmDomainName $VmDomainName -AsJob -SessionMaxRetries 1 -ScriptBlock {
                [PSCustomObject]@{ Path = (Test-Path $using:PathToVerify); Root = (Test-Path "C:\") }
            } -SuppressLog
            $ready = $true -eq $out.ScriptBlockOutput.Path
            if ($ready) {
                $channelBrokenCount = 0
                Write-ProgressElapsed -showTimeout -stopwatch $stopWatch -timespan $timespan -text "VM is responding"
            }
            elseif ($count -gt 1) {
                # C:\ liveness already came back in the same round-trip above.
                $readytest = $true -eq $out.ScriptBlockOutput.Root

                if ($readytest) {
                    $channelBrokenCount = 0
                    Write-ProgressElapsed -showTimeout -stopwatch $stopWatch -timespan $timespan -text "VM is responding. Waiting for $PathToVerify to exist."
                }
                else {
                    # VM is not responding to PSDirect at all.
                    # Check heartbeat to decide whether to hard-restart.
                    $vmCheck = Get-VM2 -Name $VmName -ErrorAction SilentlyContinue
                    $hb = if ($vmCheck) { $vmCheck.Heartbeat } else { "N/A" }

                    # Detect channel-broken from the actual session diagnostics.
                    # The call timing out or returning a VMBus error is evidence
                    # the PSDirect channel is hung — distinct from auth failures.
                    # (Single coalesced probe now, so one ChannelBroken flag.)
                    $channelBrokenNow = $out.ChannelBroken
                    $hbText = "heartbeat: $hb"
                    if ($channelBrokenNow) { $hbText += ", channel broken" }
                    Write-ProgressElapsed -showTimeout -stopwatch $stopWatch -timespan $timespan -text "VM is not responding ($hbText)"

                    # Everything above this point reports through Write-ProgressElapsed, which
                    # is console-only, and the probe runs -SuppressLog. So a VM that never
                    # answers leaves NO trace at all until the loop times out -- CS2-FS1 went
                    # 4m11s silent and then died mid-recovery, and the run log could not say
                    # what it had been failing on. One line a minute, capped by the modulus.
                    if ($count % 20 -eq 0) {
                        $probeErrText = ''
                        try { if ($out.ErrorDetails) { $probeErrText = (@($out.ErrorDetails) -join '; ') -replace '\s+', ' ' } } catch { }
                        if ($probeErrText.Length -gt 200) { $probeErrText = $probeErrText.Substring(0, 200) }
                        Write-Log "$VmName`: still not responding to PSDirect: poll=$count elapsed=$([int]$stopWatch.Elapsed.TotalSeconds)s heartbeat=$hb channelBroken=$channelBrokenNow timedOut=$($out.TimedOut) consecutiveBroken=$channelBrokenCount lastError='$probeErrText'" -LogOnly
                    }

                    # Only hard-reset when heartbeat is NoContact (IC not responding
                    # at all — VM is likely stuck at boot or crashed).
                    # OkApplicationsUnknown / OkApplicationsHealthy mean the OS is
                    # still booting normally; resetting would just delay things.
                    $heartbeatStuck = ($hb -eq "NoContact" -or $hb -eq "N/A")
                    if ($restartCount -lt $maxRestarts -and $heartbeatStuck -and ($count -ge 10 -or $stopWatch.Elapsed.TotalMinutes -ge 3)) {
                        $restartCount++
                        Write-Log "$VmName`: Not responding after $count polls (heartbeat: $hb). Hard-resetting VM (attempt $restartCount/$maxRestarts)." -Warning
                        Write-ProgressElapsed -showTimeout -stopwatch $stopWatch -timespan $timespan -text "Hard-resetting VM (attempt $restartCount/$maxRestarts)"
                        stop-vm2 -name $vmName -TurnOff | Out-Null
                        start-sleep -seconds 10
                        start-vm2 -name $vmName | Out-Null
                        Wait-ForHeartbeat -VmName $VmName -Stopwatch $stopWatch -Timespan $timeSpan | Out-Null
                        $count = 0
                        $channelBrokenCount = 0
                    }
                    elseif (-not $heartbeatStuck -and $channelBrokenNow -and -not $psdirectRebootDone) {
                        # Heartbeat is healthy but PSDirect channel is broken
                        # (sessions timed out or returned VMBus errors like
                        # "socket target process has ended").  This is distinct
                        # from auth failures where the channel works fine.
                        # Require 3 consecutive channel-broken results + 3 min
                        # elapsed to avoid false positives from transient timeouts.
                        $channelBrokenCount++
                        # The reboot decision below is taken on this counter, so record each
                        # step of it. Bounded: the branch stops firing once it reaches 3.
                        Write-Log "$VmName`: PSDirect channel-broken evidence $channelBrokenCount/3 (poll=$count elapsed=$([int]$stopWatch.Elapsed.TotalSeconds)s heartbeat=$hb timedOut=$($out.TimedOut) parkedRunspaces=$(@($global:ps_orphanRunspaces).Count))" -LogOnly
                        if ($channelBrokenCount -ge 3 -and $stopWatch.Elapsed.TotalMinutes -ge 3) {
                            $psdirectRebootDone = $true
                            Write-Log "$VmName`: PSDirect channel broken after $channelBrokenCount consecutive failures despite healthy heartbeat ($hb). Rebooting VM to recover VMBus." -Warning
                            Write-ProgressElapsed -showTimeout -stopwatch $stopWatch -timespan $timespan -text "Rebooting VM — PSDirect channel broken with healthy heartbeat"
                            stop-vm2 -name $vmName -TurnOff | Out-Null
                            start-sleep -seconds 10
                            start-vm2 -name $vmName | Out-Null
                            Wait-ForHeartbeat -VmName $VmName -Stopwatch $stopWatch -Timespan $timeSpan | Out-Null
                            $count = 0
                        }
                    }
                    elseif (-not $heartbeatStuck -and -not $channelBrokenNow) {
                        # Session failed with a normal error (auth, etc.) — not a
                        # channel problem.  Reset the channel-broken counter.
                        $channelBrokenCount = 0
                    }
                }
            }


        } until ($ready -or ($stopWatch.Elapsed -ge $timeSpan))

        if (-not $ready) {
            # Try the command one more time, to get real error in logs
            $lastAttempt = Invoke-VmCommand -VmName $VmName -VmDomainName $VmDomainName -AsJob -ScriptBlock { Test-Path $using:PathToVerify } -ShowVMSessionError

            # Log a detailed failure summary
            $elapsedMin = [int]$stopWatch.Elapsed.TotalMinutes
            $vmCheck = Get-VM2 -Name $VmName -ErrorAction SilentlyContinue
            $vmState = if ($vmCheck) { $vmCheck.State } else { "NotFound" }
            $vmHb = if ($vmCheck) { $vmCheck.Heartbeat } else { "N/A" }
            $vmUptime = if ($vmCheck -and $vmCheck.State -eq "Running") { "$([int]$vmCheck.Uptime.TotalMinutes)min" } else { "N/A" }
            $lastError = if ($lastAttempt.ScriptBlockFailed -and $lastAttempt.ErrorDetails) { ($lastAttempt.ErrorDetails -join '; ') } else { $null }

            $reason = if ($lastAttempt.ScriptBlockOutput -eq $false) {
                "PSDirect works but '$PathToVerify' does not exist"
            } elseif ($lastAttempt.ScriptBlockFailed) {
                "PSDirect connection failed"
            } else {
                "Unknown (last output: $($lastAttempt.ScriptBlockOutput))"
            }

            Write-Log "$VmName`: WAIT FAILURE SUMMARY: $reason | Elapsed=${elapsedMin}min | Restarts=$restartCount/$maxRestarts | VM=$vmState | Heartbeat=$vmHb | Uptime=$vmUptime" -Warning
            if ($lastError) {
                Write-Log "$VmName`: Last PSDirect error: $lastError" -Warning
            }
        }
    }



    if ($ready) {
        Write-Progress2 -Activity "Waiting for virtual machine" -Status "Wait complete." -Completed -force
        if (-not $Quiet.IsPresent) { Write-Log "$VmName`: VM is now available." -Success }
    }
    else {
        Write-Progress2 -Activity "Waiting for virtual machine" -Status "Timer expired while waiting for VM" -Completed -force
        Write-Log "$VmName`: Timer expired while waiting for VM" -Warning
    }

    return $ready
}

function Get-VmHostSideDiag {
    # Best-effort host-side (Hyper-V) snapshot of a VM, used to annotate PSDirect
    # readiness/channel failures ("An error occurred while creating the pipeline",
    # broken transport, etc.) in the build log. All fields come straight from the
    # hypervisor -- no PSDirect round-trip -- so they're available even when the
    # guest's session can't be created. Reviewing these alongside the failure tells
    # us whether the failure correlates with a freshly-(re)started/booting guest
    # (low Uptime / non-Ok Heartbeat) and therefore whether the readiness gate
    # thresholds (e.g. the 60s pending-reboot skip) need tuning. Never throws.
    param([string]$VmName)
    try {
        $vm = Get-VM2 -Name $VmName
        if (-not $vm) { return "[host-diag: VM '$VmName' not found in Hyper-V]" }
        $up = if ($vm.Uptime) { "$([int]$vm.Uptime.TotalSeconds)s" } else { "n/a" }
        $hb = if ($vm.Heartbeat) { "$($vm.Heartbeat)" } else { "n/a" }
        return "[host-diag: State=$($vm.State) Uptime=$up Heartbeat=$hb Status='$($vm.Status)']"
    }
    catch {
        return "[host-diag: unavailable ($($_.Exception.Message))]"
    }
}

function Invoke-VmCommand {
    param (
        [Parameter(Mandatory = $true, HelpMessage = "VM Name")]
        [string]$VmName,
        [Parameter(Mandatory = $true, HelpMessage = "Script Block to execute")]
        [ScriptBlock]$ScriptBlock,
        [Parameter(Mandatory = $true, HelpMessage = "Domain Name to use for creating domain creds")]
        [string]$VmDomainName, # = "WORKGROUP",
        [Parameter(Mandatory = $false, HelpMessage = "Domain Account to use for creating domain creds")]
        [string]$VmDomainAccount,
        [Parameter(Mandatory = $false, HelpMessage = "Argument List to supply to ScriptBlock")]
        [object[]]$ArgumentList,
        [Parameter(Mandatory = $false, HelpMessage = "Display Name of the script for log/console")]
        [string]$DisplayName,
        [Parameter(Mandatory = $false, HelpMessage = "Suppress log entries. Useful when waiting for VM to be ready to run commands.")]
        [switch]$SuppressLog,
        [Parameter(Mandatory = $false, HelpMessage = "Check return value = true to indicate success")]
        [switch]$CommandReturnsBool,
        [Parameter(Mandatory = $false, HelpMessage = "Show VM Session errors, very noisy")]
        [switch]$ShowVMSessionError,
        [Parameter(Mandatory = $false, HelpMessage = "Run command as a job")]
        [switch]$AsJob,
        [Parameter(Mandatory = $false, HelpMessage = "When running as a job.. Timeout length. With -PollProgress this is a STALL timeout (max time with no progress heartbeat from the guest), not an absolute deadline.")]
        [int]$TimeoutSeconds = 180,
        [Parameter(Mandatory = $false, HelpMessage = "When running as a job, poll the inner job's Progress stream and re-emit the latest record so long-running remote scriptblocks surface live status (instead of appearing frozen). The remote scriptblock must call Write-Progress for there to be anything to forward. Also switches -TimeoutSeconds to heartbeat/stall semantics: each new progress record resets the timer (bounded by an absolute ceiling).")]
        [switch]$PollProgress,
        [Parameter(Mandatory = $false, HelpMessage = "Skip domain credential fallback via VMNote. Use during OOBE polling when VM is not yet domain-joined.")]
        [switch]$SkipDomainFallback,
        [Parameter(Mandatory = $false, HelpMessage = "Max retries for Get-VmSession (default 3). Reduce for tight polling loops.")]
        [int]$SessionMaxRetries = 3,
        [Parameter(Mandatory = $false, HelpMessage = 'With -AsJob, treat non-terminating errors the remote scriptblock wrote (Write-Error) as a failure. The synchronous path gets this free via -ErrorVariable, but under -AsJob those errors land on the CHILD job and $Err2 stays empty, so a scriptblock that reports failure with Write-Error + return completes as "Succeeded". Set this when converting a sync caller to -AsJob for a timeout, so its existing failure/retry handling keeps working.')]
        [switch]$FailOnRemoteError,
        [Parameter(Mandatory = $false, HelpMessage = "On an -AsJob timeout, after evicting the wedged session run a 30s liveness probe (hostname); if the guest still does not answer, reboot the VM to recover. Default OFF -- only set where the VM is expected to be responsive (e.g. post-build Phase 11 checks), NEVER in readiness/OOBE polling loops where a timeout is normal and the VM may be intentionally mid-reboot.")]
        [switch]$RebootIfUnresponsive,
        [Parameter(Mandatory = $false, HelpMessage = "What If")]
        [switch]$WhatIf
    )
    try {
        # Set display name for logging
        if (-not $DisplayName) {
            $DisplayName = ($ScriptBlock.ToString() -replace '\s+', ' ').Trim()
            if ($DisplayName.Length -gt 80) { $DisplayName = $DisplayName.Substring(0, 77) + '...' }
        }

        # WhatIf
        if ($WhatIf.IsPresent) {
            Write-Log "WhatIf: Will run '$DisplayName' inside '$VmName'"
            return $true
        }

        # Fatal failure
        if ($null -eq $Common.LocalAdmin) {
            Write-Log "$VmName`: Skip running '$DisplayName' since Local Admin creds not available" -Failure
            return $false
        }

        # Log entry
        if (-not $SuppressLog) {
            Write-Log "$VmName`: Running '$DisplayName'" -Verbose
        }

        # Create return object
        $return = [PSCustomObject]@{
            CommandResult     = $false
            ScriptBlockFailed = $false
            ScriptBlockOutput	= $null
            ErrorDetails      = $null
            ChannelBroken     = $false
            TimedOut          = $false
            Rebooted          = $false
        }

        # Prepare args
        $HashArguments = @{
            ScriptBlock = $ScriptBlock
        }

        if ($ArgumentList) {
            $HashArguments.Add("ArgumentList", $ArgumentList)
        }

        # Get VM Session
        $ps = $null
        $sessionDiag = @{ ChannelBroken = $false }
        $localOnlySession = $SkipDomainFallback.IsPresent
        # When -SuppressLog is set the caller is polling for VM readiness (OOBE /
        # SMB / path checks in tight do/until loops), so a session that can't be
        # created yet is expected, not a failure. Route Get-VmSession's per-attempt
        # warning and final-failure message to -LogOnly -Verbose (recorded for
        # diagnostics, never on screen) instead of letting it emit type=3 errors
        # that make the phase look broken. -ShowVMSessionError still overrides this.
        $quietSession = $SuppressLog.IsPresent -and -not $ShowVMSessionError.IsPresent
        if ($VmDomainAccount) {
            $ps = Get-VmSession -VmName $VmName -VmDomainName $VmDomainName -VmDomainAccount $VmDomainAccount -ShowVMSessionError:$ShowVMSessionError -MaxRetries $SessionMaxRetries -LocalOnly:$localOnlySession -Diagnostics $sessionDiag -Quiet:$quietSession
        }

        if (-not $ps) {
            $ps = Get-VmSession -VmName $VmName -VmDomainName $VmDomainName -ShowVMSessionError:$ShowVMSessionError -MaxRetries $SessionMaxRetries -LocalOnly:$localOnlySession -Diagnostics $sessionDiag -Quiet:$quietSession
        }

        if (-not $ps -and $VmDomainName -eq "WORKGROUP" -and -not $SkipDomainFallback) {
            $note = Get-VMNote -VMName $VmName
            $domain2 = $note.domain
            $adminName = $note.adminName
            if (-not $adminName) {
                $adminName = "admin"
            }
            $ps = Get-VmSession -VmName $VmName -VmDomainName $domain2 -VmDomainAccount $adminName -ShowVMSessionError:$ShowVMSessionError -MaxRetries $SessionMaxRetries -Diagnostics $sessionDiag -Quiet:$quietSession
        }

        $failed = ($null -eq $ps)
        if ($failed) {
            $return.ChannelBroken = [bool]$sessionDiag.ChannelBroken
        }

        # Run script block inside VM
        $inflightToken = $null
        $jobFailureReason = $null
        if (-not $failed) {
            # Mark this scriptblock as in-flight on $ps so a concurrent pipeline on
            # the SAME cached session (the suspected cause of "An error occurred while
            # creating the pipeline") is visible to the failure-site diagnostic below.
            $inflightToken = Enter-VmSessionInflight -Session $ps -DisplayName $DisplayName
            try {
                if ($AsJob) {
                    $job = Invoke-Command -Session $ps @HashArguments -ErrorVariable Err2 -ErrorAction SilentlyContinue -AsJob
                    # Without this the ledger only ever holds terminal ops, so an empty
                    # census cannot distinguish "created no jobs" from "created many and
                    # released none through the ledger" -- which is exactly what the
                    # CS2-FS1 census could not say. No Get-PSCallStack on this op.
                    Write-VmJobLedger -Op 'created' -Job $job -VmName $VmName -DisplayName $DisplayName
                    if ($PollProgress) {
                        # Poll the inner job's Progress stream while it runs and re-emit the
                        # latest record. Under -AsJob the remote scriptblock's Write-Progress
                        # records are confined to the nested job (they don't propagate to this
                        # caller the way a synchronous Invoke-Command -Session would), so a
                        # long remote operation looks frozen. Forwarding the latest record via
                        # Write-Progress2 -force surfaces live status in the caller's progress
                        # stream (e.g. the Phase 11 job's display via Wait-Phase/Write-JobProgress).
                        #
                        # HEARTBEAT (STALL) TIMEOUT: with -PollProgress, $TimeoutSeconds is the
                        # max time we'll wait WITHOUT a new progress record from the guest -- it
                        # is NOT an absolute deadline. Every Write-Progress the remote scriptblock
                        # emits is a heartbeat that resets the timer, so a validation that
                        # legitimately spends several minutes across many short steps (e.g. the
                        # DomainMember CCM-client / ccmsetup wait loops, which heartbeat every
                        # ~10s) never gets reaped as a false "timed out" failure. Only a genuinely
                        # hung scriptblock -- no progress at all for $TimeoutSeconds -- is killed.
                        # An absolute ceiling bounds a scriptblock that heartbeats forever.
                        $stallSeconds = $TimeoutSeconds
                        $absoluteCeiling = (Get-Date).AddSeconds([Math]::Max($TimeoutSeconds * 6, 1800))
                        $stallDeadline = (Get-Date).AddSeconds($stallSeconds)
                        $lastForwarded = $null
                        $lastProgressCount = 0
                        while ($job.State -eq "Running" -and (Get-Date) -lt $stallDeadline -and (Get-Date) -lt $absoluteCeiling) {
                            Start-Sleep -Milliseconds 750
                            try {
                                # PSRemotingJob exposes per-session streams on its child job.
                                $progressSource = if ($job.ChildJobs -and $job.ChildJobs.Count -gt 0) { $job.ChildJobs[0] } else { $job }
                                if ($progressSource -and $progressSource.Progress -and $progressSource.Progress.Count -gt 0) {
                                    # Any growth in the progress stream is a heartbeat -> reset the
                                    # stall timer. The guest emits a distinct status (with an
                                    # elapsed-seconds counter) on each loop iteration so the record
                                    # count always advances even when the activity is unchanged.
                                    if ($progressSource.Progress.Count -ne $lastProgressCount) {
                                        $lastProgressCount = $progressSource.Progress.Count
                                        $stallDeadline = (Get-Date).AddSeconds($stallSeconds)
                                    }
                                    $lastRec = $progressSource.Progress[$progressSource.Progress.Count - 1]
                                    if ($lastRec -and -not [string]::IsNullOrWhiteSpace($lastRec.Activity) -and -not [string]::IsNullOrWhiteSpace($lastRec.StatusDescription)) {
                                        $line = "$($lastRec.Activity)|$($lastRec.StatusDescription)"
                                        if ($line -ne $lastForwarded) {
                                            $lastForwarded = $line
                                            Write-Progress2 -Activity $lastRec.Activity -Status $lastRec.StatusDescription -PercentComplete 0 -force
                                        }
                                    }
                                }
                            }
                            catch { }
                        }
                        if ($job.State -eq "Running") {
                            if ((Get-Date) -ge $absoluteCeiling) {
                                Write-Log "$VmName`: Job '$DisplayName' hit absolute ceiling ($([int]([Math]::Max($TimeoutSeconds * 6, 1800)))s); stopping." -LogOnly
                            }
                            else {
                                Write-Log "$VmName`: Job '$DisplayName' stalled (no progress heartbeat for ${stallSeconds}s); stopping." -LogOnly
                            }
                        }
                    }
                    else {
                        $job | Wait-Job -Timeout $TimeoutSeconds
                    }
                    if ($job.State -eq "Completed") {
                        # Read the child's error stream BEFORE Receive-Job drains it.
                        $remoteErrors = @()
                        if ($FailOnRemoteError) {
                            try {
                                foreach ($cj in @($job.ChildJobs)) {
                                    if ($cj.Error -and $cj.Error.Count -gt 0) {
                                        $remoteErrors += @($cj.Error | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
                                    }
                                }
                            }
                            catch { }
                        }
                        $return.ScriptBlockOutput = (Receive-Job $job)
                        if ($remoteErrors.Count -gt 0) {
                            $failed = $true
                            $return.ScriptBlockFailed = $true
                            $return.ErrorDetails = $remoteErrors
                            if (-not $SuppressLog) {
                                Write-Log "$VmName`: Job '$DisplayName' completed but the guest reported an error: $($remoteErrors -join '; ')" -Failure
                            }
                        }
                        else {
                            if (-not $SuppressLog) {
                                Write-Log "$VmName`: Job '$DisplayName' Succeeded" -LogOnly
                            }
                            $failed = $false
                        }
                        # Dispose here. Parking these instead (so a later transport break would
                        # find a live object) was measured and is worse: one Phase 4 worker
                        # reached parkedJobs=538 / live jobs=539 on a single VM, and the
                        # scavenger's "safe" rule -- runspace no longer Opened -- fires exactly
                        # WHILE the transport is breaking across all of them, which is the
                        # window it was meant to avoid. The ledger also shows disposal was never
                        # the trigger: the crash census recorded parked=672 reaped=134 and ZERO
                        # disposed/abandoned, with the last ledger op 24 minutes earlier.
                        Write-VmJobLedger -Op 'disposed' -Job $job -VmName $VmName -DisplayName $DisplayName -Detail 'reason=completed-drained'
                        Remove-Job $job -Force -ErrorAction SilentlyContinue

                        # The PSRemotingJob above ran ON the cached session's runspace
                        # (Invoke-Command -Session $ps -AsJob). Wait-Job + Remove-Job return as
                        # soon as the job object is reaped, but the SERVER-SIDE (in-guest)
                        # PSDirect/VMBus pipeline from that job keeps tearing down for a brief
                        # window AFTER local Remove-Job. If the very next caller issues a
                        # SYNCHRONOUS Invoke-Command on this same cached session during that window
                        # (e.g. Stop-DSC -AsJob immediately followed by the synchronous "Check
                        # pending reboot" probe in Common.ScriptBlocks.ps1), the new pipeline-create
                        # races that server-side teardown and surfaces the non-terminating engine
                        # error "An error occurred while creating the pipeline."
                        #
                        # PROVEN (CSTest full pass 2026-06-29/30, 884baf8f diag, 841/841 samples):
                        # at the failure site runspaceAvail=Available, concurrentOnSameSession=<none>.
                        # So the LOCAL RunspaceAvailability flag is a FALSE-READY signal -- it flips
                        # to Available the instant the job is reaped, well before the transport's
                        # server-side pipeline is actually gone. Gating on RunspaceAvailability
                        # (the prior fix) is therefore inert: it returns immediately and provides no
                        # protection, which is exactly why the flood persisted (838 errors, 0
                        # "did not return to Available" give-ups).
                        #
                        # Real fix: probe ACTUAL pipeline-creatability. Issue a trivial round-trip
                        # on the same cached session; if it throws the pipeline/transport-teardown
                        # error, the server side isn't ready yet -- back off and retry. Once a
                        # round-trip succeeds, the transport is clear and the next synchronous reuse
                        # is safe. Bounded (~5s) so a genuinely wedged session can't hang the caller.
                        #
                        # The probe must be judged on its RESULT, not on whether it threw.
                        # "An error occurred while creating the pipeline" is a non-terminating
                        # engine error written straight to the error stream by the remoting
                        # layer -- -ErrorAction Stop does NOT convert it (that is precisely why
                        # the real synchronous call below catches it via -ErrorVariable and not
                        # via catch{}). The first version of this probe used -ErrorAction Stop
                        # inside try/catch, so it never threw, set ready on the first attempt
                        # and was completely inert: 0 give-up lines logged while the pending-
                        # reboot check that immediately follows failed on every VM. Check the
                        # error stream and the round-trip value instead.
                        try {
                            if ($ps -and $ps.Runspace) {
                                $teardownSig = 'creating the pipeline|pipeline is not|session is in|availability is Busy|not available to run commands|has been closed|No valid sessions|transport|broken'
                                $probeSw = [System.Diagnostics.Stopwatch]::StartNew()
                                $probeDeadline = (Get-Date).AddSeconds(5)
                                $probeReady = $false
                                $probeAttempts = 0
                                while (-not $probeReady -and (Get-Date) -lt $probeDeadline) {
                                    $probeAttempts++
                                    $probeErr = $null
                                    $probeOut = $null
                                    try {
                                        $probeOut = Invoke-Command -Session $ps -ScriptBlock { 1 } -ErrorVariable probeErr -ErrorAction SilentlyContinue
                                    }
                                    catch {
                                        $probeErr = @($_)
                                    }
                                    $probeBlob = ""
                                    if ($probeErr -and $probeErr.Count -gt 0) { $probeBlob = ($probeErr | ForEach-Object { "$_" }) -join ' ' }
                                    if ($probeOut -eq 1 -and -not $probeBlob) {
                                        $probeReady = $true
                                    }
                                    elseif ($probeBlob -and $probeBlob -notmatch $teardownSig) {
                                        # Unexpected error (not the teardown race): stop probing
                                        # and let the real call surface/handle it.
                                        break
                                    }
                                    else {
                                        # Still tearing down (error matched, or the round-trip
                                        # silently produced nothing) -- back off.
                                        Start-Sleep -Milliseconds 100
                                    }
                                }
                                $probeSw.Stop()
                                if ($probeReady) {
                                    if ($probeAttempts -gt 1 -and -not $SuppressLog) {
                                        Write-Log "$VmName`: Session transport became pipeline-ready after $probeAttempts attempts ($([math]::Round($probeSw.Elapsed.TotalSeconds,1))s) following job '$DisplayName'." -LogOnly
                                    }
                                }
                                else {
                                    if (-not $SuppressLog) {
                                        Write-Log "$VmName`: Session transport did not become pipeline-ready within $([math]::Round($probeSw.Elapsed.TotalSeconds,1))s ($probeAttempts attempts) after job '$DisplayName'; evicting the cached session so the next call rebuilds it." -LogOnly
                                    }
                                    # Leak rather than dispose: the server-side pipeline from the
                                    # job is demonstrably still alive, and disposing a session
                                    # whose transport is mid-teardown is the disposed-object
                                    # callback crash documented above.
                                    Remove-VmSessionFromCache -VmName $VmName -LeakSession
                                }
                                # Stamp the timeline AFTER the probe so the next failure autopsy
                                # reports the gap from "we declared this session usable" to the
                                # failing pipeline-create, not from Remove-Job.
                                Set-VmSessionPipelineEvent -Session $ps -Kind "asjob-probed(ready=$probeReady,attempts=$probeAttempts)" -Op $DisplayName
                            }
                        }
                        catch { }
                    }
                    else {
                        Write-Log "$VmName`: Job '$DisplayName' Failed State: $($job.State)" -LogOnly
                        $failed = $true
                        $return.ScriptBlockFailed = $true
                        # -ErrorVariable on Invoke-Command -AsJob only captures errors raised
                        # while STARTING the job; anything the remote pipeline throws lands on
                        # the child job, so $Err2 is empty for every real job failure and the
                        # message degenerated to "Unknown Error". Harvest the child job's
                        # failure reason / error stream so the log names the actual fault.
                        $jobFailureReason = $null
                        try {
                            $reasonParts = @()
                            foreach ($cj in @($job.ChildJobs)) {
                                if ($cj.JobStateInfo -and $cj.JobStateInfo.Reason) { $reasonParts += "$($cj.JobStateInfo.Reason)".Trim() }
                                if ($cj.Error -and $cj.Error.Count -gt 0) { $reasonParts += @($cj.Error | ForEach-Object { "$_".Trim() }) }
                            }
                            if ($job.JobStateInfo -and $job.JobStateInfo.Reason) { $reasonParts += "$($job.JobStateInfo.Reason)".Trim() }
                            $reasonParts = @($reasonParts | Where-Object { $_ } | Select-Object -Unique)
                            if ($reasonParts.Count -gt 0) { $jobFailureReason = $reasonParts -join '; ' }
                        }
                        catch {}
                        if ($Err2.Count -ne 0) {
                            $OutErr = "$($Err2[0].ToString().Trim())"
                        }
                        elseif ($jobFailureReason) {
                            $OutErr = $jobFailureReason
                        }
                        else {
                            $OutErr = "Unknown Error"
                        }
                        if (-not $SuppressLog) {
                            Write-Log "$VmName`: Failed to run '$DisplayName'. Job State: $($job.State) Error: $OutErr." -Failure
                        }
                        # "Unknown Error" means the child job's Reason AND Error stream were
                        # both empty -- 626 of these in 72h (561 on one VM) with nothing to act
                        # on. Dump what the job object still knows while it is alive; Remove-Job
                        # below disposes it. Deliberately a SEPARATE line, not appended to
                        # $OutErr: the channel-broken classifier below regex-matches $OutErr for
                        # words like 'transport'/'channel'/'broken' that appear in this text.
                        if ($OutErr -eq 'Unknown Error') {
                            try {
                                $f = @("job=[state=$($job.State) status='$($job.StatusMessage)' loc='$($job.Location)' hasData=$($job.HasMoreData)")
                                try { if ($job.PSBeginTime -and $job.PSEndTime) { $f += "ran=$([math]::Round((($job.PSEndTime) - ($job.PSBeginTime)).TotalSeconds,1))s" } elseif ($job.PSBeginTime) { $f += "began=$($job.PSBeginTime.ToString('HH:mm:ss.fff')) neverEnded" } else { $f += 'neverBegan' } } catch { }
                                $f += ']'
                                $ci = 0
                                foreach ($cj in @($job.ChildJobs)) {
                                    $ci++
                                    $rt = '<none>'
                                    try { if ($cj.JobStateInfo.Reason) { $rt = $cj.JobStateInfo.Reason.GetType().FullName } } catch { }
                                    $counts = @()
                                    foreach ($s in @('Error', 'Warning', 'Verbose', 'Information', 'Output', 'Progress')) {
                                        try { $counts += "$s=$(@($cj.$s).Count)" } catch { $counts += "$s=?" }
                                    }
                                    $f += "child${ci}=[state=$($cj.State) reasonType=$rt $($counts -join ' ') hasData=$($cj.HasMoreData)]"
                                }
                                # Session state at the moment of failure is the key correlate:
                                # a Broken/Closed transport explains an empty error stream.
                                try { $f += "session=[state=$($ps.State) avail=$($ps.Availability) rs=$($ps.Runspace.RunspaceStateInfo.State)/$($ps.Runspace.RunspaceAvailability)]" } catch { $f += 'session=[unreadable]' }
                                Write-Log "$VmName`: 'Unknown Error' autopsy for '$DisplayName': $($f -join ' ')" -Warning -LogOnly
                            }
                            catch { }
                        }
                        $jobTimedOut = ($job.State -eq "Running")
                        # Was this terminal failure caused by a broken PSDirect/VMBus channel
                        # (vs an ordinary scriptblock error)? Inspect the job's failure reason
                        # + error streams NOW, while the job is still alive (Remove-Job below
                        # would dispose it). Used to decide whether the job must be abandoned
                        # rather than disposed -- see the terminal-state branch below.
                        $jobChannelBroken = $false
                        if (-not $jobTimedOut) {
                            $jobErrBlob = "$OutErr"
                            try {
                                foreach ($cj in @($job.ChildJobs)) {
                                    if ($cj.JobStateInfo -and $cj.JobStateInfo.Reason) { $jobErrBlob += " " + $cj.JobStateInfo.Reason.ToString() }
                                    if ($cj.Error -and $cj.Error.Count -gt 0) { $jobErrBlob += " " + (@($cj.Error | ForEach-Object { $_.ToString() }) -join ' ') }
                                }
                                if ($job.JobStateInfo -and $job.JobStateInfo.Reason) { $jobErrBlob += " " + $job.JobStateInfo.Reason.ToString() }
                            }
                            catch {}
                            $jobChannelBroken = $jobErrBlob -match 'creating the pipeline|pipeline is not|transport|channel|broken|Cannot connect|not connected|session is in|availability is Busy|No valid sessions|has been closed|socket target process|VMBus|target process has ended'
                            # The regex above matches the error TEXT, but a PSDirect/VMBus
                            # transport break does not always carry one of those tokens --
                            # e.g. "Processing data from remote server <vm> failed ... The I/O
                            # operation has been aborted because of either a thread exit or an
                            # application request", or the bare "The background process reported
                            # an error" (ErrorCode 2100). Those regex MISSES are exactly the
                            # dangerous disposals: the pipeline was severed by a dying channel,
                            # so the Stop-Job/Remove-Job branch below DISPOSES the job, and the
                            # reboot the caller is about to perform (DSC-monitor Restart-VM2Smart,
                            # Wait-ForVm channel-broken recovery, or the guest's own CM-install
                            # reboot) then fires a StateChanged callback on the already-disposed
                            # job on a threadpool thread -> unhandled PSObjectDisposedException
                            # ('object "PSJob" has already been disposed') that kills the phase
                            # child process (proven on cstest6 CS6-PS1SITE/-P Phase 8, both
                            # children crashed ~70s apart right after a heartbeat-recovery
                            # restart). The AUTHORITATIVE signal is the SESSION's own runspace
                            # state, not the error text: if the transport is no longer Opened,
                            # the failure is a channel break regardless of how it was worded, so
                            # abandon (don't dispose) + leak the session.
                            if (-not $jobChannelBroken) {
                                try {
                                    $rsState = $null
                                    $rsAvail = $null
                                    if ($ps -and $ps.Runspace) {
                                        $rsState = "$($ps.Runspace.RunspaceStateInfo.State)"
                                        $rsAvail = "$($ps.Runspace.RunspaceAvailability)"
                                    }
                                    if ($rsState -and $rsState -ne 'Opened') { $jobChannelBroken = $true }
                                    elseif ($rsAvail -eq 'None') { $jobChannelBroken = $true }
                                    if (-not $jobChannelBroken) {
                                        # Belt-and-braces: a child job's own runspace may report
                                        # broken even when the parent session momentarily still
                                        # reads Opened. Guarded -- the Runspace member is not on
                                        # every job type.
                                        foreach ($cj in @($job.ChildJobs)) {
                                            $cjRs = $null
                                            try { $cjRs = $cj.Runspace } catch {}
                                            if ($cjRs -and "$($cjRs.RunspaceStateInfo.State)" -in @('Broken', 'Closed', 'Disconnected', 'Closing')) { $jobChannelBroken = $true; break }
                                        }
                                    }
                                    if ($jobChannelBroken -and -not $SuppressLog) {
                                        Write-Log "$VmName`: Job '$DisplayName' terminal failure reclassified as channel-broken via runspace state (state=$rsState avail=$rsAvail); abandoning the job instead of disposing it to avoid a late disposed-job callback crash." -LogOnly
                                    }
                                }
                                catch {}
                            }
                        }
                        if ($jobTimedOut) {
                            # -SuppressLog callers (e.g. best-effort telemetry like
                            # Get-GuestTimingStats polling ScriptWorkflow.json) explicitly asked
                            # not to spam the console/log with expected, non-fatal timeouts --
                            # honor that here too instead of always emitting an -Failure (ERROR)
                            # line. Still recorded to the log file for diagnostics.
                            if ($SuppressLog) {
                                Write-Log "$VmName`: Job '$DisplayName' timed out. Job State: $($job.State) Error: $OutErr." -LogOnly -Verbose
                            }
                            else {
                                Write-Log "$VmName`: Job '$DisplayName' timed out. Job State: $($job.State) Error: $OutErr." -Failure
                            }
                            # A timed-out PSDirect/PSRemoting job is wedged on a dead or hung
                            # VMBus channel. Stop-Job / Remove-Job BLOCK on it (often for
                            # minutes) because the remote pipeline can't acknowledge
                            # cancellation until the VM is rebooted -- synchronously stopping
                            # it here would just make the caller MORE stuck. Signal
                            # cancellation asynchronously and ABANDON the job object instead;
                            # it is reaped when the reboot below breaks its transport, or when
                            # this process exits. (We do NOT Receive/Remove it -- it never
                            # produced output and a forced remove would block on the same dead
                            # transport.)
                            try { $job.StopJobAsync() } catch {}
                            Write-VmJobLedger -Op 'abandoned' -Job $job -VmName $VmName -DisplayName $DisplayName -Detail 'reason=timeout-still-running'
                        }
                        else {
                            # Job is in a terminal state (Failed / Stopped). Inspect WHY before
                            # disposing it. A plain scriptblock error is safe to Stop+Remove
                            # (its pipeline is done and no transport break is imminent). But a
                            # failure caused by a BROKEN PSDIRECT CHANNEL is different: the
                            # caller (e.g. Wait-ForVm's channel-broken recovery) is about to
                            # stop-vm2 -TurnOff / reboot the VM to recover VMBus, which breaks
                            # this session's transport. Disposing the job now (Remove-Job) lets
                            # that later transport break fire a StateChanged callback on a
                            # threadpool thread against the already-disposed job ->
                            # PSObjectDisposedException ('object "PSJob" has already been
                            # disposed') that crashes the whole phase child process (observed on
                            # ZZ-CREPE in Phase 2). So for a channel-broken terminal failure,
                            # treat it like the timeout path: ABANDON the job (do NOT dispose --
                            # a later callback then finds a live object) and leak its session.
                            if ($jobChannelBroken) {
                                try { $job.StopJobAsync() } catch {}
                                Write-VmJobLedger -Op 'abandoned' -Job $job -VmName $VmName -DisplayName $DisplayName -Detail 'reason=channel-broken'
                            }
                            else {
                                Stop-Job $job -ErrorAction SilentlyContinue | Out-Null
                                Write-VmJobLedger -Op 'disposed' -Job $job -VmName $VmName -DisplayName $DisplayName -Detail 'reason=terminal-failure-not-channel-broken'
                                Remove-Job $job -Force -ErrorAction SilentlyContinue
                            }
                        }
                        if ($jobTimedOut) {
                            # The job never finished within the timeout: the guest
                            # didn't answer, so this PSDirect session is suspect.
                            # Evict the cached session for this VM so the NEXT call
                            # builds a FRESH session instead of reusing a wedged
                            # channel -- reusing a hung session is what cascades into
                            # a full phase hang.
                            $return.TimedOut = $true
                            # -LeakSession (do NOT dispose): the timed-out job above
                            # was only StopJobAsync'd (abandoned, NOT removed -- a
                            # synchronous Remove-Job blocks on the dead VMBus). If we
                            # DISPOSE its session now, the job's later transport-break
                            # StateChanged callback -- fired when the VM is rebooted to
                            # recover the channel (Wait-ForVm's heartbeat reboot, or
                            # Invoke-VmLivenessRecovery) -- runs on a threadpool thread
                            # against an already-disposed object -> unhandled
                            # PSObjectDisposedException ('object "PSJob" has already
                            # been disposed') that crashes the whole phase child
                            # process. Evict the cache ENTRY but LEAK the session object
                            # (reaped once the abandoned job below reaches a terminal state);
                            # the wedged channel is no longer reachable via the cache anyway.
                            Remove-VmSessionFromCache -VmName $VmName -LeakSession -AbandonedJob $job
                            if ($RebootIfUnresponsive) {
                                $recovery = Invoke-VmLivenessRecovery -VmName $VmName -VmDomainName $VmDomainName -Quiet:$SuppressLog
                                $return.Rebooted = [bool]$recovery.Rebooted
                            }
                        }
                        elseif ($jobChannelBroken) {
                            # Channel-broken terminal failure: the abandoned job above was NOT
                            # disposed. Surface it to the caller and evict the cache ENTRY while
                            # LEAKING the session object (do NOT dispose -- same disposed-object
                            # callback hazard) so the next call builds a fresh channel and the
                            # imminent VM reboot/TurnOff can't crash the process via this
                            # session's transport break.
                            $return.ChannelBroken = $true
                            Remove-VmSessionFromCache -VmName $VmName -LeakSession -AbandonedJob $job
                        }
                    }
                }
                else {
                    # Suppress Invoke-Command's auto-generated progress record whose Activity
                    # is the raw scriptblock text.  Explicit Write-Progress2 calls in the
                    # calling code provide the meaningful progress instead.
                    $savedProgressPref = $ProgressPreference
                    $ProgressPreference = 'SilentlyContinue'
                    try {
                        $return.ScriptBlockOutput = Invoke-Command -Session $ps @HashArguments -ErrorVariable Err2 -ErrorAction SilentlyContinue

                        # History, so this is not re-litigated a third time:
                        # * The first retry here EVICTED and rebuilt the session. It fired
                        #   1,364 times and recovered 0 -- 456 on a brand-new session, failing
                        #   in 27-42ms -- which read as "not transient at all".
                        # * That pointed at something inside $Test_PendingReboot, since the
                        #   error arrives as a RemoteException (serialized back FROM the guest).
                        #   Removing Get-WindowsFeature -- its only ServerManager/WinPS-compat
                        #   cmdlet -- did NOT help: the error persists on plain member servers
                        #   that never reach that branch.
                        # * err-stack and err-remote-at come back EMPTY, so the guest names no
                        #   line, which fits the scriptblock never running at all.
                        # * a retry on the UNCHANGED session (no eviction) -- the one thing
                        #   left untried, and the thing postFailTrivial appeared to promise --
                        #   recovered 0 of 7. So postFailTrivial's 810/810 does NOT generalise:
                        #   a trivial `{1}` succeeds where the real payload still fails, on the
                        #   same session, milliseconds apart.
                        # No retry here any more: none of the three ever recovered a single
                        # call, and re-issuing would double-execute a caller's scriptblock,
                        # which is unsafe for anything non-idempotent. Autopsy only.
                        $createSig = $global:ps_pipelineCreateSignature
                        if (-not $createSig) { $createSig = 'An error occurred while creating the pipeline|The pipeline is not available|availability is Busy|is not available to run commands' }
                        if ($null -eq $return.ScriptBlockOutput -and $Err2 -and $Err2.Count -gt 0 -and
                            ("$($Err2 -join ' ')" -match $createSig)) {
                            # -LogOnly, so safe to emit even for -SuppressLog callers (the
                            # post-phase pending-reboot check is one).
                            Write-Log "$VmName`: '$DisplayName' pipeline-create autopsy -- $(Get-VmPipelineFailureAutopsy -Session $ps -Errors $Err2)" -LogOnly
                        }
                    }
                    finally {
                        $ProgressPreference = $savedProgressPref
                    }
                    Set-VmSessionPipelineEvent -Session $ps -Kind 'sync-done' -Op $DisplayName
                    # Overwrite any leaked Invoke-Command progress with the clean DisplayName.
                    # $ProgressPreference suppression doesn't reliably prevent PS Direct
                    # sessions from adding raw-scriptblock progress records to the job stream.
                    if (-not $SuppressLog) {
                        Write-Progress2 "$VmName`: $DisplayName" -Status "Done" -force
                    }
                }
            }
            catch {
                $failed = $true
                $caughtException = $_
                if (-not $SuppressLog) {
                    Write-Log "$VmName`: Failed to run '$DisplayName'. Error: $_" -Failure
                    Write-Log "$($_.ScriptStackTrace)" -LogOnly
                    Write-Exception -ExceptionInfo $_
                }
            }
            if ($CommandReturnsBool) {

                #if (([bool]$($return.ScriptBlockOutput) -ne $true -and [bool]$($return.ScriptBlockOutput) -ne $false) {
                if ($return.ScriptBlockOutput -isnot [bool]) {
                    Write-Log "Output was: $($return.ScriptBlockOutput)" -Warning
                    $failed = $true
                    $return.ScriptBlockFailed = $true
                    if ($Err2.Count -ne 0) {
                        $failed = $true
                        $return.ScriptBlockFailed = $true
                        if (-not $SuppressLog) {
                            if ($Err2.Count -eq 1) {
                                Write-Log "$VmName`: Failed to run '$DisplayName'. Error: $($Err2[0].ToString().Trim())." -Failure
                            }
                            else {
                                $msg = @()
                                foreach ($failMsg in $Err2) { $msg += $failMsg }
                                Write-Log "$VmName`: Failed to run '$DisplayName'. Error: {$($msg -join '; ')}" -Failure
                            }
                        }
                    }
                }
            }
            else {
                if ($Err2.Count -ne 0) {
                    $failed = $true
                    $return.ScriptBlockFailed = $true
                    if (-not $SuppressLog) {
                        if ($Err2.Count -eq 1) {
                            Write-Log "$VmName`: Failed to run '$DisplayName'. Error: $($Err2[0].ToString().Trim())." -Failure
                        }
                        else {
                            $msg = @()
                            foreach ($failMsg in $Err2) { $msg += $failMsg }
                            Write-Log "$VmName`: Failed to run '$DisplayName'. Error: {$($msg -join '; ')}" -Failure
                        }
                    }
                }
            }
        }
        else {
            $return.ScriptBlockFailed = $true
            # Uncomment when debugging, this is called many times while waiting for VM to be ready
            # Write-Log "Invoke-VmCommand: $VmName`: Failed to get VM Session." -Failure -LogOnly
            # return $return
        }

        # Capture error details on the return object for callers to inspect
        if ($failed) {
            # Snapshot whether the scriptblock produced NO output BEFORE the block
            # below back-fills ScriptBlockOutput with error text -- a genuine
            # no-output failure (output null) distinguishes a real pipeline-create
            # collision from a scriptblock that ran and returned but errored.
            $sbOutputWasNull = ($null -eq $return.ScriptBlockOutput)
            if ($Err2 -and $Err2.Count -gt 0) {
                $return.ErrorDetails = @($Err2 | ForEach-Object { $_.ToString().Trim() })
            }
            elseif ($caughtException) {
                $return.ErrorDetails = @("$caughtException".Trim())
            }
            elseif ($jobFailureReason) {
                $return.ErrorDetails = @($jobFailureReason)
            }
            # Populate ScriptBlockOutput with error text when command failed but output is null
            if ($null -eq $return.ScriptBlockOutput) {
                if ($return.ErrorDetails) {
                    $return.ScriptBlockOutput = $return.ErrorDetails[0]
                }
            }
            # When the failure is a PSDirect readiness/channel issue (the recurring
            # "An error occurred while creating the pipeline", a broken transport, a
            # session that won't connect, etc.) emit a companion host-side diagnostic
            # line so post-run log review can correlate these failures with the VM's
            # actual Hyper-V uptime/heartbeat. Over many runs this tells us whether the
            # failures cluster on freshly-booting guests (=> a readiness gate/threshold
            # needs tuning) or hit settled VMs (=> something else). Gated on the error
            # signature (and ChannelBroken) so ordinary scriptblock failures don't
            # trigger a host query or add log noise. -LogOnly: file only, not console.
            if (-not $SuppressLog) {
                $errBlob = "$($return.ErrorDetails -join ' ')"
                if ($return.ChannelBroken -or $errBlob -match 'creating the pipeline|pipeline is not|transport|channel|broken|Cannot connect|not connected|session is in|availability is Busy|No valid sessions') {
                    Write-Log "$VmName`: '$DisplayName' PSDirect readiness diag -- $(Get-VmHostSideDiag -VmName $VmName)" -LogOnly
                    # Mechanism diagnostic: was a SECOND pipeline running on this same
                    # cached session from another thread when the error fired (the
                    # concurrency hypothesis), and was the runspace Busy / output null?
                    # This is what tells us whether the fix needs per-session
                    # serialization (concurrency) vs the AsJob settle-wait already in
                    # place (transitional) vs something else (Available + idle).
                    Write-Log "$VmName`: '$DisplayName' pipeline-race diag -- $(Get-VmSessionConcurrencyDiag -Session $ps -SelfToken $inflightToken -OutputWasNull $sbOutputWasNull)" -LogOnly
                    # Full autopsy: exception chain + FullyQualifiedErrorId + the session's
                    # real state + how long ago the previous pipeline on it finished. The
                    # race diag above reported an identical, non-discriminating
                    # 'Available/null/none' on all 800+ historical failures.
                    Write-Log "$VmName`: '$DisplayName' pipeline-create autopsy -- $(Get-VmPipelineFailureAutopsy -Session $ps -Errors $Err2 -CaughtException $caughtException)" -LogOnly
                }
            }
        }

        # Release the in-flight marker AFTER the diagnostic above has read it.
        Exit-VmSessionInflight -Token $inflightToken

        # Set Command Result state in return object
        if (-not $failed) {
            $return.CommandResult = $true
            if (-not $SuppressLog) {
                Write-Log "$VmName`: Successfully ran '$DisplayName'" -LogOnly -Verbose
            }
        }
    }
    catch {
        Write-Log "$VmName`: Invoke-VMCommand Exception $_"
        # Ensure the in-flight marker is released even on an unexpected throw, so a
        # leaked entry can't produce a false-positive concurrency reading later.
        Exit-VmSessionInflight -Token $inflightToken
    }
    return $return

}

$global:ps_cache = @{}
# Remembers which credential style last worked for each VM so the next
# cold connect can try it first, avoiding 30s timeout on wrong creds.
# Values: 'primary' | 'local' | 'domain-lookup' | 'administrator'.
$global:ps_lastGoodCred = @{}

# In-flight tracker for the "An error occurred while creating the pipeline"
# investigation. Keyed by PSSession.InstanceId; value is a synchronized list of
# @{ ThreadId; Display; At } for every Invoke-VmCommand currently executing a
# scriptblock on that session. Lets the failure-site diagnostic state, with
# proof, whether a second pipeline was running on the SAME cached session from
# another thread at the moment the pipeline-create error fired (the concurrency
# mechanism) vs the session being idle (something else). Cheap: two locked list
# mutations per call, only ever read on a failure.
$global:ps_inflight = [System.Collections.Hashtable]::Synchronized(@{})

function Enter-VmSessionInflight {
    # Mark a scriptblock as executing on $Session. Returns an opaque token to pass
    # to Exit-VmSessionInflight. Never throws.
    param($Session, [string]$DisplayName)
    try {
        if (-not $Session) { return $null }
        $key = "$($Session.InstanceId)"
        $entry = @{ ThreadId = [System.Threading.Thread]::CurrentThread.ManagedThreadId; Display = $DisplayName; At = (Get-Date) }
        [System.Threading.Monitor]::Enter($global:ps_inflight.SyncRoot)
        try {
            if (-not $global:ps_inflight.ContainsKey($key)) { $global:ps_inflight[$key] = (New-Object System.Collections.ArrayList) }
            [void]$global:ps_inflight[$key].Add($entry)
        }
        finally { [System.Threading.Monitor]::Exit($global:ps_inflight.SyncRoot) }
        return @{ Key = $key; Entry = $entry }
    }
    catch { return $null }
}

function Exit-VmSessionInflight {
    param($Token)
    try {
        if (-not $Token) { return }
        [System.Threading.Monitor]::Enter($global:ps_inflight.SyncRoot)
        try {
            if ($global:ps_inflight.ContainsKey($Token.Key)) {
                $global:ps_inflight[$Token.Key].Remove($Token.Entry)
                if ($global:ps_inflight[$Token.Key].Count -eq 0) { [void]$global:ps_inflight.Remove($Token.Key) }
            }
        }
        finally { [System.Threading.Monitor]::Exit($global:ps_inflight.SyncRoot) }
    }
    catch { }
}

function Get-VmSessionConcurrencyDiag {
    # Build a one-line diagnostic describing the session's runspace availability and
    # any OTHER in-flight scriptblock on the same session right now (i.e. genuine
    # concurrent use). $SelfToken is excluded so the calling op doesn't list itself.
    # Never throws.
    param($Session, $SelfToken, [bool]$OutputWasNull)
    try {
        $avail = '<no-session>'
        if ($Session) { try { $avail = [string]$Session.Runspace.RunspaceAvailability } catch { $avail = '<unknown>' } }
        $concurrent = @()
        if ($Session) {
            $key = "$($Session.InstanceId)"
            [System.Threading.Monitor]::Enter($global:ps_inflight.SyncRoot)
            try {
                if ($global:ps_inflight.ContainsKey($key)) {
                    foreach ($e in @($global:ps_inflight[$key])) {
                        if ($SelfToken -and [object]::ReferenceEquals($e, $SelfToken.Entry)) { continue }
                        $concurrent += "tid=$($e.ThreadId) op='$($e.Display)' for=$([int]((Get-Date) - $e.At).TotalMilliseconds)ms"
                    }
                }
            }
            finally { [System.Threading.Monitor]::Exit($global:ps_inflight.SyncRoot) }
        }
        $concStr = if ($concurrent.Count) { ($concurrent -join ' | ') } else { '<none>' }
        $rsId = try { [string][System.Management.Automation.Runspaces.Runspace]::DefaultRunspace.Id } catch { '?' }
        return "runspaceAvail=$avail outputWasNull=$OutputWasNull thisThread=$([System.Threading.Thread]::CurrentThread.ManagedThreadId) defaultRunspace=$rsId concurrentOnSameSession=[$concStr]"
    }
    catch { return "concurrency-diag-unavailable ($($_.Exception.Message))" }
}

# Per-session timeline for the "creating the pipeline" investigation. Keyed by
# PSSession.InstanceId. Records when the session was built and when the previous
# pipeline on it finished, so the failure autopsy can state -- in milliseconds --
# how long after the preceding -AsJob teardown the failing pipeline-create landed.
# That number is what distinguishes a server-side teardown race (tens/hundreds of
# ms) from a session that has been idle for seconds and is simply dead.
$global:ps_pipelineTimeline = [System.Collections.Hashtable]::Synchronized(@{})

function Set-VmSessionPipelineEvent {
    # Record 'what just finished' on a session. Never throws.
    param($Session, [string]$Kind, [string]$Op)
    try {
        if (-not $Session) { return }
        $key = "$($Session.InstanceId)"
        [System.Threading.Monitor]::Enter($global:ps_pipelineTimeline.SyncRoot)
        try {
            if (-not $global:ps_pipelineTimeline.ContainsKey($key)) { $global:ps_pipelineTimeline[$key] = @{} }
            $slot = $global:ps_pipelineTimeline[$key]
            if ($Kind -eq 'created') { $slot['CreatedAt'] = (Get-Date) }
            else {
                $slot['LastAt'] = (Get-Date)
                $slot['LastKind'] = $Kind
                $slot['LastOp'] = $Op
            }
        }
        finally { [System.Threading.Monitor]::Exit($global:ps_pipelineTimeline.SyncRoot) }
    }
    catch { }
}

function Get-VmPipelineFailureAutopsy {
    # One-line, high-detail autopsy for a pipeline-create failure. The existing
    # concurrency diag only reports RunspaceAvailability, which was 'Available' on
    # every one of the 800+ recorded failures -- i.e. it cannot discriminate. This
    # adds the three things that can:
    #   1. the ErrorRecord's FullyQualifiedErrorId + exception chain (names the exact
    #      throw site inside the remoting stack instead of just its message text),
    #   2. the session's REAL state (PSSession.State / .Availability /
    #      Runspace.RunspaceStateInfo.State+Reason -- all different from Availability),
    #   3. how long ago the previous pipeline on this session finished, and what it was.
    # Never throws.
    param($Session, $Errors, $CaughtException)
    try {
        $parts = @()

        $sState = '?'; $sAvail = '?'; $rsState = '?'; $rsReason = '<none>'; $rsAvail = '?'
        if ($Session) {
            try { $sState = [string]$Session.State } catch { }
            try { $sAvail = [string]$Session.Availability } catch { }
            try { $rsAvail = [string]$Session.Runspace.RunspaceAvailability } catch { }
            try { $rsState = [string]$Session.Runspace.RunspaceStateInfo.State } catch { }
            try {
                $r = $Session.Runspace.RunspaceStateInfo.Reason
                if ($r) { $rsReason = "$($r.GetType().Name): $($r.Message)" }
            }
            catch { }
        }
        $parts += "sess=[state=$sState avail=$sAvail rsState=$rsState rsAvail=$rsAvail rsReason='$rsReason']"

        $ageStr = 'n/a'; $sinceStr = 'n/a'; $prevOp = '<none>'; $prevKind = '<none>'
        if ($Session) {
            $key = "$($Session.InstanceId)"
            [System.Threading.Monitor]::Enter($global:ps_pipelineTimeline.SyncRoot)
            try {
                if ($global:ps_pipelineTimeline.ContainsKey($key)) {
                    $slot = $global:ps_pipelineTimeline[$key]
                    if ($slot['CreatedAt']) { $ageStr = "$([int]((Get-Date) - $slot['CreatedAt']).TotalMilliseconds)ms" }
                    if ($slot['LastAt']) { $sinceStr = "$([int]((Get-Date) - $slot['LastAt']).TotalMilliseconds)ms" }
                    if ($slot['LastOp']) { $prevOp = $slot['LastOp'] }
                    if ($slot['LastKind']) { $prevKind = $slot['LastKind'] }
                }
            }
            finally { [System.Threading.Monitor]::Exit($global:ps_pipelineTimeline.SyncRoot) }
        }
        $parts += "timeline=[sessionAge=$ageStr sincePrevPipeline=$sinceStr prevKind=$prevKind prevOp='$prevOp']"

        $i = 0
        foreach ($e in @($Errors)) {
            if (-not $e) { continue }
            $i++
            if ($i -gt 3) { break }
            $eType = '?'; $eFq = '?'; $eCat = '?'; $eTarget = '<null>'; $inner = '<none>'
            try { if ($e.Exception) { $eType = $e.Exception.GetType().FullName } } catch { }
            try { $eFq = [string]$e.FullyQualifiedErrorId } catch { }
            try { $eCat = [string]$e.CategoryInfo.Category } catch { }
            try { if ($null -ne $e.TargetObject) { $eTarget = "$($e.TargetObject)" } } catch { }
            try {
                $ix = $e.Exception.InnerException
                $chain = @()
                $depth = 0
                while ($ix -and $depth -lt 4) { $chain += "$($ix.GetType().Name): $($ix.Message)"; $ix = $ix.InnerException; $depth++ }
                if ($chain.Count) { $inner = ($chain -join ' <- ') }
            }
            catch { }
            # TransportErrorCode / ErrorCode carry the hvsocket/WinRM native failure
            # when the exception is a PSRemotingTransportException -- the single most
            # useful field for telling a guest-side host death from a local race.
            $native = ''
            try {
                if ($e.Exception.PSObject.Properties['ErrorCode']) { $native += " errorCode=$($e.Exception.ErrorCode)" }
                if ($e.Exception.PSObject.Properties['TransportMessage']) { $native += " transportMsg='$($e.Exception.TransportMessage)'" }
            }
            catch { }
            $parts += "err$i=[type=$eType fqeid=$eFq cat=$eCat target='$eTarget'$native inner='$inner']"

            # WHICH command, and WHERE. A RemoteException (which is what all 268 of
            # these turned out to be) means the record was serialized back FROM the
            # guest -- the pipeline was created and something inside the scriptblock
            # raised it. CategoryInfo.Activity names that command; InvocationInfo
            # gives the line. Without these the message on its own -- "An error
            # occurred while creating the pipeline" -- is unattributable, which is
            # why 1,364 retries produced no new information.
            try {
                $parts += "err$i-where=[activity='$([string]$e.CategoryInfo.Activity)' reason='$([string]$e.CategoryInfo.Reason)' targetName='$([string]$e.CategoryInfo.TargetName)']"
            }
            catch { }
            try {
                if ($e.InvocationInfo) {
                    $srcLine = "$($e.InvocationInfo.Line)" -replace '\s+', ' '
                    if ($srcLine.Length -gt 120) { $srcLine = $srcLine.Substring(0, 120) }
                    $parts += "err$i-at=[cmd='$($e.InvocationInfo.MyCommand)' line=$($e.InvocationInfo.ScriptLineNumber) src='$($srcLine.Trim())']"
                }
            }
            catch { }
            try {
                $sre = $e.Exception.SerializedRemoteException
                if ($sre) { $parts += "err$i-remote=[$($sre.GetType().Name): $("$($sre.Message)" -replace '\s+', ' ')]" }
            }
            catch { }
            # err-at stayed EMPTY across 810 samples: a deserialized record has no live
            # InvocationInfo, and CategoryInfo.Activity/TargetName come back blank -- which
            # is the only reason "something inside the scriptblock" was ever ruled out.
            # ScriptStackTrace and SerializedRemoteInvocationInfo DO survive serialization
            # and name the guest-side line.
            try {
                $sst = "$($e.ScriptStackTrace)" -replace '\s+', ' '
                if ($sst.Trim()) {
                    if ($sst.Length -gt 220) { $sst = $sst.Substring(0, 220) }
                    $parts += "err$i-stack=[$($sst.Trim())]"
                }
            }
            catch { }
            try {
                $rii = $e.Exception.SerializedRemoteInvocationInfo
                if ($rii) {
                    $rLine = "$($rii.Line)" -replace '\s+', ' '
                    if ($rLine.Length -gt 140) { $rLine = $rLine.Substring(0, 140) }
                    $parts += "err$i-remote-at=[cmd='$($rii.MyCommand)' line=$($rii.ScriptLineNumber) offset=$($rii.OffsetInLine) src='$($rLine.Trim())']"
                }
            }
            catch { }
        }
        if ($i -eq 0 -and $CaughtException) {
            $parts += "caught=[type=$($CaughtException.Exception.GetType().FullName) fqeid=$($CaughtException.FullyQualifiedErrorId)]"
        }

        # THE decisive measurement, and only production can take it. Three synthetic
        # harnesses have now failed to reproduce this cold -- payload slices up to
        # 4131 chars, the real Stop_RunningDSC WmiPrvSE kill, and 64 stress threads --
        # all 150/150 green on an idle host, because server-side teardown there
        # completes in microseconds. So ask the one question no harness can:
        # AT THE MOMENT OF FAILURE, does a trivial pipeline still work on this session?
        #   ok      -> the session and transport are fine RIGHT NOW; the failing
        #              create raced something specific to it. Retry is viable.
        #   fail    -> the transport really is down; the readiness probe that runs
        #              ~1s earlier and always passes is simply too early to see it.
        # A rebuilt session previously failed 456/456 in 27-42ms, which already argues
        # against evict-and-rebuild; this separates "session dead" from "create raced".
        try {
            # Only probe a session that still claims to be usable. That is not a
            # limitation: every recorded failure had Availability='Available', so this
            # is exactly the interesting case, and it avoids issuing a round trip into
            # an obviously-dead session (Invoke-Command has no timeout to bound it).
            if ($Session -and "$($Session.Availability)" -eq 'Available') {
                $probeSw = [Diagnostics.Stopwatch]::StartNew()
                $probeErr = $null
                $probeOut = Invoke-Command -Session $Session -ScriptBlock { 1 } -ErrorAction SilentlyContinue -ErrorVariable probeErr
                $probeSw.Stop()
                $probeMs = [int]$probeSw.Elapsed.TotalMilliseconds
                if ($probeOut -eq 1 -and -not $probeErr) {
                    $parts += "postFailTrivial=[ok ${probeMs}ms -- session ALIVE at failure time]"
                }
                else {
                    $pm = ''
                    try { if ($probeErr) { $pm = "$(@($probeErr)[0].Exception.Message)" -replace '\s+', ' ' } } catch { }
                    $parts += "postFailTrivial=[FAILED ${probeMs}ms '$pm']"
                }
            }
            else { $parts += "postFailTrivial=[skipped avail='$(if ($Session) { $Session.Availability } else { '<null session>' })']" }
        }
        catch { $parts += "postFailTrivial=[threw '$("$($_.Exception.Message)" -replace '\s+', ' ')']" }

        return ($parts -join ' ')
    }
    catch { return "autopsy-unavailable ($($_.Exception.Message))" }
}

# Error-message signatures for a pipeline that failed to be CREATED -- i.e. the
# remote scriptblock provably never started. Deliberately narrower than the
# teardown signature used elsewhere: 'transport'/'broken'/'closed' can also fire
# mid-execution, and retrying those risks running a non-idempotent scriptblock
# twice. Everything here is raised before any remote code runs.
$global:ps_pipelineCreateSignature = 'An error occurred while creating the pipeline|The pipeline is not available|availability is Busy|is not available to run commands|Cannot invoke the pipeline because it was not created'


# New-PSSessionWithTimeout
# Wraps New-PSSession -VMId in a separate runspace so the call can be
# capped at $TimeoutSec seconds.  PSDirect's VMId parameter set does
# not accept -SessionOption (which carries OpenTimeout), so there is
# no native way to prevent an indefinite hang when PSDirect is broken
# inside the guest (e.g. during BDC promotion).
# Returns @{ Session; TimedOut; ErrorMessage } so callers can
# distinguish channel-broken (timeout / VMBus error) from auth errors.
function New-PSSessionWithTimeout {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '',
        Justification = 'The nested job scriptblock parameter $cred receives an existing [pscredential]; it is never a plaintext password.')]
    param(
        [string]$Name,
        [guid]$VMId,
        [pscredential]$Credential,
        [int]$TimeoutSec = 30
    )

    # Return a diagnostic hashtable so callers can distinguish
    # timeout (channel hung) from auth/connection errors.
    $result = @{ Session = $null; TimedOut = $false; ErrorMessage = $null }

    # NO sweep here. This runs on every new PSDirect session, i.e. constantly MID-PHASE,
    # and it silently broke the contract the abandon paths depend on: they StopJobAsync a
    # job and leak its session specifically so a later transport break finds a LIVE object,
    # documented as "reaped at process exit". Once parking existed, this call reaped them
    # 120s later instead -- disposing a session with a still-running abandoned job riding
    # it, which is the disposed-object crash those paths were written to avoid. Its only
    # guard, RunspaceAvailability -ne 'Busy', is documented in this same file as a
    # false-ready signal. Reaping happens where it is safe: Clear-VmSessionCache in each
    # worker's finally (that VM's phase work is over) and the -Force pass at end of run.

    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.Open()

    $psi = [System.Management.Automation.PowerShell]::Create()
    $psi.Runspace = $rs

    $null = $psi.AddScript({
        param($name, $vmId, $cred)
        New-PSSession -Name $name -VMId $vmId -Credential $cred -ErrorAction Stop
    }).AddArgument($Name).AddArgument($VMId).AddArgument($Credential)

    $async = $psi.BeginInvoke()

    if (-not $async.AsyncWaitHandle.WaitOne($TimeoutSec * 1000)) {
        # Timed out — use BeginStop (non-blocking) instead of Stop() which
        # blocks until the underlying VMBus call completes.  When PSDirect
        # is wedged, Stop() hangs indefinitely, defeating the timeout.
        # BeginStop queues the cancellation and returns immediately; the
        # runspace is parked for deferred disposal rather than abandoned, so
        # it is reclaimed once the async stop lands instead of holding ~8MB
        # for the life of the shell.
        try { $psi.BeginStop($null, $null) } catch {}
        Add-OrphanRunspace -Runspace $rs -PowerShell $psi -Reason 'connect timeout' -VmName $Name
        $result.TimedOut = $true
        return $result
    }

    try {
        $result.Session = $psi.EndInvoke($async) | Select-Object -First 1
    }
    catch {
        $result.ErrorMessage = "$_"
    }

    $psi.Dispose()

    if ($result.Session) {
        # Keep the runspace alive — closing it can destroy the PSSession
        # whose transport was established through it.  Attach it to the
        # session so it can be cleaned up when the session is evicted.
        $result.Session | Add-Member -NotePropertyName '_OwnerRunspace' -NotePropertyValue $rs -Force
        try {
            $st = Get-VmSessionStats
            $st['created']++
            $tag = Get-VmSessionCallerTag
            $result.Session | Add-Member -NotePropertyName '_CallerTag' -NotePropertyValue $tag -Force
            $st['byCaller'][$tag] = 1 + [int]$st['byCaller'][$tag]
        }
        catch { }
    }
    else {
        $rs.Close()
        $rs.Dispose()
    }
    return $result
}

# Runspaces that could not be disposed at the moment they were abandoned.
# RunspaceFactory::CreateRunspace() is the ONLY runspace API in this codebase that
# leaks 1:1 when not explicitly disposed -- [PowerShell]::Create()+Dispose() and
# Start-ThreadJob both reclaim cleanly (measured, temp/probe-runspace-creators.ps1)
# -- and New-PSSessionWithTimeout is its only caller. Both of its abandon paths
# (connect timeout, and a session evicted with -LeakSession) used to drop the
# runspace on the floor, where it stayed for the life of the shell holding its own
# command + format + module tables, ~8MB each. A 5.5h Mega build ended with 121
# open runspaces against just 18 cached sessions.
# Deferring rather than never disposing: the reason these are abandoned is that a
# late transport callback on an already-disposed object crashes the phase process,
# so give them a settle window and only then reclaim.
$global:ps_orphanRunspaces = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))

# Create-vs-dispose ledger for PSDirect sessions. Held on the APPDOMAIN, not in
# $global:, because the thing being measured is ThreadJob workers -- and a ThreadJob
# gets its own runspace, so its $global: is a different scope. A $global: ledger can
# only ever see the launcher's own sessions, which is exactly why the first ledger
# read created=10/disposeCalls=10 while 183 leaked pairs sat there uncounted. AppDomain
# data is per-PROCESS, so every ThreadJob in the launcher increments the same counters.
if (-not [System.AppDomain]::CurrentDomain.GetData('MemLabs_SessionStats')) {
    [System.AppDomain]::CurrentDomain.SetData('MemLabs_SessionStats',
        [System.Collections.Hashtable]::Synchronized(@{
                created           = 0   # New-PSSessionWithTimeout returned a live session
                disposeCalls      = 0   # Remove-VmSession entered
                disposeLeftOpen   = 0   # ...Close()+Dispose() ran, runspace still not Closed
                disposeNoOwner    = 0   # ...session had no _OwnerRunspace to close
                disposeThrew      = 0   # ...the close path threw
                cacheRaceLost     = 0   # lost a create race; disposed OUR new session, kept the cached one
                cacheEvicted      = 0   # cache slot held a DEAD session; parked it instead of dropping it
                workerCleanups    = 0   # Clear-VmSessionCache calls (proves the fix is live)
                workerDisposed    = 0   # sessions those calls released
                byCaller          = [System.Collections.Hashtable]::Synchronized(@{})  # caller -> net undisposed
            }))
}
function Get-VmSessionStats { [System.AppDomain]::CurrentDomain.GetData('MemLabs_SessionStats') }

# Usage stamps on each cached PSDirect session. `ps_cache=19` alone cannot tell a
# WORKING cache (one warm session per live VM, reused every phase) from dead
# weight (created once, never touched again) -- and the two want opposite fixes.
# Measurement only; nothing here reaps.
function Set-VmSessionCacheStamp {
    param(
        [object] $Session,
        [string] $VmName,
        [switch] $Hit
    )
    if (-not $Session) { return }
    try {
        $now = Get-Date
        if ($Hit) {
            $Session | Add-Member -MemberType NoteProperty -Name '_CacheHits' -Value (1 + [int]$Session._CacheHits) -Force
        }
        else {
            $Session | Add-Member -MemberType NoteProperty -Name '_CachedAt' -Value $now -Force
            $Session | Add-Member -MemberType NoteProperty -Name '_CacheHits' -Value 0 -Force
            $Session | Add-Member -MemberType NoteProperty -Name '_CachedVm' -Value $VmName -Force
        }
        $Session | Add-Member -MemberType NoteProperty -Name '_LastUsed' -Value $now -Force
    }
    catch { }
}

# One-line census of $global:ps_cache for the phase-boundary and end-of-run
# reports. Deliberately local-only (no Get-VM / no round-trip to any guest) so
# it is safe to call from inside the phase wait loop.
function Get-VmSessionCacheCensus {
    try {
        if (-not $global:ps_cache -or $global:ps_cache.Count -eq 0) { return 'ps_cache census: empty' }
        $now = Get-Date
        $rows = foreach ($key in @($global:ps_cache.Keys)) {
            $s = $global:ps_cache[$key]
            if (-not $s) { continue }
            $rsState = ''
            try { $rsState = "$($s.Runspace.RunspaceStateInfo.State)" } catch { }
            [pscustomobject]@{
                Vm      = if ($s._CachedVm) { [string]$s._CachedVm } else { [string]$key }
                Avail   = "$($s.Availability)"
                Runspace = $rsState
                Hits    = [int]$s._CacheHits
                AgeMin  = if ($s._CachedAt) { [int]($now - [datetime]$s._CachedAt).TotalMinutes } else { -1 }
                IdleMin = if ($s._LastUsed) { [int]($now - [datetime]$s._LastUsed).TotalMinutes } else { -1 }
            }
        }
        $rows = @($rows)
        if ($rows.Count -eq 0) { return 'ps_cache census: empty' }
        # Entries stamped before this build's Common.ps1 loaded report Age/Idle -1;
        # exclude them from the aging stats rather than skewing them to 0.
        $timed = @($rows | Where-Object { $_.IdleMin -ge 0 })
        $never = @($rows | Where-Object { $_.Hits -eq 0 }).Count
        $byAvail = (@($rows | Group-Object Avail | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ' ')
        $byRs = (@($rows | Group-Object Runspace | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ' ')
        $idleMax = if ($timed.Count) { ($timed | Measure-Object IdleMin -Maximum).Maximum } else { -1 }
        $ageMax = if ($timed.Count) { ($timed | Measure-Object AgeMin -Maximum).Maximum } else { -1 }
        $hitsTotal = ($rows | Measure-Object Hits -Sum).Sum
        $worst = (@($rows | Sort-Object IdleMin -Descending | Select-Object -First 5 |
                    ForEach-Object {
                        if ($_.IdleMin -lt 0) { "$($_.Vm)=unstamped/hits$($_.Hits)" }
                        else { "$($_.Vm)=idle$($_.IdleMin)m/age$($_.AgeMin)m/hits$($_.Hits)" }
                    }) -join ' ')
        return "ps_cache census: $($rows.Count) entries; neverReused=$never totalHits=$hitsTotal; idleMax=${idleMax}m ageMax=${ageMax}m; avail [$byAvail]; runspace [$byRs]; oldest-idle: $worst"
    }
    catch { return "ps_cache census failed: $($_.Exception.Message)" }
}

function Get-VmSessionCallerTag {
    # Name the code path that owns a session, so the end-of-run report can say WHICH
    # caller leaks rather than just how many. Skips this module's own plumbing --
    # including Invoke-VmCommand, which every caller funnels through and which
    # therefore attributes 100% of sessions to itself (the first reading was a
    # useless "Invoke-VmCommand=6"). The frame above it is the actual feature.
    try {
        $skip = @(
            'Get-VmSessionCallerTag', 'New-PSSessionWithTimeout', 'Get-VmSession',
            'Remove-VmSession', 'Clear-VmSessionCache', 'Invoke-VmCommand',
            'Invoke-VmCommandWithRetry'
        )
        foreach ($fr in @(Get-PSCallStack | Select-Object -Skip 1)) {
            $fn = "$($fr.FunctionName)"
            if ($fn -in $skip) { continue }
            # An anonymous frame is useless on its own; qualify it with its script.
            if ($fn -match '^<') {
                $sn = ''
                try { if ($fr.ScriptName) { $sn = Split-Path $fr.ScriptName -Leaf } } catch { }
                if ($sn) { return "$sn$fn" }
                continue
            }
            if ($fn) { return $fn }
        }
    }
    catch { }
    return '<unknown>'
}

function Add-OrphanRunspace {
    param($Runspace, $PowerShell, $Session, [string]$Reason, [string]$VmName, $Job)
    try {
        if (-not $Runspace -and -not $PowerShell -and -not $Session) { return }
        [void]$global:ps_orphanRunspaces.Add([pscustomobject]@{
                Rs = $Runspace; Ps = $PowerShell; Sess = $Session; At = (Get-Date); Reason = $Reason; VmName = $VmName; Job = $Job
            })
    }
    catch { }
}

function Clear-OrphanRunspaces {
    <#
    .SYNOPSIS
    Dispose parked runspaces once they are safe to touch.
    .PARAMETER Force
    End-of-run: reclaim regardless of age. Jobs have already been removed by then,
    so the late-callback hazard that made these unsafe is gone.
    #>
    [CmdletBinding()]
    param([switch]$Force, [int]$MinAgeSeconds = 120)

    $reclaimed = 0
    try {
        foreach ($entry in @($global:ps_orphanRunspaces)) {
            if (-not $entry) { continue }
            $age = ((Get-Date) - $entry.At).TotalSeconds
            if (-not $Force -and $age -lt $MinAgeSeconds) { continue }
            # Still executing: leave it. A Dispose() here is the documented crash.
            if (-not $Force) {
                # An ABANDONED JOB is still riding this session. Invoke-VmCommand's timeout /
                # channel-broken paths StopJobAsync the job and leak the session precisely so a
                # later transport break finds a LIVE object; disposing here re-creates the crash
                # they were avoiding, and turns "leaked, reaped at process exit" into "disposed
                # 120s later". RunspaceAvailability cannot see this -- it is a documented
                # false-ready signal that reads Available while the server-side pipeline lives.
                if ($entry.Job) {
                    $jobState = $null
                    try { $jobState = "$($entry.Job.State)" } catch { }
                    if ($jobState -notin @('Completed', 'Failed', 'Stopped')) { continue }
                }
                $avail = $null
                try { $avail = $entry.Rs.RunspaceAvailability } catch { }
                if ("$avail" -eq 'Busy') { continue }
            }
            try { if ($entry.Ps) { $entry.Ps.Dispose() } } catch { }
            # Release the PSSession BEFORE its owner runspace -- the session's
            # transport rides that runspace. Parking only the runspace (the original
            # behaviour) left the RemoteRunspace open forever: the leak ledger showed
            # 31 undisposed sessions as exactly 31 local + 31 remote runspaces, 22 of
            # them attributed to Repair-VmPSDirectChannel, whose -LeakSession eviction
            # is the only path that never disposes.
            try {
                if ($entry.Sess) {
                    Remove-PSSession $entry.Sess -ErrorAction SilentlyContinue
                    try {
                        $tag = "$($entry.Sess._CallerTag)"
                        if ($tag) { $bc = (Get-VmSessionStats)['byCaller']; $bc[$tag] = [int]$bc[$tag] - 1 }
                    }
                    catch { }
                }
            }
            catch { }
            try {
                if ($entry.Rs) {
                    $entry.Rs.Close()
                    $entry.Rs.Dispose()
                }
            }
            catch { }
            # Last, and only now: the transport is closed, so disposing the job it was
            # abandoned onto can no longer be reached by a teardown callback.
            try {
                if ($entry.Job) {
                    Write-VmJobLedger -Op 'reaped' -Job $entry.Job -VmName $entry.VmName -DisplayName 'orphan-session' -Detail "force=$($Force.IsPresent) reason=$($entry.Reason)"
                    Remove-Job $entry.Job -Force -ErrorAction SilentlyContinue
                }
            }
            catch { }
            [void]$global:ps_orphanRunspaces.Remove($entry)
            $reclaimed++
        }
    }
    catch { }
    if ($reclaimed -gt 0) {
        try { Write-Log "Reclaimed $reclaimed orphaned runspace(s); $(@($global:ps_orphanRunspaces).Count) still parked." -LogOnly } catch { }
    }
    return $reclaimed
}

# Lifetime ledger for every job this process creates against a VM.
#
# The crash being chased is an unhandled PSObjectDisposedException on a THREADPOOL
# thread. It carries no stack, no try/catch can see it, and the process is simply gone --
# four investigations have failed to name the object from the logs because nothing ever
# recorded which jobs existed, how each was let go of, or from where. So write it down
# BEFORE the power operation that breaks the transport.
$global:ps_jobLedger = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))

function Write-VmJobLedger {
    param(
        [ValidateSet('created', 'parked', 'disposed', 'abandoned', 'reaped')]
        [string]$Op,
        $Job,
        [string]$VmName,
        [string]$DisplayName,
        [string]$Detail
    )
    try {
        $id = 'n/a'
        try { $id = "$($Job.InstanceId)".Substring(0, 8) } catch { }
        $state = ''
        try { $state = "$($Job.State)" } catch { }
        $rsState = ''
        try { $rsState = "$($Job.ChildJobs[0].Runspace.RunspaceStateInfo.State)" } catch { }
        $site = ''
        # Only for the ops that can actually cause the crash; Get-PSCallStack is not free
        # and 'created'/'parked' happen on every single Invoke-VmCommand.
        if ($Op -in @('disposed', 'abandoned')) {
            try { $site = ((Get-PSCallStack | Select-Object -Skip 1 -First 2 | ForEach-Object { $_.Location }) -join ' <- ') } catch { }
        }
        [void]$global:ps_jobLedger.Add([pscustomobject]@{
                At = (Get-Date); Op = $Op; Id = $id; Vm = $VmName; Name = $DisplayName
                State = $state; RsState = $rsState; Site = $site; Detail = $Detail
            })
        # Cheapest way to give the crash handler a VM name; it cannot reach $currentItem.
        if ($VmName) { $global:ps_crashVm = $VmName }
        # A static string write, so the compiled crash handler can report the last job
        # operation without touching any PowerShell state on a dying threadpool thread.
        try { [MemLabsCrash]::Context = "vm=$VmName lastOp=$Op id=$id job='$DisplayName' state=$state rs=$rsState $Detail" } catch { }
        # Disposal is the only operation that can manufacture the crash, so it is written
        # to disk the instant it happens rather than waiting for a census that may never run.
        if ($Op -in @('disposed', 'abandoned')) {
            Write-Log "[JobLedger] $Op id=$id vm=$VmName job='$DisplayName' state=$state rs=$rsState $Detail at $site" -LogOnly
        }
    }
    catch { }
}

# Everything needed to identify the disposed object, rendered at the moment it matters:
# immediately before a Hyper-V power operation breaks a VM's transport.
# Emits ONE Write-Log per line: a multi-line string embeds raw newlines in the JSONL
# record, which split the first census across lines and made it unreadable there.
function Write-VmJobLedgerCensus {
    param([string]$VmName, [string]$Context)
    try {
        Write-Log "[JobLedger] CENSUS ($Context) vm=$VmName pid=$PID" -LogOnly

        $live = @()
        try { $live = @(Get-Job -ErrorAction SilentlyContinue) } catch { }
        # Summarise. One run reached 539 live jobs, and listing them produced a line no
        # one could read and nothing could parse.
        $byState = (@($live | Group-Object State | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ' ')
        $rsStates = @()
        foreach ($lj in $live) {
            try { $rsStates += "$($lj.ChildJobs[0].Runspace.RunspaceStateInfo.State)" } catch { $rsStates += 'unknown' }
        }
        $byRs = (@($rsStates | Group-Object | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ' ')
        Write-Log "[JobLedger]   live jobs=$($live.Count) state [$byState] runspace [$byRs]" -LogOnly
        # Name them while there are few enough to name. The CS2-FS1 crash census summarised
        # its single live job to "NotStarted=1" with a blank runspace, which is exactly the
        # object worth identifying and the only form in which it was recorded.
        if ($live.Count -le 12) {
            foreach ($lj in $live) {
                $ljId = ''; $ljRs = ''; $ljCmd = ''
                try { $ljId = "$($lj.InstanceId)".Substring(0, 8) } catch { }
                try { $ljRs = "$($lj.ChildJobs[0].Runspace.RunspaceStateInfo.State)/$($lj.ChildJobs[0].Runspace.RunspaceAvailability)" } catch { }
                try { $ljCmd = ("$($lj.Command)" -replace '\s+', ' ').Trim(); if ($ljCmd.Length -gt 90) { $ljCmd = $ljCmd.Substring(0, 90) } } catch { }
                Write-Log "[JobLedger]   live job id=$ljId num=$($lj.Id) name='$($lj.Name)' state=$($lj.State) rs=$ljRs cmd='$ljCmd'" -LogOnly
            }
        }

        $entries = @($global:ps_jobLedger)
        $byOp = (@($entries | Group-Object Op | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ' ')
        if (-not $byOp) { $byOp = '(empty -- this process released no job through the ledger)' }
        Write-Log "[JobLedger]   ledger totals: $byOp" -LogOnly

        # These are the candidates. A disposed job whose transport is about to break is
        # exactly the crash, so print them youngest-first with age.
        $risky = @($entries | Where-Object { $_.Op -in @('disposed', 'abandoned', 'reaped') } | Sort-Object At -Descending | Select-Object -First 10)
        foreach ($r in $risky) {
            $age = [int]((Get-Date) - $r.At).TotalSeconds
            Write-Log "[JobLedger]   ${age}s ago $($r.Op) id=$($r.Id) vm=$($r.Vm) job='$($r.Name)' state=$($r.State) rs=$($r.RsState) $($r.Detail) at $($r.Site)" -LogOnly
        }
        if ($risky.Count -eq 0) { Write-Log "[JobLedger]   no disposed/abandoned/reaped jobs recorded" -LogOnly }

        $orphans = 0
        $parked = @()
        try { $parked = @($global:ps_orphanRunspaces) } catch { }
        $orphans = $parked.Count
        $cacheRs = ''
        try {
            $cacheRs = (@(@($global:ps_cache.Keys) | ForEach-Object {
                        $s = $global:ps_cache[$_]
                        $st = ''
                        try { $st = "$($s.Runspace.RunspaceStateInfo.State)" } catch { }
                        "$_=$st"
                    }) -join ' ')
        }
        catch { }
        Write-Log "[JobLedger]   orphanRunspaces=$orphans cacheRunspaces [$cacheRs]" -LogOnly

        # A bare count is not evidence. On the CS2-FS1 crash the parked list was the ONLY
        # thing this worker had accumulated -- 8 entries, each a PowerShell object with a
        # BeginInvoke still outstanding against the transport Stop-VM2 was about to break --
        # and "orphanRunspaces=8" was everything the census said about them.
        foreach ($p in @($parked | Sort-Object At -Descending | Select-Object -First 12)) {
            $pAge = 0; $pRs = ''; $pJob = 'none'; $pDone = ''
            try { $pAge = [int]((Get-Date) - $p.At).TotalSeconds } catch { }
            try { $pRs = "$($p.Rs.RunspaceStateInfo.State)/$($p.Rs.RunspaceAvailability)" } catch { }
            try { if ($p.Job) { $pJob = "$($p.Job.State)" } } catch { }
            try { if ($p.Ps) { $pDone = " psInvocation=$($p.Ps.InvocationStateInfo.State)" } } catch { }
            Write-Log "[JobLedger]   parked ${pAge}s ago vm=$($p.VmName) reason='$($p.Reason)' rs=$pRs job=$pJob$pDone" -LogOnly
        }

        # Hand the compiled crash handler something to print. It is otherwise only fed by
        # Write-VmJobLedger, which never runs in a worker that disposed nothing -- so the
        # CONTEXT line would have been empty on exactly the crash it was written for.
        try {
            [MemLabsCrash]::Context = "vm=$VmName ctx='$Context' liveJobs=$($live.Count) [$byState] orphans=$orphans ledger=[$byOp]"
        }
        catch { }
    }
    catch {
        try { Write-Log "[JobLedger] census failed: $($_.Exception.Message)" -LogOnly } catch { }
    }
}

# The one thing that can actually name the disposed object.
#
# An unhandled exception on a threadpool thread cannot be caught by try/catch and kills
# the process -- but the CLR still raises AppDomain.UnhandledException FIRST, and that
# handler runs with the live exception in hand, including the StackTrace the serialized
# job error reports as null.
#
# The handler MUST be compiled, not a PowerShell scriptblock. A scriptblock-as-delegate
# needs an available Runspace to execute; on an arbitrary threadpool thread during
# process teardown there is none, so it is never invoked -- measured: the child died and
# wrote nothing. A C# delegate has no such dependency and writes with File.AppendAllText,
# which is synchronous and needs no PowerShell state.
function Register-VmCrashHandler {
    # Re-callable: the C# side subscribes once and every call just re-points the target
    # file. That matters because the first call happens while this file is still being
    # dot-sourced, long before $Common (and therefore the logs folder) exists.
    param([string]$Path)
    try {
        if (-not ('MemLabsCrash' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
public static class MemLabsCrash {
    public static string LogPath = "";
    public static string Context = "";
    private static bool _hooked;
    public static void Register(string logPath) {
        LogPath = logPath;
        if (_hooked) { return; }
        _hooked = true;
        AppDomain.CurrentDomain.UnhandledException += OnUnhandled;
    }
    private static void OnUnhandled(object sender, UnhandledExceptionEventArgs e) {
        try {
            StringBuilder sb = new StringBuilder();
            sb.AppendLine("==== UNHANDLED EXCEPTION " + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff")
                + " pid=" + System.Diagnostics.Process.GetCurrentProcess().Id
                + " terminating=" + e.IsTerminating + " ====");
            sb.AppendLine("CONTEXT: " + Context);
            Exception ex = e.ExceptionObject as Exception;
            if (ex != null) {
                sb.AppendLine("TYPE : " + ex.GetType().FullName);
                sb.AppendLine("MSG  : " + ex.Message);
                sb.AppendLine("FULL : " + ex.ToString());
                Exception inner = ex.InnerException;
                int depth = 0;
                while (inner != null && depth < 5) {
                    sb.AppendLine("INNER" + depth + ": " + inner.GetType().FullName + ": " + inner.Message);
                    inner = inner.InnerException;
                    depth++;
                }
            } else {
                sb.AppendLine("RAW  : " + Convert.ToString(e.ExceptionObject));
            }
            File.AppendAllText(LogPath, sb.ToString());
        } catch { }
    }
}
'@ -ErrorAction Stop
        }
        if (-not $Path) { $Path = Join-Path ([System.IO.Path]::GetTempPath()) "VMBuild.crash.$PID.log" }
        [MemLabsCrash]::Register($Path)
        $global:ps_crashHandlerRegistered = $true
        $global:ps_crashHandlerPath = $Path
    }
    catch {
        # Arming is the whole point of this function; a silent failure here means the next
        # worker death is unattributable again, so say so rather than swallowing it.
        $global:ps_crashHandlerRegistered = $false
        $global:ps_crashHandlerPath = $null
        try { Write-Log "[CrashHandler] FAILED to arm for pid $PID`: $($_.Exception.Message)" -Warning -LogOnly } catch { }
    }
}

# Every per-VM worker dot-sources this file, so registering here covers all of them
# without touching each job scriptblock. Re-pointed at the logs folder once $Common
# exists -- see the Register-VmCrashHandler call in the init block below.
Register-VmCrashHandler

function Get-RunspaceInventory {
    <#
    .SYNOPSIS
    Name the OWNER of every surviving runspace, not just its state.
    .DESCRIPTION
    End-of-run counts kept climbing across builds in one launcher (162 -> 182 -> 186)
    with "0 parked", so the orphan reclaim never saw them -- but a state-only
    breakdown cannot tell these apart, and they need opposite fixes:
      * LocalRunspace + <local>  = RunspaceFactory transport runspace (~8MB of command
                                   and format tables) -- New-PSSessionWithTimeout, or a
                                   Start-ThreadJob whose job was never Remove-Job'd.
      * RemoteRunspace + VMConnectionInfo = a PSDirect PSSession never disposed, i.e.
                                   created outside ps_cache or evicted without
                                   Remove-VmSession. Target names which VM.
    #>
    $rows = New-Object System.Collections.Generic.List[object]
    try {
        foreach ($r in @(Get-Runspace -ErrorAction SilentlyContinue)) {
            if ($r.Id -eq 1) { continue }
            if ("$($r.RunspaceStateInfo.State)" -eq 'Closed') { continue }
            $origin = '<local>'
            try { if ($r.OriginalConnectionInfo) { $origin = $r.OriginalConnectionInfo.GetType().Name } } catch { }
            $target = ''
            try { if ($r.ConnectionInfo -and $r.ConnectionInfo.ComputerName) { $target = "$($r.ConnectionInfo.ComputerName)" } } catch { }
            if (-not $target) { try { if ($r.ConnectionInfo -and $r.ConnectionInfo.VMName) { $target = "$($r.ConnectionInfo.VMName)" } } catch { } }
            $rows.Add([pscustomobject]@{
                    Id     = $r.Id
                    Kind   = $r.GetType().Name
                    Origin = $origin
                    State  = "$($r.RunspaceStateInfo.State)/$($r.RunspaceAvailability)"
                    Name   = "$($r.Name)"
                    Target = $target
                })
        }
    }
    catch { }
    return $rows.ToArray()
}

function Clear-VmSessionCache {
    <#
    .SYNOPSIS
    Dispose every PSDirect session this runspace cached. MUST be called by any
    Start-ThreadJob worker before it returns.
    .DESCRIPTION
    A ThreadJob shares the launcher's PROCESS but gets its own RUNSPACE, and both
    halves of that matter here (both measured, temp/test-threadjob-inner-runspace.ps1):
      * its $global: is a SEPARATE scope, so $global:ps_cache and the session ledger
        it writes are invisible to New-Lab's end-of-run cleanup;
      * a runspace it creates SURVIVES Remove-Job -- the job's own runspace is
        reclaimed, anything created inside it is not.
    So every PSDirect session a thread-job worker opens leaks a LocalRunspace +
    RemoteRunspace pair into the shared process for the life of the launcher. That is
    the leak: the ledger read created=10 disposeCalls=10 while 183 pairs stayed open,
    because the 183 were never created by the launcher's own runspace at all.
    Harmless in a Start-Job worker, where process exit would have done it anyway.
    #>
    $n = 0
    try {
        foreach ($key in @($global:ps_cache.Keys)) {
            try { Remove-VmSession $global:ps_cache[$key]; $n++ } catch { }
        }
        $global:ps_cache = @{}
    }
    catch { }
    try { $null = Clear-OrphanRunspaces -Force } catch { }
    # Counted on the AppDomain so the launcher can see that thread-job workers really
    # did run this -- the fix it verifies is otherwise completely silent.
    try {
        $st = Get-VmSessionStats
        $st['workerCleanups']++
        $st['workerDisposed'] += $n
    }
    catch { }
    return $n
}

# Dispose a PSSession and its owner runspace (if created by
# New-PSSessionWithTimeout).  Use this instead of Remove-PSSession
# directly when evicting sessions from ps_cache.
function Remove-VmSession {
    param([object]$Session)
    if (-not $Session) { return }
    # ORDER MATTERS. The PSSession's transport was established THROUGH
    # _OwnerRunspace (see New-PSSessionWithTimeout: "closing it can destroy the
    # PSSession whose transport was established through it"), so disposing the
    # runspace first leaves Remove-PSSession tearing down a session whose transport
    # is already gone -- it fails silently under -ErrorAction SilentlyContinue.
    # NOTE: reordering alone did NOT stop the leak (it kept climbing 238->324 with
    # the fix live), so the counters below measure whether disposal is being SKIPPED
    # or is being called and FAILING -- two different bugs that look identical from
    # the end-of-run runspace count.
    try { (Get-VmSessionStats)['disposeCalls']++ } catch { }
    # Decrement the creating caller's tally so byCaller ends up as NET undisposed.
    try {
        $tag = "$($Session._CallerTag)"
        if ($tag) { $bc = (Get-VmSessionStats)['byCaller']; $bc[$tag] = [int]$bc[$tag] - 1 }
    }
    catch { }
    try { Remove-PSSession $Session -ErrorAction SilentlyContinue } catch {}
    try {
        if ($Session._OwnerRunspace) {
            $Session._OwnerRunspace.Close()
            $Session._OwnerRunspace.Dispose()
            # Did it actually close? A silently-failed Close is indistinguishable
            # from never calling it, unless we look.
            try {
                if ("$($Session._OwnerRunspace.RunspaceStateInfo.State)" -ne 'Closed') {
                    (Get-VmSessionStats)['disposeLeftOpen']++
                }
            }
            catch { }
        }
        else { try { (Get-VmSessionStats)['disposeNoOwner']++ } catch { } }
    } catch { try { (Get-VmSessionStats)['disposeThrew']++ } catch { } }
}

# Evict + dispose EVERY cached PSDirect session for a VM and forget its
# last-known-good credential. Call this whenever a command against the VM
# times out / the channel is suspect: a session whose command hung must not
# be reused (it stays in ps_cache reporting Availability='Available' and the
# next caller rides the same wedged channel -> cascading hangs). The next
# Get-VmSession then builds a fresh, validated session.
function Remove-VmSessionFromCache {
    param(
        [string]$VmName,
        # When set, the cache ENTRY is removed (so the next Get-VmSession builds a
        # fresh session) but the underlying PSSession/runspace is NOT disposed.
        # Use this when an abandoned, still-running timed-out PSRemoting job is
        # bound to the session: disposing it now would let the job's late
        # state-change/transport callback (which fires when a subsequent reboot
        # breaks the VMBus) hit an already-disposed object on a threadpool thread
        # -> unhandled PSObjectDisposedException that kills the phase child
        # process. Leaking the session object (reaped at process exit) is the safe
        # trade -- the channel is dead and is no longer reachable via the cache.
        [switch]$LeakSession,
        # The job StopJobAsync'd onto this session. Parked with it so the reaper can tell
        # a quiet session from one that still has a live pipeline riding it.
        $AbandonedJob
    )
    if (-not $VmName) { return }
    $VmName = $VmName.Split('.')[0]
    foreach ($key in @($global:ps_cache.Keys)) {
        if ($key -like "$VmName-*") {
            $sess = $global:ps_cache[$key]
            $global:ps_cache.Remove($key)
            if (-not $LeakSession) { Remove-VmSession $sess }
            else {
                # Park the owner runspace AND the session rather than dropping them:
                # not disposing NOW is what keeps the late transport callback safe, but
                # it does not have to mean never. Passing the session matters -- parking
                # the runspace alone left the PSSession's RemoteRunspace open for the
                # life of the launcher, which is the bulk of the measured leak.
                try { Add-OrphanRunspace -Runspace $sess._OwnerRunspace -Session $sess -Reason 'session leaked (abandoned job)' -VmName $VmName -Job $AbandonedJob } catch { }
            }
            $dispNote = if ($LeakSession) { 'leaked (abandoned job may still ride it)' } else { 'disposed' }
            Write-Log "$VmName`: Evicted cached PSDirect session '$key' ($dispNote; timed out / unresponsive)" -Verbose
        }
    }
    if ($global:ps_lastGoodCred.ContainsKey($VmName)) { $global:ps_lastGoodCred.Remove($VmName) }
}

# Liveness probe + reboot escalation for a VM whose PSDirect command timed
# out. The caller has already evicted the wedged session, so this runs a
# fresh, short 'hostname' probe over a NEW session:
#   - guest answers  -> it is alive; the original command was merely slow /
#                       stuck. Do NOT reboot.
#   - probe also times out -> the channel is genuinely wedged. Reboot the VM
#                       to recover (bounded, single attempt).
# Returns @{ Alive; Rebooted }. The probe deliberately does NOT pass
# -RebootIfUnresponsive, so there is no recursion.
function Invoke-VmLivenessRecovery {
    param(
        [string]$VmName,
        [string]$VmDomainName,
        [switch]$Quiet
    )
    $outcome = @{ Alive = $false; Rebooted = $false }
    if (-not $Quiet) {
        Write-Log "$VmName`: PSDirect command timed out; running 30s liveness probe (hostname) before escalating." -Warning
    }
    $probe = Invoke-VmCommand -VmName $VmName -VmDomainName $VmDomainName -SuppressLog `
        -DisplayName "Liveness probe (hostname)" -AsJob -TimeoutSeconds 30 -SessionMaxRetries 1 `
        -ScriptBlock { $env:COMPUTERNAME }
    if ($probe -and -not $probe.ScriptBlockFailed -and $probe.ScriptBlockOutput) {
        $outcome.Alive = $true
        if (-not $Quiet) {
            Write-Log "$VmName`: Liveness probe OK (guest responded '$($probe.ScriptBlockOutput)'); NOT rebooting -- the original command was slow, not the channel." -Warning
        }
        return $outcome
    }
    # Probe failed too -> channel wedged. Reboot to recover.
    Write-Log "$VmName`: Liveness probe FAILED after session eviction; PSDirect channel is wedged. Rebooting VM to recover." -Warning
    $rebooted = Restart-UnresponsiveVm -VmName $VmName -MaxRetries 1 -WaitTimeSeconds 120
    $outcome.Rebooted = [bool]$rebooted
    # Drop any session that may have been re-created during the probe so the
    # post-reboot guest gets a fresh channel. -LeakSession: a probe that timed
    # out left an abandoned job bound to that session; disposing it here (right
    # after a reboot that just broke its transport) risks the same disposed-job
    # callback crash, so evict the cache entry but don't dispose the object.
    Remove-VmSessionFromCache -VmName $VmName -LeakSession
    if ($rebooted) {
        Write-Log "$VmName`: VM rebooted and is responsive again." -Warning
    }
    else {
        Write-Log "$VmName`: VM did NOT become responsive after reboot." -Failure
    }
    return $outcome
}

# Pre-flight channel remediation for the Phase 10 (maintenance) and Phase 11
# (validation) per-VM jobs. A VM can be fully Running with a healthy heartbeat
# yet have a WEDGED PowerShell Direct / VMBus channel -- New-PSSession -VMId
# times out, so the per-VM job can never open a session and fails with an opaque
# "Start-VMMaintenance returned no data" (Phase 10) or "ScriptBlock failed (no
# error detail returned)" (Phase 11). This probes the channel and, ONLY when it
# is genuinely wedged (guest Running + heartbeat alive + ChannelBroken), reboots
# the VM once to recover VMBus and re-probes to confirm.
#
# A healthy VM passes the first probe instantly (one cheap PSDirect round-trip,
# zero recovery cost), so the helper is safe to call unconditionally at the top
# of every per-VM job: only genuinely-broken machines pay the reboot, and each
# runs in its own parallel job. Linux guests and roles that aren't PSDirect-
# managed here (OSDClient / AADClient / StandaloneRootCA) are skipped via the
# VM note so they are never probed or rebooted.
function Repair-VmPSDirectChannel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$VmName,
        [Parameter(Mandatory = $false)]
        [string]$VmDomainName = "WORKGROUP",
        [Parameter(Mandatory = $false)]
        [string]$Phase = ""
    )

    $tag = if ($Phase) { "[Phase $Phase]: " } else { "" }

    $vm = Get-VM2 -Name $VmName -ErrorAction SilentlyContinue
    if (-not $vm) { return $true }                  # caller's normal path will report a missing VM
    if ($vm.State -ne 'Running') { return $true }   # never wake an intentionally-off VM here

    # Skip roles / OS that don't use the Windows PSDirect maintenance pipeline.
    # Mirrors the Linux + excluded-role checks in Start-VMMaintenance so a Linux
    # guest (no PSDirect) or an OSD/AAD client / offline root CA is never probed
    # or rebooted by this helper.
    $note = Get-VMNote -VMName $VmName
    if ($note) {
        if ($note.role -in @('OSDClient', 'AADClient', 'StandaloneRootCA')) { return $true }
        $noteIsLinux = $false
        if ($note.role -eq 'Proxy') { $noteIsLinux = $true }
        elseif ($note.PSObject.Properties.Name -contains 'osFamily' -and $note.osFamily -eq 'Linux') { $noteIsLinux = $true }
        elseif ($note.operatingSystem -and ($note.operatingSystem -like 'Ubuntu*' -or $note.operatingSystem -like 'Debian*' -or $note.operatingSystem -like 'Linux*')) { $noteIsLinux = $true }
        elseif ($note.deployedOS -and ($note.deployedOS -like 'Ubuntu*' -or $note.deployedOS -like 'Debian*' -or $note.deployedOS -like 'Linux*')) { $noteIsLinux = $true }
        if ($noteIsLinux) { return $true }
    }

    # Quick health probe. A healthy VM returns instantly -> no recovery cost.
    $probe = Invoke-VmCommand -VmName $VmName -VmDomainName $VmDomainName -SuppressLog `
        -DisplayName "PSDirect channel probe" -CommandReturnsBool -SessionMaxRetries 2 `
        -ScriptBlock { $true }
    if ($probe -and -not $probe.ScriptBlockFailed -and $probe.ScriptBlockOutput -eq $true) {
        return $true
    }

    # Probe failed. Only a wedged VMBus/PSDirect channel (guest Running, heartbeat
    # alive, ChannelBroken) is recoverable by a reboot. Auth / other failures are
    # left to the caller's normal path to report.
    $vm = Get-VM2 -Name $VmName -ErrorAction SilentlyContinue
    $hb = if ($vm) { "$($vm.Heartbeat)" } else { "N/A" }
    $channelBroken = ($probe -and $probe.ChannelBroken)
    $heartbeatAlive = ($hb -ne 'NoContact' -and $hb -ne 'N/A')
    if (-not ($channelBroken -and $heartbeatAlive)) {
        return $true
    }

    Write-Log "$tag$VmName`: PowerShell Direct channel is wedged (VM Running, heartbeat $hb). Rebooting once to recover VMBus before continuing." -Warning

    # Drop the dead cached session so the post-reboot guest gets a fresh channel.
    Remove-VmSessionFromCache -VmName $VmName -LeakSession

    $rebooted = Restart-UnresponsiveVm -VmName $VmName -MaxRetries 1 -WaitTimeSeconds 240
    if (-not $rebooted) {
        Write-Log "$tag$VmName`: VM did not come back responsive after recovery reboot; continuing -- the caller's normal path will report any remaining failure." -Warning
        return $false
    }

    # Restart-UnresponsiveVm only confirms RDP; confirm PSDirect specifically.
    $probe2 = Invoke-VmCommand -VmName $VmName -VmDomainName $VmDomainName -SuppressLog `
        -DisplayName "PSDirect channel re-probe" -CommandReturnsBool -SessionMaxRetries 3 `
        -ScriptBlock { $true }
    if ($probe2 -and -not $probe2.ScriptBlockFailed -and $probe2.ScriptBlockOutput -eq $true) {
        Write-Log "$tag$VmName`: PowerShell Direct channel recovered after reboot." -Success
        return $true
    }

    Write-Log "$tag$VmName`: PowerShell Direct channel still not responding after recovery reboot." -Warning
    return $false
}

function Get-VmSession {
    param (
        [Parameter(Mandatory = $true, HelpMessage = "VM Name")]
        [string]$VmName,
        [Parameter(Mandatory = $false, HelpMessage = "Domain Name to use for creating domain creds")]
        [string]$VmDomainName = "WORKGROUP",
        [Parameter(Mandatory = $false, HelpMessage = "Domain Account to use for creating domain creds")]
        [string]$VmDomainAccount,
        [Parameter(Mandatory = $false, HelpMessage = "Show VM Session errors, very noisy")]
        [switch]$ShowVMSessionError,
        [Parameter(Mandatory = $false, HelpMessage = "Max retry attempts (default 3). Reduce for tight polling loops.")]
        [int]$MaxRetries = 3,
        [Parameter(Mandatory = $false, HelpMessage = "Only try local/primary credentials. Skip domain-lookup fallback.")]
        [switch]$LocalOnly,
        [Parameter(Mandatory = $false, HelpMessage = "Suppress the final 'Could not create session' type=3 failure log. Use for best-effort liveness probes (e.g. Copy-ItemSafe heartbeat) where a miss during OOBE is expected and not an error.")]
        [switch]$Quiet,
        [Parameter(Mandatory = $false, HelpMessage = "Hashtable populated with channel diagnostics: ChannelBroken = true when PSDirect timed out or returned a VMBus error.")]
        [hashtable]$Diagnostics
    )


    $VmName = $VmName.Split(".")[0]

    $ps = $null

    # Cache key
    $cacheKey = $VmName + "-" + $VmDomainName

    # Set domain name to VmName when workgroup
    if ($VmDomainName -eq "WORKGROUP") {
        $vmDomainName = $VmName
    }

    # Get PS Session
    if ($VmDomainAccount) {
        $username = "$VmDomainName\$VmDomainAccount"
        $cacheKey = $cacheKey + "-" + $VmDomainAccount
    }
    else {
        $username = "$VmDomainName\$($Common.LocalAdmin.UserName)"
        $cacheKey = $cacheKey + "-" + $Common.LocalAdmin.UserName
    }

    Write-Log "$VmName`: Get-VmSession started with cachekey $cacheKey" -Verbose

    # ── Fast path: exact cache key match ──────────────────────────────────
    if ($global:ps_cache.ContainsKey($cacheKey)) {
        $ps = $global:ps_cache[$cacheKey]
        if ($ps.Availability -eq "Available") {
            Write-Log "$VmName`: Returning session for $userName from cache using key $cacheKey." -Verbose
            Set-VmSessionCacheStamp -Session $ps -VmName $VmName -Hit
            return $ps
        }
        else {
            $global:ps_cache.Remove($cacheKey)
            $global:ps_lastGoodCred.Remove($VmName)
            Remove-VmSession $ps
        }
    }

    # ── Fast path: ANY available session for this VM ──────────────────────
    # Between phases the caller often changes VmDomainName (WORKGROUP →
    # domain or vice-versa), causing a cache miss even though a perfectly
    # good session already exists under a different key.
    foreach ($existingKey in @($global:ps_cache.Keys)) {
        if ($existingKey -like "$VmName-*") {
            $existingPs = $global:ps_cache[$existingKey]
            if ($existingPs.Availability -eq "Available") {
                Write-Log "$VmName`: Reusing existing session from key '$existingKey' (caller asked for '$cacheKey')." -Verbose
                Set-VmSessionCacheStamp -Session $existingPs -VmName $VmName -Hit
                return $existingPs
            }
            else {
                $global:ps_cache.Remove($existingKey)
                $global:ps_lastGoodCred.Remove($VmName)
                Remove-VmSession $existingPs
            }
        }
    }

    $vm = get-vm2 -Fallback -Name $VmName
    if (-not $vm) {
        Write-Log "[Get-VMSession] $VmName`: Failed to find VM named $VmName" -Failure
        return $null
    }

    # ── Build ordered credential list ─────────────────────────────────────
    # Each entry: @{ Tag; Username; CacheKey }.  The 'primary' credential
    # (what the caller asked for) is always present.  Additional fallbacks
    # are appended when they differ from primary.  If a previous call for
    # this VM already succeeded with a known credential tag, that entry is
    # moved to the front so we try it first (avoids 30s timeout on wrong
    # creds).
    $credEntries = [System.Collections.Generic.List[hashtable]]::new()

    # Primary: what the caller asked for
    $credEntries.Add(@{ Tag = 'primary'; Username = $username; CacheKey = $cacheKey })

    # Local fallback: VMNAME\localadmin (only if different from primary)
    $localUser = "$VmName\$($Common.LocalAdmin.UserName)"
    $localCacheKey = "$VmName-WORKGROUP-$($Common.LocalAdmin.UserName)"
    if ($localUser -ne $username) {
        $credEntries.Add(@{ Tag = 'local'; Username = $localUser; CacheKey = $localCacheKey })
    }

    # Domain-lookup fallback: use the domain from Get-List VM record.
    # Skip in job context — jobs know the domain from deployConfig, and
    # Get-List's cold path (Get-VM + bulk warmup) is extremely expensive
    # when 20+ job workers all hit it simultaneously.
    if (-not $LocalOnly -and -not $Common.InJob) {
        $vmRecord = Get-List -type VM | Where-Object { $_.VmName -eq $VmName }
        if ($vmRecord -and $vmRecord.Domain) {
            $domainLookupUser = "$($vmRecord.Domain)\$($Common.LocalAdmin.UserName)"
            $domainLookupCacheKey = "$VmName-$($vmRecord.Domain)-$($Common.LocalAdmin.UserName)"
            if ($domainLookupUser -ne $username -and $domainLookupUser -ne $localUser) {
                $credEntries.Add(@{ Tag = 'domain-lookup'; Username = $domainLookupUser; CacheKey = $domainLookupCacheKey })
            }
        }
    }

    # Administrator fallback: DOMAIN\Administrator (after DC promotion)
    if (-not $LocalOnly -and $VmDomainName -ne "WORKGROUP" -and $VmDomainName -ne $VmName) {
        $adminUser = "$VmDomainName\Administrator"
        $adminCacheKey = "$VmName-$VmDomainName-Administrator"
        if ($adminUser -ne $username) {
            $credEntries.Add(@{ Tag = 'administrator'; Username = $adminUser; CacheKey = $adminCacheKey })
        }
    }

    # If we remember which credential last worked, move it to the front
    $lastGood = $global:ps_lastGoodCred[$VmName]
    if ($lastGood) {
        $idx = -1
        for ($i = 0; $i -lt $credEntries.Count; $i++) {
            if ($credEntries[$i].Tag -eq $lastGood) { $idx = $i; break }
        }
        if ($idx -gt 0) {
            $entry = $credEntries[$idx]
            $credEntries.RemoveAt($idx)
            $credEntries.Insert(0, $entry)
            Write-Log "$VmName`: Trying last-known-good credential '$lastGood' ($($entry.Username)) first." -Verbose
        }
    }

    $failCount = 0
    [bool]$sawChannelBroken = $false
    while ($true) {
        $ps = $null
        $failCount++
        if ($failCount -gt 2) {
            start-sleep -seconds 5
        }

        if ($failCount -gt $MaxRetries) {
            break
        }

        # Skip New-PSSession entirely if the VM is not running.
        # Avoids 30s+ timeout per credential attempt on a dead/rebooting VM.
        $vmState = (Get-VM2 -Name $VmName -ErrorAction SilentlyContinue).State
        if ($vmState -ne 'Running') {
            Write-Log "$VmName`: VM state is '$vmState'; skipping session attempt $failCount/$MaxRetries" -Verbose
            continue
        }

        # Try each credential in order; stop on first success
        $triedNames = @()
        foreach ($entry in $credEntries) {
            $triedNames += $entry.Username
            $creds = New-Object System.Management.Automation.PSCredential ($entry.Username, $Common.LocalAdmin.Password)
            Write-Log "$VmName`: Trying credential '$($entry.Username)' (tag=$($entry.Tag))." -Verbose
            $connectResult = New-PSSessionWithTimeout -Name $VmName -VMId $vm.vmID -Credential $creds
            $ps = $connectResult.Session
            if ($ps -and $ps.Availability -eq "Available") {
                $cacheKey = $entry.CacheKey
                # This slot may already hold a session: two callers can race a create for the
                # same VM (parallel phase workers, or a worker and the launcher). The bare
                # assignment that used to be here dropped the loser on the floor -- never handed
                # to Remove-VmSession, so its guest-side PowerShell Direct host survived for the
                # life of the VM. Measured: 142 orphaned hosts / 14.8 GB across a 17-VM lab.
                $existingSession = $global:ps_cache[$cacheKey]
                if ($existingSession -and -not [object]::ReferenceEquals($existingSession, $ps)) {
                    if ("$($existingSession.State)" -eq 'Opened' -and "$($existingSession.Availability)" -eq 'Available') {
                        # We lost. Dispose OURS -- nothing has a reference to it yet, so this is
                        # the one session here that is unambiguously safe to tear down inline.
                        try { (Get-VmSessionStats)['cacheRaceLost']++ } catch { }
                        Remove-VmSession $ps
                        return $existingSession
                    }
                    # Slot holds a dead session. Park it: another thread may still be riding it,
                    # and disposing something with a live pipeline is the documented cause of the
                    # disposed-PSJob phase crash.
                    try { (Get-VmSessionStats)['cacheEvicted']++ } catch { }
                    Add-OrphanRunspace -Runspace $existingSession._OwnerRunspace -Session $existingSession -Reason 'cache slot overwritten' -VmName $VmName
                }
                $global:ps_lastGoodCred[$VmName] = $entry.Tag
                Write-Log "$VmName`: Created session using $($entry.Username). CacheKey [$cacheKey]" -Success -Verbose
                $global:ps_cache[$cacheKey] = $ps
                Set-VmSessionCacheStamp -Session $ps -VmName $VmName
                Set-VmSessionPipelineEvent -Session $ps -Kind 'created'
                return $ps
            }
            # Detect channel-broken indicators: timeout means VMBus is hung;
            # "socket target process has ended" / "background process reported
            # an error" mean the guest-side PSDirect host crashed.
            # Auth errors (access denied, logon failure) are NOT channel-broken.
            $channelBroken = $false
            if ($connectResult.TimedOut) {
                $sawChannelBroken = $true
                $channelBroken = $true
            }
            elseif ($connectResult.ErrorMessage -match 'socket target process has ended|background process reported an error') {
                $sawChannelBroken = $true
                $channelBroken = $true
            }
            Remove-VmSession $ps

            # When the transport itself is dead -- the connect timed out (guest
            # never answered the hvsocket) or the guest-side PSDirect host
            # crashed -- cycling through the remaining credentials is pointless:
            # they all ride the SAME broken channel and would each burn the full
            # connect timeout for nothing. Credential cycling only helps for AUTH
            # failures (access denied / logon failure), which return fast and are
            # NOT channel-broken. Stop this pass immediately and let the outer
            # retry loop (with backoff) decide whether to try again.
            if ($channelBroken) {
                Write-Log "$VmName`: connect did not respond on '$($entry.Username)' (channel broken, not an auth error); skipping remaining credentials this pass." -Verbose
                break
            }
        }

        $triedList = $triedNames -join ', '
        if (-not $Quiet -and ($ShowVMSessionError.IsPresent -or ($failCount -eq $MaxRetries))) {
            Write-Log "$VmName`: Failed to establish a session (attempt $failCount/$MaxRetries). Tried: $triedList" -Warning
        }
        elseif ($Quiet) {
            # Quiet probe: keep it in the log for diagnostics but never on screen.
            Write-Log "$VmName`: Failed to establish a session (attempt $failCount/$MaxRetries). Tried: $triedList" -Warning -Verbose -LogOnly
        }
        else {
            Write-Log "$VmName`: Failed to establish a session (attempt $failCount/$MaxRetries). Tried: $triedList" -Warning -Verbose
        }
    }
    # Populate diagnostics for the caller so it knows WHY we failed
    if ($Diagnostics -and $sawChannelBroken) {
        $Diagnostics.ChannelBroken = $true
    }
    # Best-effort probes (e.g. Copy-ItemSafe heartbeat, MaxRetries=1) routinely
    # miss while the guest is still in OOBE; that is expected, not a failure.
    # -Quiet downgrades this from a type=3 error (which makes Phase 1 look
    # broken) to a log-only verbose entry: it's recorded in the log for
    # diagnostics but never spews the console.
    if ($Quiet) {
        Write-Log "$VmName`: Could not create session after $MaxRetries retries (quiet probe)." -LogOnly -Verbose
    }
    else {
        Write-Log "$VmName`: Could not create session after $MaxRetries retries." -Failure
    }
}


function Invoke-ChkdskScanForCorruption {
    # When a file operation fails with a cyclic-redundancy-check / I/O read error,
    # the volume the file lives on has filesystem or media damage. Run the ONLINE
    # scanner 'chkdsk <drive> /scan' (read-only, no dismount) up to $Passes times to
    # let NTFS self-heal minor corruption via the spot-verifier/spot-fixer. Returns
    # $true when the FINAL pass reports the volume clean (self-repaired or never
    # damaged), $false when errors remain (needs offline /f /r or the disk is failing).
    param (
        [Parameter(Mandatory = $true)] [string]$Path,
        [int]$Passes = 2
    )

    $drive = $null
    try { $drive = Split-Path -Path $Path -Qualifier -ErrorAction SilentlyContinue } catch {}
    if ([string]::IsNullOrWhiteSpace($drive)) {
        Write-Log "Invoke-ChkdskScanForCorruption: could not determine the drive for '$Path'; skipping chkdsk." -Warning
        return $false
    }

    if (-not (Get-Command chkdsk.exe -ErrorAction SilentlyContinue)) {
        Write-Log "Invoke-ChkdskScanForCorruption: chkdsk.exe not available; skipping scan of '$drive'." -Warning
        return $false
    }

    $lastExit = -1
    for ($pass = 1; $pass -le $Passes; $pass++) {
        Write-Log "Corruption detected on '$drive'; running online scan 'chkdsk $drive /scan' (pass $pass of $Passes)..." -Warning
        try {
            $out = & chkdsk.exe $drive /scan 2>&1
            $lastExit = $LASTEXITCODE
            foreach ($line in $out) {
                if ($line -and -not [string]::IsNullOrWhiteSpace($line.ToString())) {
                    Write-Log ("chkdsk $drive /scan: " + $line.ToString().Trim()) -LogOnly
                }
            }
            Write-Log "chkdsk $drive /scan pass $pass exit code: $lastExit" -LogOnly
        }
        catch {
            Write-Log "chkdsk $drive /scan pass $pass threw: $($_.Exception.Message)" -Warning
            $lastExit = -1
        }
    }

    # chkdsk /scan exit code: 0 = no problems found (clean, or spot-fixed and now
    # clean). Anything else = problems remain / could not be checked.
    if ($lastExit -eq 0) {
        Write-Log "chkdsk $drive /scan reports the volume is clean after $Passes pass(es); continuing." -Success
        return $true
    }

    Write-Log "chkdsk $drive /scan did NOT clear the corruption (final exit $lastExit). '$drive' likely needs an offline 'chkdsk $drive /f /r' and/or the physical disk is failing (check SMART). Move the workspace/downloads to a healthy drive." -Failure
    return $false
}


function Get-Tools {
    param (
        [Parameter(Mandatory = $false, HelpMessage = "Skip Hash Testing of downloaded files.")]
        [switch]$IgnoreHashFailure,
        [Parameter(Mandatory = $false, HelpMessage = "Force redownloading the file, if it exists.")]
        [switch]$ForceDownloadFiles,
        [Parameter(Mandatory = $false, HelpMessage = "Optional VM Name.")]
        [object]$VmName,
        [Parameter(Mandatory = $false, HelpMessage = "Optional Tool Name.")]
        [object]$ToolName,
        [Parameter(Mandatory = $false)]
        [switch]$UseCDN,
        [Parameter(Mandatory = $false)]
        [switch]$IncludeOptional,
        [Parameter(Mandatory = $false, HelpMessage = "Inject tools inside all Virtual Machines.")]
        [switch]$Inject,
        [Parameter(Mandatory = $false, HelpMessage = "Dry Run.")]
        [switch]$WhatIf
    )

    $allSuccess = $true


    $ToolName | Where-Object { $_ -NotIn $Common.AzureFileList.Tools.Name -or (-not $_) } | ForEach-Object {
        if (-not [String]::IsNullOrWhiteSpace($_)) {
            Write-Log "Invalid Tool Name ($_) specified." -Warning
            return $false
        }
    }
    #if ($ToolName -and $Common.AzureFileList.Tools.Name -notcontains $ToolName) {
    #    Write-Log "Invalid Tool Name ($ToolName) specified." -Warning
    #    return $false
    #}

    if ($VmName) {
        $Inject = $true
    }

    Write-Log "Downloading/Verifying Tools that need to be injected in Virtual Machines..." -Activity
    foreach ($tool in $Common.AzureFileList.Tools) {


        if ($ToolName -and ($tool.Name -NotIn $ToolName)) { continue }

        if (-not $ToolName -and $tool.Optional -and -not $IncludeOptional.IsPresent) {
            if (-not $tool.Roles) {
                continue
            }
        }

        $name = $tool.Name
        $url = $tool.URL
        $fileTargetRelative = $tool.Target
        $fileName = Split-Path $url -Leaf
        if ($fileName.Contains("?")) {
            $fileName = $fileName.Split("?")[0]
        }
        $fileNameForDownload = Join-Path "tools" $fileName
        $downloadPath = Join-Path $Common.AzureToolsPath $fileName

        if (-not $tool.IsPublic) {
            $url = "$($StorageConfig.StorageLocation)/$url"
        }

        if (-not $tool.md5) {
            Write-Log "Downloading/Verifying '$name' without hash" -SubActivity
            $worked = Get-File -Source $url -Destination $downloadPath -DisplayName "Downloading '$filename' to $downloadPath..." -Action "Downloading" -UseBITS -UseCDN:$UseCDN -WhatIf:$WhatIf
        }
        else {
            Write-Log "Downloading/Verifying '$name'" -SubActivity
            $tempworked = Get-FileWithHash -FileName $fileNameForDownload -FileDisplayName $name -FileUrl $url -ExpectedHash $tool.md5 -UseBITS -ForceDownload:$ForceDownloadFiles -IgnoreHashFailure:$IgnoreHashFailure -hashAlg "MD5" -UseCDN:$UseCDN -WhatIf:$WhatIf
            $worked = $tempworked.success
        }

        if (-not $worked) {
            Write-RedX "Failed to Download or Verify '$name'"
            $allSuccess = $false
        }

        # Move to staging dir
        if ($worked) {

            # Create final destination directory, if not present
            $fileDestination = Join-Path $Common.StagingInjectPath $fileTargetRelative
            if (-not (Test-Path $fileDestination)) {
                $folderToCreate = $fileDestination
                if ($fileDestination.Contains(".")) {
                    $folderToCreate = Split-Path $fileDestination -Parent
                }
                New-Item -Path $folderToCreate -ItemType Directory -Force | Out-Null
            }

            # File downloaded
            $extractIfZip = $tool.ExtractFolderIfZip
            if (Test-Path $downloadPath) {
                if ($downloadPath.ToLowerInvariant().EndsWith(".zip") -and $extractIfZip -eq $true) {
                    # Use a marker file to track which zip MD5 was last extracted.
                    # Timestamp comparison is unreliable because Get-FileWithHash
                    # can touch the download file during verification, and
                    # Expand-Archive -Force rewrites all extracted file timestamps.
                    $markerPath = Join-Path $fileDestination ".extracted-md5"
                    $currentMd5 = if ($tool.md5) { $tool.md5 } else { (Get-FileHash $downloadPath -Algorithm MD5).Hash }
                    $skipExtract = $false
                    if ((Test-Path $fileDestination) -and (Test-Path $markerPath)) {
                        $lastMd5 = Get-Content $markerPath -Raw -ErrorAction SilentlyContinue
                        if ($lastMd5 -and $lastMd5.Trim() -eq $currentMd5) {
                            $skipExtract = $true
                        }
                    }
                    if ($skipExtract) {
                        Write-Log -LogOnly "Staging for $fileName already up-to-date, skipping extract."
                    }
                    else {
                        Write-Log -LogOnly "Extracting $fileName to $fileDestination."
                        Expand-Archive -Path $downloadPath -DestinationPath $fileDestination -Force
                        $currentMd5 | Set-Content $markerPath -Force -ErrorAction SilentlyContinue
                    }
                }
                else {
                    # Skip copy if the staged file has the same size and the
                    # download hash hasn't changed
                    $skipCopy = $false
                    if (Test-Path $fileDestination) {
                        $srcItem = Get-Item $downloadPath
                        $dstItem = Get-Item $fileDestination -ErrorAction SilentlyContinue
                        if ($dstItem -and -not $dstItem.PSIsContainer -and $dstItem.Length -eq $srcItem.Length) {
                            $skipCopy = $true
                        }
                    }
                    if ($skipCopy) {
                        Write-Log -LogOnly "Staging for $fileName already up-to-date, skipping copy."
                    }
                    else {
                        Write-Log -LogOnly "Copying $fileName to $fileDestination."
                        $copied = $false
                        $copyAttempt = 0
                        while (-not $copied -and $copyAttempt -lt 2) {
                            $copyAttempt++
                            try {
                                Copy-Item -Path $downloadPath -Destination $fileDestination -Force -Confirm:$false -ErrorAction Stop
                                $copied = $true
                            }
                            catch {
                                $copyErr = $_.Exception.Message
                                Write-Log "Copy of '$fileName' to staging failed (attempt $copyAttempt): $copyErr" -Warning
                                # A cyclic-redundancy-check / I/O read error means the CACHED
                                # download at $downloadPath is corrupt on disk (bad sector /
                                # failing volume). Purge the corrupt cache (and any partial
                                # destination) and re-download once, then retry the copy.
                                $isCorruptRead = $copyErr -match 'cyclic redundancy|CRC|data error|I/O error|IO error|corrupt'
                                if ($isCorruptRead -and $copyAttempt -lt 2) {
                                    # Filesystem/media damage. Attempt an online self-repair
                                    # (chkdsk /scan x2). If it can't clear it, the error was
                                    # already reported by the helper -- give up on this file.
                                    $volumeClean = Invoke-ChkdskScanForCorruption -Path $downloadPath -Passes 2
                                    if (-not $volumeClean) {
                                        $allSuccess = $false
                                        break
                                    }
                                    Write-Log "Corrupt cached download detected for '$fileName'; purging '$downloadPath' and re-downloading." -Warning
                                    try { Remove-Item -Path $downloadPath -Force -Confirm:$false -ErrorAction SilentlyContinue } catch {}
                                    # $fileDestination is usually the staging FOLDER (Copy-Item
                                    # drops the file into it); only the single staged file may be
                                    # a partial/corrupt copy. Never Remove-Item the folder itself
                                    # (that would recurse-delete every staged tool and prompt for
                                    # -Recurse). Resolve the specific staged file and remove only that.
                                    $stagedFilePath = $fileDestination
                                    if (Test-Path -LiteralPath $fileDestination -PathType Container) {
                                        $stagedFilePath = Join-Path $fileDestination (Split-Path $downloadPath -Leaf)
                                    }
                                    if ((Test-Path -LiteralPath $stagedFilePath -PathType Leaf)) {
                                        try { Remove-Item -LiteralPath $stagedFilePath -Force -Confirm:$false -ErrorAction SilentlyContinue } catch {}
                                    }
                                    if ($tool.md5) {
                                        $rd = Get-FileWithHash -FileName $fileNameForDownload -FileDisplayName $name -FileUrl $url -ExpectedHash $tool.md5 -UseBITS -ForceDownload -IgnoreHashFailure:$IgnoreHashFailure -hashAlg "MD5" -UseCDN:$UseCDN
                                        $redownloaded = $rd.success
                                    }
                                    else {
                                        $redownloaded = Get-File -Source $url -Destination $downloadPath -DisplayName "Re-downloading '$fileName' to $downloadPath..." -Action "Downloading" -UseBITS -UseCDN:$UseCDN
                                    }
                                    if (-not $redownloaded) {
                                        Write-Log "Re-download of '$fileName' failed; cannot stage it." -Failure
                                        $allSuccess = $false
                                        break
                                    }
                                }
                                else {
                                    # Not a recoverable corrupt-read, or the retry after
                                    # re-download also failed -- give up on this file.
                                    Write-Log "Giving up staging '$fileName' after $copyAttempt attempt(s)." -Failure
                                    $allSuccess = $false
                                    break
                                }
                            }
                        }
                    }
                }
            }
        }
    }


    $injected = $allSuccess
    if ($Inject.IsPresent -and $allSuccess) {
        Write-Log "Injecting $ToolName to $VmName..." -Activity
        $HashArguments = @{
            WhatIf          = $WhatIf
            IncludeOptional = $IncludeOptional
        }

        if ($VmName) { $HashArguments.Add("VmName", $VmName) }
        if ($ToolName) {
            $HashArguments.Add("ToolName", $ToolName)
            $HashArguments.Add("Force", $true)
        }
        $HashArguments.Add("ShowProgress", $true)
        $injected = Install-Tools @HashArguments

    }

    if (-not $Inject.IsPresent) {
        Write-Host2
    }

    return $injected
}

function Install-Tools {

    param (
        [Parameter(Mandatory = $false, HelpMessage = "Optional VM Name.")]
        [object]$VmName,
        [Parameter(Mandatory = $false, HelpMessage = "Optional ToolName Name.")]
        [object]$ToolName,
        [Parameter(Mandatory = $false)]
        [switch]$IncludeOptional,
        [Parameter(Mandatory = $false)]
        [switch]$ShowProgress,
        [Parameter(Mandatory = $false)]
        [boolean]$SkipAutoDeploy = $false,
        [Parameter(Mandatory = $false, HelpMessage = "Dry Run.")]
        [switch]$WhatIf,
        [switch]$Force
    )

    Write-Log "Install-Tools called. $($VmName) $($ToolName -join ",")"
    $swToolList = [System.Diagnostics.Stopwatch]::StartNew()
    $toolListPath = 'full SmartUpdate'
    $staleState = 0
    if ($VmName) {
        # -SmartUpdate refreshes EVERY VM (Get-VM, then Update-VMFromHyperV per VM, then a
        # disk-cache write) just to select one, and its 3s throttle is per-process so a job
        # per VM never shares it: 46.6s median on an 18-VM lab vs 2.4s on a 6-VM one. Same
        # vmms logjam Get-VM2 already dodges for job workers. Take the cached entry and
        # refresh only this VM's State, the one field acted on below.
        $allVMs = @(Get-List -Type VM | Where-Object { $_.vmName -in $VmName })
        $toolListPath = 'cached + per-VM state'
        if ($allVMs.Count -ne @($VmName).Count) {
            # Cache miss (e.g. a VM created earlier in this run): pay for the full refresh.
            $allVMs = @(Get-List -Type VM -SmartUpdate | Where-Object { $_.vmName -in $VmName })
            $toolListPath = 'cache miss -> full SmartUpdate'
        }
        foreach ($vmEntry in $allVMs) {
            $liveVm = Get-VM -Name $vmEntry.vmName -ErrorAction SilentlyContinue
            if ($liveVm) {
                $vmEntry | Add-Member -MemberType NoteProperty -Name 'state' -Value ($liveVm.State.ToString()) -Force
            }
            else {
                # Falling back to the cached state is a correctness risk (the caller refuses to
                # inject unless State is Running), so never let it pass unremarked.
                $staleState++
                Write-Log "Install-Tools: could not read live state for $($vmEntry.vmName); using cached state '$($vmEntry.state)'." -Warning
            }
        }
    }
    else {
        $allVMs = Get-List -Type VM -SmartUpdate | Where-Object { $_.vmbuild -eq $true } | Sort-Object -Property State -Descending
    }
    $swToolList.Stop()
    Write-Log ("[StepTiming] {0} ToolInject-GetList completed in {1} seconds ({2} VM(s) matched, {3}{4})" -f `
            ($VmName -join ','), [Math]::Round($swToolList.Elapsed.TotalSeconds, 1), @($allVMs).Count, $toolListPath,
        $(if ($staleState -gt 0) { ", $staleState stale state" } else { '' })) -LogOnly

    $success = $true

    $InjectToolsScriptBlock = {
        param (
            [object] $vm,
            [array] $ToolName,
            [boolean] $force = $true,
            [boolean] $SkipAutoDeploy = $false,
            [string] $ScriptRoot
        )

        #$rootPath = Split-Path $ScriptRoot -Parent
        # Single-VM callers reach this via .Invoke() from a phase job that ALREADY loaded
        # Common.ps1. Re-dot-sourcing it buys nothing and costs ~2.4s solo -- 12.6s median,
        # 48.9s worst under 22-way Phase 2 concurrency -- once per VM.
        $swBoot = [System.Diagnostics.Stopwatch]::StartNew()
        $commonAlreadyLoaded = $false
        try {
            $commonAlreadyLoaded = [bool]($Common -and $Common.Initialized -and (Get-Command Write-Log -ErrorAction SilentlyContinue))
        }
        catch { $commonAlreadyLoaded = $false }
        if (-not $commonAlreadyLoaded) {
            if (test-path $ScriptRoot\Common.ps1) {
                . $ScriptRoot\Common.ps1 -InJob
            }
            else {
                $rootPath = Split-Path $ScriptRoot -Parent
                . $rootPath\Common.ps1 -InJob
            }
        }
        $swBoot.Stop()

        $ToolName = $ToolName | ForEach-Object { $_ }
        $TotalCount = $ToolName.Count
        $success = $true
        # Benign skips: not a failure of injection, just nothing to do for this VM.
        if ($vm.role -eq "OSDClient") { return $true } # no injecting inside OSD client
        if ($vm.vmbuild -eq $false) { return $true } # don't touch VM's we didn't create

        $vmName = $vm.vmName
        Write-Log ("[StepTiming] {0} ToolInject-Bootstrap completed in {1} seconds ({2})" -f `
                $vmName, [Math]::Round($swBoot.Elapsed.TotalSeconds, 1),
            $(if ($commonAlreadyLoaded) { 'reused already-loaded Common' } else { 'dot-sourced Common.ps1 -InJob' })) -LogOnly
        Write-Log "$vmName`: Injecting Tools $($ToolName -join ",") to C:\tools directory inside the VM" -Activity

        # Get VM Session
        if ($vm.State -ne "Running") {
            Write-Log "$vmName`: VM is not running. Start the VM and try again." -Warning
            return $false
        }

        $swSession = [System.Diagnostics.Stopwatch]::StartNew()
        $ps = Get-VmSession -VmName $vm.vmName -VmDomainName $vm.domain
        $swSession.Stop()
        Write-Log ("[StepTiming] {0} ToolInject-GetSession completed in {1} seconds" -f $vmName, [Math]::Round($swSession.Elapsed.TotalSeconds, 1)) -LogOnly
        if (-not $ps) {
            Write-Log "$vmName`: Failed to get a session with the VM." -Failure
            return $false
        }

        $i = 0
        $ToolList = @()
        foreach ($tool in $Common.AzureFileList.Tools) {

                $i++
                if ($TotalCount -gt 0) {
                    $percent = [Math]::Round(($i / $TotalCount) * 100)
                }
                else {
                    $percent = 100
                }
                #SkipAutoDeploy is set when cmoptions.PrePopulateObjects is true
                if ($SkipAutoDeploy) {
                    if ($tool.Appinstall -eq $true) {
                        if ($vm.operatingSystem.Contains("Windows 1")) {
                            if ($vm.Role -eq "DomainMember") {
                                #If this is a Domain Member, windows 10 or 11, and the app is auto deployed.. do not add it to tools
                                Write-Progress2 "Injecting tools" -Status "Skipping $($tool.Name) on $VmName, should be deployed via CM" -Log
                                continue

                            }
                        }
                    }
                }

                if (-not $ToolName -and $tool.NoUpdate) {
                    Write-Log "$vmName`: Skipped injecting '$($tool.Name) since it's marked NoUpdate." -Verbose
                    continue
                }

                if ($ToolName -and $tool.Name -NotIn $ToolName) {
                    Write-Log "$vmName`: Skipped injecting '$($tool.Name) since it's not in the list." -Verbose
                    continue
                }

                #Write-Progress2 "Injecting tools" -Status "Preparing to Inject $($tool.Name) to $VmName" -Log

                $stop = $true
                if (-not $ToolName -and ($tool.Optional -and -not $IncludeOptional.IsPresent)) {
                    if ($tool.Roles) {
                        if ($vm.Role -in $tool.Roles) {
                            Write-Progress2 "Injecting tools" -Status "Injecting $($tool.Name) to $VmName (Stop1 False)" -Log
                            $stop = $false
                        }
                        if ($vm.InstallSUP -and "WSUS" -in $tool.Roles) {
                            Write-Progress2 "Injecting tools" -Status "Injecting $($tool.Name) to $VmName (Stop2 False)"  -Log
                            $stop = $false
                        }
                    }
                    if ($stop) {
                        continue
                    }
                }

                $ToolList += $tool
                Write-Log -LogOnly "[Injecting tool] Injecting $($tool.Name) to $($vm.vmName) Percent: $percent"
                #Write-Progress2 "Injecting tool" -Status "Injecting $($tool.Name) to $($vm.vmName)" -Log -percentcomplete $percent

            }
            $fast = $true
            if ($vm.operatingSystem -like "*2016*") {
                $fast = $false
            }
            $worked = Copy-ToolToVM -Tool $ToolList -VMName $vm.vmName -WhatIf:$WhatIf -Fast:$fast -Force:$Force
            if (-not $worked) {
                $success = $false
                Write-Progress2 "Injecting tools" -Status "Failed to Inject at least one tool to $VmName" -Log
                # NOT -OutputStream. Write-Log -OutputStream does Write-Output, which lands
                # in THIS function's output stream -- and every caller assigns the result
                # ($injected = Install-Tools ...), so the log object was captured into
                # $injected alongside $false. That made $injected a 2-element array, which
                # is truthy, so `if (-not $injected)` was FALSE on failure: the Phase 2
                # wedged-VM detection + hard-reset + retry never ran, and the phase tally
                # never saw the failure either (CS4-CS1SQL: 'Failed to inject at least one
                # tool' at 22:47 -> '[Phase 2] 11 success, 0 warnings, 0 failures' at 22:51,
                # then a Phase 11 failure 5 hours later). The caller emits the OutputStream
                # line now, where it actually reaches the job's output stream.
                Write-Log "$vmName`: Failed to inject at least one tool" -Failure
                start-sleep -seconds 5

            }
            else {
                #Write-Progress2 "Injecting tools" -Status "Injected $($tool.Name) to $VmName" -Log
                Write-Log "$vmName`: Successfully injected '$($ToolList.Name -Join ",")'" -Success

            }

            if ($success) {
                Write-Progress2 "Injecting tools" -Status "All Tools successfully copied to  $VmName" -Log -Completed
                return $true
            }
            else {
                Write-Progress2 "Injecting tools" -Status "All Tools copied to $VmName, but at least 1 has failed." -Log -Completed
                return $false
            }

    }
    Write-Log -Verbose "Injecting Tools $($ToolName -join ",") to Virtual Machines $($allVMs.vmName -join ",")"
    if ($allVMs.Count -gt 1) {
        $start = Start-NormalJobs -machines $allVMs -ScriptBlock $InjectToolsScriptBlock -Phase "Tool Install" -argument1 $ToolName -argument2 $force -argument3 $SkipAutoDeploy

        $result = Wait-Phase -Phase "Tool Install" -Jobs $start.Jobs -AdditionalData $start.AdditionalData

        if ($ShowProgress) {
            $countWorked = $result.Success
            $countFailed = $result.Failed

            Write-Host
            Write-Log "Finished Injecting Tools. Success: $countWorked; Failures: $countFailed" -SubActivity

            Write-Progress2 "Injecting tools Completed. Success: $countWorked; Failures: $countFailed" -Status "Done" -Completed
        }
        $success = ($result.Failed -eq 0)
        Start-Sleep -seconds 3
        clear-host
    }
    else {
        $success = $InjectToolsScriptBlock.Invoke($allVMs[0], $ToolName, $force, $SkipAutoDeploy, $PSScriptRoot)
        if ($ShowProgress) {

            Write-Log "Finished Injecting Tools. Success: $success" -SubActivity

            Write-Progress2 "Injecting tools Completed. Success: $success" -Status "Done" -Completed
        }
    }

    # Stale tool zip cleanup is handled by the caller (Start-Phase post-P2
    # block) after all parallel jobs complete. Do NOT clean here — parallel
    # jobs would delete zips that other in-flight jobs still need.

    return $success
}

function Clean-StaleToolZips {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '',
        Justification = 'Established internal helper name; renaming would touch its call sites across the codebase.')]
    param()
    # Scan all per-VM toolhash cache files to find which tool zips are
    # actively referenced, then delete any tools-*.zip that isn't needed.
    # This prevents 200+ MB zips from accumulating across reruns when
    # fingerprints change (e.g. a tool is added/removed).
    try {
        $tempPath = $Common.TempPath
        if (-not $tempPath -or -not (Test-Path $tempPath)) { return }

        $cacheFiles = Get-ChildItem -Path $tempPath -Filter "toolhash-*.json" -File -ErrorAction SilentlyContinue
        if (-not $cacheFiles) { return }

        $activeZips = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($cf in $cacheFiles) {
            try {
                $cached = Get-Content $cf.FullName -Raw | ConvertFrom-Json
                if ($cached.ZipFiles) {
                    foreach ($zf in $cached.ZipFiles) {
                        $null = $activeZips.Add($zf)
                    }
                }
            }
            catch {}
        }

        if ($activeZips.Count -eq 0) { return }

        $allZips = Get-ChildItem -Path $tempPath -Filter "tools-*.zip" -File -ErrorAction SilentlyContinue
        foreach ($zip in $allZips) {
            if (-not $activeZips.Contains($zip.Name)) {
                $sizeMB = [Math]::Round($zip.Length / 1MB, 1)
                Write-Log "Cleaning stale tool zip: $($zip.Name) (${sizeMB} MB)" -LogOnly
                Remove-Item $zip.FullName -Force -ErrorAction SilentlyContinue
            }
        }
    }
    catch {
        Write-Log "Clean-StaleToolZips: $_" -LogOnly
    }
}

function Get-VMListEntryWithLiveState {
    <#
    .SYNOPSIS
        Cached Get-List entry for ONE named VM, with only its state refreshed.
    .DESCRIPTION
        `Get-List -Type VM -SmartUpdate` refreshes EVERY VM on the host (Get-VM, an
        Update-VMFromHyperV per VM, then a disk-cache write) just to select one, and its
        3s throttle is per-process -- so N concurrent phase workers each pay the whole
        refresh at the same instant. Measured 9.9-13.2s per VM, 126.7s across one Phase 2
        on an 11-VM lab.

        `state` is the only field callers act on (they refuse to touch a VM that is not
        Running); domain and operatingSystem come from vmNotes and do not change mid-run.
        So take the cached entry and refresh just that one field with a targeted Get-VM.

        Returns $null if the VM is unknown even after a full refresh.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$VmName,
        [Parameter(Mandatory = $false, HelpMessage = "Names the StepTiming marker so the log says which call site paid.")]
        [string]$Caller = 'VMListLookup'
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $lookupPath = 'cached + per-VM state'
    $staleState = $false

    $vm = Get-List -Type VM | Where-Object { $_.vmName -eq $VmName } | Select-Object -First 1
    if (-not $vm) {
        # Cache miss (e.g. a VM created earlier in this run): pay for the full refresh.
        $vm = Get-List -Type VM -SmartUpdate | Where-Object { $_.vmName -eq $VmName } | Select-Object -First 1
        $lookupPath = 'cache miss -> full SmartUpdate'
    }
    if ($vm) {
        $liveVm = Get-VM -Name $vm.vmName -ErrorAction SilentlyContinue
        if ($liveVm) {
            # String, not the enum, to match how Update-VMFromHyperV sets it.
            $vm | Add-Member -MemberType NoteProperty -Name 'state' -Value ($liveVm.State.ToString()) -Force
        }
        else {
            # Callers gate on Running, so a stale 'Off' would silently skip their work.
            $staleState = $true
            Write-Log "$VmName`: $Caller could not read live state; using cached state '$($vm.state)'." -Warning
        }
    }
    $sw.Stop()
    Write-Log ("[StepTiming] {0} {1}-GetList completed in {2} seconds ({3}{4})" -f `
            $VmName, $Caller, [Math]::Round($sw.Elapsed.TotalSeconds, 1), $lookupPath,
        $(if ($staleState) { ', stale state' } else { '' })) -LogOnly

    return $vm
}

function Get-ToolSetFingerprint {
    <#
    .SYNOPSIS
        Path+size fingerprint for a set of tool source entries, memoized per process.
    .DESCRIPTION
        The fingerprint depends only on host-side files, so it is identical for every
        VM -- but Copy-ToolToVM computed it per VM, which meant 11 concurrent recursive
        walks of the same tool trees (Wireshark, Netmon, Toolbox...). Measured: 0.4s
        single-threaded in Build-ToolZipsForPhase2 vs 8.2-14.3s per VM under contention,
        112.5s aggregate across one Phase 2, every one of which ended in
        "Tools unchanged ... Skipping".

        Held on the APPDOMAIN, deliberately NOT on disk. A stale fingerprint is not a
        slow answer, it is a WRONG one: Copy-ToolToVM compares it against the VM note
        and skips injection on a match, so serving a pre-change value would silently
        leave old tools on the guest. Process-scoped memo cannot outlive the run that
        computed it. Workers are runspaces in the launcher process (same reason
        MemLabs_SessionStats lives here); if that ever stops being true the lookup
        simply misses and every caller computes as before.

        Sizes, not timestamps: Get-Tools re-extracts the zips every run, which rewrites
        LastWriteTimeUtc even when content is identical.
    #>
    param(
        [Parameter(Mandatory = $false)]
        [object[]]$Entries
    )

    $entryList = @($Entries | Where-Object { $null -ne $_ })
    if ($entryList.Count -eq 0) { return $null }

    $sorted = @($entryList | Sort-Object { $_.TargetRelative })

    $memo = $null
    $setKey = $null
    try {
        $keySource = ($sorted | ForEach-Object { "$($_.TargetRelative)|$($_.SourcePath)" }) -join "`n"
        $keyStream = [System.IO.MemoryStream]::new([System.Text.Encoding]::UTF8.GetBytes($keySource))
        $setKey = (Get-FileHash -InputStream $keyStream -Algorithm MD5).Hash
        $keyStream.Dispose()

        $memo = [System.AppDomain]::CurrentDomain.GetData('MemLabs_ToolFingerprints')
        if (-not $memo) {
            $memo = [System.Collections.Hashtable]::Synchronized(@{})
            [System.AppDomain]::CurrentDomain.SetData('MemLabs_ToolFingerprints', $memo)
        }
        if ($memo.ContainsKey($setKey)) { return $memo[$setKey] }
    }
    catch {
        $memo = $null
    }

    $parts = foreach ($entry in $sorted) {
        $item = Get-Item $entry.SourcePath -ErrorAction SilentlyContinue
        if ($item -is [System.IO.DirectoryInfo]) {
            $children = Get-ChildItem $item.FullName -Recurse -File | Sort-Object FullName
            foreach ($child in $children) {
                "$($entry.TargetRelative)|$($child.FullName.Substring($item.FullName.Length))|$($child.Length)"
            }
        }
        else {
            "$($entry.TargetRelative)|$($item.Length)"
        }
    }
    $str = $parts -join "`n"
    $stream = [System.IO.MemoryStream]::new([System.Text.Encoding]::UTF8.GetBytes($str))
    $hash = (Get-FileHash -InputStream $stream -Algorithm MD5).Hash
    $stream.Dispose()

    if ($memo -and $setKey) { $memo[$setKey] = $hash }

    return $hash
}

function Build-ToolZipsForPhase2 {
    <#
    .SYNOPSIS
        Pre-builds the fingerprint-keyed tools zips on the host so Phase 2
        jobs find them already built and skip the Compress-Archive step.
        Runs serially on the host before Start-PhaseJobs dispatches workers.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$deployConfig
    )

    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Log "Build-ToolZipsForPhase2: Pre-building tool zips..." -LogOnly

    # --- Collect all tool entries the same way Copy-ToolToVM does ---
    $commonEntries = @()
    $allExtraSets = @{}  # fingerprint -> entries

    foreach ($tool in $Common.AzureFileList.Tools) {
        if ($tool.NoUpdate) { continue }

        $toolFileName = Split-Path $tool.url -Leaf
        if ($toolFileName.Contains("?")) { $toolFileName = $toolFileName.Split("?")[0] }
        $fileTargetRelative = Join-Path $tool.Target $toolFileName

        if ($toolFileName.ToLowerInvariant().EndsWith(".zip") -and $tool.ExtractFolderIfZip) {
            $fileTargetRelative = $tool.Target
        }

        $toolPathHost = Join-Path $Common.StagingInjectPath $fileTargetRelative

        if ($tool.Name -eq "WMI Explorer") {
            $toolPathHost = Join-Path $toolPathHost "WmiExplorer.exe"
            $fileTargetRelative = Join-Path $fileTargetRelative "WmiExplorer.exe"
        }

        if (-not (Test-Path $toolPathHost)) { continue }

        $entry = [PSCustomObject]@{
            Name           = $tool.Name
            SourcePath     = $toolPathHost
            TargetRelative = $fileTargetRelative
        }

        if ($tool.Optional -and $tool.Roles) {
            # Track per-role extra entries; they get their own fingerprint
            foreach ($role in $tool.Roles) {
                if (-not $allExtraSets.ContainsKey($role)) {
                    $allExtraSets[$role] = @()
                }
                $allExtraSets[$role] += $entry
            }
        }
        elseif ($tool.Optional -and -not $tool.Roles) {
            # Pure optional with no roles — skipped in normal Install-Tools
            continue
        }
        else {
            $commonEntries += $entry
        }
    }

    # Add maintenance fix files to common bundle
    try {
        $maintPaths = Get-MaintenanceInjectPaths
        foreach ($file in $maintPaths.Files) {
            $sourcePath = Join-Path $Common.StagingInjectPath "staging\$file"
            if (Test-Path $sourcePath) {
                $commonEntries += [PSCustomObject]@{
                    Name           = "MaintFix:$file"
                    SourcePath     = $sourcePath
                    TargetRelative = "staging\$file"
                }
            }
        }
        foreach ($toolFolder in $maintPaths.Tools) {
            $sourcePath = Join-Path $Common.StagingInjectPath "tools\$toolFolder"
            if (Test-Path $sourcePath) {
                $commonEntries += [PSCustomObject]@{
                    Name           = "MaintFix:$toolFolder"
                    SourcePath     = $sourcePath
                    TargetRelative = "tools\$toolFolder"
                }
            }
        }
    }
    catch {
        Write-Log "Build-ToolZipsForPhase2: Could not add maintenance fix files: $_" -LogOnly
    }

    # --- Fingerprint helper (same logic as Copy-ToolToVM) ---
    # --- Build zip helper (same logic as Copy-ToolToVM.$buildZip) ---
    $buildZipLocal = {
        param([object[]]$entries, [string]$fingerprint, [string]$label)
        if ($entries.Count -eq 0) { return $null }

        $zipPath = Join-Path $Common.TempPath "tools-$fingerprint.zip"
        if (Test-Path $zipPath) {
            Write-Log "Build-ToolZipsForPhase2: $label zip already exists ($fingerprint)." -LogOnly
            return $zipPath
        }

        $stagingDir = Join-Path $Common.TempPath "toolzip-$fingerprint"
        if (Test-Path $stagingDir) { Remove-Item $stagingDir -Recurse -Force }
        New-Item -Path $stagingDir -ItemType Directory -Force | Out-Null

        foreach ($entry in $entries) {
            $dest = Join-Path $stagingDir $entry.TargetRelative
            $destDir = Split-Path $dest -Parent
            if (-not (Test-Path $destDir)) {
                New-Item -Path $destDir -ItemType Directory -Force | Out-Null
            }
            if ((Get-Item $entry.SourcePath) -is [System.IO.DirectoryInfo]) {
                Copy-Item -Path $entry.SourcePath -Destination $dest -Recurse -Force
            }
            else {
                Copy-Item -Path $entry.SourcePath -Destination $dest -Force
            }
        }

        Write-Log "Build-ToolZipsForPhase2: Creating $label zip ($($entries.Count) items)..." -LogOnly
        $prevPref = $Global:ProgressPreference
        $Global:ProgressPreference = "SilentlyContinue"
        try {
            Compress-Archive -Path "$stagingDir\*" -DestinationPath $zipPath -Force
        }
        finally {
            $Global:ProgressPreference = $prevPref
        }
        Remove-Item $stagingDir -Recurse -Force -ErrorAction SilentlyContinue
        $sizeMB = [Math]::Round((Get-Item $zipPath).Length / 1MB, 1)
        Write-Log "Build-ToolZipsForPhase2: $label zip created (${sizeMB} MB)." -LogOnly
        return $zipPath
    }

    # --- Helper: find the most recently modified source file across entries ---
    $getNewestSource = {
        param([object[]]$entries)
        $newest = $null
        foreach ($entry in $entries) {
            $item = Get-Item $entry.SourcePath -ErrorAction SilentlyContinue
            if ($item -is [System.IO.DirectoryInfo]) {
                $child = Get-ChildItem $item.FullName -Recurse -File -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
                if ($child -and (-not $newest -or $child.LastWriteTimeUtc -gt $newest.LastWriteTimeUtc)) { $newest = $child }
            }
            else {
                if ($item -and (-not $newest -or $item.LastWriteTimeUtc -gt $newest.LastWriteTimeUtc)) { $newest = $item }
            }
        }
        return $newest
    }

    # --- Build common zip ---
    $builtCount = 0
    $allZipNames = @()
    if ($commonEntries.Count -gt 0) {
        $commonFP = Get-ToolSetFingerprint -Entries $commonEntries
        $zipPath = Join-Path $Common.TempPath "tools-$commonFP.zip"
        $zipExists = Test-Path $zipPath
        $newestFile = & $getNewestSource $commonEntries
        $newestInfo = if ($newestFile) { "$($newestFile.Name) ($($newestFile.Length) bytes, $($newestFile.LastWriteTimeUtc.ToString('yyyy-MM-dd HH:mm:ss')) UTC)" } else { "(none)" }
        Write-Log "Build-ToolZipsForPhase2: common fingerprint=$commonFP, zipExists=$zipExists, tempPath=$($Common.TempPath), newest=$newestInfo" -LogOnly
        $null = & $buildZipLocal $commonEntries $commonFP "common tools"
        $allZipNames += "tools-$commonFP.zip"
        $builtCount++
    }

    # --- Build unique extra zips (one per distinct role-tool set) ---
    $builtExtraFPs = @{}
    foreach ($role in $allExtraSets.Keys) {
        $extraEntries = $allExtraSets[$role]
        $extraFP = Get-ToolSetFingerprint -Entries $extraEntries
        if (-not $builtExtraFPs.ContainsKey($extraFP)) {
            $zipPath = Join-Path $Common.TempPath "tools-$extraFP.zip"
            $zipExists = Test-Path $zipPath
            $newestFile = & $getNewestSource $extraEntries
            $newestInfo = if ($newestFile) { "$($newestFile.Name) ($($newestFile.Length) bytes, $($newestFile.LastWriteTimeUtc.ToString('yyyy-MM-dd HH:mm:ss')) UTC)" } else { "(none)" }
            Write-Log "Build-ToolZipsForPhase2: extra ($role) fingerprint=$extraFP, zipExists=$zipExists, newest=$newestInfo" -LogOnly
            $null = & $buildZipLocal $extraEntries $extraFP "extra tools ($role)"
            $allZipNames += "tools-$extraFP.zip"
            $builtExtraFPs[$extraFP] = $true
            $builtCount++
        }
    }

    # --- Write a manifest so Clean-StaleToolZips knows these zips are active ---
    if ($allZipNames.Count -gt 0) {
        $manifestPath = Join-Path $Common.TempPath "toolhash-_prebuild.json"
        @{ ZipFiles = $allZipNames } | ConvertTo-Json | Set-Content $manifestPath -Force -ErrorAction SilentlyContinue
    }

    $timer.Stop()
    Write-Log "Build-ToolZipsForPhase2: Pre-built $builtCount zip(s) in $($timer.Elapsed.ToString('hh\:mm\:ss'))."
}

function Copy-ToolToVM {
    param(
        [Parameter(Mandatory = $true, HelpMessage = "Tool PS Object.")]
        [object]$Tool,
        [Parameter(Mandatory = $true, HelpMessage = "VM Name to inject tool in.")]
        [string]$VMName,
        [Parameter(Mandatory = $false, HelpMessage = "Dry Run.")]
        [switch]$WhatIf,
        [Parameter(Mandatory = $false, HelpMessage = "Fast.. Might hang.")]
        [switch]$Fast,
        [Parameter(Mandatory = $false, HelpMessage = "Force copy even if hash matches.")]
        [switch]$Force
    )

    $vm = Get-VMListEntryWithLiveState -VmName $VMName -Caller 'ToolCopy'

    if ($vm.State -ne "Running") {
        Write-Log "$vmName`: VM is not running. Start the VM and try again." -Warning
        return $false
    }

    $ps = Get-VmSession -VmName $vm.vmName -VmDomainName $vm.domain
    if (-not $ps) {
        Write-Log "$vmName`: Failed to get a session with the VM." -Failure
        return $false
    }

    # --- Build list of source paths to bundle ---
    $commonEntries = @()
    $extraEntries = @()
    foreach ($ToolItem in $Tool) {
        if ($ToolItem.NoUpdate -eq $true) {
            Write-Log "$vmName`: Skipped injecting '$($ToolItem.Name) since it's marked NoUpdate." -Verbose
            continue
        }

        $toolFileName = Split-Path $ToolItem.url -Leaf
        if ($toolFileName.Contains("?")) {
            $toolFileName = $toolFileName.Split("?")[0]
        }
        $fileTargetRelative = Join-Path $ToolItem.Target $toolFileName

        if ($toolFileName.ToLowerInvariant().EndsWith(".zip") -and $ToolItem.ExtractFolderIfZip) {
            $fileTargetRelative = $ToolItem.Target
        }

        $toolPathHost = Join-Path $Common.StagingInjectPath $fileTargetRelative

        if ($ToolItem.Name -eq "WMI Explorer") {
            $toolPathHost = Join-Path $toolPathHost "WmiExplorer.exe"
            $fileTargetRelative = Join-Path $fileTargetRelative "WmiExplorer.exe"
        }

        if (-not (Test-Path $toolPathHost)) {
            Write-Log "$vmName`: Source path not found for '$($ToolItem.Name)': $toolPathHost" -Warning
            continue
        }

        $entry = [PSCustomObject]@{
            Name             = $ToolItem.Name
            SourcePath       = $toolPathHost
            TargetRelative   = $fileTargetRelative
        }

        # Tools with Optional+Roles are VM-specific; everything else is common
        if ($ToolItem.Optional -and $ToolItem.Roles) {
            $extraEntries += $entry
        }
        else {
            $commonEntries += $entry
        }
    }

    # --- Add maintenance fix InjectFiles/InjectTools to the common bundle
    #     so they ride with the tools. Phase 10 skips the redundant PSDirect
    #     copy when the files already exist on the VM. ---
    try {
        $maintPaths = Get-MaintenanceInjectPaths
        foreach ($file in $maintPaths.Files) {
            $sourcePath = Join-Path $Common.StagingInjectPath "staging\$file"
            if (Test-Path $sourcePath) {
                $commonEntries += [PSCustomObject]@{
                    Name           = "MaintFix:$file"
                    SourcePath     = $sourcePath
                    TargetRelative = "staging\$file"
                }
            }
        }
        foreach ($toolFolder in $maintPaths.Tools) {
            $sourcePath = Join-Path $Common.StagingInjectPath "tools\$toolFolder"
            if (Test-Path $sourcePath) {
                $commonEntries += [PSCustomObject]@{
                    Name           = "MaintFix:$toolFolder"
                    SourcePath     = $sourcePath
                    TargetRelative = "tools\$toolFolder"
                }
            }
        }
    }
    catch {
        Write-Log "$vmName`: Could not add maintenance fix files to tools bundle: $_" -LogOnly
    }

    if ($commonEntries.Count -eq 0 -and $extraEntries.Count -eq 0) {
        Write-Log "$vmName`: No tools to inject." -Verbose
        return $true
    }

    # --- Compute fingerprints ---
    $commonFingerprint = $null
    $extraFingerprint = $null
    $vmHashPath = "C:\Tools\Tools.MD5"
    $hostCachePath = Join-Path $Common.TempPath "toolhash-$VMName.json"

    try {
        $swFp = [System.Diagnostics.Stopwatch]::StartNew()
        if ($commonEntries.Count -gt 0) {
            $commonFingerprint = Get-ToolSetFingerprint -Entries $commonEntries
        }
        if ($extraEntries.Count -gt 0) {
            $extraFingerprint = Get-ToolSetFingerprint -Entries $extraEntries
        }
        $swFp.Stop()
        Write-Log ("[StepTiming] {0} ToolInject-Fingerprint completed in {1} seconds" -f $vmName, [Math]::Round($swFp.Elapsed.TotalSeconds, 1)) -LogOnly
    }
    catch {
        Write-Log "$vmName`: Source fingerprint computation failed, will do full rebuild: $_" -LogOnly
    }

    # Combined fingerprint for the VM-level skip check (common + extras)
    $combinedFingerprint = if ($commonFingerprint -and $extraFingerprint) {
        $s = [System.IO.MemoryStream]::new([System.Text.Encoding]::UTF8.GetBytes("$commonFingerprint|$extraFingerprint"))
        $h = (Get-FileHash -InputStream $s -Algorithm MD5).Hash; $s.Dispose(); $h
    }
    elseif ($commonFingerprint) { $commonFingerprint }
    elseif ($extraFingerprint) { $extraFingerprint }
    else { $null }

    # --- Fast skip: if combined fingerprint + VM hash match, skip everything ---
    if ($combinedFingerprint -and -not $WhatIf -and -not $Force) {
        # The VM note reverts with the guest on a checkpoint restore (Common.Snapshots.ps1
        # re-applies it from the sidecar json), so it tracks real guest state. toolhash-<vm>.json
        # in TempPath does NOT revert, which is why that path still has to ask the guest.
        try {
            $noteFingerprint = (Get-VMNote -VMName $vm.vmName -ErrorAction SilentlyContinue).ToolsFingerprint
            if ($noteFingerprint -and $noteFingerprint -eq $combinedFingerprint) {
                Write-Log "$vmName`: Tools unchanged (VM note fingerprint match). Skipping." -Success
                return $true
            }
        }
        catch { }
        try {
            if (Test-Path $hostCachePath) {
                $cached = Get-Content $hostCachePath -Raw | ConvertFrom-Json
                if ($cached.SourceFingerprint -eq $combinedFingerprint) {
                    $cachedBundleHash = $cached.BundleMD5
                    $hashCheck = Invoke-VmCommand -VmName $vm.vmName -VmDomainName $vm.domain -SuppressLog -ScriptBlock {
                        if (Test-Path $using:vmHashPath) {
                            return (Get-Content $using:vmHashPath -ErrorAction SilentlyContinue | Select-Object -First 1)
                        }
                        return $null
                    }
                    if (-not $hashCheck.ScriptBlockFailed -and $hashCheck.ScriptBlockOutput -eq $cachedBundleHash) {
                        Write-Log "$vmName`: Tools unchanged (source fingerprint + VM hash match). Skipping." -Success
                        try { Update-VMNoteProperty -VmName $vm.vmName -PropertyName 'ToolsFingerprint' -PropertyValue $combinedFingerprint } catch { }
                        return $true
                    }
                }
            }
        }
        catch {
            Write-Log "$vmName`: Cache check failed, falling through to full rebuild: $_" -LogOnly
        }
    }

    # --- Helper: build a zip with mutex guarding. Returns the zip path. ---
    #     If another job already built the zip (fingerprint match), reuses it.
    $buildZip = {
        param([object[]]$entries, [string]$fingerprint, [string]$label)

        if ($entries.Count -eq 0) { return $null }

        $zipPath = Join-Path $Common.TempPath "tools-$fingerprint.zip"
        $mutexName = "Global\MemLabs-ToolZip-$fingerprint"
        $mutex = [System.Threading.Mutex]::new($false, $mutexName)

        try {
            # Wait up to 10 minutes for the mutex
            if (-not $mutex.WaitOne(600000)) {
                Write-Log "$vmName`: Timed out waiting for $label zip mutex. Building anyway." -Warning
            }

            # After acquiring the mutex, check if the zip already exists
            if (Test-Path $zipPath) {
                Write-Log "$vmName`: Reusing existing $label bundle (built by another VM)." -LogOnly
                return $zipPath
            }

            # Build the zip
            $stagingDir = Join-Path $Common.TempPath "toolzip-$fingerprint"
            if (Test-Path $stagingDir) { Remove-Item $stagingDir -Recurse -Force }
            New-Item -Path $stagingDir -ItemType Directory -Force | Out-Null

            foreach ($entry in $entries) {
                $dest = Join-Path $stagingDir $entry.TargetRelative
                $destDir = Split-Path $dest -Parent
                if (-not (Test-Path $destDir)) {
                    New-Item -Path $destDir -ItemType Directory -Force | Out-Null
                }
                if ((Get-Item $entry.SourcePath) -is [System.IO.DirectoryInfo]) {
                    Copy-Item -Path $entry.SourcePath -Destination $dest -Recurse -Force
                }
                else {
                    Copy-Item -Path $entry.SourcePath -Destination $dest -Force
                }
            }

            Write-Log "$vmName`: Creating $label bundle ($($entries.Count) items)..." -LogOnly
            $prevPref = $Global:ProgressPreference
            $Global:ProgressPreference = "SilentlyContinue"
            try {
                Compress-Archive -Path "$stagingDir\*" -DestinationPath $zipPath -Force
            }
            finally {
                $Global:ProgressPreference = $prevPref
            }
            Remove-Item $stagingDir -Recurse -Force -ErrorAction SilentlyContinue

            return $zipPath
        }
        finally {
            try { $mutex.ReleaseMutex() } catch {}
            $mutex.Dispose()
        }
    }

    # --- Build the common zip (shared across all VMs, mutex-guarded) ---
    $commonZipPath = $null
    $extraZipPath = $null

    if ($commonEntries.Count -gt 0) {
        if ($commonFingerprint) {
            $commonZipPath = & $buildZip $commonEntries $commonFingerprint "common tools"
        }
        else {
            # No fingerprint available — fall back to VM-specific zip without mutex
            $commonZipPath = & $buildZip $commonEntries $VMName "common tools"
        }
    }

    # --- Build the extras zip (role-specific tools, also mutex-guarded by its fingerprint) ---
    if ($extraEntries.Count -gt 0) {
        if ($extraFingerprint) {
            $extraZipPath = & $buildZip $extraEntries $extraFingerprint "extra tools"
        }
        else {
            $extraZipPath = & $buildZip $extraEntries "$VMName-extra" "extra tools"
        }
    }

    # --- Compute a combined MD5 from the zip file(s) for the VM hash check ---
    $zipPaths = @()
    if ($commonZipPath) { $zipPaths += $commonZipPath }
    if ($extraZipPath) { $zipPaths += $extraZipPath }

    $hashParts = foreach ($zp in $zipPaths) {
        (Get-FileHash -Path $zp -Algorithm MD5).Hash
    }
    $combinedHashString = $hashParts -join "|"
    $bundleStream = [System.IO.MemoryStream]::new([System.Text.Encoding]::UTF8.GetBytes($combinedHashString))
    $bundleHash = (Get-FileHash -InputStream $bundleStream -Algorithm MD5).Hash
    $bundleStream.Dispose()

    $totalSizeMB = [Math]::Round(($zipPaths | ForEach-Object { (Get-Item $_).Length } | Measure-Object -Sum).Sum / 1MB, 1)
    $totalItems = $commonEntries.Count + $extraEntries.Count

    # --- Check if the VM already has this exact bundle ---
    $skipCopy = $false
    if (-not $WhatIf -and -not $Force) {
        $hashCheck = Invoke-VmCommand -VmName $vm.vmName -VmDomainName $vm.domain -SuppressLog -ScriptBlock {
            if (Test-Path $using:vmHashPath) {
                return (Get-Content $using:vmHashPath -ErrorAction SilentlyContinue | Select-Object -First 1)
            }
            return $null
        }
        if (-not $hashCheck.ScriptBlockFailed -and $hashCheck.ScriptBlockOutput -eq $bundleHash) {
            Write-Log "$vmName`: Tools bundle hash matches ($bundleHash). Skipping copy." -Success
            $skipCopy = $true
        }
    }

    # Collect zip filenames for the cleanup manifest
    $activeZipNames = @($zipPaths | ForEach-Object { Split-Path $_ -Leaf })

    if ($skipCopy) {
        if ($combinedFingerprint) {
            @{ SourceFingerprint = $combinedFingerprint; BundleMD5 = $bundleHash; ZipFiles = $activeZipNames } | ConvertTo-Json | Set-Content $hostCachePath -Force -ErrorAction SilentlyContinue
            try { Update-VMNoteProperty -VmName $vm.vmName -PropertyName 'ToolsFingerprint' -PropertyValue $combinedFingerprint } catch { }
        }
        return $true
    }

    Write-Log "$vmName`: Copying tools bundle (${totalSizeMB} MB, $totalItems items) to VM..."
    Write-Progress2 "Injecting tools" -Status "Copying tools bundle (${totalSizeMB} MB) to $VMName" -Log -force

    # --- Prefer a content-addressed ISO, then fall back to PSDirect copy ---
    $success = $false
    $isoDelivered = $false
    $isoAttempted = $false
    $progressPref = $ProgressPreference
    try {
        $ProgressPreference = "SilentlyContinue"
        if (-not $WhatIf -and -not $env:MEMLABS_NO_TOOLS_ISO) {
            try {
                $toolsVm = Get-VM -Name $vm.vmName -ErrorAction SilentlyContinue
                if ($toolsVm -and $toolsVm.Generation -ne 1) {
                    $isoAttempted = $true
                    $toolsIso = Get-MemlabsToolsIsoForBundles -ZipPaths $zipPaths -BundleHash $bundleHash
                    if ($toolsIso -and (Mount-MemlabsToolsIsoToVm -VmName $vm.vmName -IsoPath $toolsIso)) {
                        try {
                            $visible = Confirm-IsoVisibleInGuest -VmName $vm.vmName -VmDomainName $vm.domain -MarkerRelativePath 'Tools.Bundle.md5' -Context 'tools' -TimeoutSeconds 90 -Phase 2
                            if ($visible) {
                                $isoResult = Invoke-VmCommand -VmName $vm.vmName -VmDomainName $vm.domain -ArgumentList @($bundleHash, $script:MemlabsToolsVolumeLabel) -DisplayName 'Tools: Expand bundles from mounted ISO' -ScriptBlock {
                                    param($expectedHash, $volumeLabel)

                                    $volume = Get-Volume -FileSystemLabel $volumeLabel -ErrorAction SilentlyContinue |
                                        Where-Object { $_.DriveLetter } | Select-Object -First 1
                                    if (-not $volume) {
                                        return [PSCustomObject]@{ Ok = $false; Reason = "$volumeLabel volume not found" }
                                    }

                                    $root = "$($volume.DriveLetter):\"
                                    $actualHash = Get-Content -Path (Join-Path $root 'Tools.Bundle.md5') -ErrorAction SilentlyContinue | Select-Object -First 1
                                    if ($actualHash -ne $expectedHash) {
                                        return [PSCustomObject]@{ Ok = $false; Reason = "bundle hash mismatch (expected $expectedHash, found $actualHash)" }
                                    }

                                    $bundleNames = @(Get-Content -Path (Join-Path $root 'Tools.Bundles.txt') -ErrorAction SilentlyContinue | Where-Object { $_ })
                                    if ($bundleNames.Count -eq 0) {
                                        return [PSCustomObject]@{ Ok = $false; Reason = 'bundle manifest is empty' }
                                    }

                                    foreach ($bundleName in $bundleNames) {
                                        $bundlePath = Join-Path $root $bundleName
                                        if (-not (Test-Path $bundlePath)) {
                                            return [PSCustomObject]@{ Ok = $false; Reason = "bundle '$bundleName' is missing" }
                                        }
                                        Expand-Archive -Path $bundlePath -DestinationPath 'C:\' -Force -ErrorAction Stop
                                    }
                                    return [PSCustomObject]@{ Ok = $true; Reason = '' }
                                }
                                if (-not $isoResult.ScriptBlockFailed -and $isoResult.ScriptBlockOutput -and $isoResult.ScriptBlockOutput.Ok) {
                                    $isoDelivered = $true
                                    $success = $true
                                    Write-Log "$vmName`: Expanded tools bundle from $([System.IO.Path]::GetFileName($toolsIso))." -Success
                                }
                                else {
                                    $reason = if ($isoResult.ScriptBlockOutput) { $isoResult.ScriptBlockOutput.Reason } else { 'in-guest ISO extraction failed' }
                                    Write-Log "$vmName`: Tools ISO delivery did not complete ($reason). Falling back to direct copy." -Warning
                                }
                            }
                            else {
                                Write-Log "$vmName`: Tools ISO was not visible in the guest. Falling back to direct copy." -Warning
                            }
                        }
                        finally {
                            Dismount-MemlabsToolsIsoFromVm -VmName $vm.vmName
                        }
                    }
                }
            }
            catch {
                Write-Log "$vmName`: Tools ISO delivery failed: $($_.Exception.Message). Falling back to direct copy." -Warning
                try { Dismount-MemlabsToolsIsoFromVm -VmName $vm.vmName } catch {}
            }
        }

        if (-not $isoDelivered) {
            if ($isoAttempted) {
                Write-Log "$vmName`: Using direct tools transfer fallback." -LogOnly
            }

            # Mount/eject invalidates the old optical-view session. Always reacquire
            # here so the fallback never uses a session disposed by ISO handling.
            $ps = Get-VmSession -VmName $vm.vmName -VmDomainName $vm.domain
            if (-not $ps) { throw 'Could not acquire a guest session for direct tools transfer' }

            $success = $true
            foreach ($zp in $zipPaths) {
                $vmZipPath = "C:\Windows\Temp\tools-bundle.zip"

                if ($Fast) {
                    Copy-Item -ToSession $ps -Path $zp -Destination $vmZipPath -Force -WhatIf:$WhatIf -ErrorAction Stop
                }
                else {
                    $copyResult = Copy-ItemSafe -VMName $vm.vmName -VmDomainName $vm.domain -Path $zp -Destination $vmZipPath -Force -WhatIf:$WhatIf
                    if ($copyResult -eq $false) {
                        throw "Copy-ItemSafe exhausted retries copying tools bundle to VM"
                    }
                }

                if (-not $WhatIf) {
                    $expandResult = Invoke-VmCommand -VmName $vm.vmName -VmDomainName $vm.domain -ScriptBlock {
                        Expand-Archive -Path $using:vmZipPath -DestinationPath "C:\" -Force
                        Remove-Item -Path $using:vmZipPath -Force -ErrorAction SilentlyContinue
                    }
                    if ($expandResult.ScriptBlockFailed) {
                        Write-Log "$vmName`: Failed to expand tools bundle inside VM. $($expandResult.ScriptBlockOutput)" -Failure
                        $success = $false
                        break
                    }
                }
            }
        }

        # Write the combined bundle hash to the VM
        if ($success -and -not $WhatIf) {
            $writeHash = Invoke-VmCommand -VmName $vm.vmName -VmDomainName $vm.domain -SuppressLog -ScriptBlock {
                $using:bundleHash | Set-Content -Path $using:vmHashPath -Force -ErrorAction SilentlyContinue
            }
            if ($writeHash.ScriptBlockFailed) {
                Write-Log "$vmName`: Could not write Tools.MD5 hash file. Next run will re-copy." -LogOnly
            }
        }

        if ($success) {
            Write-Log "$vmName`: Successfully injected $totalItems tools via bundle. Hash: $bundleHash" -Success
            if ($combinedFingerprint) {
                @{ SourceFingerprint = $combinedFingerprint; BundleMD5 = $bundleHash; ZipFiles = $activeZipNames } | ConvertTo-Json | Set-Content $hostCachePath -Force -ErrorAction SilentlyContinue
                try { Update-VMNoteProperty -VmName $vm.vmName -PropertyName 'ToolsFingerprint' -PropertyValue $combinedFingerprint } catch { }
            }
        }
    }
    catch {
        Write-Log "$vmName`: Failed to copy tools bundle to VM. $_" -Failure
        $success = $false
    }
    finally {
        $ProgressPreference = $progressPref
    }
    return $success
}

function Copy-LanguagePacksToVM {

    param (
        [Parameter(Mandatory = $false, HelpMessage = "Optional VM Name.")]
        [string]$VmName,
        [Parameter(Mandatory = $false)]
        [switch]$ShowProgress,
        [Parameter(Mandatory = $false, HelpMessage = "Dry Run.")]
        [switch]$WhatIf
    )

    $destDir = "C:\LanguagePacks"

    if ($VmName) {
        # Null-filtered: @($null) has Count 1, which would iterate once on a null VM.
        $allVMs = @(Get-VMListEntryWithLiveState -VmName $VmName -Caller 'LanguagePacks' | Where-Object { $null -ne $_ })
    }
    else {
        $allVMs = Get-List -Type VM -SmartUpdate | Where-Object { $_.vmbuild -eq $true } | Sort-Object -Property State -Descending
    }

    foreach ($vm in $allVMs) {
        $vmName = $vm.vmName
        Write-Log "$vmName`: Trying to copy Language Packs to $destDir inside the VM" -Activity

        $sourceDir = Join-Path $Common.ConfigPath "locales" $vm.operatingSystem
        if (-not (Test-Path -Path "${sourceDir}\*" -Include *.cab)) {
            Write-Log "$vmName`: Cannot find language pack(s) in $sourceDir. Skipping copy." -Warning
            continue
        }

        # Get VM Session
        if ($vm.State -ne "Running") {
            Write-Log "$vmName`: VM is not running. Start the VM and try again." -Warning
            continue
        }

        $ps = Get-VmSession -VmName $vm.vmName -VmDomainName $vm.domain
        if (-not $ps) {
            Write-Log "$vmName`: Failed to get a session with the VM." -Failure
            continue
        }

        if ($ShowProgress) {
            Write-Progress2 "Copying language packs" -Status "Copying language packs to $VmName"
        }

        Write-Log "$vmName`: Copying '${sourceDir}\*' from HOST to VM (${destDir}\)."

        try {
            $progressPref = $ProgressPreference
            $ProgressPreference = "SilentlyContinue"


            Copy-Item -ToSession $ps -Filter "*.cab" -Path "${sourceDir}" -Destination "${destDir}" -Recurse -WhatIf:$WhatIf -ErrorAction Stop
        }
        catch {
            Write-Log "$vmName`: Failed to copy language packs. $_" -Failure
            return $false
        }
        finally {
            $ProgressPreference = $progressPref
        }
    }

    Write-Host2

    if ($ShowProgress) {
        Write-Progress2 "Copying language packs" -Status "Done" -Completed
    }

    return $true
}

function Copy-LocaleConfigToVM {

    param (
        [Parameter(Mandatory = $false, HelpMessage = "Optional VM Name.")]
        [string]$VmName,
        [Parameter(Mandatory = $false)]
        [switch]$ShowProgress,
        [Parameter(Mandatory = $false, HelpMessage = "Dry Run.")]
        [switch]$WhatIf
    )

    $sourceDir = $Common.ConfigPath
    $destDir = "C:\staging\locale"
    $localeConfigFile = "_localeConfig.json"

    if ($VmName) {
        # Null-filtered: @($null) has Count 1, which would iterate once on a null VM.
        $allVMs = @(Get-VMListEntryWithLiveState -VmName $VmName -Caller 'LocaleConfig' | Where-Object { $null -ne $_ })
    }
    else {
        $allVMs = Get-List -Type VM -SmartUpdate | Where-Object { $_.vmbuild -eq $true } | Sort-Object -Property State -Descending
    }

    foreach ($vm in $allVMs) {
        $vmName = $vm.vmName
        Write-Log "$vmName`: Trying to copy $localeConfigFile to $destDir inside the VM" -Activity

        if (-not (Test-Path -Path "${sourceDir}\*" -Include "$localeConfigFile")) {
            Write-Log "$vmName`: Cannot find $localeConfigFile in $sourceDir. Skipping copy." -Warning
            continue
        }

        # Get VM Session
        if ($vm.State -ne "Running") {
            Write-Log "$vmName`: VM is not running. Start the VM and try again." -Warning
            continue
        }

        $ps = Get-VmSession -VmName $vm.vmName -VmDomainName $vm.domain
        if (-not $ps) {
            Write-Log "$vmName`: Failed to get a session with the VM." -Failure
            continue
        }

        if ($ShowProgress) {
            Write-Progress2 "Copying $localeConfigFile" -Status "Copying $localeConfigFile to $VmName"
        }

        Write-Log "$vmName`: Copying '${sourceDir}\${localeConfigFile}' from HOST to VM (${destDir}\)."

        try {
            $progressPref = $ProgressPreference
            $ProgressPreference = "SilentlyContinue"

            # Fix me. this includes other empty folders
            Copy-Item -ToSession $ps -Filter "$localeConfigFile" -Path "${sourceDir}" -Destination "${destDir}" -Recurse -WhatIf:$WhatIf -ErrorAction Stop
        }
        catch {
            Write-Log "$vmName`: Failed to copy ${localeConfigFile}. $_" -Failure
            return $false
        }
        finally {
            $ProgressPreference = $progressPref
        }
    }

    Write-Host2

    if ($ShowProgress) {
        Write-Progress2 "Copying $localeConfigFile" -Status "Done" -Completed
    }

    return $true
}

function Get-FileFromStorage {
    param(
        [Parameter(Mandatory = $true, HelpMessage = "Storage File to download.")]
        [object]$File,
        [Parameter(Mandatory = $false, HelpMessage = "Force redownloading the file, if it exists.")]
        [switch]$ForceDownloadFiles,
        [Parameter(Mandatory = $false, HelpMessage = "Ignore Hash Failures on file downloads.")]
        [switch]$IgnoreHashFailure,
        [Parameter(Mandatory = $false)]
        [switch]$UseCDN,
        [Parameter(Mandatory = $false, HelpMessage = "Dry Run.")]
        [switch]$WhatIf
    )

    $imageName = $File.id

    $success = $true
    $hashAlg = "MD5"
    $i = 0

    foreach ($fileItem in $File.filename) {

        $isArray = $File.filename -is [array]

        if ($isArray) {
            $fileName = $File.filename[$i]
            $fileHash = $File.($hashAlg)[$i]
            $i++
        }
        else {
            $fileName = $fileItem
            $fileHash = $File.($hashAlg)
        }

        $fileUrl = "$($StorageConfig.StorageLocation)/$($filename)"
        $worked = Get-FileWithHash -FileName $fileName -FileDisplayName $imageName -FileUrl $fileUrl -ExpectedHash $fileHash -ForceDownload:$ForceDownloadFiles -IgnoreHashFailure:$IgnoreHashFailure -HashAlg $hashAlg -UseCDN:$UseCDN -WhatIf:$WhatIf
        $success = $($worked.success)
        if (-not $success) {
            Write-Log "Failed to download/verify $imageName from $fileUrl" -Failure
        }
    }

    Write-Log -Verbose "Returning $success"
    return $success
}

function Test-FileEdgeReadable {
    # On-disk corruption probe. By default reads the FIRST and LAST page of a file PLUS
    # one random probe-sized read per GB of file size, so a bad sector on a failing/
    # damaged volume surfaces as an I/O exception (cyclic redundancy check / device
    # error) instead of being silently trusted. The per-GB spot reads cheaply widen
    # coverage into the middle of large files (which the two edges miss) without paying
    # for a full sequential scan -- e.g. a 12GB VHDX gets the two edges + 12 random
    # interior reads.
    # With -FullScan it reads the ENTIRE file sequentially (in large chunks, no hashing)
    # so a bad sector ANYWHERE -- not just the two extents -- is caught. Used for VHDX
    # base images, whose mid-file rot passes the edge probe but hard-fails the later
    # Copy-Item/BITS/robocopy stage into a VM with no recovery. A raw read is cheaper
    # than re-hashing (no MD5 compute); integrity is already vouched by the hash marker,
    # so we only care about surfacing read errors.
    # Returns $false ONLY when the read fails with a media-corruption signature; any
    # other error (sharing/access) returns $true so we never delete + redownload a
    # multi-GB file over an ambiguous, non-corruption error.
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [int]$ProbeBytes = 65536,
        [switch]$FullScan
    )

    $fs = $null
    try {
        $fs = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $len = $fs.Length
        if ($len -le 0) { return $true }

        if ($FullScan) {
            # Stream the whole file so any bad sector throws. 8MB sequential reads keep
            # this fast on healthy media; on damaged media the bad region throws quickly.
            $bufSize = 8388608   # 8MB
            $buf = New-Object byte[] $bufSize
            while ($true) {
                $read = $fs.Read($buf, 0, $bufSize)
                if ($read -le 0) { break }
            }
            return $true
        }

        $chunk = [int][Math]::Min([int64]$ProbeBytes, $len)
        $buf = New-Object byte[] $chunk

        # First page
        [void]$fs.Seek(0, [System.IO.SeekOrigin]::Begin)
        if ($fs.Read($buf, 0, $chunk) -le 0) { return $false }

        # Last page (only if the file is larger than one probe chunk)
        if ($len -gt $chunk) {
            [void]$fs.Seek($len - $chunk, [System.IO.SeekOrigin]::Begin)
            if ($fs.Read($buf, 0, $chunk) -le 0) { return $false }
        }

        # Random spot checks: ~1 per GB, each a probe-sized read at a random offset
        # within its own 1GB window. Cheaply catches mid-file rot the two edges miss;
        # a bad sector under any probe throws a CRC/device error caught below.
        $oneGB = 1073741824
        $spotCount = [int][Math]::Floor([double]$len / $oneGB)
        if ($spotCount -gt 0) {
            $rng = [System.Random]::new()
            $maxOffset = $len - $chunk
            for ($g = 0; $g -lt $spotCount; $g++) {
                $windowStart = [int64]$g * $oneGB
                $windowEnd = [int64][Math]::Min([int64]($windowStart + $oneGB), $maxOffset)
                if ($windowEnd -le $windowStart) { continue }
                $offset = $windowStart + [int64]($rng.NextDouble() * ($windowEnd - $windowStart))
                if ($offset -lt 0) { $offset = 0 }
                if ($offset -gt $maxOffset) { $offset = $maxOffset }
                [void]$fs.Seek($offset, [System.IO.SeekOrigin]::Begin)
                if ($fs.Read($buf, 0, $chunk) -le 0) { return $false }
            }
        }
        return $true
    }
    catch {
        $msg = $_.Exception.Message
        if ($msg -match 'cyclic redundancy|CRC|data error|I/O error|IO error|device|corrupt|unreadable|0x80070570|0x8007001F|0x80070017') {
            Write-Log "Read probe detected corruption in '$Path': $($msg.Trim())" -Warning
            return $false
        }
        # Non-corruption error (locked / access denied / etc) -- do NOT force a redownload.
        Write-Log -LogOnly "Read probe on '$Path' hit a non-corruption error (treating as readable): $($msg.Trim())"
        return $true
    }
    finally {
        if ($fs) { $fs.Dispose() }
    }
}

function Get-FileWithHash {

    param(
        [Parameter(Mandatory = $true, HelpMessage = "File Name. Relative Path inside azureFiles directory.")]
        [string]$FileName,
        [Parameter(Mandatory = $false, HelpMessage = "File Display Name.")]
        [string]$FileDisplayName,
        [Parameter(Mandatory = $true, HelpMessage = "File URL.")]
        [string]$FileUrl,
        [Parameter(Mandatory = $true, HelpMessage = "Expected File Hash.")]
        [string]$ExpectedHash,
        [Parameter(Mandatory = $true, HelpMessage = "Hash Algorithm.")]
        [string]$hashAlg,
        [Parameter(Mandatory = $false, HelpMessage = "Force redownloading the file, if it exists.")]
        [switch]$ForceDownload,
        [Parameter(Mandatory = $false, HelpMessage = "Ignore Hash Failures on file downloads.")]
        [switch]$IgnoreHashFailure,
        [Parameter(Mandatory = $false)]
        [switch]$UseCDN,
        [Parameter(Mandatory = $false)]
        [switch]$UseBITS,
        [Parameter(Mandatory = $false, HelpMessage = "Dry Run.")]
        [switch]$WhatIf
    )

    $fileNameLeaf = Split-Path $FileName -Leaf
    $localImagePath = Join-Path $Common.AzureFilesPath $FileName
    $localImageHashPath = "$localImagePath.$hashAlg"
    $isIso = $fileNameLeaf -like '*.iso'

    # Before deleting/overwriting an ISO we manage, confirm no VM still has it mounted
    # (a mounted ISO locks the file, so the delete + redownload would fail and leave a
    # stale copy). Ejects the exact ISO from every VM's DVD drive; no-op for non-ISO
    # files and when the helper/Hyper-V isn't available.
    $ejectIsoBeforeRedownload = {
        if ($isIso -and -not $WhatIf -and (Get-Command Dismount-IsoFromAllVMs -ErrorAction SilentlyContinue)) {
            $ejectedFrom = @(Dismount-IsoFromAllVMs -IsoPath $localImagePath)
            if ($ejectedFrom.Count -gt 0) {
                Write-Log "Ejected '$fileNameLeaf' from $($ejectedFrom.Count) VM(s) before re-download: $($ejectedFrom -join ', ')" -Warning
            }
        }
    }

    $return = [PSCustomObject]@{
        success  = $true
        download = $false
    }

    #Write-Log "Downloading/Verifying '$FileDisplayName'" -SubActivity

    if (Test-Path $localImagePath) {

        if (Test-Path $localImageHashPath) {
            # Read hash from local hash file
            $localFileHash = Get-Content $localImageHashPath
        }
        else {
            # Download if file present, but hashFile isn't there.
            #Get-File -Source $FileUrl -Destination $localImagePath -DisplayName "Hash Missing. Downloading '$FileName' to $localImagePath..." -Action "Downloading" -ResumeDownload -UseCDN:$UseCDN -UseBITS:$UseBITS -WhatIf:$WhatIf

            # Calculate file hash, save to local hash file
            Write-Log "Calculating $hashAlg hash for $FileName in $($Common.AzureFilesPath)..."
            $hashFileResult = Get-FileHash -Path $localImagePath -Algorithm $hashAlg
            $localFileHash = $hashFileResult.Hash
            $localFileHash | Out-File -FilePath $localImageHashPath -Force            
        }
        # For dynamically updated packages, its impossible to know the hash ahead of time, so we just re-download these every run
        if ($ExpectedHash -ne "NONE") {
            if ($localFileHash -eq $ExpectedHash) {
                #Write-GreenCheck "Found $FileName in $($Common.AzureFilesPath) with expected hash $ExpectedHash."
                Write-Log -logonly "Found $FileName in $($Common.AzureFilesPath) with expected hash $ExpectedHash."
                if ($ForceDownload.IsPresent) {
                    Write-WhiteI "ForceDownload switch present. Removing pre-existing $fileNameLeaf file..." -Warning
                    & $ejectIsoBeforeRedownload
                    Remove-Item -Path $localImagePath -Force -WhatIf:$WhatIf -ProgressAction SilentlyContinue | Out-Null
                    $return.download = $true
                }
                else {
                    # The hash marker matches, so we would normally trust the cached
                    # file WITHOUT re-reading it. But the marker is only a CACHED hash
                    # value -- a file that rotted on disk (bad sector) after the marker
                    # was written still "matches". Cheaply probe the first and last page:
                    # if the media is damaged the read throws a CRC error and we fall
                    # into the same delete + redownload recovery as a hash mismatch.
                    # We deliberately do NOT full-read every cached file here -- that would
                    # add minutes to every healthy deploy. Mid-file rot that passes this
                    # cheap probe is caught later at the Phase 1 copy (Get-File), which
                    # confirms the source is corrupt, purges it, and asks the operator to
                    # re-run (the next deploy's verify pass then re-downloads it).
                    if (-not $WhatIf -and -not (Test-FileEdgeReadable -Path $localImagePath)) {
                        Write-OrangePoint "Cached $FileName passed the hash-marker check but FAILED a CRC edge-read probe (corrupt on disk). Purging file + hash marker and redownloading..."
                        & $ejectIsoBeforeRedownload
                        Remove-Item -Path $localImagePath -Force -ErrorAction SilentlyContinue -WhatIf:$WhatIf -ProgressAction SilentlyContinue | Out-Null
                        Remove-Item -Path $localImageHashPath -Force -ErrorAction SilentlyContinue -WhatIf:$WhatIf -ProgressAction SilentlyContinue | Out-Null
                        $return.download = $true
                    }
                    else {
                        # Write-Log "ForceDownload switch not present. Skip downloading '$fileNameLeaf'." -LogOnly
                        $return.download = $false
                        $return.success = $true
                    }
                }
            }
            else {
                Write-OrangePoint "Found $FileName in $($Common.AzureFilesPath) but file hash $localFileHash does not match expected hash $ExpectedHash. Redownloading..."
                & $ejectIsoBeforeRedownload
                Remove-Item -Path $localImagePath -Force -ErrorAction SilentlyContinue -WhatIf:$WhatIf -ProgressAction SilentlyContinue | Out-Null
                Remove-Item -Path $localImageHashPath -Force -ErrorAction SilentlyContinue -WhatIf:$WhatIf -ProgressAction SilentlyContinue | Out-Null
                $return.download = $true
            }
        }
    }
    else {
        $return.download = $true
    }

    if ($return.download) {
        $worked = Get-File -Source $FileUrl -Destination $localImagePath -DisplayName "Downloading '$FileName' to $localImagePath..." -Action "Downloading" -UseCDN:$UseCDN -UseBITS:$UseBITS -WhatIf:$WhatIf -ForceDownload
        if (-not $worked) {
            $return.success = $false
        }
        else {
            if ($ExpectedHash -ne "NONE") {
                # Calculate file hash, save to local hash file
                Write-WhiteI "Calculating $hashAlg hash for downloaded $FileName in $($Common.AzureFilesPath)..."
                $hashFileResult = Get-FileHash -Path $localImagePath -Algorithm $hashAlg
                $localFileHash = $hashFileResult.Hash
                if ($localFileHash -eq $ExpectedHash) {
                    $localFileHash | Out-File -FilePath $localImageHashPath -Force
                    Write-GreenCheck "Downloaded $FileName in $($Common.AzureFilesPath) has expected hash $ExpectedHash."
                    $return.success = $true
                }
                else {
                    if ($IgnoreHashFailure) {
                        Write-WhiteI "Downloaded $filename in $($Common.AzureFilesPath) but file hash $localFileHash does not match expected hash $ExpectedHash."
                        $return.success = $true
                    }
                    else {
                        Write-RedX "Downloaded $filename in $($Common.AzureFilesPath) but file hash $localFileHash does not match expected hash $ExpectedHash."
                        $return.success = $false
                    }
                }
            }
            else {
                $return.success = $true
            }
        }
    }

    return $return
}

$QuickEditCodeSnippet = @"
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using System.Runtime.InteropServices;


public static class DisableConsoleQuickEdit
{
    const uint ENABLE_QUICK_EDIT = 0x0040;

    // STD_INPUT_HANDLE (DWORD): -10 is the standard input device.
    const int STD_INPUT_HANDLE = -10;

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr GetStdHandle(int nStdHandle);

    [DllImport("kernel32.dll")]
    static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);

    [DllImport("kernel32.dll")]
    static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);

    public static bool SetQuickEdit(bool SetEnabled)
    {

        IntPtr consoleHandle = GetStdHandle(STD_INPUT_HANDLE);

        // get current console mode
        uint consoleMode;
        if (!GetConsoleMode(consoleHandle, out consoleMode))
        {
            // ERROR: Unable to get console mode.
            return false;
        }

        // Clear the quick edit bit in the mode flags
        if (SetEnabled)
        {
            consoleMode &= ~ENABLE_QUICK_EDIT;
        }
        else
        {
            consoleMode |= ENABLE_QUICK_EDIT;
        }

        if (!SetConsoleMode(consoleHandle, consoleMode))
        {
            return false;
        }

        return true;
    }
}
"@

if ($null -eq $QuickEditMode) {
    try {
        $QuickEditMode = add-type -TypeDefinition $QuickEditCodeSnippet -Language CSharp -ErrorAction SilentlyContinue
    }
    catch {}
}

function Set-QuickEdit() {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false, HelpMessage = "This switch will disable Console QuickEdit option")]
        [switch]$DisableQuickEdit = $false
    )

    if ([DisableConsoleQuickEdit]::SetQuickEdit($DisableQuickEdit)) {
        Write-Verbose "QuickEdit settings has been updated."
    }
    else {
        Write-Verbose "Something went wrong changing QuickEdit settings."
    }
}

function Get-SupportedOptionsCacheSignature {

    $fileListPath = Join-Path $Common.AzureFilesPath ($(if ($Common.DevBranch) { "_fileList_develop.json" } else { "_fileList.json" }))
    $azureFilesPathLastWriteUtc = $null
    $isoPathLastWriteUtc = $null
    $osIsoPathLastWriteUtc = $null
    $fileListLastWriteUtc = $null

    try {
        if (Test-Path $Common.AzureFilesPath) {
            $azureFilesPathLastWriteUtc = (Get-Item $Common.AzureFilesPath).LastWriteTimeUtc.ToString("o")
        }
    }
    catch {}

    try {
        $isoPath = Join-Path $Common.AzureFilesPath "ISO"
        if (Test-Path $isoPath) {
            $isoPathLastWriteUtc = (Get-Item $isoPath).LastWriteTimeUtc.ToString("o")
        }
    }
    catch {}

    try {
        $osIsoPath = Join-Path $Common.AzureFilesPath "ISO\OS"
        if (Test-Path $osIsoPath) {
            $osIsoPathLastWriteUtc = (Get-Item $osIsoPath).LastWriteTimeUtc.ToString("o")
        }
    }
    catch {}

    try {
        if (Test-Path $fileListPath) {
            $fileListLastWriteUtc = (Get-Item $fileListPath).LastWriteTimeUtc.ToString("o")
        }
    }
    catch {}

    $signatureObject = [PSCustomObject]@{
        OfflineMode             = [bool]$Common.OfflineMode
        DevBranch               = [bool]$Common.DevBranch
        FileListPath            = $fileListPath
        FileListLastWriteUtc    = $fileListLastWriteUtc
        AzureFilesPath          = $Common.AzureFilesPath
        AzureFilesLastWriteUtc  = $azureFilesPathLastWriteUtc
        IsoPathLastWriteUtc     = $isoPathLastWriteUtc
        OsIsoPathLastWriteUtc   = $osIsoPathLastWriteUtc
        OsSignature             = @($Common.AzureFileList.OS | ForEach-Object { "$($_.id)|$($_.filename)" }) -join ';'
        SqlSignature            = @($Common.AzureFileList.ISO | ForEach-Object { "$($_.id)|$($_.filename)" }) -join ';'
        CmSignature             = @($Common.AzureFileList.CMVersions | ForEach-Object { "$($_.filename)|$($_.versions -join ',')" }) -join ';'
    }

    return ($signatureObject | ConvertTo-Json -Compress)
}

function Set-SupportedOptions {

    $supportedOptionsCacheFile = $null
    if ($Common.CachePath) {
        $supportedOptionsCacheFile = Join-Path $Common.CachePath "supported-options.json"
    }

    if (-not $DisableSupportedOptionsCache -and $supportedOptionsCacheFile -and $Common.AzureFileList) {
        try {
            $currentSupportedOptionsSignature = Get-SupportedOptionsCacheSignature
            if (Test-Path $supportedOptionsCacheFile) {
                $cachedSupportedOptionsRaw = Get-Content $supportedOptionsCacheFile -ErrorAction SilentlyContinue
                if (-not [string]::IsNullOrWhiteSpace($cachedSupportedOptionsRaw)) {
                    $cachedSupportedOptions = $cachedSupportedOptionsRaw | ConvertFrom-Json
                    if ($cachedSupportedOptions -and $cachedSupportedOptions.Signature -eq $currentSupportedOptionsSignature -and $cachedSupportedOptions.Supported) {
                        $Common.Supported = $cachedSupportedOptions.Supported
                        Write-Log "Loaded supported options from cache." -LogOnly
                        return
                    }
                }
            }
        }
        catch {
            Write-Log "Failed reading supported options cache: $_" -LogOnly
        }
    }

    $roles = @(
        "DomainMember",
        "WorkgroupMember",
        "InternetClient",
        "AADClient",
        "OSDClient",
        "CAS",
        "Primary",
        "Secondary",
        "SiteSystem",
        "PassiveSite",
        "FileServer",
        "SQLAO",
        "WSUS",
        "DC",
        "BDC",
        "StandaloneRootCA",
        "Proxy",
        "LinuxServer",
        "LinuxClient"
    )

    $rolesForExisting = @(
        "DomainMember",
        "WorkgroupMember",
        "InternetClient",
        "AADClient",
        "OSDClient",
        "CAS",
        "Primary",
        "Secondary",
        "SiteSystem",
        "PassiveSite",
        "FileServer",
        "SQLAO",
        "WSUS",
        "BDC",
        "StandaloneRootCA",
        "Proxy",
        "LinuxServer",
        "LinuxClient"
    )

    # wsusDataBaseServer / wsusContentDir must be updatable so that when a SUP is
    # added to an EXISTING MP/DP, the modify-VM menu renders them as selectable
    # rows -- otherwise they show grey/read-only and the user can't open the
    # Get-WsusDBName picker to choose WID / local SQL / remote SQL / an existing
    # SQL VM for the WSUS database (or change the content dir).
    # InstallPatchMyPC / PatchMyPCFileServer and pushClient are updatable so they
    # can be ADDED to an existing VM (PatchMyPC installs in Phase 8 from
    # InstallPatchMyPC; pushClient re-runs the client push in Phase 8). Like the
    # SUP, PatchMyPC has no removal path, so genconfig locks it once deployed.
    $updatablePropList = @("InstallCA", "InstallRP", "InstallMP", "InstallDP", "InstallSUP", "InstallSSMS", "InstallSMSProv", "memory", "dynamicMinRam", "virtualProcs", "useProxy", "installOffice", "useDatabaseReplica", "replicaSqlServerVM", "replicaDbName", "wsusDataBaseServer", "wsusContentDir", "InstallPatchMyPC", "PatchMyPCFileServer", "pushClient")
    $propsToUpdate = $updatablePropList

    $cmVersions += Get-CMVersions

    $operatingSystems = Get-OperatingSystems

    $sqlVersions = Get-SqlVersions

    $supported = [PSCustomObject]@{
        Roles             = $roles
        RolesForExisting  = $rolesForExisting
        AllRoles          = ($roles + $rolesForExisting | Select-Object -Unique)
        OperatingSystems  = $operatingSystems
        SqlVersions       = $sqlVersions
        CMVersions        = $cmVersions
        UpdatablePropList = $updatablePropList
        PropsToUpdate     = $propsToUpdate
    }

    $Common.Supported = $supported

    if (-not $DisableSupportedOptionsCache -and $supportedOptionsCacheFile -and $Common.AzureFileList) {
        try {
            if (-not $currentSupportedOptionsSignature) {
                $currentSupportedOptionsSignature = Get-SupportedOptionsCacheSignature
            }

            [PSCustomObject]@{
                GeneratedOnUtc = (Get-Date).ToUniversalTime().ToString("o")
                Signature      = $currentSupportedOptionsSignature
                Supported      = $supported
            } | ConvertTo-Json -Depth 6 | Set-Content -Path $supportedOptionsCacheFile -Encoding UTF8
        }
        catch {
            Write-Log "Failed writing supported options cache: $_" -LogOnly
        }
    }

}

function Get-SqlVersions {
    $sqlVersions = $Common.AzureFileList.ISO.id | Select-Object -Unique | Sort-Object
    if ($common.OfflineMode) {
        #Remove any SQL version that dont have downloaded files. In offline mode, we only want to show SQL version options that are fully available for deployment
        Foreach ($sqlVersion in $sqlVersions) {
            $filesForVersion = $Common.AzureFileList.ISO | Where-Object { $_.id -eq $sqlVersion } | Select-Object -ExpandProperty filename
            foreach ($file in $filesForVersion) {
                if (-not (Test-Path (Join-Path $Common.AzureFilesPath $file))) {
                    Write-Log "In Offline Mode, removing SQL version $sqlVersion from supported SQL version list since file $file is not downloaded."
                    $sqlVersions = $sqlVersions | Where-Object { $_ -ne $sqlVersion }
                    break
                }
            }
        }
    }
    return $sqlVersions
}

function Get-OperatingSystems {
    $osList = $Common.AzureFileList.OS.id | Where-Object { $_ -ne "vmbuildadmin" } | Sort-Object
    if ($Common.OfflineMode) {
        #Remove any OS that dont have downloaded files. In offline mode, we only want to show OS options that are fully available for deployment
        Foreach ($os in $osList) {
            $filesForOS = $Common.AzureFileList.OS | Where-Object { $_.id -eq $os } | Select-Object -ExpandProperty filename
            foreach ($file in $filesForOS) {
                if (-not (Test-Path (Join-Path $Common.AzureFilesPath $file))) {
                    Write-Log "In Offline Mode, removing $os from supported OS list since file $file is not downloaded."
                    $osList = $osList | Where-Object { $_ -ne $os }
                    break
                }
            }
        }
        return $osList
    }
    return $osList
}
function Get-CMVersions {
    $cmVersions = @()
    foreach ($version in $Common.AzureFileList.CMVersions) {
        if ($version -eq "current-branch") {
            continue
        }
        $cmversions += $version.versions
    }
    $cmVersions = $cmVersions | Sort-Object -Descending

    if ($common.OfflineMode) {
        #Remove any CM version that dont have downloaded files. In offline mode, we only want to show CM version options that are fully available for deployment
        #If there is a downloadURL keep it in the list, since this means the file is available from the web.
        Foreach ($cmVersion in $cmVersions) {
                       
            $filesForVersion = $Common.AzureFileList.CMVersions | Where-Object { $null -ne $_.filename } 
            foreach ($file in $filesForVersion) {
                if (-not (Test-Path (Join-Path $Common.AzureFilesPath $file.filename))) {
                    Write-Log "In Offline Mode, removing CM version $cmVersion from supported CM version list since file $file is not downloaded."
                    $cmVersions = $cmVersions | Where-Object { $_ -ne $cmVersion }
                    break
                }
            }
        }
    }
    return $cmVersions
}

function Get-CMBaselineVersion {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string]
        $CMVersion
    )

    return ($Common.AzureFileList.CMVersions | Where-Object { $_.versions -contains $CMVersion })

}

function Get-CMLatestBaselineVersion {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string]
        $CMVersion
    )

    return ($Common.AzureFileList.CMVersions.baselineVersion | Where-Object { $_ -notin "tech-preview", "current-branch" } | Sort-Object -Descending | Select-Object -First 1)

}

function Get-CMLatestVersion {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string]
        $CMVersion
    )

    return (Get-CMVersions | Where-Object { $_ -notin "tech-preview", "current-branch" } | Select-Object -First 1)

}

function Get-BranchName {
    try {
        $branch = git rev-parse --abbrev-ref HEAD

        if ($branch -eq "HEAD") {
            # we're probably in detached HEAD state, so print the SHA
            $branch = git rev-parse --short HEAD
        }

        return $branch

    }
    catch {
        return $null
    }
}

Function Set-PS7ProgressWidth {
    if ($PSVersionTable.PSVersion.Major -eq 7) {
        $maxWidth = 500
        try {
            $currentWidth = 0
            # Get-LiveWindowSize uses a fresh CONOUT$ handle via P/Invoke, which
            # returns the real terminal width even in ConPTY hosts (Windows Terminal,
            # VS Code) where [Console]::WindowWidth can return a stale cached value.
            if (Get-Command Get-LiveWindowSize -ErrorAction SilentlyContinue) {
                $size = Get-LiveWindowSize
                if ($size -and $size.Width -gt 0) {
                    $currentWidth = $size.Width
                }
            }
            if ($currentWidth -le 0) {
                $currentWidth = [Console]::WindowWidth
            }
            if ($currentWidth -gt 0) {
                $maxWidth = [Math]::Round(($currentWidth * 0.95), 0)
            }
        }
        catch {}
        $PSStyle.Progress.MaxWidth = $maxWidth
    }
}
Function Install-HostToServer2025 {
    $filename = (Join-Path $common.AzureFilesPath $server2025.filename)
    if (-not (Test-Path $filename) -and $common.OfflineMode) {
        Write-Log "Offline mode is enabled and $filename does not exist. Cannot proceed with Server 2025 installation." -Failure
        return
    }   

    if (-not $common.IsAzureVM) {
        Write-Log "This host is not an Azure VM. Please update this host manually to server 2025." -Warning
        Start-Sleep -Seconds 15
        return
    }
    $server2025 = $common.azureFilelist.SupportFiles | Where-Object { $_.id -like "*Server 2025*" }
    Get-FileFromStorage $server2025
    $filename = (Join-Path $common.AzureFilesPath $server2025.filename)
    if (Test-Path $filename) {

        $response = Read-YesOrNoWithTimeout -Prompt "Do you want to install Windows Server 2025 on this host? (Y/n)" -HideHelp -Default "y" -timeout 180
        if ($response -eq "n") {
            return
        }

        $expandLocation = "C:\temp\Upgrade2025"

        powershell.exe -NoProfile -Command "Expand-Archive -Path '$filename' -DestinationPath '$expandLocation' -Force"
    }
    else {
        Write-Log "Failed to download $filename" -Failure
        return
    }
    $exeLocation = (Join-Path $expandLocation "Windows Server 2025")
    $exe = (Join-Path $exeLocation "setup.exe")
    if (Test-Path $exe) {
        if ([Environment]::OSVersion.Version -ge [System.version]"10.0.26100.0") {
            write-Log "Host is already on Server 2025. Not running $exe /auto upgrade /dynamicupdate disable /eula accept"
        }
        else {
            write-Log "Stopping all VMs"

            Get-VM | Where-Object { $_.State -eq "Running" } | Stop-VM -Force
            Get-VM | Where-Object { $_.State -ne "Off" } | Stop-VM -TurnOff -Force
            write-Log "Running $exe /auto upgrade /dynamicupdate disable /eula accept /imageindex 4"
            Start-Process -FilePath $exe -ArgumentList "/auto upgrade /dynamicupdate disable /eula accept /imageindex 4" -Wait
        }
    }

}

Function Add-CmdHistory {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string]
        $Text
    )
    if (-not $common.PS7) {
        return
    }

    if ($global:AddHistoryLine) {
        return
    }

    $global:AddHistoryLine = $Text

    try {
        [Microsoft.PowerShell.PSConsoleReadLine]::AddToHistory($Text)
    }
    catch {}

}
Function Set-TitleBar {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string]
        $Text
    )

    $VersionString = "MemLabs $($global:Common.MemLabsVersion)"
    if ($devBranch) {
        $VersionString = "DevLabs $($global:Common.MemLabsVersion)"
    }

    if ($global:Common.OfflineMode) {
        $VersionString += " (Offline Mode)"
    }

    if ($Global:ConfigFile) {
        $config = [System.Io.Path]::GetFileNameWithoutExtension(($Global:configfile))
        $VersionString = $config + " - " + $VersionString
    }
    # Set Title bar
    $host.ui.RawUI.WindowTitle = $VersionString + " - " + $Text
}

####################
### DOT SOURCING ###
####################

# RemoveOnly profile: load only the files needed for Remove-VirtualMachine.
# Saves ~2-3s per ThreadJob worker during domain removal (skips ~20 files).
$removeOnlyProfile = ($StartupProfile -eq 'RemoveOnly')

# PS5.1 stub so callers can reference Test-VmIsLinux without loading Common.Linux.ps1,
# which uses PS7-only syntax. PS7 dot-sources the real implementation instead.
if ($PSVersionTable.PSVersion.Major -lt 7) {
    function Test-VmIsLinux {
        param ([Parameter(Mandatory = $false, ValueFromPipeline = $true)] [object]$Vm)
        if (-not $Vm) { return $false }
        if ($Vm.PSObject.Properties.Name -contains 'osFamily' -and $Vm.osFamily -eq 'Linux') { return $true }
        foreach ($prop in @('operatingSystem', 'deployedOS')) {
            if ($Vm.PSObject.Properties.Name -contains $prop) {
                $val = $Vm.$prop
                if ($val -and ($val -like 'Ubuntu*' -or $val -like 'Debian*' -or $val -like 'Linux*')) { return $true }
            }
        }
        return $false
    }
}

if ($removeOnlyProfile) {
    . $PSScriptRoot\common\Common.StorageToken.ps1
    . $PSScriptRoot\common\Common.Colors.ps1
    . $PSScriptRoot\common\Common.Config.ps1
    . $PSScriptRoot\common\Common.HyperV.ps1
    . $PSScriptRoot\common\Common.Phases.ps1
    . $PSScriptRoot\common\Common.Remove.ps1
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        . $PSScriptRoot\common\Common.Linux.ps1
    }
}
else {

. $PSScriptRoot\common\Common.StorageToken.ps1

. $PSScriptRoot\common\Common.Colors.ps1
. $PSScriptRoot\common\Common.BaseImage.ps1
. $PSScriptRoot\common\Common.Config.ps1
. $PSScriptRoot\common\Common.Phases.ps1
# Config validation is entry-point work (New-Lab, genconfig); no function in it is
# reachable from a job scriptblock. Common.Validation.Functional.ps1 is the opposite --
# 50 of its 51 functions are job-reachable -- so it stays.
if (-not $InJob) {
    . $PSScriptRoot\common\Common.Validation.ps1
}
. $PSScriptRoot\common\Common.Validation.Functional.ps1
if (-not $InJob) {
    . $PSScriptRoot\common\Common.RdcMan.ps1
    . $PSScriptRoot\common\Common.mRemoteNG.ps1
}
. $PSScriptRoot\common\Common.Remove.ps1
. $PSScriptRoot\common\Common.Maintenance.ps1
. $PSScriptRoot\common\Common.DownloadCache.ps1
. $PSScriptRoot\common\Common.ScriptBlocks.ps1
# Config wizard, menus and RDP-client writers are host-only: no function in them is
# reachable from a job scriptblock, so a job spends ~376ms compiling code it cannot call.
if (-not $InJob) {
    . $PSScriptRoot\common\Common.GenConfig.ps1
    . $PSScriptRoot\common\Common.GenConfig.NewDomain.ps1
    . $PSScriptRoot\common\Common.GenConfig.CmMenus.ps1
    . $PSScriptRoot\common\Common.GenConfig.PKIMenus.ps1
    . $PSScriptRoot\common\Common.GenConfig.Existing.ps1
    . $PSScriptRoot\common\Common.GenConfig.ConfigFiles.ps1
    . $PSScriptRoot\common\Common.GenConfig.Summary.ps1
    . $PSScriptRoot\common\Common.GenConfig.RoleMenus.ps1
    . $PSScriptRoot\common\Common.GenConfig.Validation.ps1
    . $PSScriptRoot\common\Common.GenConfig.AddVM.ps1
    . $PSScriptRoot\common\Common.GenConfig.VMList.ps1
    . $PSScriptRoot\common\Common.GenConfig.DiskMenu.ps1
    . $PSScriptRoot\common\Common.GenConfig.Help.ps1
    . $PSScriptRoot\common\Common.Layout.ps1
}
. $PSScriptRoot\common\Common.Health.ps1
. $PSScriptRoot\common\Common.HyperV.ps1
if ($PSVersionTable.PSVersion.Major -ge 7) {
    . $PSScriptRoot\common\Common.Linux.ps1
}
. $PSScriptRoot\common\Common.snapshots.ps1
# Host-side PKI is driven from New-Lab (Install-PKI); the in-guest PKI work is DSC.
if (-not $InJob) {
    . $PSScriptRoot\common\Common.PKI.ps1
    . $PSScriptRoot\common\Common.menu.ps1
}


if ($PSVersionTable.PSVersion -ge [Version]'7.4') {
    $PS7 = $true
    $PSStyle.Progress.Style = "`e[38;5;123m"
    $psstyle.Formatting.TableHeader = "`e[3;38;5;195m"
    $psstyle.Formatting.Warning = "`e[33m"
    # Set-PS7ProgressWidth is the only job-reachable caller and already guards with
    # Get-Command plus a [Console]::WindowWidth fallback.
    if (-not $InJob) {
        . $PSScriptRoot\common\Common.NewMenu.ps1
    }
    . $PSScriptRoot\common\Common.PS7.ps1
}

} # end else (non-RemoveOnly profile)

# Stamp what THIS PROCESS loaded, not what is on disk. The phase scriptblocks
# ($global:VM_Config, $global:Phase10Job, ...) are parsed once, when Common.ScriptBlocks.ps1
# is dot-sourced, and Start-Job/Start-ThreadJob hands the job that already-parsed object --
# so the `. Common.ps1 -InJob` at the top of each job refreshes FUNCTIONS but never a
# scriptblock BODY. A launcher left open across a `git pull` keeps running the old bodies
# while the log's Git banner (read from the working tree at deploy time) reports the new
# commit; that mismatch has silently invalidated more than one investigation.
if (-not $InJob) {
    $global:MemLabsCodeLoadStamp = [pscustomobject]@{ LoadedUtc = [datetime]::UtcNow; ProcessId = $PID }
}

function Get-MemLabsStaleSourceFile {
    # Launcher-resident .ps1 files edited since this process parsed them. A non-empty result
    # means edits inside scriptblock bodies in those files are NOT running, whatever the
    # Git banner says -- only a restart picks them up.
    if (-not $global:MemLabsCodeLoadStamp) { return @() }
    $loadedUtc = $global:MemLabsCodeLoadStamp.LoadedUtc
    $files = @(Get-ChildItem -Path $PSScriptRoot -Filter *.ps1 -File -ErrorAction SilentlyContinue) +
    @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'common') -Filter *.ps1 -File -ErrorAction SilentlyContinue)
    return @($files | Where-Object { $_.LastWriteTimeUtc -gt $loadedUtc } | Sort-Object LastWriteTimeUtc -Descending)
}

############################
### Common Object        ###
############################

if (-not $PSBoundParameters.ContainsKey('StartupProfile') -and $FastInit.IsPresent) {
    $StartupProfile = "Fast"
}

$profileSkipStorageInit = $false
$profileSkipMaintenanceRefresh = $false
$profileSkipEnvironmentDetection = $false
$profileSkipHostPreparation = $false

if ($StartupProfile -eq "Fast" -or $removeOnlyProfile) {
    $profileSkipStorageInit = $true
    $profileSkipMaintenanceRefresh = $true
    $profileSkipEnvironmentDetection = $true
    $profileSkipHostPreparation = $true
}

$effectiveSkipStorageInit = $profileSkipStorageInit -or $SkipStorageInit.IsPresent
$effectiveSkipMaintenanceRefresh = $profileSkipMaintenanceRefresh -or $SkipMaintenanceRefresh.IsPresent
$effectiveSkipEnvironmentDetection = $profileSkipEnvironmentDetection -or $SkipEnvironmentDetection.IsPresent
$effectiveSkipHostPreparation = $profileSkipHostPreparation -or $SkipHostPreparation.IsPresent

# Jobs inherit context from the parent process; skip expensive probes
# that are irrelevant inside Start-Job / ThreadJob workers.
if ($InJob) {
    $effectiveSkipEnvironmentDetection = $true
    if (-not $GetLatestHotfixVersion) {
        $effectiveSkipMaintenanceRefresh = $true
    }
    $effectiveSkipHostPreparation = $true
}

# $Common.Initialized alone cannot gate this block: -InJob, -FastInit and a
# default load all set it to $true while delivering very different objects
# (measured -- both of the first two leave $Common.LocalAdmin null and
# OfflineMode true, which makes every later Invoke-VmCommand return a bare
# $false). Whoever loaded first therefore capped everyone after them, and each
# entry point grew its own `$Common.Initialized = $false` workaround. Record
# what this load ATTEMPTS, and re-initialize when a later caller asks for
# something the loaded one skipped. Strictly an upgrade: a request for the same
# or fewer capabilities (every job, which is the hot path) still short-circuits.
$requestedInitCapabilities = @{
    StorageInit          = (-not $effectiveSkipStorageInit)
    MaintenanceRefresh   = (-not $effectiveSkipMaintenanceRefresh)
    EnvironmentDetection = (-not $effectiveSkipEnvironmentDetection)
    HostPreparation      = (-not $effectiveSkipHostPreparation)
}

$initUpgradeReason = $null
if ($Common.Initialized) {
    if ($Common.InitCapabilities) {
        $gained = @(foreach ($cap in 'StorageInit', 'MaintenanceRefresh', 'EnvironmentDetection', 'HostPreparation') {
                if ($requestedInitCapabilities[$cap] -and -not $Common.InitCapabilities[$cap]) { $cap }
            })
        if ($gained.Count -gt 0) { $initUpgradeReason = $gained -join ', ' }
    }
    elseif ($requestedInitCapabilities['StorageInit'] -and $null -eq $Common.LocalAdmin) {
        # No stamp means this $Common predates the capability record (a launcher
        # left open across the update). Ask the object rather than assume it is
        # complete -- assuming would be the same first-loader-wins trap. A missing
        # LocalAdmin proves the load that built it produced no credential. Fires at
        # most once: the rebuilt $Common carries InitCapabilities either way.
        $initUpgradeReason = 'StorageInit (unstamped $Common, no LocalAdmin)'
    }
}

if (-not $Common.Initialized -or $initUpgradeReason) {

    if ($initUpgradeReason) {
        Write-Log "Common: re-initializing to add $initUpgradeReason -- the loaded init skipped it" -LogOnly
    }

    try {
        Write-Progress2 "MemLabs initializing" -Status "Starting..." -PercentComplete 0
        $Global:ProgressPreference = 'SilentlyContinue'
        if (-not $InJob) {
            try {
                $currentProcess = [System.Diagnostics.Process]::GetCurrentProcess()
                if ($currentProcess.PriorityClass -ne [System.Diagnostics.ProcessPriorityClass]::High) {
                    $currentProcess.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::High
                }
            }
            catch {}
        }
    }
    catch {}
    finally {
        $Global:ProgressPreference = 'Continue'
    }
    Write-Progress2 "MemLabs initializing" -Status "Please Wait..." -PercentComplete 1
    $global:vm_remove_list = @()
    $global:init_failed = $false
    $global:AddHistoryLine = $null
    $Global:MenuHistory = $null
    $global:GenConfigErrorMessages = $null
    $global:existingMachines = $null
    $global:DisableSmartUpdate = $false


    try {
        ###################
        ### GIT BRANCH  ###
        ###################

        $startupCachePath = New-Directory -DirectoryPath (Join-Path $PSScriptRoot "cache")
        $gitBranchCacheFile = Join-Path $startupCachePath "git-branch-context.json"

        $image = (Join-Path $PSScriptRoot "MemLabs.png")
        if ($InJob -and -not $PSBoundParameters.ContainsKey('DevBranch')) {
            # Jobs don't need git status; default to non-dev branch
            $devBranch = $false
        }
        elseif (-not $PSBoundParameters.ContainsKey('DevBranch')) {
            Write-Progress2 "MemLabs initializing" -Status "Checking Git Status" -PercentComplete 2
            write-log "$($env:ComputerName) is running git branch from $($pwd.Path)" -LogOnly
            $devBranch = $false
            $currentBranch = $null

            if (-not $DisableGitBranchCache) {
                try {
                    if (Test-Path $gitBranchCacheFile) {
                        $cachedGitBranchContextRaw = Get-Content $gitBranchCacheFile -ErrorAction SilentlyContinue
                        if (-not [string]::IsNullOrWhiteSpace($cachedGitBranchContextRaw)) {
                            $cachedGitBranchContext = $cachedGitBranchContextRaw | ConvertFrom-Json
                            if ($cachedGitBranchContext -and $cachedGitBranchContext.GeneratedOnUtc -and $cachedGitBranchContext.CurrentBranch) {
                                $cachedGitGeneratedOnUtc = [DateTime]::Parse($cachedGitBranchContext.GeneratedOnUtc)
                                $gitCacheAgeMinutes = [Math]::Abs(((Get-Date).ToUniversalTime() - $cachedGitGeneratedOnUtc).TotalMinutes)
                                if ($gitCacheAgeMinutes -le $GitBranchCacheMinutes) {
                                    $currentBranch = $cachedGitBranchContext.CurrentBranch
                                    $cachedIsDevBranch = $false
                                    if ($null -ne $cachedGitBranchContext.IsDevBranch) {
                                        if ($cachedGitBranchContext.IsDevBranch -is [bool]) {
                                            $cachedIsDevBranch = $cachedGitBranchContext.IsDevBranch
                                        }
                                        elseif ($cachedGitBranchContext.IsDevBranch.PSObject.Properties.Name -contains "IsPresent") {
                                            $cachedIsDevBranch = [bool]$cachedGitBranchContext.IsDevBranch.IsPresent
                                        }
                                        else {
                                            $cachedIsDevBranch = [bool]$cachedGitBranchContext.IsDevBranch
                                        }
                                    }
                                    $devBranch = $cachedIsDevBranch
                                    Write-Log "Loaded git branch context from cache (age: $([Math]::Round($gitCacheAgeMinutes, 1)) minutes)." -LogOnly
                                }
                            }
                        }
                    }
                }
                catch {
                    Write-Log "Failed reading git branch cache: $_" -LogOnly
                }
            }

            try {
                if (-not $currentBranch) {
                    if ($pwd.Path -like '*memlabs*') {
                        $currentBranch = Get-BranchName
                    }
                    else {
                        #Set the current location to the script root
                        Set-Location -Path $PSScriptRoot
                        $currentBranch = Get-BranchName
                    }
                }
            }
            catch {}

            if ($currentBranch -and $currentBranch -notmatch "main") {
                $devBranch = $true
            }

            if (-not $DisableGitBranchCache -and $currentBranch) {
                try {
                    [PSCustomObject]@{
                        GeneratedOnUtc = (Get-Date).ToUniversalTime().ToString("o")
                        CurrentBranch  = $currentBranch
                        IsDevBranch    = [bool]$devBranch
                    } | ConvertTo-Json | Set-Content -Path $gitBranchCacheFile -Encoding UTF8
                }
                catch {
                    Write-Log "Failed writing git branch cache: $_" -LogOnly
                }
            }

            if ($devBranch) {
                $image = (Join-Path $PSScriptRoot "DevLabs.png")
            }
        }

        # Write progress
        Set-BackgroundImage $image "right" (50 - 1) "uniform" -InJob:$InJob
        # PS Version
        $PS7 = $false
        Set-BackgroundImage $image "right" (50 - 3) "uniform" -InJob:$InJob
        Write-Progress2 "MemLabs initializing" -Status "Checking PS Version" -PercentComplete 3
        if ($PSVersionTable.PSVersion.Major -eq 7) {
            $PS7 = $true
            $PSStyle.Progress.Style = "`e[38;5;123m"
            $psstyle.Formatting.TableHeader = "`e[3;38;5;195m"
            $psstyle.Formatting.Warning = "`e[33m"

        }

        # Set-StrictMode -Off
        # if ($devBranch) {
        #     Set-StrictMode -Version 1.0
        # }
        Set-BackgroundImage $image "right" (50 - 5) "uniform" -InJob:$InJob
        Write-Progress2 "MemLabs initializing" -Status "Checking Directories" -PercentComplete 5
        # Paths
        $staging = New-Directory -DirectoryPath (Join-Path $PSScriptRoot "baseimagestaging")           # Path where staged files for base image creation go
        $storagePath = New-Directory -DirectoryPath (Join-Path $PSScriptRoot "azureFiles")             # Path for downloaded files
        $logsPath = New-Directory -DirectoryPath (Join-Path $PSScriptRoot "logs")                      # Path for log files
        $initCachePath = $startupCachePath                                                                 # Path for init-time cache files
        $initContextCacheFile = Join-Path $initCachePath "init-context.json"
        $hotfixVersionCacheFile = Join-Path $initCachePath "latest-hotfix-version.json"
        $desktopPath = [Environment]::GetFolderPath("Desktop")

        # Get latest hotfix version

        # Kick off environment detection in parallel (PS7 ThreadJob). The env
        # probe is the slowest cold-start step that's truly self-contained: it
        # calls Get-DnsClient + Get-NetIPAddress, and on non-Azure hosts the
        # Invoke-RestMethod to 169.254.169.254 blocks for the full 2s timeout.
        # Running it alongside the directory/setup work below overlaps that
        # wait with otherwise-serial init. The job is only started when:
        #   - PS 7 with Start-ThreadJob available (ThreadJob shares the
        #     process; ~100ms to spin up vs many seconds for Start-Job)
        #   - not running InJob
        #   - the on-disk init-context cache file looks stale (cheap mtime peek)
        #   - env detection isn't being skipped via switch/profile
        # On any of those failing, we fall through to the existing inline
        # behavior so PS 5.1 / cache-hit / skipped paths are unchanged.
        $envProbeJob = $null
        $envCacheLikelyStale = $true
        if (-not $DisableInitContextCache) {
            try {
                if (Test-Path $initContextCacheFile) {
                    $cacheAgeMin = ((Get-Date) - (Get-Item $initContextCacheFile -ErrorAction Stop).LastWriteTime).TotalMinutes
                    if ($cacheAgeMin -le $InitContextCacheMinutes) {
                        $envCacheLikelyStale = $false
                    }
                }
            }
            catch {}
        }
        if ($PS7 -and -not $InJob -and -not $effectiveSkipEnvironmentDetection -and $envCacheLikelyStale `
                -and (Get-Command -Name Start-ThreadJob -ErrorAction SilentlyContinue)) {
            try {
                $envProbeJob = Start-ThreadJob -Name "MemLabs-EnvProbe" -ScriptBlock {
                    $result = [PSCustomObject]@{ CorpNetInterfaceIndex = $null; IsAzureVM = $false }
                    try {
                        $dnsClient = Get-DnsClient -ErrorAction SilentlyContinue | Where-Object { $_.ConnectionSpecificSuffix -eq "corp.microsoft.com" } | Select-Object -First 1
                        if ($dnsClient) { $result.CorpNetInterfaceIndex = $dnsClient.InterfaceIndex }
                    }
                    catch {}
                    try {
                        if (Get-NetIPAddress -AddressFamily IPV4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -eq "10.1.0.4" }) {
                            $result.IsAzureVM = $true
                        }
                    }
                    catch {}
                    if (-not $result.IsAzureVM) {
                        try {
                            $meta = Invoke-RestMethod -Uri "http://169.254.169.254/metadata/instance?api-version=2021-02-01" -Headers @{ Metadata = "true" } -TimeoutSec 2 -ErrorAction Stop
                            if ($meta -and $meta.compute -and $null -ne $meta.compute.azEnvironment) {
                                $result.IsAzureVM = $true
                            }
                        }
                        catch {}
                    }
                    return $result
                }
            }
            catch {
                $envProbeJob = $null
            }
        }

        Set-BackgroundImage $image "right" (50 - 7) "uniform" -InJob:$InJob
        Write-Progress2 "MemLabs initializing" -Status "Loading Global Configuration" -PercentComplete 7
        # Common global props

        # Is CorpNet Host?
        $corpNetInterfaceIndex = $null
        $isAzureVM = $false
        $loadedInitContextCache = $false
        if (-not $DisableInitContextCache) {
            try {
                if (Test-Path $initContextCacheFile) {
                    $cachedInitContextRaw = Get-Content $initContextCacheFile -ErrorAction SilentlyContinue
                    if (-not [string]::IsNullOrWhiteSpace($cachedInitContextRaw)) {
                        $cachedInitContext = $cachedInitContextRaw | ConvertFrom-Json
                        if ($cachedInitContext -and $cachedInitContext.GeneratedOnUtc) {
                            $cachedGeneratedOnUtc = [DateTime]::Parse($cachedInitContext.GeneratedOnUtc)
                            $cacheAgeMinutes = [Math]::Abs(((Get-Date).ToUniversalTime() - $cachedGeneratedOnUtc).TotalMinutes)
                            if ($cacheAgeMinutes -le $InitContextCacheMinutes) {
                                $corpNetInterfaceIndex = $cachedInitContext.CorpNetInterfaceIndex
                                $isAzureVM = [bool]$cachedInitContext.IsAzureVM
                                $loadedInitContextCache = $true
                                Write-Log "Loaded initialization context from cache (age: $([Math]::Round($cacheAgeMinutes, 1)) minutes)." -LogOnly
                            }
                        }
                    }
                }
            }
            catch {
                Write-Log "Failed reading initialization context cache: $_" -LogOnly
            }
        }

        if (-not $InJob) {
            $colors = Get-Colors
            if (-not $loadedInitContextCache) {
                # Prefer the background ThreadJob result when available; falls
                # through to inline probing otherwise (PS 5.1, job failed to
                # start, or env detection skipped).
                $envFromJob = $null
                if ($envProbeJob) {
                    try {
                        $envFromJob = Receive-Job -Job $envProbeJob -Wait -AutoRemoveJob -ErrorAction SilentlyContinue
                    }
                    catch {
                        Write-Log "Background env probe job failed: $_" -LogOnly
                        $envFromJob = $null
                    }
                    $envProbeJob = $null
                }

                if ($envFromJob) {
                    $corpNetInterfaceIndex = $envFromJob.CorpNetInterfaceIndex
                    $isAzureVM = [bool]$envFromJob.IsAzureVM
                }
                else {
                    $dnsClient = Get-DnsClient | Where-Object { $_.ConnectionSpecificSuffix -eq "corp.microsoft.com" } | Select-Object -First 1
                    if ($dnsClient) {
                        $corpNetInterfaceIndex = $dnsClient.InterfaceIndex
                    }

                    if (-not $effectiveSkipEnvironmentDetection) {
                        # The 10.1.0.4 NIC check is specific to one Azure
                        # environment's address plan; other environments use a
                        # different gateway/subnet, so it can't be the sole
                        # signal. IMDS is the authoritative, environment-agnostic
                        # probe -- always fall back to it when the NIC check
                        # doesn't match. ($meta must be cleared first so a stale
                        # value from a failed call can't be misread as success.)
                        if (Get-NetIPAddress -AddressFamily IPV4 | Where-Object { $_.IPAddress -eq "10.1.0.4" }) { $isAzureVM = $true }
                        if (-not $isAzureVM) {
                            $meta = $null
                            try { $meta = Invoke-RestMethod -Uri "http://169.254.169.254/metadata/instance?api-version=2021-02-01" -Headers @{ Metadata = "true" } -TimeoutSec 2 -ErrorAction Stop }
                            catch {}
                            if ($meta -and $meta.compute -and $null -ne $meta.compute.azEnvironment) {
                                $isAzureVM = $true
                            }
                        }
                    }
                    else {
                        Write-Log "Skipping Azure/environment detection during initialization." -LogOnly
                    }
                }

                if (-not $DisableInitContextCache) {
                    try {
                        [PSCustomObject]@{
                            GeneratedOnUtc       = (Get-Date).ToUniversalTime().ToString("o")
                            CorpNetInterfaceIndex = $corpNetInterfaceIndex
                            IsAzureVM            = $isAzureVM
                        } | ConvertTo-Json | Set-Content -Path $initContextCacheFile -Encoding UTF8
                    }
                    catch {
                        Write-Log "Failed writing initialization context cache: $_" -LogOnly
                    }
                }
            }
            else {
                Write-Log "Skipping environment probes because initialization context cache is fresh." -LogOnly
                # Cache was loaded after we speculatively started the env probe
                # job (the on-disk mtime check is approximate). Discard the job
                # so we don't leak a runspace.
                if ($envProbeJob) {
                    try { Remove-Job -Job $envProbeJob -Force -ErrorAction SilentlyContinue | Out-Null } catch {}
                    $envProbeJob = $null
                }
            }
        }
        elseif (-not $loadedInitContextCache) {
            # InJob path: child jobs (e.g. Phase 10 maintenance) get IsAzureVM
            # only from the on-disk cache above -- the inline probe lives in the
            # -not $InJob branch and never runs here. If the cache is missing or
            # stale, fall back to a cheap inline probe so Azure-gated work (e.g.
            # Fix_ActivateWindows) still registers instead of silently defaulting
            # IsAzureVM to $false and dropping the fix.
            if (-not $effectiveSkipEnvironmentDetection) {
                try {
                    if (Get-NetIPAddress -AddressFamily IPV4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -eq "10.1.0.4" }) { $isAzureVM = $true }
                }
                catch {}
                if (-not $isAzureVM) {
                    try {
                        $meta = Invoke-RestMethod -Uri "http://169.254.169.254/metadata/instance?api-version=2021-02-01" -Headers @{ Metadata = "true" } -TimeoutSec 2 -ErrorAction Stop
                        if ($meta -and $meta.compute -and $null -ne $meta.compute.azEnvironment) { $isAzureVM = $true }
                    }
                    catch {}
                }
            }
        }

        if (-not $header1) {
            $header1 = "==="
        }
        if (-not $header2) {
            $header2 = "+++"
        }

        if (-not $breakPrefix) {
            $breakPrefix = "-----"
        }

        # Load sticky mouse preference from cache (default: enabled)
        $mouseEnabled = $true
        $mousePrefFile = Join-Path $startupCachePath "mouse-preference.json"
        if (Test-Path $mousePrefFile) {
            try {
                $mousePref = Get-Content $mousePrefFile -ErrorAction SilentlyContinue | ConvertFrom-Json
                if ($null -ne $mousePref.MouseEnabled) {
                    $mouseEnabled = [bool]$mousePref.MouseEnabled
                }
            }
            catch {}
        }

        # Version lives in version.json so bumping a release no longer rewrites this 11k-line
        # file. Absence is fatal on purpose: MemLabsVersion is stamped into VM notes and
        # LatestHotfixVersion feeds a `-ge` comparison in Common.Maintenance.ps1, so a silent
        # default would mis-stamp every VM rather than fail.
        $versionFile = Join-Path $PSScriptRoot "version.json"
        $versionData = $null
        try {
            $versionData = Get-Content -LiteralPath $versionFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            throw "MemLabs version file '$versionFile' is missing or unparseable: $($_.Exception.Message)"
        }
        foreach ($versionProp in 'memLabsVersion', 'latestHotfixVersion') {
            # -is [string] is the load-bearing part: an unquoted JSON number parses as a Double
            # and 260811.0 silently becomes 260811.
            if (-not ($versionData.$versionProp -is [string]) -or [string]::IsNullOrWhiteSpace($versionData.$versionProp)) {
                throw "MemLabs version file '$versionFile' has no usable string '$versionProp'. The value must be quoted."
            }
        }

        $global:Common = [PSCustomObject]@{
            MemLabsVersion              = $versionData.memLabsVersion
            LatestHotfixVersion         = $versionData.latestHotfixVersion
            PS7                         = $PS7
            Initialized                 = $true
            InitCapabilities            = $requestedInitCapabilities
            InJob                       = $InJob
            TempPath                    = New-Directory -DirectoryPath (Join-Path $PSScriptRoot "temp")             # Path for temporary files
            ConfigPath                  = New-Directory -DirectoryPath (Join-Path $PSScriptRoot "config")           # Path for Config files
            # ConfigSamplesPath     = New-Directory -DirectoryPath (Join-Path $PSScriptRoot "config\reserved")   # Path for Config files
            CachePath                   = New-Directory -DirectoryPath (Join-Path $PSScriptRoot "cache")            # Path for Get-List cache files
            SizeCache                   = $null                                                                     # Cache for Memory Assigned, and Disk Usage
            NetCache                    = $null                                                                     # Cache for Get-NetworkAdapter
            AzureFilesPath              = $storagePath                                                              # Path for downloaded files
            AzureImagePath              = New-Directory -DirectoryPath (Join-Path $storagePath "os")                # Path to store sysprepped gold image after customization
            AzureIsoPath                = New-Directory -DirectoryPath (Join-Path $storagePath "iso")               # Path for ISO's (typically for SQL)
            AzureOSIsoPath              = New-Directory -DirectoryPath (Join-Path $storagePath "osiso")             # Path for ISO's (typically for Windows)
            AzureToolsPath              = New-Directory -DirectoryPath (Join-Path $storagePath "tools")             # Path for downloading tools to inject in the VM
            StagingAnswerFilePath       = New-Directory -DirectoryPath (Join-Path $staging "unattend")              # Path for Answer files
            StagingInjectPath           = New-Directory -DirectoryPath (Join-Path $staging "filesToInject")         # Path to files to inject in VHDX
            StagingWimPath              = New-Directory -DirectoryPath (Join-Path $staging "wim")                   # Path for WIM file imported from ISO
            StagingImagePath            = New-Directory -DirectoryPath (Join-Path $staging "vhdx-base")             # Path to store base image, before customization
            StagingVMPath               = New-Directory -DirectoryPath (Join-Path $staging "vm")                    # Path for staging VM for customization
            LogPath                     = Join-Path $logsPath "VMBuild.log"                                         # Log File
            CrashLogsPath               = New-Directory -DirectoryPath (Join-Path $logsPath "crashlogs")            # Path for crash logs
            RdcManFilePath              = Join-Path $DesktopPath "memlabs.rdg"                                      # RDCMan File
            MRemoteNGFilePath           = Join-Path $env:ProgramData "memlabs\memlabs-mremoteng.xml"                # mRemoteNG File
            VerboseEnabled              = $VerboseEnabled.IsPresent                                                 # Verbose Logging
            VerboseToLogOnly            = $false                                                                    # When true, verbose goes to log only (suppressed from console)
            VerboseTailProcess          = $null                                                                     # Process object for secondary verbose tail window
            DevBranch                   = $devBranch                                                                # Git dev branch
            Supported                   = $null                                                                     # Supported Configs
            AzureFileList               = $null
            LocalAdmin                  = $null
            FatalError                  = $null
            ActivityHeader              = $header1
            SubActivityHeader           = $header2
            BreakPrefix                 = $breakPrefix
            Colors                      = $colors
            IsAzureVM                   = $isAzureVM
            CorpNetInterfaceIndex       = $corpNetInterfaceIndex
            OfflineMode                 = $false
            MouseEnabled                = $mouseEnabled
            NewestStorageConfigFileName = "_storageConfig2026.1.json"
            StorageConfigLocation       = $null
        }

        # Storage config
        $global:StorageConfig = [PSCustomObject]@{
            StorageLocation = $null
            StorageToken    = $null
        }
        $global:DSC_Copied = @()

        # Register a one-time engine-exit handler so any buffered log lines
        # are flushed before the process terminates. Safe no-op when called
        # multiple times.
        Register-LogBufferExitFlush

        # The crash handler armed during the dot-source above, before this block ran, so
        # its target was still the %TEMP% fallback: a per-PID file, on the lab host, that
        # nothing in the run log ever names. A per-VM worker dying is the exact failure it
        # exists to explain, so put it with the logs and print the path.
        try {
            $crashHandlerPath = Join-Path $global:Common.CrashLogsPath "VMBuild.unhandled.$PID.log"
            Register-VmCrashHandler -Path $crashHandlerPath
            if ($global:ps_crashHandlerRegistered) {
                Write-Log "[CrashHandler] armed pid=$PID -> $crashHandlerPath" -LogOnly
            }
        }
        catch {
            Write-Log "[CrashHandler] could not re-point crash log to the logs folder: $($_.Exception.Message)" -Warning -LogOnly
        }

        if (-not $InJob) {
            Write-Log "Memlabs $($global:Common.MemLabsVersion) Initializing" -LogOnly
            if (-not $removeOnlyProfile) {
                Set-TitleBar "Init Phase"
            }
            Write-Log "Loading required modules." -Verbose
        }

        ### Test Storage config and access

            Set-BackgroundImage $image "right" (50 - 9) "uniform" -InJob:$InJob
            Write-Progress2 "MemLabs initializing" -Status "Checking Storage Config" -PercentComplete 9
            if (-not $effectiveSkipStorageInit) {
                try {
                    $getresults = Initialize-Storage
                }
                catch {
                    #Write-Exception $_         
                    $common.OfflineMode = $true
                    Write-Log "Exception getting storage config. Using Offline Mode" -Warning
                }
            }
            else {
                $common.OfflineMode = $true
                $getresults = $false
                Write-Log "Skipping storage initialization due to startup switches. Using Offline Mode." -LogOnly
            }
            if (-not $getresults -and -not $effectiveSkipStorageInit) {
                $common.OfflineMode = $true
                Write-Log "failed to get the storage JSON file. Using Offline Mode" -Warning
            }

            # Fail fast if the local admin (vmbuildadmin) credential could not be obtained.
            # Offline mode is only viable when that credential is ALREADY cached on disk
            # (Common.CachePath\vmbuildadmin.txt). If it is not, either storage init was
            # short-circuited before Get-LocalAdminCredential ran (missing cached
            # fileList/productID) or the SAS token is expired -- and nothing downstream
            # (Set-VMNote, Invoke-VmCommand, the Fix_* maintenance fixes, DSC) can work
            # without it. Stop here with an actionable message instead of limping into
            # maintenance and dying with an opaque "You cannot call a method on a
            # null-valued expression" from $Common.LocalAdmin.GetNetworkCredential().
            if (-not $InJob -and -not $effectiveSkipStorageInit -and $null -eq $Common.LocalAdmin) {
                if ([string]::IsNullOrWhiteSpace($Common.FatalError)) {
                    $Common.FatalError = "Local admin credential (vmbuildadmin) is unavailable. In offline mode it must be cached at '$(Join-Path $Common.CachePath 'vmbuildadmin.txt')'. Your storage config / SAS token has likely expired -- refresh the storage config (update your token and re-run) before deploying."
                }
                Write-Log "Critical: $($Common.FatalError)" -Failure
            }


            if ((-not $InJob -or $GetLatestHotfixVersion) -and -not $effectiveSkipMaintenanceRefresh -and -not $common.OfflineMode) {
                Set-BackgroundImage $image "right" (50 - 11) "uniform" -InJob:$InJob
                Write-Progress2 "MemLabs initializing" -Status "Gathering VM Maintenance Tasks" -PercentComplete 11

                $loadedHotfixCache = $false
                if (-not $DisableHotfixCache) {
                    try {
                        if (Test-Path $hotfixVersionCacheFile) {
                            $cachedHotfixRaw = Get-Content $hotfixVersionCacheFile -ErrorAction SilentlyContinue
                            if (-not [string]::IsNullOrWhiteSpace($cachedHotfixRaw)) {
                                $cachedHotfix = $cachedHotfixRaw | ConvertFrom-Json
                                if ($cachedHotfix -and $cachedHotfix.GeneratedOnUtc -and $cachedHotfix.LatestHotfixVersion) {
                                    $cachedHotfixGeneratedOnUtc = [DateTime]::Parse($cachedHotfix.GeneratedOnUtc)
                                    $hotfixCacheAgeMinutes = [Math]::Abs(((Get-Date).ToUniversalTime() - $cachedHotfixGeneratedOnUtc).TotalMinutes)
                                    if ($hotfixCacheAgeMinutes -le $HotfixCacheMinutes) {
                                        $global:Common.latestHotfixVersion = $cachedHotfix.LatestHotfixVersion
                                        $loadedHotfixCache = $true
                                        Write-Log "Loaded latest hotfix version from cache (age: $([Math]::Round($hotfixCacheAgeMinutes, 1)) minutes)." -LogOnly
                                    }
                                }
                            }
                        }
                    }
                    catch {
                        Write-Log "Failed reading hotfix cache: $_" -LogOnly
                    }
                }

                if (-not $loadedHotfixCache) {
                    $vmFixes = Get-VMFixes -ReturnDummyList
                    if ($vmFixes) {
                        $latestHotfixVersion = $vmFixes | Sort-Object { ConvertTo-MemLabsVersion $_.FixVersion } -Descending | Select-Object -First 1 -ExpandProperty FixVersion
                        if ($latestHotfixVersion) {
                            $global:Common.latestHotfixVersion = $latestHotfixVersion

                            if (-not $DisableHotfixCache) {
                                try {
                                    [PSCustomObject]@{
                                        GeneratedOnUtc      = (Get-Date).ToUniversalTime().ToString("o")
                                        LatestHotfixVersion = $latestHotfixVersion
                                    } | ConvertTo-Json | Set-Content -Path $hotfixVersionCacheFile -Encoding UTF8
                                }
                                catch {
                                    Write-Log "Failed writing hotfix cache: $_" -LogOnly
                                }
                            }
                        }
                    }
                }
            }
            else {
                Write-Log "Skipping maintenance refresh during initialization." -LogOnly
            }
        
        ### Set supported options
        Set-BackgroundImage $image "right" (50 - 13) "uniform" -InJob:$InJob
        Write-Progress2 "MemLabs initializing" -Status "Gathering Supported Options" -PercentComplete 13
        Write-Log "Init: Setting supported options..." -LogOnly
        Flush-LogBuffer -All
        if (-not $InJob) {
            Set-SupportedOptions
        }

        # Generate cache
        $i = 14
        if (-not $InJob.IsPresent) {
            Write-Log "Init: Starting host preparation (DHCP, registry, cache cleanup)..." -LogOnly
            Flush-LogBuffer -All

            if (-not $effectiveSkipHostPreparation) {
                try {
                    Start-DHCP | out-null
                }
                catch {
                    Write-Log "Skipping DHCP startup preparation due to error: $_" -Warning
                }

                #disable Sticky Keys
                Set-ItemProperty -Path "HKCU:\Control Panel\Accessibility\StickyKeys" -Name "Flags" -Type String -Value "506"
                Set-ItemProperty -Path "HKCU:\Control Panel\Accessibility\ToggleKeys" -Name "Flags" -Type String -Value "58"
                Set-ItemProperty -Path "HKCU:\Control Panel\Accessibility\Keyboard Response" -Name "Flags" -Type String -Value "122"
            }
            else {
                Write-Log "Skipping host preparation during initialization." -LogOnly
            }

            try {
                if ($global:common.CachePath) {
                    $threshold = 2
                    Get-ChildItem -Path $global:common.CachePath -File -Filter "*.json" | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$threshold) } | Remove-Item -Force -ProgressAction SilentlyContinue | out-null
                }
            }
            catch {}

            try {
                Get-ChildItem -Force 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\NetworkList\Profiles' -Recurse | ForEach-Object { $_.PSChildName } | ForEach-Object { Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\NetworkList\Profiles\$($_)" -Name "Category" -Value 1 }
            }
            catch {}

            # Retrieve VM List, and cache results
            Set-BackgroundImage $image "right" (50 - $i) "uniform" -InJob:$InJob

            if (-not $InJob) {
                # The background Start-Job warmup was removed: it runs in a
                # separate process so its $global:vm_List is never shared with
                # the foreground. The extra Get-VM + Get-VMNetworkAdapter calls
                # serialize behind vmms.exe and cause the foreground's first
                # Get-List call (in Test-NoRRAS → Test-Networks) to stall for
                # minutes. The foreground populates its own cache on first use.
                Write-Progress2 "MemLabs initializing" -Status "Skipping background VM warmup (foreground will populate on demand)" -PercentComplete $i
                Write-Log "Init: Skipping background VM cache warmup; foreground will populate on first Get-List call." -LogOnly
                Flush-LogBuffer -All
                $i++
                Set-BackgroundImage $image "right" (50 - $i) "uniform" -InJob:$InJob
                Write-Progress2 "MemLabs initializing" -Status "Finalizing" -PercentComplete $i

                # Start a background ThreadJob to refresh LastKnownIP for running
                # VMs. This runs after init so it doesn't contend with the
                # foreground's first Get-List call.
                Start-VMIPRefreshJob

                # Add HGS Registry key to allow local CA Cert
                New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\HgsClient" -Name "LocalCACertSupported" -Value 1 -PropertyType DWORD -Force -ErrorAction SilentlyContinue | Out-Null
            }


        }
        Set-BackgroundImage $image "right" 5 "uniform" -InJob:$InJob
        # Write progress
        Write-Progress2 "MemLabs initializing" -Completed
    }
    catch {
        Write-Log "Failed to initialize MemLabs. $_ " -Failure
        Write-Exception $_
        #Get-PSCallStack | out-Host
        Write-Progress2 "MemLabs initializing" -Completed
        $global:init_failed = $true
        return
    }

}