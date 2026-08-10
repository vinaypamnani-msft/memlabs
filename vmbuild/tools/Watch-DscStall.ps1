<#
.SYNOPSIS
    Catches the recurring ~195-200s DSC stall in the act and says WHAT was blocked.

.DESCRIPTION
    Across 20,050 [DscTiming] per-resource rows in vmbuild\logs there is a hard
    cliff at 195s: 3 rows land in 192-195s, then 205 rows land in 195-200s. It
    lands on resources whose real work is sub-second ([WriteStatus] writes one
    line and has been measured at 195.1s, 195.2s and 195.6s), so it is not the
    resource doing work -- something freezes for ~195s and whichever resource is
    executing absorbs it.

    The DSC status stream cannot answer this: the last-posted status absorbs the
    whole silence, so the stall shows up under a different caption every run.
    This tool answers it from OUTSIDE DSC.

    It runs a 1s sampler in the guest, in its own powershell.exe -- a process the
    DSC engine (WmiPrvSE) cannot block. Per tick it records a monotonic
    Stopwatch reading AND UTC wall clock, so the three cases separate cleanly:

      sampler ALSO late          -> the guest/VM froze (host CPU, storage, or the
                                    VM was descheduled) -- not a DSC problem
      wall jumped >> monotonic   -> the guest clock was corrected / VM was
                                    saved+restored; the 195s never really elapsed
      sampler on time            -> only DSC was blocked; the deep samples then
                                    name what it was blocked ON

    Deep samples fire once the DSC status text has been static for a while and
    use ONLY Win32 process APIs plus netstat -- no WMI, no CIM, no DSC cmdlets.
    That matters twice over: interrogating the LCM mid-apply hangs (see
    Get-DscLocalConfigurationManager), and if WMI itself is the wedged component
    then a WMI-based probe is exactly the probe that cannot report it.

    Guest side is read-only apart from its own JSONL under C:\staging\DSC.

.PARAMETER Action
    Start    Deploy + launch the sampler in each target VM (detached, self-expiring).
    Stop     Stop the sampler in each target VM.
    Collect  Pull each guest's JSONL back to vmbuild\logs\dscstall\.
    Report   Analyse collected JSONL and print stall windows + a verdict each.
    SelfTest Run the sampler locally with an injected freeze and assert it fires.

.PARAMETER DomainName
    Lab domain (e.g. cstest1.com). Required for Start/Stop/Collect.

.PARAMETER VMName
    Limit to these VM(s), wildcards allowed. Default: every Running VM in the domain.

.PARAMETER Path
    Folder holding collected JSONL for -Action Report. Default vmbuild\logs\dscstall.

.PARAMETER DurationMinutes
    Guest sampler lifetime. It self-terminates at the deadline so an orphan cannot
    outlive the build. Default 480.

.PARAMETER StallSeconds
    A window is reported once the DSC status text has been static this long.
    Default 60 (well under the 195s we are hunting, well over normal churn).

.EXAMPLE
    # Before starting the phase you expect to stall
    .\tools\Watch-DscStall.ps1 -Action Start -DomainName cstest1.com

.EXAMPLE
    .\tools\Watch-DscStall.ps1 -Action Collect -DomainName cstest1.com
    .\tools\Watch-DscStall.ps1 -Action Report

.EXAMPLE
    # Prove the detector fires before trusting a quiet run
    .\tools\Watch-DscStall.ps1 -Action SelfTest
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Start', 'Stop', 'Collect', 'Report', 'SelfTest')]
    [string]$Action,
    [string]$DomainName,
    [string[]]$VMName,
    [string]$Path,
    [int]$DurationMinutes = 480,
    [int]$StallSeconds = 60,
    [int]$TimeoutSeconds = 180
)

$ErrorActionPreference = 'Stop'

$toolsRoot = $PSScriptRoot
$vmbuildRoot = Split-Path -Parent $toolsRoot
if (-not $Path) { $Path = Join-Path $vmbuildRoot 'logs\dscstall' }

$guestDir = 'C:\staging\DSC\StallWatch'
$guestScript = "$guestDir\Watch-Stall.ps1"
$guestOut = "$guestDir\samples.jsonl"
$guestStopFile = "$guestDir\stop.flag"

