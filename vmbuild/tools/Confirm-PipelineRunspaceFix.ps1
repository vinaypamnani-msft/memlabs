#requires -Version 5.1
<#
.SYNOPSIS
    Confirms the Invoke-VmCommand -AsJob runspace-settle fix that closes the
    "An error occurred while creating the pipeline" race.

.DESCRIPTION
    Background (proven 2026-06-26):
      - Invoke-VmCommand -AsJob runs `Invoke-Command -Session $ps -AsJob` ON the
        CACHED session's runspace (Common.ps1). It Wait-Job's then Remove-Job's
        and returns -- but the runspace transitions Busy -> Available
        ASYNCHRONOUSLY. There is a brief settle window after Remove-Job where
        RunspaceAvailability is not yet Available.
      - In production, Stop-DSC (-AsJob) is immediately followed by the
        synchronous "Check pending reboot" probe on the SAME cached session.
        When that sync pipeline-create lands in the settle window it races the
        runspace teardown and surfaces the non-terminating engine error
        "An error occurred while creating the pipeline." (or, a few ms earlier
        while the job is still live, the clean "session availability is Busy"
        guard). Both are the same collision.
      - The fix: after Remove-Job in Invoke-VmCommand's -AsJob completed branch,
        block (bounded 10s) until the cached runspace returns to Available so
        the next synchronous reuse never lands mid-transition.

    This script runs two harnesses against a real lab VM:
      A) CONTROL (raw, bypasses the fix) -- reproduces the exact pre-fix
         sequence: ICM -Session -AsJob, Wait-Job, Remove-Job, then IMMEDIATELY a
         synchronous ICM on the same session with NO settle wait. Counts how
         many synchronous calls hit a pipeline-create / Busy / not-available
         error. This is the behavior the fix removes.
      B) FIXED (through Invoke-VmCommand) -- the production code path. After each
         Invoke-VmCommand -AsJob it asserts the cached runspace is Available
         (the fix's invariant) and then issues the synchronous Invoke-VmCommand
         probe, counting any failure. Should be 0/N with the fix in place.

    MUST be run on the lab HOST (where the VMs live) in a session that has
    Common.ps1 loaded (Get-VmSession / Invoke-VmCommand / $Common available),
    AND with the fixed Common.ps1 on disk (commit + push, then pull on the host).

.PARAMETER VmName
    Short VM name, e.g. RP1-PS1SITE.

.PARAMETER VmDomainName
    Domain FQDN used for the PSDirect domain credential, e.g. reporting1.com.
    (Get-VmSession builds DOMAIN\<localadmin-username>; the bare local
    $Common.LocalAdmin is rejected by domain-joined VMs.)

.PARAMETER Runs
    Iterations per harness. Default 50.

.PARAMETER StressThreads
    Number of in-process CPU-spinning ThreadJobs to run DURING both harnesses to
    saturate the .NET threadpool. This is what makes the race observable: on an
    idle host the runspace's Busy -> Available completion callback fires in
    microseconds, so neither the CONTROL nor the FIXED path collides. The
    production flood happens under VM_Config load (many Start-Job child processes
    saturating the host), which DELAYS that callback and stretches the settle
    window. Saturating the threadpool here reproduces that delay so the CONTROL
    (no settle wait) actually shows busy-after-Remove / pipeline errors while the
    FIXED path stays clean.
      -1 (default) = auto = 4 x logical processors
       0          = no stress (idle-host run; usually inconclusive for the CONTROL)
       N          = exactly N spinner threads

.EXAMPLE
    .\Confirm-PipelineRunspaceFix.ps1 -VmName RP1-PS1SITE -VmDomainName reporting1.com -Runs 50

.EXAMPLE
    # Force heavy threadpool starvation to make the CONTROL fail:
    .\Confirm-PipelineRunspaceFix.ps1 -VmName RP1-PS1SITE -VmDomainName reporting1.com -Runs 100 -StressThreads 32
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$VmName,
    [Parameter(Mandatory = $true)] [string]$VmDomainName,
    [int]$Runs = 50,
    [int]$StressThreads = -1
)

