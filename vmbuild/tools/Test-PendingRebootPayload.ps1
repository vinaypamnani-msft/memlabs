<#
.SYNOPSIS
    Bisects the 'Check pending reboot' pipeline-create failure: transport, or payload?
.DESCRIPTION
    HOST-run, read-only. Everything measured so far points AWAY from the transport:

      * a trivial `{1}` round-trip on the SAME cached session succeeds immediately
        before the failure, every time (the 510b945f readiness probe never once
        reported a problem);
      * the real scriptblock then fails in 27-42 ms -- too fast for a guest round
        trip -- and does so deterministically (1,364 retries, 0 recovered);
      * the enriched autopsy shows err1-where activity='' targetName='' and
        err1-remote='An error occurred while creating the pipeline', so NOTHING
        inside the scriptblock ever ran;
      * rebuilding the session first does not help.

    Confirm-PipelineRunspaceFix.ps1 exercises this sequence with `{ 'reboot-check' }`
    -- a trivial payload -- which is why it always reports the fixed path clean. It
    has never tested the real one. This sends progressively larger slices of the REAL
    $Test_PendingReboot body down the SAME session, back to back, so the answer is
    one of:

      all payloads pass          -> not reproducible right now; run during a build
      only the trivial passes    -> payload SIZE (serialisation limit)
      passes until slice N       -> that slice's CONTENT is the trigger
      all payloads fail          -> transport after all; the trivial probe is too weak

.PARAMETER VmName
    VM to probe. Pick one that has actually failed -- NOC-DC1 accounts for 30 of the
    'Check pending reboot' failures across the nocm logs.
.PARAMETER PrecedeWithAsJob
    Run a benign -AsJob command first. NOTE: this only mimics the SHAPE of
    "Stop Any Running DSC's" (an -AsJob call immediately before the sync one). It
    does NOT do what that command actually does, and a 5x5 sweep with it passed
    every payload -- so shape alone is not the trigger.
.PARAMETER RealStopDsc
    Send what Stop_RunningDSC really does: drain the guest job table, remove the DSC
    configuration documents, and FORCE-KILL WmiPrvSE + WmiApSrv in the guest. That
    kill is the part the benign version omits and is the strongest remaining suspect.
    The build already does this on every VM at the start of every phase, so it is not
    an unusual thing to do to the guest -- but it IS disruptive, hence opt-in.
.PARAMETER StressThreads
    Starve the HOST threadpool while probing, the way Confirm-PipelineRunspaceFix.ps1
    does. The failure only ever appears during a build, so host contention is the
    other half of the missing context.
.EXAMPLE
    .\Test-PendingRebootPayload.ps1 -VmName NOC-DC1 -VmDomainName nocm.com -RealStopDsc
.EXAMPLE
    .\Test-PendingRebootPayload.ps1 -VmName NOC-DC1 -VmDomainName nocm.com -RealStopDsc -StressThreads 64 -Runs 20
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$VmName,
    [Parameter(Mandatory)][string]$VmDomainName,
    [int]$Runs = 5,
    [switch]$PrecedeWithAsJob,
    [switch]$RealStopDsc,
    [int]$StressThreads = 0
)

$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'Common.ps1') | Out-Null

# Slices of the real $Test_PendingReboot, each adding one construct. Kept literal
# rather than imported: $Test_PendingReboot is defined inside another scriptblock
# and is not reachable from here.
$payloads = [ordered]@{
    '01-trivial' = { 1 }

    '02-registry-only' = {
        $reasons = @()
        if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $reasons += 'CBS\RebootPending' }
        if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $reasons += 'WindowsUpdate\RebootRequired' }
        @{ Reasons = $reasons }
    }

    '03-plus-cim-ccm' = {
        $reasons = @()
        try {
            $ccmReboot = Invoke-CimMethod -Namespace 'root\ccm\ClientSDK' -ClassName CCM_ClientUtilities -MethodName DetermineIfRebootPending -ErrorAction SilentlyContinue
            if ($ccmReboot -and $ccmReboot.RebootPending) { $reasons += 'SCCM\RebootPending' }
        }
        catch {}
        @{ Reasons = $reasons }
    }

    '04-plus-pfro-parse' = {
        $reasons = @()
        $pfro = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations
        if ($pfro) {
            $opLines = @()
            for ($i = 0; $i -lt $pfro.Count; $i += 2) {
                $src = $pfro[$i] -replace '^\\\?\?\\', ''
                $rawDst = if ($i + 1 -lt $pfro.Count) { $pfro[$i + 1] } else { $null }
                $dst = if ($rawDst) { $rawDst -replace '^\\\?\?\\', '' } else { '(delete)' }
                $opLines += "$src -> $dst"
            }
            $reasons += ($opLines -join "`n")
        }
        @{ Reasons = $reasons }
    }

    # Same character count as the largest slice but no real work -- separates SIZE
    # from CONTENT. If this fails and 02 passes, it is serialisation size.
    '05-bulk-comment-only' = [scriptblock]::Create(('# padding' + ("`n# " + ('x' * 100)) * 40) + "`n1")
}

