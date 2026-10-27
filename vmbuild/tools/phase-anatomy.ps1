# Anatomy of one phase: the serial preamble, then the chain for the VM that finishes last.
param(
    [Parameter(Mandatory)][string]$LogPath,
    [int]$Phase = 4,
    [string]$VM
)
$ErrorActionPreference = 'Stop'
$rows = [System.Collections.Generic.List[object]]::new()
foreach ($l in [System.IO.File]::ReadLines($LogPath)) {
    if (-not $l) { continue }
    try { $o = $l | ConvertFrom-Json } catch { continue }
    if (-not $o.t) { continue }
    $rows.Add([pscustomobject]@{ T = [datetime]$o.t; M = ("$($o.msg)" -replace '\s+', ' ').Trim() })
}
$ban = @($rows | Where-Object { $_.M -match '^Phase (\d+) - ' })
$start = $null; $end = $null
for ($i = 0; $i -lt $ban.Count; $i++) {
    if ([int]([regex]::Match($ban[$i].M, '^Phase (\d+) - ').Groups[1].Value) -ne $Phase) { continue }
    $start = $ban[$i].T
    $end = if ($i + 1 -lt $ban.Count) { $ban[$i + 1].T } else { $rows[-1].T }
    break
}
if (-not $start) { "Phase $Phase not found"; return }
$slice = @($rows | Where-Object { $_.T -ge $start -and $_.T -le $end })
"log: $(Split-Path $LogPath -Leaf)   Phase $Phase = $([Math]::Round(($end-$start).TotalSeconds,1))s   entries=$($slice.Count)"

$firstJob = $slice | Where-Object { $_.M -match "\[Phase $Phase\] Created job" } | Select-Object -First 1
''
if ($firstJob) {
    'preamble before the first VM job: {0:N1}s' -f ($firstJob.T - $start).TotalSeconds
    $slice | Where-Object { $_.T -le $firstJob.T -and $_.M -notmatch '^Checking |^\[JobLedger\]' } |
        ForEach-Object { '   +{0,5:N1}s  {1}' -f ($_.T - $start).TotalSeconds, $_.M.Substring(0, [Math]::Min(94, $_.M.Length)) }
}

''
'--- per-step totals ---'
$st = foreach ($r in $slice) {
    $m = [regex]::Match($r.M, "\[StepTiming\] (?<vm>\S+) \[Phase $Phase\] (?<step>\w+) completed in (?<s>[\d.]+)")
    if ($m.Success) { [pscustomobject]@{ VM = $m.Groups['vm'].Value; Step = $m.Groups['step'].Value; Sec = [double]$m.Groups['s'].Value } }
}
$st = @($st)
if ($st.Count) {
    $st | Group-Object Step | ForEach-Object {
        [pscustomobject]@{ Step = $_.Name; N = $_.Count; Mean = [Math]::Round(($_.Group | Measure-Object Sec -Average).Average, 1); Max = [Math]::Round(($_.Group | Measure-Object Sec -Maximum).Maximum, 1) }
    } | Sort-Object Mean -Descending | Format-Table -AutoSize | Out-String -Width 70
}
else { '  (no StepTiming rows)' }

if (-not $VM) {
    $last = @{}
    foreach ($r in $slice) {
        $m = [regex]::Match($r.M, '(?<v>CT3-[\w\-]+|CS\d-[\w\-]+)')
        if ($m.Success -and $r.M -notmatch '^\[JobLedger\]') { $last[$m.Groups['v'].Value] = $r.T }
    }
    if ($last.Count) { $VM = ($last.GetEnumerator() | Sort-Object Value | Select-Object -Last 1).Key }
}
''
"--- critical-path VM: $VM ---"
$mine = @($slice | Where-Object { $_.M -match [regex]::Escape($VM) -and $_.M -notmatch '^\[JobLedger\]|^\[Injecting tool\]|\[DscTiming\] \S+ - ' })
'{0,-9} {1,7}  {2}' -f 'time', 'delta', 'message'
'-' * 116
$prev = $null
foreach ($r in $mine) {
    $d = if ($prev) { ($r.T - $prev).TotalSeconds } else { 0 }
    $mark = if ($d -ge 4) { ' <<' } else { '' }
    '{0,-9} {1,7:N1}  {2}{3}' -f $r.T.ToString('HH:mm:ss'), $d, $r.M.Substring(0, [Math]::Min(86, $r.M.Length)), $mark
    $prev = $r.T
}
''
'{0} span: {1:N1}s   phase: {2:N1}s   tail after this VM: {3:N1}s' -f $VM, ($mine[-1].T - $mine[0].T).TotalSeconds, ($end - $start).TotalSeconds, ($end - $mine[-1].T).TotalSeconds