$ErrorActionPreference = 'Stop'

if ($StressThreads -lt 0) { $StressThreads = 4 * [Environment]::ProcessorCount }

$script:stressJobs = @()
function Start-Stress {
    param([int]$Threads)
    if ($Threads -le 0) { return }
    if (-not (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue)) {
        Write-Host "  (Start-ThreadJob unavailable; running WITHOUT stress -- CONTROL will likely be inconclusive)" -ForegroundColor DarkYellow
        return
    }
    $script:stressJobs = 1..$Threads | ForEach-Object {
        Start-ThreadJob -ThrottleLimit ($Threads + 8) -ScriptBlock {
            $x = 0.0
            while ($true) { for ($k = 0; $k -lt 250000; $k++) { $x += [math]::Sqrt($k + 1) } }
        }
    }
    Write-Host "  (stress: $Threads CPU-spinning threads engaged to starve the threadpool / delay the runspace callback)" -ForegroundColor DarkGray
}
function Stop-Stress {
    if ($script:stressJobs -and $script:stressJobs.Count) {
        $script:stressJobs | Stop-Job -ErrorAction SilentlyContinue
        $script:stressJobs | Remove-Job -Force -ErrorAction SilentlyContinue
        $script:stressJobs = @()
    }
}

# --- Ensure Common.ps1 functions are available -------------------------------
$needLoad = -not (Get-Command Invoke-VmCommand -ErrorAction SilentlyContinue) -or
            -not (Get-Command Get-VmSession   -ErrorAction SilentlyContinue)
if ($needLoad) {
    $vmbuildRoot = Split-Path -Parent $PSScriptRoot
    $commonPath = Join-Path $vmbuildRoot 'Common.ps1'
    if (-not (Test-Path $commonPath)) { throw "Could not find Common.ps1 at $commonPath. Run from an initialized vmbuild session." }
    Write-Host "Dot-sourcing $commonPath ..." -ForegroundColor DarkGray
    . $commonPath
}
if (-not $Common -or -not $Common.LocalAdmin) {
    throw "`$Common.LocalAdmin is not populated. Run this from an initialized vmbuild host session (the same one you build labs from)."
}

$errPattern = 'creating the pipeline|not available to run commands|availability is Busy|No valid sessions'

function Get-RunspaceAvail {
    param($Session)
    try { return [string]$Session.Runspace.RunspaceAvailability } catch { return '<unknown>' }
}

Write-Host ""
Write-Host "VM=$VmName  Domain=$VmDomainName  Runs=$Runs  StressThreads=$StressThreads" -ForegroundColor Cyan

# Resolve the cached session once (production reuses this exact object).
$s = Get-VmSession -VmName $VmName -VmDomainName $VmDomainName
if (-not $s) { throw "Get-VmSession returned null for $VmName (domain cred path failed)." }
Write-Host "session id=$($s.Id)  avail=$(Get-RunspaceAvail $s)" -ForegroundColor DarkGray
"sanity: $(Invoke-Command -Session $s -ScriptBlock { 'ok' })" | Write-Host -ForegroundColor DarkGray

