<#
.SYNOPSIS
    Standalone repro/A-B harness for the Phase 2 "orphan progress bar" bug.

.DESCRIPTION
    Reproduces the production mechanism in isolation (no lab build required):

      * Spawns N child Start-Jobs that each emit a HIGH VOLUME of Write-Progress
        records at ActivityId 0 in a tight loop (mimics the Install-Tools /
        Invoke-VmCommand / DHCP-cmdlet flood that follows "Testing IP Address").
      * The parent polls each job's Progress stream and RE-renders a single
        managed bar per job (Id = job.Id) WITH a VM-name prefix, exactly like
        Write-JobProgress in Common.Phases.ps1.
      * The parent holds $Global:ProgressPreference = 'SilentlyContinue' between
        renders, exactly like Wait-Phase.

    The render step mirrors Write-Progress2Impl's -force path. Two modes:

      $UseLocalPref = $false  -> OLD behavior: flip $Global:ProgressPreference to
                                 'Continue' around the render. EXPECT an orphan
                                 bar (no VM prefix) to flicker at the bottom as
                                 PS7 auto-renders the child jobs' RAW ActivityId-0
                                 records during the Continue window.

      $UseLocalPref = $true   -> FIX: set a FUNCTION-LOCAL $ProgressPreference =
                                 'Continue' for the render while $Global stays
                                 'SilentlyContinue'. EXPECT no orphan bar.

.EXAMPLE
    # Reproduce the orphan bug:
    .\Repro-ProgressOrphan.ps1 -UseLocalPref:$false

.EXAMPLE
    # Verify the fix:
    .\Repro-ProgressOrphan.ps1 -UseLocalPref:$true

.NOTES
    Diagnostic/dev harness. Keep in the workspace. Run under PowerShell 7.
#>
[CmdletBinding()]
param(
    [bool]$UseLocalPref = $true,
    [int]$JobCount = 4,
    [int]$Seconds = 20,
    # When set, the child jobs (and the parent render loop) call a real DHCP
    # CIM cmdlet on every iteration. CIM cmdlets resolve ProgressPreference
    # from the GLOBAL scope of their runspace and emit genuine progress
    # records -- the ingredient the synthetic Write-Progress flood lacks. A
    # fresh Start-Job runspace defaults $Global:ProgressPreference to
    # 'Continue', so these records land in the child's Progress stream and
    # PS7 can auto-render them during the parent's -force flip window.
    [bool]$WithDhcp = $true,
    # DHCP scope to read. Auto-detected from the host's first scope when blank.
    [string]$ScopeId = "",
    # THE REAL FIX EXPERIMENT. Empirically, DHCP-off renders 4 clean stacked
    # bars but DHCP-on collapses them onto a single overwriting line for BOTH
    # -UseLocalPref values -- proving the function-local ProgressPreference
    # change in the PARENT does NOT fix the DHCP breakage. The trigger is the
    # CHILD job's DHCP CIM call: a fresh Start-Job runspace defaults
    # $Global:ProgressPreference to 'Continue', so the CIM cmdlet emits genuine
    # progress records that PS7 auto-renders (and that the parent's naive
    # last-record read surfaces), corrupting the managed panel. When this is
    # $true the child pins $Global:ProgressPreference = 'SilentlyContinue'
    # around its DHCP call -- expected to restore the 4 clean stacked bars.
    [bool]$PinChildGlobalPref = $false,
    # DECISIVE MECHANISM TEST. Empirically the PinChildGlobalPref wrap makes NO
    # difference: count stays 0 every cycle whether the DHCP call's own progress
    # is silenced or not. So suppressing CIM progress is not the fix -- merely
    # INVOKING a CIM cmdlet in the child stops its synthetic Write-Progress -Id 0
    # records from accumulating in .Progress. This switch decides WHY:
    #   * Child calls DHCP for only the FIRST N iterations, then does pure
    #     synthetic Write-Progress with NO further CIM.
    #   * If count STAYS 0 after iteration N  -> CIM permanently poisons the
    #     runspace's progress routing (fix: keep CIM out of child jobs entirely).
    #   * If count GROWS after iteration N    -> CIM only drains while ongoing
    #     (fix: move all DHCP work to the parent so children do zero CIM).
    # 0 = current behavior (DHCP every iteration). Try 3 for the test.
    [int]$DhcpFirstN = 0,
    # CANDIDATE FIX. DhcpFirstN proved a single CIM call PERMANENTLY poisons the
    # child runspace's progress routing: count stays 0 for the rest of the run
    # even after the child stops calling DHCP. So the fix is to keep the CIM
    # cmdlet OUT of the child's main runspace. When this is set, the child runs
    # each Get-DhcpServerv4Reservation in a FRESH in-process [powershell]
    # runspace (cheap -- no process spawn) so the CIM progress plumbing attaches
    # to that throwaway runspace, never the one whose .Progress the parent reads.
    # EXPECT: count grows, 4 clean stacked bars render.
    [bool]$DhcpInIsolatedRunspace = $false
)