"VM       : $VmName ($VmDomainName)"
"Runs     : $Runs   PrecedeWithAsJob=$PrecedeWithAsJob  RealStopDsc=$RealStopDsc  StressThreads=$StressThreads"
"Payloads : $(@($payloads.Keys) -join ', ')"
""

# The failure has never been seen on an idle host. Starve the threadpool the way
# Confirm-PipelineRunspaceFix.ps1 does, so the launcher is under the same pressure.
$stressRunspaces = @()
if ($StressThreads -gt 0) {
    for ($i = 0; $i -lt $StressThreads; $i++) {
        $psx = [powershell]::Create()
        $null = $psx.AddScript({ $end = (Get-Date).AddMinutes(20); while ((Get-Date) -lt $end) { $null = 1..2000 | ForEach-Object { $_ * 2 } } })
        $null = $psx.BeginInvoke()
        $stressRunspaces += $psx
    }
    "  (started $StressThreads stress worker(s))"
}

# What Stop_RunningDSC actually does to the guest. The WmiPrvSE/WmiApSrv kill is the
# part -PrecedeWithAsJob omits, and the build performs it on every VM every phase.
$realStopDscBody = {
    try { Get-Job | Remove-Job -Force -ErrorAction SilentlyContinue } catch {}
    try { Remove-DscConfigurationDocument -Stage Current, Pending, Previous -Force -ErrorAction SilentlyContinue | Out-Null } catch {}
    try {
        Get-Process WmiPrvSE -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Get-Process WmiApSrv -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    catch {}
    'stopdsc-real'
}

$results = [ordered]@{}
foreach ($k in $payloads.Keys) { $results[$k] = @{ Ok = 0; Fail = 0; Errs = @() } }

try {
    for ($run = 1; $run -le $Runs; $run++) {
        if ($RealStopDsc) {
            $null = Invoke-VmCommand -VmName $VmName -VmDomainName $VmDomainName -AsJob -SuppressLog `
                -DisplayName 'Stop Any Running DSC (real)' -ScriptBlock $realStopDscBody
        }
        elseif ($PrecedeWithAsJob) {
            $null = Invoke-VmCommand -VmName $VmName -VmDomainName $VmDomainName -AsJob -SuppressLog `
                -DisplayName 'Stop DSC (repro)' -ScriptBlock { Start-Sleep -Milliseconds 150; 'stopdsc' }
        }
        foreach ($k in $payloads.Keys) {
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $r = Invoke-VmCommand -VmName $VmName -VmDomainName $VmDomainName -SuppressLog `
                -DisplayName "payload $k" -ScriptBlock $payloads[$k]
            $sw.Stop()
            $len = "$($payloads[$k])".Length
            if ($r.ScriptBlockFailed) {
                $results[$k].Fail++
                $msg = ''
                try { if ($r.ErrorDetails) { $msg = (@($r.ErrorDetails) -join ' | ') } } catch {}
                $results[$k].Errs += "$([math]::Round($sw.Elapsed.TotalMilliseconds))ms $msg"
            }
            else { $results[$k].Ok++ }
            "run $run  {0,-22} len={1,-6} {2,-4} {3,6}ms" -f $k, $len, $(if ($r.ScriptBlockFailed) { 'FAIL' } else { 'ok' }), [math]::Round($sw.Elapsed.TotalMilliseconds)
        }
    }
}
finally {
    foreach ($psx in $stressRunspaces) { try { $psx.Stop(); $psx.Dispose() } catch {} }
}

""
"=== SUMMARY ==="
foreach ($k in $results.Keys) {
    "{0,-22} ok={1,-4} fail={2,-4} {3}" -f $k, $results[$k].Ok, $results[$k].Fail, (($results[$k].Errs | Select-Object -First 2) -join ' ;; ')
}
""
$trivialOk = $results['01-trivial'].Fail -eq 0
$anyRealFail = @($results.Keys | Where-Object { $_ -ne '01-trivial' -and $results[$_].Fail -gt 0 }).Count -gt 0
if ($trivialOk -and $anyRealFail) {
    "VERDICT: PAYLOAD. The trivial round-trip works on the same session while a larger one fails -- this is not the transport. The first failing slice above names the trigger."
}
elseif (-not $trivialOk) {
    "VERDICT: TRANSPORT. Even the trivial payload failed, so the session/channel is genuinely broken here."
}
elseif (-not $RealStopDsc -and $StressThreads -eq 0) {
    "VERDICT: NOT REPRODUCED, and this run did not model the trigger. A 5x5 sweep with -PrecedeWithAsJob already passed everything, which rules OUT payload size and content. Re-run with -RealStopDsc (guest WmiPrvSE/WmiApSrv kill, what the phase actually does) and -StressThreads, ideally during a build."
}
else {
    "VERDICT: NOT REPRODUCED even with RealStopDsc=$RealStopDsc StressThreads=$StressThreads. The trigger needs something still absent here -- run it against a VM mid-phase."
}
