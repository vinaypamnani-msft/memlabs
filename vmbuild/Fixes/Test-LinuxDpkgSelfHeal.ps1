<#
.SYNOPSIS
    Verify the Linux dpkg defense-in-depth (consistency guard + known-good
    restore + last-resort rebuild) against a real VM -- ideal for confirming a
    box with a corrupt /var/lib/dpkg/status self-heals BEFORE you rebuild it.

.DESCRIPTION
    Run this on the memlabs HOST (the machine that runs New-Lab), against a
    deployed Linux VM. It:
      1. Probes the guest BEFORE: does dpkg-query parse the status DB? is smbd
         listening on :445? what backups exist (known-good / status-old) and is
         /var/lib/dpkg/info intact (needed for rebuild)?
      2. Runs the SAME self-heal the Phase 11 SMB check runs -- the shared
         roles/ensure-samba.sh with the apt-retry.sh guard inlined
         (Get-LinuxScript -IncludeAptRetry). This exercises apt_retry's
         PRE/POST dpkg_guard_check, which restores from the known-good snapshot
         or, if no parseable backup exists, calls rebuild_dpkg_status to
         reconstruct the status DB from on-disk metadata.
      3. Probes AFTER and dumps /var/log/memlabs-dpkg-guard.log so you can see
         exactly which recovery path fired.

    The only mutation is the intended self-heal on the target VM (install samba
    + repair the dpkg DB). Nothing on the host is changed.

.PARAMETER VmName
    The Hyper-V VM name to test (default: PL-OREGANO).

.PARAMETER IPAddress
    Optional explicit guest IPv4 (skips Hyper-V KVP resolution).

.EXAMPLE
    .\Test-LinuxDpkgSelfHeal.ps1
    # Tests PL-OREGANO end-to-end and prints a PASS/FAIL verdict.

.EXAMPLE
    .\Test-LinuxDpkgSelfHeal.ps1 -VmName PL-PITA
#>