if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Warning "This harness reproduces a PS7 auto-render behavior; run it under PowerShell 7."
}

# Diagnostic log written to the mirrored logs folder so the dev box can read
# it. Captures, per poll cycle, each job's full progress-record inventory
# (ActivityId/Activity/Percent counts) and exactly which record + Id the
# parent chose to render. This pinpoints why bars collapse: e.g. whether the
# ActivityId-0 filter is selecting nothing, or PS7 is grouping every render
# under one SourceId/line.
$logDir = Join-Path $PSScriptRoot "..\logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$script:ReproLog = Join-Path $logDir ("Repro-ProgressOrphan-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
function Write-ReproLog {
    param([string]$Message)
    $line = "{0} {1}" -f (Get-Date -Format "HH:mm:ss.fff"), $Message
    Add-Content -Path $script:ReproLog -Value $line -Encoding utf8
}
Write-Host ("Diagnostic log: {0}" -f $script:ReproLog) -ForegroundColor DarkGray
Write-ReproLog ("[Env] PS={0} Host={1} ProgressView={2} UseLocalPref={3} WithDhcp={4} PinChildGlobalPref={5} JobCount={6}" -f $PSVersionTable.PSVersion, $Host.Name, ($PSStyle.Progress.View), $UseLocalPref, $WithDhcp, $PinChildGlobalPref, $JobCount)

# Resolve a DHCP scope to exercise the CIM-progress path. If DHCP isn't
# available, fall back to the synthetic-only flood with a warning.
if ($WithDhcp) {
    if (-not (Get-Command Get-DhcpServerv4Scope -ErrorAction SilentlyContinue)) {
        Write-Warning "DhcpServer module/cmdlets not available; running synthetic-only (no DHCP CIM records)."
        $WithDhcp = $false
    }
    elseif (-not $ScopeId) {
        $ScopeId = (Get-DhcpServerv4Scope -ErrorAction SilentlyContinue | Select-Object -First 1).ScopeId.IPAddressToString
        if (-not $ScopeId) {
            Write-Warning "No DHCP scope found on this host; running synthetic-only (no DHCP CIM records)."
            $WithDhcp = $false
        }
        else {
            Write-Host ("Using DHCP scope {0} for CIM progress flood." -f $ScopeId) -ForegroundColor DarkGray
        }
    }
}

