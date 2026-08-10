<#
.SYNOPSIS
    Retro-apply the Phase 1 guest settings to an EXISTING lab.

.DESCRIPTION
    Phase 1 gained three guest settings that only new VMs receive. This applies
    the same three to VMs that are already built:

      1. Defender tuning   -- copies staging\Optimize-Defender.ps1 into C:\staging
                              and runs it (exclusions for CM/SQL/WSUS paths).
      2. WMI arbitration   -- HKLM\SOFTWARE\Microsoft\WBEM\CIMOM
                              ArbThrottlingEnabled = 0
      3. WSMan RC retry    -- HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WSMAN\Client
                              max_retry_timeout_ms = 2000

    (3) is the one that matters for the 195s DSC stall. When the DC's push channel
    is orphaned mid-apply, the target's robust-connection layer buffers every later
    LCM message and blocks each one until its retry timer expires. That timer is
    this value + a hardcoded 15000ms server delta, so the default 180000 produces
    the observed 195s. 2000 is WSMAN_MIN_RETRY_TIMEOUT, the floor the WSMan config
    layer clamps to, giving ~17s. Both registry values are read back after writing
    because the service clamps them.

    Both registry settings are read at SERVICE START, so they do nothing until
    Winmgmt / WinRM restart. A reboot is the clean way. -RestartServices does it
    in place, but see the warning on that parameter.

.PARAMETER DomainName
    Only touch VMs in this domain. Omit for every VM the host knows about.

.PARAMETER VMName
    Only touch these VMs. Combines with -DomainName.

.PARAMETER CheckOnly
    Report each VM's current values and make NO changes.

.PARAMETER SkipDefender
    Registry settings only. Useful for a fast pass -- the Defender step copies a
    file and runs a script, so it is much the slowest of the three.

.PARAMETER RestartServices
    Restart Winmgmt and WinRM after setting the registry values, so they take
    effect without a reboot.

    DO NOT USE ON A LAB THAT IS MID-BUILD. Restarting Winmgmt drops every WMI
    client on the guest (ConfigMgr, DSC, the LCM); restarting WinRM kills any
    in-flight DSC push channel, which is the exact thing this is meant to protect.
    Safe on an idle lab, harmful on a running one.

.EXAMPLE
    .\Set-Phase1LabSettings.ps1 -DomainName cstest1.com -CheckOnly
.EXAMPLE
    .\Set-Phase1LabSettings.ps1 -DomainName cstest1.com
.EXAMPLE
    .\Set-Phase1LabSettings.ps1 -VMName CT1-PS1SITE -RestartServices
#>
[CmdletBinding()]
param(
    [string]$DomainName,
    [string[]]$VMName,
    [switch]$CheckOnly,
    [switch]$SkipDefender,
    [switch]$RestartServices
)

$ErrorActionPreference = 'Stop'

$vmbuildRoot = Split-Path -Parent $PSScriptRoot
$commonPath = Join-Path $vmbuildRoot 'Common.ps1'
if (-not (Test-Path -LiteralPath $commonPath)) { throw "Common.ps1 not found at $commonPath" }

$bom = [System.IO.File]::ReadAllBytes($commonPath)[0..2]
if (-not ($bom[0] -eq 0xEF -and $bom[1] -eq 0xBB -and $bom[2] -eq 0xBF)) {
    throw "Common.ps1 is missing its UTF-8 BOM. Run: git checkout -- vmbuild/Common.ps1"
}

. $commonPath

# Get-VmSession needs the cached local admin password; without it every guest
# call fails silently rather than loudly.
if (-not ($Common -and $Common.LocalAdmin -and $Common.LocalAdmin.Password)) {
    throw ("Local admin (vmbuildadmin) credential not loaded -- guest calls would fail silently. " +
        "cacheExists={0}. Open a new PowerShell window and retry." -f (Test-Path (Join-Path $vmbuildRoot 'cache\vmbuildadmin.txt')))
}

$targets = @(Get-List -Type VM -SmartUpdate)
if ($DomainName) { $targets = @($targets | Where-Object { $_.domain -and ("$($_.domain)" -eq $DomainName) }) }
if ($VMName) { $targets = @($targets | Where-Object { $VMName -contains $_.vmName }) }
if ($targets.Count -eq 0) { throw "No VMs matched (DomainName='$DomainName' VMName='$($VMName -join ",")')." }