#region guest payload -------------------------------------------------------
# ASCII only, Windows PowerShell 5.1 only: no ternary, no ?? / ?., no -Parallel.
$guestPayload = @'
param(
    [string]$OutFile = 'C:\staging\DSC\StallWatch\samples.jsonl',
    [string]$StopFile = 'C:\staging\DSC\StallWatch\stop.flag',
    [string]$StatusFile = 'C:\staging\DSC\DSC_Status.txt',
    [string]$DscLog = 'C:\staging\DSC\DSC_Log.log',
    [int]$IntervalMs = 1000,
    [int]$DurationMinutes = 480,
    [int]$DeepAfterSeconds = 15,
    [int]$DeepEverySeconds = 10,
    [int]$InjectStallSeconds = 0
)

$dir = Split-Path -Parent $OutFile
if (-not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }

# Processes worth naming when something blocks. WmiPrvSE hosts class-based DSC
# resources; the rest are the usual machine-wide lock holders.
$watchNames = @('WmiPrvSE', 'WmiApSrv', 'msiexec', 'TrustedInstaller', 'TiWorker', 'MsMpEng', 'powershell', 'dsc')

function Write-Sample {
    param($Record)
    $Record | ConvertTo-Json -Depth 5 -Compress | Out-File -FilePath $OutFile -Append -Encoding ascii
}

function Get-ProcCpuMs {
    $map = @{}
    foreach ($p in (Get-Process -ErrorAction SilentlyContinue)) {
        try { $map["$($p.Id)|$($p.ProcessName)"] = $p.TotalProcessorTime.TotalMilliseconds } catch {}
    }
    return $map
}

# Thread state / wait reason come from System.Diagnostics.ProcessThread, i.e.
# straight Win32. Deliberately not Win32_Thread: a WMI query cannot describe a
# wedged WMI.
function Get-ThreadWaitHistogram {
    param([int]$ProcessId)
    $hist = @{}
    try {
        $p = Get-Process -Id $ProcessId -ErrorAction Stop
        foreach ($t in $p.Threads) {
            $state = 'Unknown'
            try { $state = "$($t.ThreadState)" } catch {}
            $key = $state
            if ($state -eq 'Wait') {
                $reason = 'Unknown'
                try { $reason = "$($t.WaitReason)" } catch {}
                $key = "Wait/$reason"
            }
            if ($hist.ContainsKey($key)) { $hist[$key] = $hist[$key] + 1 } else { $hist[$key] = 1 }
        }
    }
    catch {
        $hist['probe-failed'] = 1
    }
    return $hist
}

# netstat, not Get-NetTCPConnection: the latter is CIM and would hang alongside
# whatever it is meant to be reporting on.
function Get-PidConnections {
    param([int[]]$ProcessIds)
    $out = @()
    try {
        $lines = & netstat.exe -ano 2>$null
        foreach ($l in $lines) {
            $parts = ($l.Trim() -split '\s+')
            if ($parts.Count -lt 5) { continue }
            if ($parts[0] -ne 'TCP') { continue }
            $owner = 0
            if (-not [int]::TryParse($parts[$parts.Count - 1], [ref]$owner)) { continue }
            if ($ProcessIds -notcontains $owner) { continue }
            $out += ('{0} {1} {2}' -f $parts[3], $parts[2], $owner)
        }
    }
    catch {}
    return @($out | Select-Object -First 40)
}

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$deadline = (Get-Date).AddMinutes($DurationMinutes)
$prevMono = 0.0
$prevWall = [datetime]::UtcNow
$prevCpu = Get-ProcCpuMs
$prevWorkMs = 0.0
$seq = 0
$lastDeepMono = -100000.0
$statusText = ''
$statusChangedMono = 0.0
$injected = $false

Write-Sample ([pscustomobject]@{
        type      = 'start'
        utc       = ([datetime]::UtcNow).ToString('o')
        computer  = $env:COMPUTERNAME
        interval  = $IntervalMs
        deadline  = $deadline.ToString('o')
        psVersion = "$($PSVersionTable.PSVersion)"
    })