# Faithful copy of Write-Progress2Impl's -force render path. The previous
# simplified version called Write-Progress directly, which diverged from
# production in three ways that broke the repro (bars collapsed onto one line
# and the orphan only partially surfaced):
#   1. Production renders through a STEPPABLE PIPELINE built from
#      Microsoft.PowerShell.Utility\Write-Progress and invoked via the wrapping
#      function's CommandOrigin. That shared CommandOrigin is the SourceId PS7's
#      progress renderer uses to group the per-Id rows into one stacked panel.
#      A bare Write-Progress call has a different origin and the rows fight over
#      a single line.
#   2. Production prepends "  " to the Activity (indent) -- mirror it so the
#      rendered width/layout matches.
#   3. Production clamps PercentComplete to 1..99.
function Invoke-ManagedRender {
    [CmdletBinding()]
    param(
        [int]$Id,
        [string]$Activity,
        [string]$Status,
        [int]$Percent,
        [bool]$UseLocalPref
    )
    # Clamp exactly like Write-Progress2Impl.
    if ($Percent -le 1) { $Percent = 1 }
    if ($Percent -ge 100) { $Percent = 99 }
    # Indent prefix exactly like Write-Progress2Impl.
    $Activity = "  " + $Activity.Trim()
    $Status = $Status.TrimEnd()

    if ($UseLocalPref) {
        # FIX: function-local pref; $Global stays SilentlyContinue.
        $ProgressPreference = 'Continue'
    }
    else {
        # OLD: flip $Global to 'Continue' for the render window.
        $OriginalProgressPreference = $Global:ProgressPreference
        $Global:ProgressPreference = 'Continue'
    }

    $wpArgs = @{ Id = $Id; Activity = $Activity; Status = $Status; PercentComplete = $Percent }
    $wrappedCmd = $ExecutionContext.InvokeCommand.GetCommand('Microsoft.PowerShell.Utility\Write-Progress', [System.Management.Automation.CommandTypes]::Cmdlet)
    $scriptCmd = { & $wrappedCmd @wpArgs }
    $steppablePipeline = $scriptCmd.GetSteppablePipeline($myInvocation.CommandOrigin)
    $steppablePipeline.Begin($PSCmdlet)
    $steppablePipeline.Process($null)
    $steppablePipeline.End()

    if (-not $UseLocalPref) {
        $Global:ProgressPreference = $OriginalProgressPreference
    }
}

# Child job: flood ActivityId-0 progress records, like the post-IP Phase 2 work.
# When $WithDhcp, also call a real DHCP CIM cmdlet each iteration. The child
# does NOT set $Global:ProgressPreference (mirrors the unwrapped Phase 2 call
# sites), so the fresh runspace default 'Continue' lets the CIM progress
# records enter the child's Progress stream -- exactly what PS7 auto-renders.
$childScript = {
    param($VmName, $Iterations, $WithDhcp, $ScopeId, $PinChildGlobalPref, $DhcpFirstN, $DhcpInIsolatedRunspace)
    # Emit a start marker + the child's view of its own pref so the parent can
    # log whether the child even began and what ProgressPreference it inherited.
    "CHILD-START $VmName pref=$($Global:ProgressPreference) local=$ProgressPreference WithDhcp=$WithDhcp ScopeId=$ScopeId DhcpFirstN=$DhcpFirstN Isolated=$DhcpInIsolatedRunspace"
    $dhcpDone = 0
    try {
        foreach ($i in 1..$Iterations) {
            # When DhcpFirstN > 0, only call DHCP for the first N iterations so
            # the parent can observe whether .Progress starts accumulating once
            # the child stops issuing CIM calls.
            $doDhcp = $WithDhcp -and $ScopeId -and (($DhcpFirstN -le 0) -or ($i -le $DhcpFirstN))
            if ($doDhcp) {
                if ($DhcpInIsolatedRunspace) {
                    # Run the CIM cmdlet in a throwaway in-process runspace so its
                    # progress plumbing never attaches to THIS runspace (whose
                    # .Progress the parent reads). No process spawn -- much cheaper
                    # than a nested Start-Job.
                    $ps = [powershell]::Create()
                    try {
                        [void]$ps.AddScript('param($s) Get-DhcpServerv4Reservation -ScopeId $s -ErrorAction SilentlyContinue | Out-Null').AddArgument($ScopeId)
                        [void]$ps.Invoke()
                    }
                    finally { $ps.Dispose() }
                }
                elseif ($PinChildGlobalPref) {
                    # Candidate real fix: pin the child runspace's GLOBAL pref so the
                    # DHCP CIM cmdlet emits no progress records into the stream.
                    $childOrig = $Global:ProgressPreference
                    $Global:ProgressPreference = 'SilentlyContinue'
                    Get-DhcpServerv4Reservation -ScopeId $ScopeId -ErrorAction SilentlyContinue | Out-Null
                    $Global:ProgressPreference = $childOrig
                }
                else {
                    Get-DhcpServerv4Reservation -ScopeId $ScopeId -ErrorAction SilentlyContinue | Out-Null
                }
                $dhcpDone++
                if ($dhcpDone -eq 1) { "CHILD-FIRSTDHCP-OK $VmName" }
                if ($DhcpFirstN -gt 0 -and $i -eq $DhcpFirstN) { "CHILD-DHCPSTOP $VmName afterIter=$i" }
            }
            Write-Progress -Id 0 -Activity "Injecting tools" -Status "Injecting Tool $i to $VmName (Stop1 False)" -PercentComplete (($i % 100))
            Start-Sleep -Milliseconds 25
        }
    }
    catch {
        "CHILD-ERROR $VmName $($_.Exception.GetType().Name): $($_.Exception.Message)"
    }
}

