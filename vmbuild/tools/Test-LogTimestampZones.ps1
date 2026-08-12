<#
.SYNOPSIS
    Audits guest logs pulled into the logs folder for timezone correctness.

.DESCRIPTION
    Every pulled guest log gives us three independent facts:

      1. the timestamps INSIDE it, written by the guest in the guest's timezone;
      2. the file's mtime on the host, written by us at the moment we pulled it;
      3. the lab's configured vmOptions.timeZone, from the .config.json sidecar.

    Those three over-determine the answer, so a wrong timezone cannot hide. Two
    independent checks fall out:

    OFFSET  ConfigMgr's own logs (and, since the UTC-bias change, ours) carry the
            offset in the timestamp -- "20:22:32.990+240". That is the guest's REAL
            offset at the moment it wrote the line. Compare it to the offset the
            config asked for: a mismatch means Set-TimeZone never took effect on
            that VM, and every timestamp it produced is shifted.

    LAG     Convert the newest line to UTC, convert the file mtime to UTC, subtract.
            We pull a log right after the guest writes it, so the lag is normally
            seconds to minutes. A NEGATIVE lag is impossible -- content cannot be
            newer than the moment we copied it -- so it proves the conversion or the
            guest clock is wrong. A lag that lands within a few minutes of the
            host/guest offset difference is the signature of a mis-set zone.

    Stale logs legitimately produce a large positive lag (the component simply
    stopped writing well before the pull), so that alone is reported, not failed.

.PARAMETER LogPath
    Folder holding the pulled logs. Defaults to vmbuild\logs next to this script.

.PARAMETER Detail
    Emit one row per file instead of just the problems and a summary.

.PARAMETER LagWarnMinutes
    Positive lag above this is reported as STALE rather than assumed healthy.

.EXAMPLE
    .\Test-LogTimestampZones.ps1 -Detail
#>
[CmdletBinding()]
param(
    [string]$LogPath,
    [switch]$Detail,
    [switch]$FailOnDiverged,
    [int]$LagWarnMinutes = 240
)

if (-not $LogPath) { $LogPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'logs' }
if (-not (Test-Path -LiteralPath $LogPath)) { Write-Error "Log path not found: $LogPath"; exit 2 }

$hostOffMin = [int]([DateTimeOffset]::Now.Offset.TotalMinutes)
$fmtOff = { param($m) '{0}{1:00}:{2:00}' -f $(if ($m -ge 0) { '+' } else { '-' }), [math]::Floor([math]::Abs($m) / 60), ([math]::Abs($m) % 60) }

# Both timestamp shapes carry an optional trailing bias: minutes to ADD to reach UTC.
$rxXml = [regex]'time="(?<h>\d{2}):(?<mi>\d{2}):(?<s>\d{2})(?:\.\d+)?(?<bias>[+\-]\d+)?"\s+date="(?<mo>\d{1,2})-(?<d>\d{1,2})-(?<y>\d{4})"'
$rxNative = [regex]'\$\$<[^>]*><(?<mo>\d{1,2})-(?<d>\d{1,2})-(?<y>\d{4})\s+(?<h>\d{1,2}):(?<mi>\d{2}):(?<s>\d{2})(?:\.\d+)?(?<bias>[+\-]\d+)?>'

function Get-NewestStamp {
    param([string]$Path)
    $lines = $null
    # Array-wrap: a one-line file comes back as a STRING, and indexing a string yields a
    # single CHARACTER, so the scan below would silently find no timestamp.
    try { $lines = @(Get-Content -LiteralPath $Path -Tail 400 -ErrorAction Stop) } catch { return $null }
    if (-not $lines -or $lines.Count -eq 0) { return $null }
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        foreach ($rx in @($rxXml, $rxNative)) {
            $m = $rx.Match([string]$lines[$i])
            if (-not $m.Success) { continue }
            try {
                $dt = [datetime]::new([int]$m.Groups['y'].Value, [int]$m.Groups['mo'].Value, [int]$m.Groups['d'].Value,
                    [int]$m.Groups['h'].Value, [int]$m.Groups['mi'].Value, [int]$m.Groups['s'].Value)
            }
            catch { continue }
            $bias = $null
            if ($m.Groups['bias'].Success) { $bias = [int]$m.Groups['bias'].Value }
            return [pscustomobject]@{ Local = $dt; BiasMin = $bias }
        }
    }
    return $null
}