while ((Get-Date) -lt $deadline) {
    if (Test-Path $StopFile) { break }
    Start-Sleep -Milliseconds $IntervalMs

    # SelfTest hook: block the loop once so the lateness detector has to fire.
    if ($InjectStallSeconds -gt 0 -and -not $injected -and $seq -ge 3) {
        $injected = $true
        Start-Sleep -Seconds $InjectStallSeconds
    }

    $seq++
    $bodySw = [System.Diagnostics.Stopwatch]::StartNew()
    $mono = $sw.Elapsed.TotalMilliseconds
    $wall = [datetime]::UtcNow
    $monoDelta = $mono - $prevMono
    $wallDelta = ($wall - $prevWall).TotalMilliseconds
    $prevMono = $mono
    $prevWall = $wall

    # Lateness of the SAMPLER itself, with the sampler's own previous-tick work
    # subtracted so a merely busy guest cannot masquerade as a stall. This is the
    # load-bearing measurement: the sampler is not DSC, so if it is late too, DSC
    # is not the thing that stalled.
    $lateMs = [math]::Round($monoDelta - $IntervalMs - $prevWorkMs, 0)
    # Wall clock running ahead of the monotonic clock means time was inserted,
    # not spent: a clock correction, or a VM save/restore.
    $skewMs = [math]::Round($wallDelta - $monoDelta, 0)

    $newStatus = ''
    try { $newStatus = (Get-Content -Path $StatusFile -Raw -ErrorAction SilentlyContinue) } catch {}
    if ($null -eq $newStatus) { $newStatus = '' }
    $newStatus = "$newStatus".Trim()
    if ($newStatus -ne $statusText) {
        $statusText = $newStatus
        $statusChangedMono = $mono
    }
    $statusAgeSec = [math]::Round(($mono - $statusChangedMono) / 1000.0, 0)

    $dscLogSize = -1
    try { $dscLogSize = (Get-Item -Path $DscLog -ErrorAction SilentlyContinue).Length } catch {}
    if ($null -eq $dscLogSize) { $dscLogSize = -1 }

    $cpu = Get-ProcCpuMs
    $deltas = @()
    foreach ($k in $cpu.Keys) {
        $was = 0.0
        if ($prevCpu.ContainsKey($k)) { $was = $prevCpu[$k] }
        $d = $cpu[$k] - $was
        if ($d -gt 0) { $deltas += [pscustomobject]@{ K = $k; D = [math]::Round($d, 0) } }
    }
    $prevCpu = $cpu
    $top = @($deltas | Sort-Object D -Descending | Select-Object -First 5 | ForEach-Object { '{0}={1}' -f $_.K, $_.D })

    $watchCpu = 0.0
    $watchPids = @()
    foreach ($k in $cpu.Keys) {
        $pieces = $k -split '\|'
        if ($watchNames -contains $pieces[1]) { $watchPids += [int]$pieces[0] }
    }
    $watchPids = @($watchPids | Sort-Object -Unique)
    foreach ($e in $deltas) {
        $pieces = $e.K -split '\|'
        if ($watchNames -contains $pieces[1]) { $watchCpu += $e.D }
    }

    $rec = [pscustomobject]@{
        type       = 'tick'
        seq        = $seq
        utc        = $wall.ToString('o')
        monoMs     = [math]::Round($mono, 0)
        lateMs     = $lateMs
        skewMs     = $skewMs
        workMs     = [math]::Round($prevWorkMs, 0)
        statusAge  = $statusAgeSec
        dscLogSize = $dscLogSize
        watchCpuMs = [math]::Round($watchCpu, 0)
        topCpu     = $top
    }
    Write-Sample $rec

    # A gap the sampler itself experienced is the single most decisive record
    # here, so it gets its own line rather than hiding inside a tick.
    if ($lateMs -gt 3000 -or [math]::Abs($skewMs) -gt 3000) {
        Write-Sample ([pscustomobject]@{
                type      = 'gap'
                seq       = $seq
                utc       = $wall.ToString('o')
                lateMs    = $lateMs
                skewMs    = $skewMs
                monoDelta = [math]::Round($monoDelta, 0)
                wallDelta = [math]::Round($wallDelta, 0)
                status    = $statusText
            })
    }

    if ($statusAgeSec -ge $DeepAfterSeconds -and ($mono - $lastDeepMono) -ge ($DeepEverySeconds * 1000)) {
        $lastDeepMono = $mono
        $threads = @{}
        $probeSw = [System.Diagnostics.Stopwatch]::StartNew()
        foreach ($wp in $watchPids) {
            $h = Get-ThreadWaitHistogram -ProcessId $wp
            foreach ($k in $h.Keys) {
                $kk = "$wp/$k"
                $threads[$kk] = $h[$k]
            }
        }
        $probeSw.Stop()
        Write-Sample ([pscustomobject]@{
                type        = 'deep'
                seq         = $seq
                utc         = $wall.ToString('o')
                statusAge   = $statusAgeSec
                status      = $statusText
                watchPids   = $watchPids
                threads     = $threads
                conns       = (Get-PidConnections -ProcessIds $watchPids)
                probeMs     = [math]::Round($probeSw.Elapsed.TotalMilliseconds, 0)
                topCpu      = $top
                dscLogSize  = $dscLogSize
            })
    }

    $prevWorkMs = $bodySw.Elapsed.TotalMilliseconds
}

