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
    Watch    The whole thing in one command: start the samplers, poll until a
             stall is announced, then collect and report. This is the one to use --
             stalls are not predictable, so leave it running alongside the build.
    Start    Deploy the sampler into each target VM as a SYSTEM scheduled task and
             run it. The task carries an AtStartup trigger, so it survives the
             reboots Phase 8/9 perform; the sampler self-terminates at its deadline.
    Status   Ask every guest whether the sampler is alive and whether it has caught
             a stall yet. Cheap -- reads a one-line-per-stall summary file, not the
             samples. Safe to run repeatedly during a build.
    Stop     Stop and unregister the sampler task in each target VM.
    Collect  Pull each guest's JSONL back to vmbuild\logs\dscstall\.
    Report   Analyse collected JSONL and print stall windows + a verdict each.
    SelfTest Run the sampler locally with an injected freeze and assert it fires.

.PARAMETER PollSeconds
    -Action Watch: seconds between stall checks. Default 60.

.PARAMETER WatchMinutes
    -Action Watch: give up waiting after this long. Default 240. The samplers keep
    running either way, so a give-up is not a loss.

.PARAMETER KeepRunning
    -Action Watch: leave the samplers in place after collecting, to catch another
    stall in the same build.

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

.PARAMETER Detailed
    Print the per-window thread-wait histograms and connection lists to the
    console too. They always go to the report log regardless.

.EXAMPLE
    # One command: start, watch, detect, collect, report. Run it alongside the build.
    .\tools\Watch-DscStall.ps1 -Action Watch -DomainName cstest1.com

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
    [ValidateSet('Watch', 'Start', 'Stop', 'Status', 'Collect', 'Report', 'SelfTest')]
    [string]$Action,
    [string]$DomainName,
    [string[]]$VMName,
    [string]$Path,
    [int]$DurationMinutes = 480,
    [int]$StallSeconds = 60,
    [int]$TimeoutSeconds = 180,
    [int]$StallAlertSeconds = 150,
    [int]$PollSeconds = 60,
    [int]$WatchMinutes = 240,
    [switch]$CaptureDump,
    [switch]$KeepRunning,
    [switch]$Detailed
)

$ErrorActionPreference = 'Stop'

$toolsRoot = $PSScriptRoot
$vmbuildRoot = Split-Path -Parent $toolsRoot
# Captured here: inside a function $PSBoundParameters is the FUNCTION's, not the script's.
$PathWasExplicit = $PSBoundParameters.ContainsKey('Path')
if (-not $Path) { $Path = Join-Path $vmbuildRoot 'logs\dscstall' }

$guestDir = 'C:\staging\DSC\StallWatch'
$guestScript = "$guestDir\Watch-Stall.ps1"
$guestOut = "$guestDir\samples.jsonl"
$guestStopFile = "$guestDir\stop.flag"
$guestTaskName = 'MemLabsDscStallWatch'

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
    [int]$StallAlertSeconds = 150,
    [switch]$CaptureDump,
    [int]$InjectStallSeconds = 0
)

$dir = Split-Path -Parent $OutFile
if (-not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }

# Single instance, enforced in the guest. Two samplers appending to one file
# interleave their ticks, which silently multiplies the apparent tick rate and
# makes every statusAge-derived window meaningless. An abandoned mutex (previous
# owner killed) still grants ownership, which is what we want after a hard reset.
$stallMutex = $null
$gotLock = $false
try {
    $stallMutex = New-Object System.Threading.Mutex($false, 'Global\MemLabsDscStallWatch')
    $gotLock = $stallMutex.WaitOne(0)
}
catch [System.Threading.AbandonedMutexException] { $gotLock = $true }
catch { $gotLock = $false }
if (-not $gotLock) {
    ([pscustomobject]@{ type = 'skipped'; utc = ([datetime]::UtcNow).ToString('o'); reason = 'another sampler already holds Global\MemLabsDscStallWatch' } |
            ConvertTo-Json -Compress) | Out-File -FilePath $OutFile -Append -Encoding ascii
    return
}

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