$aErr = 0; $aBusyAfterRemove = 0; $aOut = 0
$bNotAvail = 0; $bSyncFail = 0; $bOut = 0
try {
    Start-Stress -Threads $StressThreads

    # --- Harness A: CONTROL (raw, NO settle wait = pre-fix behavior) --------------
    Write-Host ""
    Write-Host "[A] CONTROL (raw ICM -AsJob -> Wait -> Remove -> immediate sync; NO settle wait):" -ForegroundColor Yellow
    for ($i = 1; $i -le $Runs; $i++) {
        $j = Invoke-Command -Session $s -ScriptBlock { Start-Sleep -Milliseconds 150; 'bg' } -AsJob
        $j | Wait-Job | Out-Null
        Receive-Job $j | Out-Null
        Remove-Job $j -Force -ErrorAction SilentlyContinue
        # Pre-fix: no wait here. Sample the runspace state in the settle window.
        if ((Get-RunspaceAvail $s) -ne 'Available') { $aBusyAfterRemove++ }
        $e = $null
        $o = Invoke-Command -Session $s -ScriptBlock { 'fg' } -ErrorVariable e -ErrorAction SilentlyContinue
        if ($o -eq 'fg') { $aOut++ }
        if ($e -and ($e | ForEach-Object { $_.Exception.Message }) -match $errPattern) { $aErr++ }
    }
    Write-Host ("    pipelineErr/Busy/NotAvail = {0}/{1}   busy-after-Remove = {2}/{1}   out = {3}/{1}" -f $aErr, $Runs, $aBusyAfterRemove, $aOut) -ForegroundColor Yellow

    # --- Harness B: FIXED (production path through Invoke-VmCommand) --------------
    Write-Host ""
    Write-Host "[B] FIXED (Invoke-VmCommand -AsJob -> assert Available -> sync Invoke-VmCommand):" -ForegroundColor Green
    for ($i = 1; $i -le $Runs; $i++) {
        # Mimics Stop-DSC (-AsJob) immediately followed by Check pending reboot (sync).
        $null = Invoke-VmCommand -VmName $VmName -VmDomainName $VmDomainName -AsJob -SuppressLog `
            -DisplayName 'Stop DSC (repro)' -ScriptBlock { Start-Sleep -Milliseconds 150; 'stopdsc' }

        # The fix's invariant: the cached runspace must be Available the instant the
        # -AsJob call returns, so the next synchronous reuse can't collide.
        $cached = Get-VmSession -VmName $VmName -VmDomainName $VmDomainName
        if ((Get-RunspaceAvail $cached) -ne 'Available') { $bNotAvail++ }

        $r = Invoke-VmCommand -VmName $VmName -VmDomainName $VmDomainName -SuppressLog `
            -DisplayName 'Check pending reboot (repro)' -ScriptBlock { 'reboot-check' }
        if ($r.ScriptBlockOutput -eq 'reboot-check') { $bOut++ }
        if ($r.ScriptBlockFailed -or $r.ChannelBroken) { $bSyncFail++ }
    }
    Write-Host ("    runspace-not-Available-after-AsJob = {0}/{1}   sync-failed = {2}/{1}   out = {3}/{1}" -f $bNotAvail, $Runs, $bSyncFail, $bOut) -ForegroundColor Green
}
finally {
    Stop-Stress
}

Write-Host ""
$controlReproduced = ($aErr -gt 0 -or $aBusyAfterRemove -gt 0)
$fixedClean = ($bNotAvail -eq 0 -and $bSyncFail -eq 0 -and $bOut -eq $Runs)

if ($controlReproduced -and $fixedClean) {
    Write-Host "PROVEN: under load the CONTROL hit the settle window (busy-after-Remove=$aBusyAfterRemove, pipelineErr=$aErr) while the FIXED path stayed clean (0/0, $bOut/$Runs out). The settle-wait eliminates the race." -ForegroundColor Green
}
elseif ($fixedClean -and -not $controlReproduced) {
    Write-Host "INCONCLUSIVE: the FIXED path is clean ($bOut/$Runs), but the CONTROL did NOT reproduce the race on this host (busy-after-Remove=0, pipelineErr=0) -- the threadpool wasn't starved enough to stretch the settle window." -ForegroundColor DarkYellow
    Write-Host "  Re-run with more pressure, e.g. -StressThreads $([int](8 * [Environment]::ProcessorCount)) -Runs 200, or run during an actual VM_Config build." -ForegroundColor DarkYellow
}
elseif (-not $fixedClean) {
    Write-Host "ATTENTION: the FIXED path showed not-Available=$bNotAvail sync-failed=$bSyncFail out=$bOut/$Runs -- is the fixed Common.ps1 actually loaded in this session?" -ForegroundColor Red
}