$running = @($targets | Where-Object { (Get-VM -Name $_.vmName -ErrorAction SilentlyContinue).State -eq 'Running' })
$notRunning = @($targets | Where-Object { $running.vmName -notcontains $_.vmName })
foreach ($n in $notRunning) { Write-Host "  SKIP $($n.vmName) -- not running" -ForegroundColor DarkYellow }
if ($running.Count -eq 0) { throw 'No matching VM is running.' }

$mode = if ($CheckOnly) { 'CHECK ONLY -- no changes' } else { 'APPLYING' }
Write-Host "$mode on $($running.Count) VM(s)" -ForegroundColor Cyan
Write-Host ''

# One round trip per VM: read both values, optionally write, always read back.
$regSb = {
    param($doApply, $doRestart)
    $r = [ordered]@{ Arb = ''; Wsman = ''; Restart = ''; Defender = '' }

    # Optimize-Defender reports a setting as Applied whenever the final value matches
    # what was wanted, which cannot distinguish "I changed it" from "it was already
    # right under Tamper Protection". This is what actually separates the two.
    try {
        $ms = Get-MpComputerStatus -ErrorAction Stop
        $r.Defender = "TamperProtected=$($ms.IsTamperProtected) RunningMode=$($ms.AMRunningMode) RealTime=$($ms.RealTimeProtectionEnabled)"
    }
    catch { $r.Defender = "Get-MpComputerStatus failed: $($_.Exception.Message)" }

    $arbKey = 'HKLM:\SOFTWARE\Microsoft\WBEM\CIMOM'
    if (-not (Test-Path -LiteralPath $arbKey)) { $r.Arb = 'CIMOM key absent' }
    else {
        $prior = (Get-ItemProperty -LiteralPath $arbKey -Name 'ArbThrottlingEnabled' -ErrorAction SilentlyContinue).ArbThrottlingEnabled
        $priorText = 'unset'
        if ($null -ne $prior) { $priorText = "$prior" }
        if ($doApply) {
            try { New-ItemProperty -LiteralPath $arbKey -Name 'ArbThrottlingEnabled' -Value 0 -PropertyType DWord -Force -ErrorAction Stop | Out-Null }
            catch { $r.Arb = "write failed: $($_.Exception.Message)" }
        }
        if (-not $r.Arb) {
            $now = (Get-ItemProperty -LiteralPath $arbKey -Name 'ArbThrottlingEnabled' -ErrorAction SilentlyContinue).ArbThrottlingEnabled
            $nowText = 'unset'
            if ($null -ne $now) { $nowText = "$now" }
            if ($doApply) { $r.Arb = "$priorText -> $nowText" } else { $r.Arb = $nowText }
        }
    }

    $wsKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WSMAN\Client'
    if (-not (Test-Path -LiteralPath $wsKey)) { $r.Wsman = 'WSMAN Client key absent' }
    else {
        $prior = (Get-ItemProperty -LiteralPath $wsKey -Name 'max_retry_timeout_ms' -ErrorAction SilentlyContinue).max_retry_timeout_ms
        $priorText = 'unset (default 180000)'
        if ($null -ne $prior) { $priorText = "$prior" }
        if ($doApply) {
            try { New-ItemProperty -LiteralPath $wsKey -Name 'max_retry_timeout_ms' -Value 2000 -PropertyType DWord -Force -ErrorAction Stop | Out-Null }
            catch { $r.Wsman = "write failed: $($_.Exception.Message)" }
        }
        if (-not $r.Wsman) {
            $now = (Get-ItemProperty -LiteralPath $wsKey -Name 'max_retry_timeout_ms' -ErrorAction SilentlyContinue).max_retry_timeout_ms
            $nowText = 'unset'
            if ($null -ne $now) { $nowText = "$now" }
            if ($doApply) { $r.Wsman = "$priorText -> $nowText" } else { $r.Wsman = $priorText }
        }
    }

    if ($doApply -and $doRestart) {
        $done = @()
        foreach ($svc in 'Winmgmt', 'WinRM') {
            try {
                Restart-Service -Name $svc -Force -ErrorAction Stop
                $done += "$svc ok"
            }
            catch { $done += "${svc}: $($_.Exception.Message)" }
        }
        $r.Restart = ($done -join '; ')
    }
    elseif ($doApply) { $r.Restart = 'pending (needs Winmgmt/WinRM restart or reboot)' }

    return (New-Object psobject -Property $r)
}