# Everything a human needs to name the culprit, captured AT the stall rather than
# reconstructed afterwards: the wait reasons alone classify a stall, they do not
# identify it. One text file per stall so it transfers as a string.
function Write-StallBundle {
    param([string]$Folder, [string]$Status, [int]$AgeSec, [int[]]$WatchPids, [bool]$WantDump, [string]$DscLogPath)

    $stamp = ([datetime]::UtcNow).ToString('yyyyMMdd-HHmmssZ')
    $file = Join-Path $Folder "stall-$stamp.txt"
    $b = New-Object System.Collections.Generic.List[string]
    $b.Add("== STALL BUNDLE == $stamp computer=$env:COMPUTERNAME staticFor=${AgeSec}s")
    $b.Add("frozen status: $Status")

    $b.Add('')
    $b.Add('== threads of watched processes (state/waitReason/cpuMs/startAddress) ==')
    foreach ($wp in $WatchPids) {
        try {
            $proc = Get-Process -Id $wp -ErrorAction Stop
            # A protected process (MsMpEng, PPL) does not THROW on these reads -- it
            # silently yields null/0. Detect that and say so, because printing cpuMs=0
            # would claim the thread burned no CPU, which is the whole question here.
            $ptime = $null
            try { $ptime = $proc.TotalProcessorTime } catch {}
            $denied = ($null -eq $ptime)
            $pcpu = '?'
            if (-not $denied) { $pcpu = '{0:n0}' -f $ptime.TotalMilliseconds }
            $pws = '?'
            try { $pws = [int]($proc.WorkingSet64 / 1MB) } catch {}
            $note = ''
            if ($denied) { $note = '  [per-thread CPU/start denied -- protected process or insufficient rights]' }
            $b.Add(("-- pid {0} {1} cpuMs={2} ws={3}MB threads={4}{5}" -f $wp, $proc.ProcessName, $pcpu, $pws, $proc.Threads.Count, $note))
            foreach ($th in $proc.Threads) {
                $state = 'Unknown'
                try { $state = "$($th.ThreadState)" } catch {}
                $reason = ''
                if ($state -eq 'Wait') { try { $reason = "/$($th.WaitReason)" } catch {} }
                # StartAddress 0 is never real -- it means this thread's detail was
                # denied, even when the process total was readable.
                $rawAddr = 0
                try { $rawAddr = [int64]$th.StartAddress } catch {}
                $cpu = '?'
                $addr = '?'
                if (-not $denied -and $rawAddr -ne 0) {
                    $addr = '0x{0:X}' -f $rawAddr
                    try { $cpu = [int]$th.TotalProcessorTime.TotalMilliseconds } catch {}
                }
                $b.Add(("   tid={0,-8} {1}{2} cpuMs={3} start={4}" -f $th.Id, $state, $reason, $cpu, $addr))
            }
        }
        catch { $b.Add("-- pid $wp unreadable: $($_.Exception.Message)") }
    }

    $b.Add('')
    $b.Add('== top 25 processes by CPU ==')
    try {
        $procRows = @()
        foreach ($pr in (Get-Process -ErrorAction SilentlyContinue)) {
            $ms = -1
            try { $ms = $pr.TotalProcessorTime.TotalMilliseconds } catch {}
            $procRows += [pscustomobject]@{ P = $pr; Ms = $ms }
        }
        foreach ($row in ($procRows | Sort-Object Ms -Descending | Select-Object -First 25)) {
            $cpuText = '?'
            if ($row.Ms -ge 0) { $cpuText = '{0:n0}' -f $row.Ms }
            $wsText = '?'
            try { $wsText = [int]($row.P.WorkingSet64 / 1MB) } catch {}
            $b.Add(("   {0,-28} pid={1,-8} cpuMs={2,-12} ws={3}MB" -f $row.P.ProcessName, $row.P.Id, $cpuText, $wsText))
        }
    }
    catch { $b.Add("   process list failed: $($_.Exception.Message)") }

    $b.Add('')
    $b.Add('== netstat -ano (non-listening) ==')
    try {
        $ns = & netstat.exe -ano 2>$null
        foreach ($l in $ns) {
            if ($l -match '\s(SYN_SENT|ESTABLISHED|CLOSE_WAIT|FIN_WAIT|TIME_WAIT|LAST_ACK)\s') { $b.Add("   $($l.Trim())") }
        }
    }
    catch { $b.Add("   netstat failed: $($_.Exception.Message)") }

    $b.Add('')
    $b.Add("== $DscLogPath (last 120 lines) ==")
    try {
        if (Test-Path $DscLogPath) { Get-Content -Path $DscLogPath -Tail 120 -ErrorAction Stop | ForEach-Object { $b.Add("   $_") } }
        else { $b.Add('   (not present)') }
    }
    catch { $b.Add("   read failed: $($_.Exception.Message)") }

    $b.Add('')
    $b.Add('== events in the last 15 minutes ==')
    $since = (Get-Date).AddMinutes(-15)
    foreach ($logName in @('System', 'Application', 'Microsoft-Windows-DSC/Operational', 'Microsoft-Windows-WMI-Activity/Operational')) {
        $b.Add("-- $logName")
        try {
            $evts = Get-WinEvent -FilterHashtable @{ LogName = $logName; StartTime = $since } -MaxEvents 40 -ErrorAction Stop
            foreach ($ev in $evts) {
                $msg = "$($ev.Message)"
                if ($msg.Length -gt 240) { $msg = $msg.Substring(0, 240) + '...' }
                $b.Add(("   {0:HH:mm:ss} {1,-6} id={2,-6} {3}" -f $ev.TimeCreated, $ev.LevelDisplayName, $ev.Id, ($msg -replace '\s+', ' ')))
            }
        }
        catch { $b.Add("   (none, or log unavailable: $($_.Exception.Message))") }
    }

    # Opt-in: a full dump is the only artifact that yields a real call stack, but it
    # briefly suspends the target -- which is the thing under investigation.
    if ($WantDump -and $WatchPids.Count -gt 0) {
        $b.Add('')
        $b.Add('== process dump ==')
        $target = $WatchPids[0]
        try {
            $best = Get-Process -Id $WatchPids -ErrorAction SilentlyContinue |
                Sort-Object { $_.Threads.Count } -Descending | Select-Object -First 1
            if ($best) { $target = $best.Id }
        }
        catch {}
        $dumpPath = Join-Path $Folder "stall-$stamp-pid$target.dmp"
        try {
            & rundll32.exe 'C:\Windows\System32\comsvcs.dll' MiniDump $target $dumpPath full 2>&1 | Out-Null
            if (Test-Path $dumpPath) { $b.Add("   wrote $dumpPath ($([int]((Get-Item $dumpPath).Length / 1MB))MB) -- open in WinDbg, ~*k for the stacks") }
            else { $b.Add('   MiniDump produced no file') }
        }
        catch { $b.Add("   dump failed: $($_.Exception.Message)") }
    }

    $b | Out-File -FilePath $file -Encoding ascii -Force
    return $file
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
$stallAnnounced = $false
$stallFile = Join-Path $dir 'stalls.txt'
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
        $stallAnnounced = $false
    }
    $statusAgeSec = [math]::Round(($mono - $statusChangedMono) / 1000.0, 0)

    # Announce the moment a static period crosses the alert threshold, to a tiny
    # file of its own. Stalls are not predictable, so -Action Status has to be able
    # to answer "has one happened yet" without dragging back a half-megabyte of ticks.
    if (-not $stallAnnounced -and $statusAgeSec -ge $StallAlertSeconds) {
        $stallAnnounced = $true
        $bundlePath = ''
        try { $bundlePath = Write-StallBundle -Folder $dir -Status $statusText -AgeSec $statusAgeSec -WatchPids $watchPids -WantDump ([bool]$CaptureDump) -DscLogPath $DscLog }
        catch { $bundlePath = "bundle failed: $($_.Exception.Message)" }
        ('{0} {1}s static | {2} | bundle={3}' -f $wall.ToString('o'), $statusAgeSec, $statusText, $bundlePath) |
            Out-File -FilePath $stallFile -Append -Encoding ascii
        Write-Sample ([pscustomobject]@{
                type      = 'stallhit'
                seq       = $seq
                utc       = $wall.ToString('o')
                statusAge = $statusAgeSec
                status    = $statusText
                bundle    = $bundlePath
            })
    }

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