Write-Host ("Starting {0} jobs. UseLocalPref={1} WithDhcp={2} PinChildGlobalPref={3}. Watch the BOTTOM of the screen for an un-prefixed orphan bar." -f $JobCount, $UseLocalPref, $WithDhcp, $PinChildGlobalPref) -ForegroundColor Cyan

# CRITICAL ORDERING (matches production): start the jobs while the parent's
# $Global:ProgressPreference is still its default 'Continue'. PowerShell 7
# PROPAGATES the parent's preference variables into Start-Job children, so a
# child started while the parent is 'SilentlyContinue' inherits that and emits
# ZERO progress records -- the parent then has nothing to render and only PS7's
# auto-forwarded merged child bar shows (the single-bar collapse). Production
# starts jobs in Start-PhaseJobs (parent pref still 'Continue') and only flips
# the parent to 'SilentlyContinue' later in Wait-Phase, so the children inherit
# 'Continue' and their progress (incl. the DHCP CIM flood) buffers -- which is
# the real orphan mechanism.
#
# Explicitly assert 'Continue' here so a same-session rerun (where a prior run
# left Global silent) still reproduces the production precondition.
$Global:ProgressPreference = 'Continue'
$jobs = @()
foreach ($n in 1..$JobCount) {
    $vmName = "ZZ-VM{0:D2}" -f $n
    $jobs += Start-Job -Name $vmName -ScriptBlock $childScript -ArgumentList $vmName, ([int]($Seconds * 40)), $WithDhcp, $ScopeId, $PinChildGlobalPref, $DhcpFirstN, $DhcpInIsolatedRunspace
}

# Now -- AFTER the children inherited 'Continue' -- flip the parent to silent,
# exactly like Wait-Phase does once the jobs are already running.
$Global:ProgressPreference = 'SilentlyContinue'