Write-Sample ([pscustomobject]@{ type = 'stop'; utc = ([datetime]::UtcNow).ToString('o'); seq = $seq })
'@
#endregion guest payload ----------------------------------------------------

function Get-Targets {
    if (-not $DomainName) { throw "-DomainName is required for -Action $Action" }
    $all = @(Get-List -Type VM -SmartUpdate | Where-Object { $_.domain -and ("$($_.domain)" -eq $DomainName) })
    if ($VMName) {
        $all = @($all | Where-Object { $v = $_; ($VMName | Where-Object { "$($v.vmName)" -like $_ }) })
    }
    $running = @()
    foreach ($v in $all) {
        $name = "$($v.vmName)"
        $state = (Get-VM -Name $name -ErrorAction SilentlyContinue).State
        if ("$state" -eq 'Running') { $running += $name }
    }
    if ($running.Count -eq 0) { throw "No Running VMs matched domain '$DomainName'." }
    return $running
}

function Invoke-Guest {
    param([string]$Vm, [scriptblock]$Sb, [object[]]$ArgList)
    $r = Invoke-VmCommand -VmName $Vm -VmDomainName $DomainName -ScriptBlock $Sb -ArgumentList $ArgList `
        -SuppressLog -TimeoutSeconds $TimeoutSeconds -AsJob
    # Invoke-VmCommand returns a bare $false (not the result object) on its own
    # pre-flight failures, so "no output" must be reported, never treated as quiet success.
    if ($r -is [bool] -or $null -eq $r) {
        Write-Host "  $Vm : FAILED -- Invoke-VmCommand refused before dispatch (returned '$r'). Usually a missing vmbuildadmin credential." -ForegroundColor Red
        return $null
    }
    if ($r.ScriptBlockFailed -or $r.TimedOut) {
        Write-Host "  $Vm : FAILED (timedOut=$($r.TimedOut) channelBroken=$($r.ChannelBroken)) $($r.ErrorDetails)" -ForegroundColor Red
        return $null
    }
    if ($null -eq $r.ScriptBlockOutput) {
        Write-Host "  $Vm : FAILED -- guest scriptblock returned nothing. $($r.ErrorDetails)" -ForegroundColor Red
        return $null
    }
    return $r.ScriptBlockOutput
}

if ($Action -ne 'Report' -and $Action -ne 'SelfTest') {
    $commonPath = Join-Path $vmbuildRoot 'Common.ps1'
    $bom = [System.IO.File]::ReadAllBytes($commonPath)[0..2]
    if (-not ($bom[0] -eq 0xEF -and $bom[1] -eq 0xBB -and $bom[2] -eq 0xBF)) {
        throw "Common.ps1 is missing its UTF-8 BOM. Run: git checkout -- vmbuild/Common.ps1"
    }

    # A plain load: Get-VmSession needs $Common.LocalAdmin.Password, and neither
    # -InJob nor -FastInit populates it. The init gate upgrades a lighter
    # already-loaded $Common rather than short-circuiting on its Initialized flag.
    . $commonPath

    if (-not ($Common -and $Common.LocalAdmin -and $Common.LocalAdmin.Password)) {
        $credCache = Join-Path $vmbuildRoot 'cache\vmbuildadmin.txt'
        $msg = 'Local admin (vmbuildadmin) credential not loaded -- every guest call would fail silently. ' +
        'cacheExists={0} path={1} offlineMode={2} stamped={3} fatalError={4}. ' +
        'If this window loaded Common.ps1 before pulling the init-gate fix, open a new PowerShell window.'
        throw ($msg -f (Test-Path $credCache), $credCache, $Common.OfflineMode, [bool]$Common.InitCapabilities, $Common.FatalError)
    }
}

switch ($Action) {

    'Start' {
        $targets = Get-Targets
        Write-Host "Starting DSC stall sampler on $($targets.Count) VM(s): $($targets -join ', ')" -ForegroundColor Cyan
        $sb = {
            param($dir, $script, $outFile, $stopFile, $payload, $minutes)
            if (-not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
            Remove-Item -Path $stopFile -Force -ErrorAction SilentlyContinue
            Remove-Item -Path $outFile -Force -ErrorAction SilentlyContinue
            $payload | Out-File -FilePath $script -Encoding ascii -Force
            $existing = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
                    Where-Object { "$($_.CommandLine)" -like "*Watch-Stall.ps1*" })
            foreach ($e in $existing) { Stop-Process -Id $e.ProcessId -Force -ErrorAction SilentlyContinue }
            $argList = @(
                '-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden',
                '-ExecutionPolicy', 'Bypass', '-File', "`"$script`"",
                '-OutFile', "`"$outFile`"", '-StopFile', "`"$stopFile`"",
                '-DurationMinutes', "$minutes"
            )
            Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -WindowStyle Hidden | Out-Null
            Start-Sleep -Seconds 3
            $running = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
                    Where-Object { "$($_.CommandLine)" -like "*Watch-Stall.ps1*" })
            $lines = 0
            if (Test-Path $outFile) { $lines = @(Get-Content $outFile -ErrorAction SilentlyContinue).Count }
            return "pids=$($running.Count) lines=$lines"
        }
        foreach ($vm in $targets) {
            $o = Invoke-Guest -Vm $vm -Sb $sb -ArgList @($guestDir, $guestScript, $guestOut, $guestStopFile, $guestPayload, $DurationMinutes)
            if ($null -ne $o) {
                # 'pids=0' means Start-Process returned but nothing is running: report it, do not call it started.
                $ok = ("$o" -notlike 'pids=0*')
                $color = 'Green'
                if (-not $ok) { $color = 'Red' }
                Write-Host "  $vm : $o" -ForegroundColor $color
            }
        }

        # The sampler is detached, so "Start-Process returned" is not proof it
        # outlived the PSDirect session that spawned it. Re-check on a new session.
        Write-Host "`nVerifying the sampler survived the session that started it..." -ForegroundColor Cyan
        $verifySb = {
            param($outFile)
            $running = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
                    Where-Object { "$($_.CommandLine)" -like "*Watch-Stall.ps1*" })
            $lines = 0
            if (Test-Path $outFile) { $lines = @(Get-Content $outFile -ErrorAction SilentlyContinue).Count }
            return "alive=$($running.Count) lines=$lines"
        }
        foreach ($vm in $targets) {
            $o = Invoke-Guest -Vm $vm -Sb $verifySb -ArgList @($guestOut)
            if ($null -ne $o) {
                $color = 'Green'
                if ("$o" -like 'alive=0*') { $color = 'Red' }
                Write-Host "  $vm : $o" -ForegroundColor $color
            }
        }
        Write-Host "`nSampler writes $guestOut in each guest. Collect with -Action Collect." -ForegroundColor Yellow
    }

    'Stop' {
        $targets = Get-Targets
        $sb = {
            param($stopFile)
            New-Item -Path $stopFile -ItemType File -Force | Out-Null
            Start-Sleep -Seconds 3
            $running = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
                    Where-Object { "$($_.CommandLine)" -like "*Watch-Stall.ps1*" })
            foreach ($e in $running) { Stop-Process -Id $e.ProcessId -Force -ErrorAction SilentlyContinue }
            return "stopped=$($running.Count)"
        }
        foreach ($vm in $targets) {
            $o = Invoke-Guest -Vm $vm -Sb $sb -ArgList @($guestStopFile)
            if ($null -ne $o) { Write-Host "  $vm : $o" -ForegroundColor Green }
        }
    }

    'Collect' {
        $targets = Get-Targets
        if (-not (Test-Path $Path)) { New-Item -Path $Path -ItemType Directory -Force | Out-Null }
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $sb = {
            param($outFile)
            if (-not (Test-Path $outFile)) { return '' }
            return (Get-Content -Path $outFile -Raw -ErrorAction SilentlyContinue)
        }
        foreach ($vm in $targets) {
            $text = Invoke-Guest -Vm $vm -Sb $sb -ArgList @($guestOut)
            if ($null -eq $text) { continue }
            if ([string]::IsNullOrWhiteSpace($text)) {
                Write-Host "  $vm : $guestOut is missing or empty -- the sampler never ran there" -ForegroundColor Yellow
                continue
            }
            $dest = Join-Path $Path ("{0}-{1}.jsonl" -f $vm, $stamp)
            $text | Set-Content -LiteralPath $dest -Encoding UTF8
            Write-Host "  $vm : $((@($text -split "`n")).Count) line(s) -> $dest" -ForegroundColor Green
        }
        Write-Host "`nAnalyse with: .\tools\Watch-DscStall.ps1 -Action Report" -ForegroundColor Yellow
    }

    'Report' {
        if (-not (Test-Path $Path)) { throw "No collected samples at $Path" }
        $files = @(Get-ChildItem $Path -Filter '*.jsonl' -File | Sort-Object LastWriteTime -Descending)
        if ($files.Count -eq 0) { throw "No .jsonl files in $Path" }
        foreach ($f in $files) {
            Write-Host "`n=== $($f.Name) ===" -ForegroundColor Cyan
            $recs = @()
            foreach ($line in [System.IO.File]::ReadLines($f.FullName)) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                try { $recs += ($line | ConvertFrom-Json) } catch {}
            }
            $ticks = @($recs | Where-Object { $_.type -eq 'tick' })
            $gaps = @($recs | Where-Object { $_.type -eq 'gap' })
            $deeps = @($recs | Where-Object { $_.type -eq 'deep' })
            if ($ticks.Count -eq 0) { Write-Host '  no ticks' -ForegroundColor Yellow; continue }
            $span = ([datetime]$ticks[-1].utc) - ([datetime]$ticks[0].utc)
            Write-Host ("  ticks={0} span={1:hh\:mm\:ss} gaps={2} deep={3}" -f $ticks.Count, $span, $gaps.Count, $deeps.Count)

            # Windows where the DSC status text never moved.
            $windows = @()
            $run = $null
            foreach ($t in $ticks) {
                if ([int]$t.statusAge -ge $StallSeconds) {
                    if ($null -eq $run) { $run = @() }
                    $run += $t
                }
                elseif ($null -ne $run) {
                    $windows += , $run
                    $run = $null
                }
            }
            if ($null -ne $run) { $windows += , $run }

            if ($windows.Count -eq 0) {
                Write-Host "  no window with status static >= ${StallSeconds}s" -ForegroundColor Green
            }
            foreach ($w in $windows) {
                $start = [datetime]$w[0].utc
                $end = [datetime]$w[-1].utc
                $sec = [int]($end - $start).TotalSeconds + [int]$w[0].statusAge
                $maxLate = (($w | Measure-Object lateMs -Maximum).Maximum)
                $maxSkew = 0
                foreach ($t in $w) { if ([math]::Abs([double]$t.skewMs) -gt [math]::Abs($maxSkew)) { $maxSkew = [double]$t.skewMs } }
                $cpuMs = (($w | Measure-Object watchCpuMs -Sum).Sum)
                $logGrew = ([int]$w[-1].dscLogSize -gt [int]$w[0].dscLogSize)
                $winDeep = @($deeps | Where-Object { ([datetime]$_.utc) -ge $start -and ([datetime]$_.utc) -le $end })

                $verdict = 'BLOCKED: no CPU, sampler on time -- local wait (see thread reasons)'
                if ($maxLate -gt 3000 -and [math]::Abs($maxSkew) -gt 3000) {
                    $verdict = 'GUEST TIME INSERTED: wall clock jumped past the monotonic clock (VM saved/restored or clock corrected)'
                }
                elseif ($maxLate -gt 3000) {
                    $verdict = 'GUEST FROZE: the sampler was late too, so this is NOT DSC -- host CPU/storage or the VM was descheduled'
                }
                elseif ($cpuMs -gt (($end - $start).TotalMilliseconds * 0.3)) {
                    $verdict = 'DSC BUSY: real CPU was burned -- the resource was working, not stuck'
                }
                elseif (@($winDeep | Where-Object { @($_.conns).Count -gt 0 }).Count -gt 0) {
                    $verdict = 'BLOCKED, possibly on the network -- see conns below'
                }

                Write-Host ("`n  window {0:HH:mm:ss} -> {1:HH:mm:ss}  ~{2}s static" -f $start, $end, $sec) -ForegroundColor Yellow
                Write-Host ("    frozen status : {0}" -f $(if ($winDeep.Count -gt 0) { "$($winDeep[0].status)" } else { '(unknown)' }))
                Write-Host ("    sampler late  : max {0} ms   clock skew max {1} ms   sampler own work max {2} ms" -f $maxLate, $maxSkew, (($w | Measure-Object workMs -Maximum).Maximum))
                Write-Host ("    watched CPU   : {0} ms over the window   DSC_Log grew: {1}" -f $cpuMs, $logGrew)
                Write-Host ("    VERDICT       : {0}" -f $verdict) -ForegroundColor Magenta
                if ($winDeep.Count -gt 0) {
                    $last = $winDeep[-1]
                    $tp = @()
                    foreach ($p in $last.threads.PSObject.Properties) { $tp += ('{0}={1}' -f $p.Name, $p.Value) }
                    Write-Host ("    thread waits  : {0}" -f (($tp | Sort-Object) -join '  '))
                    if (@($last.conns).Count -gt 0) {
                        Write-Host ("    conns         : {0}" -f ((@($last.conns) | Select-Object -First 8) -join '  '))
                    }
                    Write-Host ("    top cpu       : {0}" -f ((@($last.topCpu)) -join '  '))
                    Write-Host ("    probe cost    : {0} ms (high = the thread probe itself was starved)" -f $last.probeMs)
                }
            }
        }
    }

    'SelfTest' {
        # P2: a diagnostic is not real until you have made it fire.
        $tmp = Join-Path $env:TEMP ('DscStallSelfTest-' + [guid]::NewGuid().ToString('N'))
        New-Item -Path $tmp -ItemType Directory -Force | Out-Null
        $script = Join-Path $tmp 'Watch-Stall.ps1'
        $out = Join-Path $tmp 'samples.jsonl'
        $status = Join-Path $tmp 'DSC_Status.txt'
        'frozen selftest status' | Set-Content -LiteralPath $status -Encoding ASCII
        $guestPayload | Out-File -FilePath $script -Encoding ascii -Force

        Write-Host "SelfTest: running the guest payload locally with an injected 8s freeze..." -ForegroundColor Cyan
        & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script `
            -OutFile $out -StopFile (Join-Path $tmp 'stop.flag') -StatusFile $status `
            -DscLog $status -DurationMinutes 1 -DeepAfterSeconds 5 -DeepEverySeconds 5 `
            -InjectStallSeconds 8 2>&1 | Out-Null

        $recs = @()
        foreach ($line in (Get-Content -LiteralPath $out -ErrorAction SilentlyContinue)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try { $recs += ($line | ConvertFrom-Json) } catch {}
        }
        $ticks = @($recs | Where-Object { $_.type -eq 'tick' })
        $gaps = @($recs | Where-Object { $_.type -eq 'gap' })
        $deeps = @($recs | Where-Object { $_.type -eq 'deep' })
        $fail = @()
        if ($ticks.Count -lt 5) { $fail += "expected >=5 ticks, got $($ticks.Count)" }
        if ($gaps.Count -lt 1) { $fail += 'the injected 8s freeze produced NO gap record' }
        elseif ([double]$gaps[0].lateMs -lt 6000) { $fail += "gap lateMs=$($gaps[0].lateMs), expected >=6000" }
        if ($deeps.Count -lt 1) { $fail += 'no deep sample was taken while the status was static' }
        elseif (@($deeps[0].threads.PSObject.Properties).Count -lt 1) { $fail += 'deep sample carried no thread wait data' }

        Write-Host ("  ticks={0} gaps={1} deep={2}" -f $ticks.Count, $gaps.Count, $deeps.Count)
        if ($gaps.Count -gt 0) { Write-Host ("  gap: lateMs={0} skewMs={1}" -f $gaps[0].lateMs, $gaps[0].skewMs) }
        if ($deeps.Count -gt 0) {
            $names = @($deeps[0].threads.PSObject.Properties | Select-Object -First 4 | ForEach-Object { "$($_.Name)=$($_.Value)" })
            Write-Host ("  deep: pids={0} waits={1}" -f (@($deeps[0].watchPids).Count), ($names -join ' '))
        }
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        if ($fail.Count -gt 0) {
            Write-Host "SELFTEST FAILED:" -ForegroundColor Red
            $fail | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
            exit 1
        }
        Write-Host 'SELFTEST PASSED -- the lateness detector and the deep sampler both fired.' -ForegroundColor Green
    }
}