$rows = New-Object System.Collections.Generic.List[object]
foreach ($vm in $running) {
    $name = $vm.vmName
    $dom = "$($vm.domain)"
    Write-Host "$name" -ForegroundColor White

    $row = [ordered]@{ VM = $name; Defender = 'skipped'; DefenderState = ''; Arb = ''; Wsman = ''; Restart = '' }

    if (-not $SkipDefender -and -not $CheckOnly) {
        $src = Join-Path $Common.StagingInjectPath 'staging\Optimize-Defender.ps1'
        if (-not (Test-Path -LiteralPath $src)) { $row.Defender = 'source missing' }
        else {
            $copied = $false
            try {
                $sess = Get-VmSession -VmName $name -VmDomainName $dom
                if ($sess) {
                    Copy-Item -ToSession $sess -Path $src -Destination 'C:\staging\Optimize-Defender.ps1' -Force -ErrorAction Stop
                    $copied = $true
                }
                else { $row.Defender = 'no session' }
            }
            catch { $row.Defender = "copy failed: $($_.Exception.Message)" }

            if ($copied) {
                $dr = Invoke-VmCommand -VmName $name -VmDomainName $dom -ScriptBlock { & 'C:\staging\Optimize-Defender.ps1' } -DisplayName 'Optimize Defender' -AsJob -TimeoutSeconds 180
                if ($dr.ScriptBlockFailed) { $row.Defender = "failed: $($dr.ScriptBlockOutput)" }
                else {
                    $msg = $dr.ScriptBlockOutput
                    if ($msg -and $msg.Message) { $msg = $msg.Message }
                    $row.Defender = "ok -- $msg"
                }
            }
        }
    }

    $rr = Invoke-VmCommand -VmName $name -VmDomainName $dom -ScriptBlock $regSb `
        -ArgumentList @((-not $CheckOnly), [bool]$RestartServices) `
        -DisplayName 'Phase 1 registry settings' -AsJob -TimeoutSeconds 180
    if ($rr.ScriptBlockFailed -or -not $rr.ScriptBlockOutput) {
        $row.Arb = "FAILED: $($rr.ScriptBlockOutput)"
        $row.Wsman = 'FAILED'
    }
    else {
        $row.Arb = $rr.ScriptBlockOutput.Arb
        $row.Wsman = $rr.ScriptBlockOutput.Wsman
        $row.Restart = $rr.ScriptBlockOutput.Restart
        $row.DefenderState = $rr.ScriptBlockOutput.Defender
    }

    foreach ($k in 'Defender', 'DefenderState', 'Arb', 'Wsman', 'Restart') {
        if ($row.$k) {
            $colour = if ("$($row.$k)" -match 'fail|FAILED|absent|missing') { 'Red' } else { 'Green' }
            Write-Host ("    {0,-9} {1}" -f $k, $row.$k) -ForegroundColor $colour
        }
    }
    $rows.Add((New-Object psobject -Property $row))
}

Write-Host ''
Write-Host '=== summary ===' -ForegroundColor Cyan
$rows | Format-Table -AutoSize VM, DefenderState, Arb, Wsman, Restart

$failed = @($rows | Where-Object { "$($_.Arb)$($_.Wsman)$($_.Defender)" -match 'fail|FAILED|absent' })
if ($failed.Count -gt 0) {
    Write-Host "$($failed.Count) VM(s) had at least one failure." -ForegroundColor Red
    exit 1
}
if (-not $CheckOnly -and -not $RestartServices) {
    Write-Host 'Registry values are set but INACTIVE until Winmgmt/WinRM restart. Reboot the VMs, or re-run with -RestartServices on an idle lab.' -ForegroundColor Yellow
}
exit 0