$deadline = (Get-Date).AddSeconds($Seconds)
$esc = [char]27
$script:cycle = 0
try {
    while ((Get-Date) -lt $deadline -and ($jobs | Where-Object { $_.State -eq 'Running' })) {
        $script:cycle++
        # Begin synchronized output, exactly like Wait-Phase: the terminal
        # buffers every progress redraw in this frame and paints them at once.
        # Without this the per-Id rows flicker and can visually collapse.
        [Console]::Write("$esc[?2026h")

        foreach ($job in $jobs) {
            $src = if ($job.ChildJobs.Count -gt 0) { $job.ChildJobs[0] } else { $job }
            $count = $src.Progress.Count
            # Select the last record the same way Write-JobProgress does:
            # iterate backward and take the first ActivityId-0 record that
            # isn't job-init noise. The naive last-record read surfaced the
            # child's raw DHCP CIM records as managed bars, which corrupted
            # the panel. This filter keeps the managed bar tied to the
            # synthetic 'Injecting tools' record like production.
            $last = $null
            for ($pi = $count - 1; $pi -ge 0; $pi--) {
                $cand = $src.Progress[$pi]
                if ($cand.ActivityId -eq 0 -and
                    $cand.Activity -ne "Preparing modules for first use." -and
                    $cand.Activity -ne "Compress-Archive") {
                    $last = $cand
                    break
                }
            }

            # Diagnostic: inventory the distinct ActivityIds present (detects
            # CIM-injected records) and log the chosen record + render Id.
            if ($script:cycle -le 3 -or ($script:cycle % 10 -eq 0)) {
                $actIds = @{}
                for ($pi = 0; $pi -lt $count; $pi++) {
                    $aid = $src.Progress[$pi].ActivityId
                    if (-not $actIds.ContainsKey($aid)) { $actIds[$aid] = 0 }
                    $actIds[$aid]++
                }
                $actSummary = ($actIds.GetEnumerator() | Sort-Object Name | ForEach-Object { "Id$($_.Key)x$($_.Value)" }) -join ","
                # Also capture job state, the child's Error stream, and any
                # Output markers (CHILD-START / CHILD-FIRSTDHCP-OK / CHILD-ERROR)
                # so we can tell whether the child died, blocked on DHCP, or
                # never wrote progress at all.
                $errCount = 0; $errMsg = ""
                try {
                    $errCount = $src.Error.Count
                    if ($errCount -gt 0) { $errMsg = ($src.Error[$errCount - 1]).ToString() }
                } catch {}
                $outMarkers = ""
                try {
                    $outMarkers = (@($src.Output) | Where-Object { $_ -is [string] -and $_ -like 'CHILD-*' } | Select-Object -Last 2) -join " | "
                } catch {}
                if ($last) {
                    Write-ReproLog ("[c{0}] job={1} jobId={2} state={7} count={3} actIds=[{4}] err={8}({9}) out=[{10}] -> render Id={2} act='{5}' pct={6}" -f $script:cycle, $job.Name, $job.Id, $count, $actSummary, $last.Activity, $last.PercentComplete, $job.State, $errCount, $errMsg, $outMarkers)
                }
                else {
                    Write-ReproLog ("[c{0}] job={1} jobId={2} state={5} count={3} actIds=[{4}] err={6}({7}) out=[{8}] -> NO RECORD SELECTED" -f $script:cycle, $job.Name, $job.Id, $count, $actSummary, $job.State, $errCount, $errMsg, $outMarkers)
                }
            }

            if ($last) {
                # Managed bar: prefix with VM name, render under the job's own Id.
                Invoke-ManagedRender -Id $job.Id -Activity ("{0}: {1}" -f $job.Name, $last.Activity) -Status $last.StatusDescription -Percent ([int]$last.PercentComplete) -UseLocalPref $UseLocalPref
            }
        }

        # Blanket-dismiss ActivityId 0 after each poll cycle, exactly like
        # Wait-Phase. CIM cmdlets (DHCP) write progress at Id 0 in the child;
        # this clears any orphan PS7 auto-rendered from that record.
        Invoke-ManagedRender -Id 0 -Activity "." -Status "Completed" -Percent 100 -UseLocalPref $UseLocalPref
        Microsoft.PowerShell.Utility\Write-Progress -Id 0 -Activity "." -Completed

        # Parent-side DHCP CIM call, mirroring Set-DeployConfigIPAddresses /
        # Remove-DHCPReservation that overlap Wait-Phase. CIM cmdlets resolve
        # ProgressPreference from the parent's GLOBAL scope; with the old
        # global-flip a render window can overlap this and surface an orphan.
        if ($WithDhcp -and $ScopeId) {
            Get-DhcpServerv4Reservation -ScopeId $ScopeId -ErrorAction SilentlyContinue | Out-Null
        }
        # Hold Global silent between renders, exactly like Wait-Phase.
        $Global:ProgressPreference = 'SilentlyContinue'

        # End synchronized output -- terminal paints the whole frame at once.
        [Console]::Write("$esc[?2026l")

        Start-Sleep -Milliseconds 200
    }
}
finally {
    foreach ($job in $jobs) {
        Write-Progress -Id $job.Id -Activity $job.Name -Completed
    }
    $jobs | Stop-Job -ErrorAction SilentlyContinue
    $jobs | Remove-Job -Force -ErrorAction SilentlyContinue
    $Global:ProgressPreference = 'Continue'
    Write-Host "Done." -ForegroundColor Green
}