[CmdletBinding()]
param(
    [string]$VmName = 'PL-OREGANO',
    [string]$IPAddress
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Bootstrap: dot-source Common.ps1 for the Linux helpers, only if not already
# loaded (so it works both standalone and inside a New-Lab session).
# ---------------------------------------------------------------------------
if (-not (Get-Command Invoke-LinuxVmCommand -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot '..\Common.ps1') -VerboseEnabled:$false -InJob:$false
}

function Write-Section {
    param([string]$Text)
    Write-Host ""
    Write-Host ("===== {0} =====" -f $Text) -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
# Resolve the guest IP.
# ---------------------------------------------------------------------------
if (-not $IPAddress) {
    $IPAddress = Get-LinuxVmIPAddress -VmName $VmName
}
if (-not $IPAddress) {
    throw "Could not resolve an IPv4 for '$VmName' (Hyper-V KVP not reporting). Pass -IPAddress explicitly."
}
Write-Host "Target: $VmName @ $IPAddress" -ForegroundColor White

# ---------------------------------------------------------------------------
# Shared guest probe: prints a compact snapshot of dpkg / smbd / backup state.
# ---------------------------------------------------------------------------
$probeBash = @'
echo -n "dpkg-query: "; if dpkg-query -W >/dev/null 2>&1; then echo "PARSES ($(dpkg-query -f '.\n' -W 2>/dev/null | wc -l) pkgs)"; else echo "CORRUPT/UNREADABLE"; fi
echo "status: $(stat -c%s /var/lib/dpkg/status 2>/dev/null || echo none)B | status-old: $(stat -c%s /var/lib/dpkg/status-old 2>/dev/null || echo none)B | known-good: $([ -s /var/backups/memlabs-dpkg-status.good ] && stat -c%s /var/backups/memlabs-dpkg-status.good || echo none)"
echo "info/*.list: $(ls /var/lib/dpkg/info/*.list 2>/dev/null | wc -l) | apt Packages lists: $(ls /var/lib/apt/lists/*_Packages 2>/dev/null | wc -l)"
echo -n "smbd: "; systemctl is-active smbd 2>/dev/null || echo inactive
echo -n "tcp/445: "; if ss -ltn 'sport = :445' 2>/dev/null | grep -q ':445'; then echo LISTENING; else echo closed; fi
'@

function Invoke-Probe {
    param([string]$Label)
    Write-Section $Label
    $r = Invoke-LinuxVmCommand -VmName $VmName -IPAddress $IPAddress -Sudo -SuppressLog `
        -TimeoutSeconds 60 -DisplayName "probe ($Label)" -BashCommand $probeBash
    $out = if ($r -and $r.ScriptBlockOutput) { $r.ScriptBlockOutput.TrimEnd() } else { '(no output)' }
    Write-Host $out -ForegroundColor Gray
    return $out
}

# ---------------------------------------------------------------------------
# BEFORE
# ---------------------------------------------------------------------------
$null = Invoke-Probe -Label 'BEFORE self-heal'

# ---------------------------------------------------------------------------
# Run the real self-heal path (ensure-samba.sh + apt-retry guard inlined).
# ---------------------------------------------------------------------------
Write-Section 'Running self-heal (roles/ensure-samba.sh with guard/rebuild)'
$ensureSamba = Get-LinuxScript -Name 'roles/ensure-samba' -IncludeAptRetry
$heal = Invoke-LinuxVmCommand -VmName $VmName -IPAddress $IPAddress -Sudo -SuppressLog `
    -TimeoutSeconds 600 -DisplayName 'ensure-samba self-heal' -BashCommand $ensureSamba
$healOut = if ($heal -and $heal.ScriptBlockOutput) { $heal.ScriptBlockOutput.TrimEnd() } else { '(no output)' }
Write-Host $healOut -ForegroundColor DarkGray

# Highlight the guard/rebuild markers so it's obvious which path fired.
Write-Section 'Guard / rebuild markers observed'
$markers = @($healOut -split "`n" | Where-Object { $_ -match 'dpkg-guard|rebuild_dpkg_status|repair_dpkg_status|SMBD_LISTENING|SMBD_DOWN' })
if ($markers.Count -gt 0) {
    $markers | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
}
else {
    Write-Host "  (none seen -- is this host running the guard/rebuild code? check apt-retry.sh)" -ForegroundColor Red
}

# ---------------------------------------------------------------------------
# AFTER
# ---------------------------------------------------------------------------
$after = Invoke-Probe -Label 'AFTER self-heal'

# ---------------------------------------------------------------------------
# On-guest guard log (the authoritative diagnosis trail).
# ---------------------------------------------------------------------------
Write-Section 'On-guest /var/log/memlabs-dpkg-guard.log (tail)'
$logR = Invoke-LinuxVmCommand -VmName $VmName -IPAddress $IPAddress -Sudo -SuppressLog `
    -TimeoutSeconds 60 -DisplayName 'guard log' `
    -BashCommand 'tail -40 /var/log/memlabs-dpkg-guard.log 2>/dev/null || echo "(no guard log present)"'
$logOut = if ($logR -and $logR.ScriptBlockOutput) { $logR.ScriptBlockOutput.TrimEnd() } else { '(no output)' }
Write-Host $logOut -ForegroundColor DarkGray

# ---------------------------------------------------------------------------
# Verdict
# ---------------------------------------------------------------------------
Write-Section 'VERDICT'
$dpkgOkAfter = $after -match 'dpkg-query: PARSES'
$smbListening = ($after -match 'tcp/445: LISTENING') -or ($healOut -match 'SMBD_LISTENING')
if ($smbListening -and $dpkgOkAfter) {
    Write-Host "PASS - defense-in-depth recovered the VM: dpkg DB parses and smbd is listening on :445." -ForegroundColor Green
    exit 0
}
elseif ($dpkgOkAfter) {
    Write-Host "PARTIAL - dpkg DB now parses (guard/rebuild worked) but smbd is not listening on :445 yet." -ForegroundColor Yellow
    Write-Host "          Re-run this script, or check 'systemctl status smbd' on the guest." -ForegroundColor Yellow
    exit 2
}
else {
    Write-Host "FAIL - dpkg DB still does not parse after self-heal." -ForegroundColor Red
    Write-Host "       If 'info/*.list' was 0 above, /var/lib/dpkg/info is also damaged and the VM must be rebuilt." -ForegroundColor Red
    exit 1
}