# A domain's timezone is NOT constant: pstest4.com alternated between India and Eastern on
# consecutive runs. New-Lab archives the previous run's sidecar by renaming it with the
# CURRENT time when the next run starts, so that stamp is the END of the window the sidecar
# describes. Build ordered windows and attribute each pulled file by its mtime.
$windowsByDomain = @{}
foreach ($cfg in @(Get-ChildItem -LiteralPath $LogPath -Filter 'VMBuild.*.config.json' -File -ErrorAction SilentlyContinue)) {
    $name = $cfg.Name -replace '^VMBuild\.', '' -replace '\.config\.json$', ''
    $endsAt = [datetime]::MaxValue
    $domain = $name
    if ($name -match '^(?<d>.+?)(?<stamp>\d{8}-\d{6})$') {
        $domain = $Matches['d']
        try { $endsAt = [datetime]::ParseExact($Matches['stamp'], 'yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture) } catch { continue }
    }
    $tzId = $null
    $vmNames = @()
    try {
        $c = Get-Content -LiteralPath $cfg.FullName -Raw | ConvertFrom-Json
        $tzId = $c.vmOptions.timeZone
        $vmNames = @(@($c.virtualMachines) | ForEach-Object { $_.vmName } | Where-Object { $_ })
    }
    catch { continue }
    if (-not $tzId) { continue }
    $tz = $null
    try { $tz = [TimeZoneInfo]::FindSystemTimeZoneById($tzId) } catch { continue }
    if (-not $windowsByDomain.ContainsKey($domain)) { $windowsByDomain[$domain] = New-Object System.Collections.Generic.List[object] }
    $windowsByDomain[$domain].Add([pscustomobject]@{ EndsAt = $endsAt; TzId = $tzId; Tz = $tz; VmNames = $vmNames })
}
foreach ($d in @($windowsByDomain.Keys)) { $windowsByDomain[$d] = @($windowsByDomain[$d] | Sort-Object EndsAt) }

# VM name -> domain. Names repeat across runs of the same lab, never across labs.
$vmToDomain = @{}
foreach ($d in $windowsByDomain.Keys) {
    foreach ($w in $windowsByDomain[$d]) { foreach ($n in $w.VmNames) { $vmToDomain[[string]$n] = $d } }
}

$files = @(Get-ChildItem -LiteralPath $LogPath -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^(?<vm>[^-]+(?:-[^-]+)*?)-Phase\d+-\d{8}-\d{6}-' })

$rows = New-Object System.Collections.Generic.List[object]
foreach ($f in $files) {
    $vm = ($f.Name -split '-Phase\d+-')[0]
    $domain = $vmToDomain[$vm]
    # The run whose window contains this pull, not just the lab's current setting.
    $win = $null
    $expOff = $null
    if ($domain) {
        $win = @($windowsByDomain[$domain] | Where-Object { $_.EndsAt -ge $f.LastWriteTime }) | Select-Object -First 1
        if ($win) { $expOff = [int]($win.Tz.GetUtcOffset($f.LastWriteTimeUtc).TotalMinutes) }
    }

    $st = Get-NewestStamp -Path $f.FullName
    if (-not $st) {
        $rows.Add([pscustomobject]@{ File = $f.Name; VM = $vm; Domain = $domain; Verdict = 'NO-TIMESTAMP'; Detail = 'no parseable timestamp in the last 400 lines' })
        continue
    }

    # Offset actually used by the writer, when the log declares it.
    $obsOff = if ($null -ne $st.BiasMin) { -$st.BiasMin } else { $null }
    # For the lag we need SOME offset: prefer the one the log declares, else the config's.
    $useOff = if ($null -ne $obsOff) { $obsOff } else { $expOff }

    $verdict = 'OK'
    $notes = @()

    if ($null -ne $obsOff -and $null -ne $expOff -and $obsOff -ne $expOff) {
        # Not automatically a bug: vmOptions.timeZone is applied by Phase 1's Fix_NewVmSettings,
        # which only runs under `if ($createVM)`. A VM reused from an earlier build keeps the
        # zone it was created with, so changing the config's timezone and re-running against an
        # existing lab leaves those VMs behind. The log's own declaration is the truth.
        $verdict = 'ZONE-DIVERGED'
        $notes += "log declares UTC$(& $fmtOff $obsOff) but the run's config asked for UTC$(& $fmtOff $expOff) ($($win.TzId)) -- expected if this VM pre-dates the timezone change (Set-TimeZone only runs for newly created VMs); the log is still self-describing so its own offset is authoritative"
    }

    if ($null -eq $useOff) {
        if ($verdict -eq 'OK') { $verdict = 'UNKNOWN-ZONE' }
        $notes += 'log declares no offset and no config sidecar resolved for this VM'
    }
    else {
        $contentUtc = $st.Local.AddMinutes(-$useOff)
        $lagMin = [math]::Round(($f.LastWriteTimeUtc - $contentUtc).TotalMinutes, 1)
        if ($lagMin -lt -2) {
            # Content newer than the moment we copied it: impossible for any real log.
            $verdict = 'FUTURE-CONTENT'
            $notes += "newest line converts to $($contentUtc.ToString('yyyy-MM-dd HH:mm:ss'))Z but the file was written at $($f.LastWriteTimeUtc.ToString('yyyy-MM-dd HH:mm:ss'))Z -- content is ${lagMin}min AHEAD of its own pull"
            $diff = $useOff - $hostOffMin
            if ($diff -ne 0 -and [math]::Abs([math]::Abs($lagMin) - [math]::Abs($diff)) -le 5) {
                $notes += "that gap equals the host/guest offset difference ($(& $fmtOff $diff)), i.e. the zone applied to this log is wrong"
            }
        }
        elseif ($lagMin -gt $LagWarnMinutes) {
            if ($verdict -eq 'OK') { $verdict = 'STALE' }
            $notes += "newest line is ${lagMin}min older than the pull (component may simply have stopped writing)"
        }
        $rows.Add([pscustomobject]@{
                File = $f.Name; VM = $vm; Domain = $domain
                DeclaredOff = $(if ($null -ne $obsOff) { & $fmtOff $obsOff } else { '' })
                ConfigOff = $(if ($null -ne $expOff) { & $fmtOff $expOff } else { '' })
                # ASSUMED means the log did not declare an offset, so the config's was used --
                # and the config is only reliable for VMs created by that same run.
                Basis = $(if ($null -ne $obsOff) { 'declared' } else { 'ASSUMED' })
                LagMin = $lagMin; Verdict = $verdict; Detail = ($notes -join '; ')
            })
        continue
    }
    $rows.Add([pscustomobject]@{ File = $f.Name; VM = $vm; Domain = $domain; DeclaredOff = ''; ConfigOff = ''; Basis = ''; LagMin = $null; Verdict = $verdict; Detail = ($notes -join '; ') })
}

"Log folder      : $LogPath"
"Host offset     : UTC$(& $fmtOff $hostOffMin)"
"Lab configs     : $($windowsByDomain.Count) domain(s), $((@($windowsByDomain.Values | ForEach-Object { $_.Count }) | Measure-Object -Sum).Sum) run window(s)"
foreach ($d in ($windowsByDomain.Keys | Sort-Object)) {
    $zones = @($windowsByDomain[$d] | ForEach-Object { $_.TzId } | Select-Object -Unique)
    if ($zones.Count -gt 1) { "                  $d changed timezone across runs: $($zones -join ' / ')" }
}
"Pulled logs     : $($rows.Count)"
''

if ($rows.Count -eq 0) {
    # Checking nothing is not the same as finding nothing wrong.
    'INCONCLUSIVE: no pulled guest logs matched <VM>-Phase<N>-<stamp>-<name>, so nothing was verified.'
    exit 3
}

$rows | Group-Object Verdict | Sort-Object Name | ForEach-Object { '  {0,-16} {1}' -f $_.Name, $_.Count }
$assumed = @($rows | Where-Object { $_.Basis -eq 'ASSUMED' })
if ($assumed.Count -gt 0) {
    "  ({0} log(s) declared no offset, so the run config's was assumed -- unreliable for a VM the run did not create)" -f $assumed.Count
}
''

$diverged = @($rows | Where-Object { $_.Verdict -eq 'ZONE-DIVERGED' })
$broken = @($rows | Where-Object { $_.Verdict -eq 'FUTURE-CONTENT' })
foreach ($set in @(@{ T = 'IMPOSSIBLE TIMESTAMPS'; R = $broken }, @{ T = 'CONFIG DIVERGENCE (log is self-describing, so still readable)'; R = $diverged })) {
    if ($set.R.Count -gt 0) {
        "$($set.T):"
        foreach ($r in $set.R) { "  [$($r.Verdict)] $($r.File)"; "      $($r.Detail)" }
        ''
    }
}

if ($Detail) {
    $rows | Sort-Object Verdict, File | Format-Table -AutoSize VM, DeclaredOff, ConfigOff, Basis, LagMin, Verdict, File
}

# An audit that inspected nothing is not a passing audit.
$judged = @($rows | Where-Object { $_.Verdict -notin 'NO-TIMESTAMP', 'UNKNOWN-ZONE' })
if ($judged.Count -eq 0) {
    'INCONCLUSIVE: no file had both a timestamp and a resolvable offset -- nothing was actually verified.'
    exit 3
}

if ($broken.Count -gt 0) { "FAILED: $($broken.Count) of $($judged.Count) judged log(s) have impossible timestamps."; exit 1 }
if ($FailOnDiverged -and $diverged.Count -gt 0) { "FAILED: $($diverged.Count) log(s) diverge from their run's configured timezone."; exit 1 }
"PASS: $($judged.Count) judged log(s) have timestamps consistent with their own declared offset and their pull time."
if ($diverged.Count -gt 0) { "      ($($diverged.Count) diverge from vmOptions.timeZone -- see above; that setting only applies to VMs the run created.)" }
exit 0
