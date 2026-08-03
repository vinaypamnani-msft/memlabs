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
    VM to probe. Use one that has failed, e.g. FAB-CS1SQLAO2 or MR1-DC1.
.PARAMETER PrecedeWithAsJob
    Run an -AsJob command first, mimicking "Stop Any Running DSC's" -- the operation
    the failure most often follows.
.EXAMPLE
    .\Test-PendingRebootPayload.ps1 -VmName MR1-DC1 -VmDomainName mpreplica.com -PrecedeWithAsJob
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$VmName,
    [Parameter(Mandatory)][string]$VmDomainName,
    [int]$Runs = 5,
    [switch]$PrecedeWithAsJob
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
"Runs     : $Runs   PrecedeWithAsJob=$PrecedeWithAsJob"
"Payloads : $(@($payloads.Keys) -join ', ')"
""

$results = [ordered]@{}
foreach ($k in $payloads.Keys) { $results[$k] = @{ Ok = 0; Fail = 0; Errs = @() } }

for ($run = 1; $run -le $Runs; $run++) {
    if ($PrecedeWithAsJob) {
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
else {
    "VERDICT: NOT REPRODUCED in this window. Re-run during an actual build, or with -PrecedeWithAsJob, on a VM that has failed before."
}