function Invoke-StartAction {
        $targets = Get-Targets
        Write-Host "Starting DSC stall sampler on $($targets.Count) VM(s): $($targets -join ', ')" -ForegroundColor Cyan
        $sb = {
            param($dir, $script, $outFile, $stopFile, $payload, $minutes, $taskName, $alertSeconds, $wantDump)
            $ev = New-Object System.Collections.Generic.List[string]
            try {
                if (-not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }

                # Kill leftovers BEFORE wiping the file, or the orphan appends into the
                # fresh one between the delete and the kill.
                $leftovers = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
                        Where-Object { "$($_.CommandLine)" -like "*Watch-Stall.ps1*" })
                foreach ($lp in $leftovers) { Stop-Process -Id $lp.ProcessId -Force -ErrorAction SilentlyContinue }
                if ($leftovers.Count -gt 0) {
                    $ev.Add("killedLeftovers=$($leftovers.Count)")
                    Start-Sleep -Seconds 2
                }

                Remove-Item -Path $stopFile -Force -ErrorAction SilentlyContinue
                Remove-Item -Path $outFile -Force -ErrorAction SilentlyContinue
                Remove-Item -Path (Join-Path $dir 'stalls.txt') -Force -ErrorAction SilentlyContinue
                $payload | Out-File -FilePath $script -Encoding ascii -Force

                $bytes = 0
                if (Test-Path $script) { $bytes = (Get-Item $script).Length }
                $ev.Add("payloadBytes=$bytes")
                if ($bytes -lt 1000) { $ev.Add('ERROR=payload-not-written'); return ($ev -join ' ') }

                # Prove the payload parses under the GUEST's PS 5.1 before scheduling it.
                # A syntax error would otherwise surface only as "no samples" much later.
                $ptok = $null
                $perr = $null
                [void][System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$ptok, [ref]$perr)
                if ($perr -and $perr.Count -gt 0) {
                    $ev.Add("ERROR=payload-parse L$($perr[0].Extent.StartLineNumber): $($perr[0].Message)")
                    return ($ev -join ' ')
                }

                # A scheduled task, not Start-Process: a detached child of the PSDirect
                # host is not guaranteed to outlive the session, and AtStartup brings the
                # sampler back after the reboots Phase 8/9 perform.
                # Unregistering a task does NOT kill an instance already running,
                # and a leftover sampler would interleave its ticks into the same file.
                Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
                $argLine = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -OutFile "{1}" -StopFile "{2}" -DurationMinutes {3} -StallAlertSeconds {4}' -f $script, $outFile, $stopFile, $minutes, $alertSeconds
                if ($wantDump) { $argLine = $argLine + ' -CaptureDump' }
                $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argLine
                $trigger = New-ScheduledTaskTrigger -AtStartup
                $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
                $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Seconds 0)
                Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
                Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
                Start-Sleep -Seconds 6

                $state = (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue).State
                $info = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
                $lines = 0
                if (Test-Path $outFile) { $lines = @(Get-Content $outFile -ErrorAction SilentlyContinue).Count }
                $ev.Add("task=$state lastResult=$($info.LastTaskResult) lines=$lines")
                if ($lines -eq 0) { $ev.Add('ERROR=task-ran-but-wrote-nothing') }
                return ($ev -join ' ')
            }
            catch {
                $ev.Add("ERROR=$($_.Exception.GetType().Name): $($_.Exception.Message)")
                return ($ev -join ' ')
            }
        }
        foreach ($vm in $targets) {
            $o = Invoke-Guest -Vm $vm -Sb $sb -ArgList @($guestDir, $guestScript, $guestOut, $guestStopFile, $guestPayload, $DurationMinutes, $guestTaskName, $StallAlertSeconds, [bool]$CaptureDump)
            if ($null -ne $o) {
                $color = 'Green'
                if ("$o" -like '*ERROR=*') { $color = 'Red' }
                Write-Host "  $vm : $o" -ForegroundColor $color
            }
        }

        # "Register-ScheduledTask returned" is not proof the sampler is still writing.
        # Re-check on a NEW session, and require the sample count to have GROWN.
        Write-Host "`nVerifying the sampler is alive and still writing..." -ForegroundColor Cyan
        $verifySb = {
            param($outFile, $taskName)
            $lines1 = 0
            if (Test-Path $outFile) { $lines1 = @(Get-Content $outFile -ErrorAction SilentlyContinue).Count }
            Start-Sleep -Seconds 4
            $lines2 = 0
            if (Test-Path $outFile) { $lines2 = @(Get-Content $outFile -ErrorAction SilentlyContinue).Count }
            $state = (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue).State
            $verdict = 'GROWING'
            if ($lines2 -le $lines1) { $verdict = 'ERROR=not-growing' }
            return "task=$state lines=$lines1->$lines2 $verdict"
        }
        foreach ($vm in $targets) {
            $o = Invoke-Guest -Vm $vm -Sb $verifySb -ArgList @($guestOut, $guestTaskName)
            if ($null -ne $o) {
                $color = 'Green'
                if ("$o" -like '*ERROR=*') { $color = 'Red' }
                Write-Host "  $vm : $o" -ForegroundColor $color
            }
        }
        Write-Host "`nSampler writes $guestOut in each guest. Collect with -Action Collect." -ForegroundColor Yellow
    }

    function Invoke-StopAction {
        $targets = Get-Targets
        $sb = {
            param($stopFile, $taskName)
            New-Item -Path $stopFile -ItemType File -Force | Out-Null
            Start-Sleep -Seconds 3
            $running = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
                    Where-Object { "$($_.CommandLine)" -like "*Watch-Stall.ps1*" })
            foreach ($e in $running) { Stop-Process -Id $e.ProcessId -Force -ErrorAction SilentlyContinue }
            # Unregister too, or the AtStartup trigger resurrects it on the next reboot.
            Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
            $left = (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)
            return "killed=$($running.Count) taskRemoved=$($null -eq $left)"
        }
        foreach ($vm in $targets) {
            $o = Invoke-Guest -Vm $vm -Sb $sb -ArgList @($guestStopFile, $guestTaskName)
            if ($null -ne $o) { Write-Host "  $vm : $o" -ForegroundColor Green }
        }
    }

    function Invoke-StatusAction {
        $targets = Get-Targets
        Write-Host "Sampler status across $($targets.Count) VM(s):" -ForegroundColor Cyan
        $sb = {
            param($dir, $outFile, $taskName)
            $state = (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue).State
            if (-not $state) { $state = 'no-task' }
            $alive = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
                    Where-Object { "$($_.CommandLine)" -like "*Watch-Stall.ps1*" }).Count
            $lines = 0
            if (Test-Path $outFile) { $lines = @(Get-Content $outFile -ErrorAction SilentlyContinue).Count }
            $stallFile = Join-Path $dir 'stalls.txt'
            $stalls = @()
            if (Test-Path $stallFile) { $stalls = @(Get-Content $stallFile -ErrorAction SilentlyContinue) }
            $last = ''
            if ($stalls.Count -gt 0) { $last = $stalls[$stalls.Count - 1] }
            return "task=$state procs=$alive lines=$lines stalls=$($stalls.Count)|$last"
        }
        $totalStalls = 0
        foreach ($vm in $targets) {
            $o = Invoke-Guest -Vm $vm -Sb $sb -ArgList @($guestDir, $guestOut, $guestTaskName)
            if ($null -eq $o) { continue }
            $parts = "$o" -split '\|', 2
            $head = $parts[0]
            $last = ''
            if ($parts.Count -gt 1) { $last = $parts[1] }
            $n = 0
            if ($head -match 'stalls=(\d+)') { $n = [int]$Matches[1] }
            $totalStalls += $n
            $color = 'Gray'
            if ($n -gt 0) { $color = 'Magenta' }
            elseif ($head -like '*procs=0*') { $color = 'Red' }
            Write-Host ("  {0,-16} {1}" -f $vm, $head) -ForegroundColor $color
            if ($last) { Write-Host ("                   last: {0}" -f $last) -ForegroundColor Magenta }
        }
        Write-Host ""
        if ($totalStalls -gt 0) {
            Write-Host "$totalStalls stall(s) caught -- run -Action Collect then -Action Report." -ForegroundColor Green
        }
        else {
            Write-Host "No stall of >= ${StallAlertSeconds}s seen yet. Leave the sampler running and check again." -ForegroundColor Yellow
        }
        return $totalStalls
    }

    function Invoke-CollectAction {
        $targets = Get-Targets
        if (-not (Test-Path $Path)) { New-Item -Path $Path -ItemType Directory -Force | Out-Null }
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        # Each collection gets its own folder. A single bad collection used to poison
        # every later report, because Report globs the whole tree.
        $runFolder = Join-Path $Path $stamp
        New-Item -Path $runFolder -ItemType Directory -Force | Out-Null
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
            $dest = Join-Path $runFolder ("{0}.jsonl" -f $vm)
            $text | Set-Content -LiteralPath $dest -Encoding UTF8
            Write-Host "  $vm : $((@($text -split "`n")).Count) line(s) -> $dest" -ForegroundColor Green

            # The bundles are the part a human reads: thread stacks-by-wait-reason,
            # events, DSC log tail, captured AT the stall.
            $bundleSb = {
                param($dir)
                $out = @()
                foreach ($bf in @(Get-ChildItem -Path $dir -Filter 'stall-*.txt' -File -ErrorAction SilentlyContinue)) {
                    $out += ("<<<FILE {0}>>>`n{1}" -f $bf.Name, (Get-Content -Path $bf.FullName -Raw -ErrorAction SilentlyContinue))
                }
                return ($out -join "`n")
            }
            $bundles = Invoke-Guest -Vm $vm -Sb $bundleSb -ArgList @($guestDir)
            if (-not [string]::IsNullOrWhiteSpace($bundles)) {
                foreach ($chunk in ("$bundles" -split '<<<FILE ')) {
                    if ([string]::IsNullOrWhiteSpace($chunk)) { continue }
                    $nl = $chunk.IndexOf("`n")
                    if ($nl -lt 0) { continue }
                    $name = $chunk.Substring(0, $nl).TrimEnd('>', "`r")
                    $body = $chunk.Substring($nl + 1)
                    $bdest = Join-Path $runFolder ("{0}-{1}" -f $vm, $name)
                    $body | Set-Content -LiteralPath $bdest -Encoding UTF8
                    Write-Host "           bundle -> $bdest" -ForegroundColor Magenta
                }
            }
        }
        Write-Host "`nCollected into $runFolder" -ForegroundColor Yellow
        Write-Host "Analyse with: .\tools\Watch-DscStall.ps1 -Action Report" -ForegroundColor Yellow
    }

    function Invoke-ReportAction {
        if (-not (Test-Path $Path)) { throw "No collected samples at $Path" }

        # Default to the NEWEST collection, not every file ever collected -- otherwise
        # one bad run keeps reappearing in every report forever. An explicit -Path wins.
        $reportRoot = $Path
        if (-not $PathWasExplicit) {
            $runs = @(Get-ChildItem $Path -Directory -ErrorAction SilentlyContinue |
                    Where-Object { @(Get-ChildItem $_.FullName -Filter '*.jsonl' -File -ErrorAction SilentlyContinue).Count -gt 0 } |
                    Sort-Object Name -Descending)
            if ($runs.Count -gt 0) {
                $reportRoot = $runs[0].FullName
                $older = $runs.Count - 1
                Write-Host "Reporting on the newest collection: $($runs[0].Name)" -ForegroundColor Cyan
                if ($older -gt 0) { Write-Host "  ($older older collection(s) ignored -- pass -Path to pick one)" -ForegroundColor DarkGray }
                $loose = @(Get-ChildItem $Path -Filter '*.jsonl' -File -ErrorAction SilentlyContinue)
                if ($loose.Count -gt 0) { Write-Host "  ($($loose.Count) loose file(s) from an older layout ignored)" -ForegroundColor DarkGray }
            }
        }

        $files = @(Get-ChildItem $reportRoot -Filter '*.jsonl' -File | Sort-Object LastWriteTime -Descending)
        if ($files.Count -eq 0) { throw "No .jsonl files in $reportRoot" }

        $reportFile = Join-Path $reportRoot ("report-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
        $reportLines = New-Object System.Collections.Generic.List[string]
        $verdictTally = @{}

        # Everything lands in the log; the console gets the short version unless -Detailed.
        function Write-Report {
            param([string]$Text = '', [string]$Color = 'Gray', [switch]$FileOnly)
            $reportLines.Add($Text)
            if ($Detailed -or -not $FileOnly) { Write-Host $Text -ForegroundColor $Color }
        }

        foreach ($f in $files) {
            Write-Report ""
            Write-Report "=== $($f.Name) ===" -Color Cyan
            $recs = @()
            foreach ($line in [System.IO.File]::ReadLines($f.FullName)) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                try { $recs += ($line | ConvertFrom-Json) } catch {}
            }
            $ticks = @($recs | Where-Object { $_.type -eq 'tick' })
            $gaps = @($recs | Where-Object { $_.type -eq 'gap' })
            $deeps = @($recs | Where-Object { $_.type -eq 'deep' })
            if ($ticks.Count -eq 0) { Write-Report '  no ticks' -Color Yellow; continue }
            $span = ([datetime]$ticks[-1].utc) - ([datetime]$ticks[0].utc)
            Write-Report ("  ticks={0} span={1:hh\:mm\:ss} gaps={2} deep={3}" -f $ticks.Count, $span, $gaps.Count, $deeps.Count)

            # A file written by more than one sampler has interleaved ticks, so every
            # statusAge-derived window in it is fiction. Say so and skip it rather than
            # reporting hundreds of invented windows.
            $starts = @($recs | Where-Object { $_.type -eq 'start' }).Count
            $expected = [int]$span.TotalSeconds
            if ($expected -lt 1) { $expected = 1 }
            $rate = [math]::Round($ticks.Count / $expected, 2)
            if ($starts -gt 1 -or $rate -gt 1.5) {
                Write-Report ("  CORRUPT: {0} start record(s), {1} ticks/sec against a 1/sec sampler -- more than one sampler wrote this file." -f $starts, $rate) -Color Red
                Write-Report '           Re-run -Action Start (it now kills leftovers and the sampler is single-instance), then collect again.' -Color Red
                continue
            }

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
                Write-Report "  no window with status static >= ${StallSeconds}s" -Color Green
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
                    $verdict = 'BLOCKED, possibly on the network -- see conns in the log'
                }
                $tag = ($verdict -split ':')[0]
                if ($verdictTally.ContainsKey($tag)) { $verdictTally[$tag] = $verdictTally[$tag] + 1 } else { $verdictTally[$tag] = 1 }

                $frozen = '(unknown)'
                if ($winDeep.Count -gt 0) { $frozen = "$($winDeep[0].status)" }
                $frozenShort = $frozen
                if ($frozenShort.Length -gt 72) { $frozenShort = $frozenShort.Substring(0, 72) + '...' }

                Write-Report ""
                Write-Report ("  window {0:HH:mm:ss} -> {1:HH:mm:ss}  ~{2}s static" -f $start, $end, $sec) -Color Yellow
                Write-Report ("    frozen status : {0}" -f $frozenShort)
                Write-Report ("    frozen full   : {0}" -f $frozen) -FileOnly
                Write-Report ("    sampler late  : max {0} ms   clock skew max {1} ms   sampler own work max {2} ms" -f $maxLate, $maxSkew, (($w | Measure-Object workMs -Maximum).Maximum))
                Write-Report ("    watched CPU   : {0} ms over the window   DSC_Log grew: {1}" -f $cpuMs, $logGrew)
                Write-Report ("    VERDICT       : {0}" -f $verdict) -Color Magenta
                if ($winDeep.Count -gt 0) {
                    $last = $winDeep[-1]
                    $tp = @()
                    foreach ($p in $last.threads.PSObject.Properties) { $tp += ('{0}={1}' -f $p.Name, $p.Value) }
                    Write-Report ("    thread waits  : {0}" -f (($tp | Sort-Object) -join '  ')) -FileOnly
                    if (@($last.conns).Count -gt 0) {
                        Write-Report ("    conns         : {0}" -f ((@($last.conns)) -join '  ')) -FileOnly
                    }
                    Write-Report ("    top cpu       : {0}" -f ((@($last.topCpu)) -join '  ')) -FileOnly
                    Write-Report ("    probe cost    : {0} ms (high = the thread probe itself was starved)" -f $last.probeMs) -FileOnly
                }
            }
        }

        Write-Report ""
        Write-Report "--- verdict summary across $($files.Count) file(s) ---" -Color Cyan
        if ($verdictTally.Count -eq 0) {
            Write-Report '  no stall windows found' -Color Green
        }
        else {
            foreach ($k in ($verdictTally.Keys | Sort-Object)) {
                Write-Report ("  {0,-22} {1} window(s)" -f $k, $verdictTally[$k])
            }
        }
        $reportLines | Set-Content -LiteralPath $reportFile -Encoding UTF8
        Write-Host ""
        Write-Host "Full report (thread waits, connections, top CPU): $reportFile" -ForegroundColor Yellow
        if (-not $Detailed) { Write-Host "Re-run with -Detailed to see all of it on screen." -ForegroundColor DarkGray }
    }

    function Invoke-SelfTestAction {
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

switch ($Action) {
    'Start' { Invoke-StartAction }
    'Stop' { Invoke-StopAction }
    'Status' { $null = Invoke-StatusAction }
    'Collect' { Invoke-CollectAction }
    'Report' { Invoke-ReportAction }
    'SelfTest' { Invoke-SelfTestAction }

    'Watch' {
        # The whole loop in one command: start, poll until a stall is announced,
        # then collect and report. Stalls are not predictable, so the only workable
        # shape is to leave this running alongside the build.
        Invoke-StartAction
        $deadline = (Get-Date).AddMinutes($WatchMinutes)
        $found = 0
        Write-Host ""
        Write-Host ("Watching until a stall of >= {0}s appears, or {1:HH:mm:ss} (-WatchMinutes {2}). Ctrl-C is safe -- the samplers keep running." -f $StallAlertSeconds, $deadline, $WatchMinutes) -ForegroundColor Cyan
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds $PollSeconds
            Write-Host ""
            Write-Host ("[{0:HH:mm:ss}] poll" -f (Get-Date)) -ForegroundColor DarkGray
            $found = Invoke-StatusAction
            if ($found -gt 0) { break }
        }
        if ($found -le 0) {
            Write-Host ""
            Write-Host "No stall seen before the watch deadline. The samplers are still running -- re-run -Action Watch or -Action Status." -ForegroundColor Yellow
            return
        }
        Write-Host ""
        Write-Host "Stall detected. Collecting..." -ForegroundColor Green
        Invoke-CollectAction
        Invoke-ReportAction
        if (-not $KeepRunning) {
            Write-Host ""
            Write-Host "Stopping samplers (-KeepRunning to leave them in place)..." -ForegroundColor Cyan
            Invoke-StopAction
        }
    }
}
