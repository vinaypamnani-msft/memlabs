param([int]$Hours = 30)

$logs = Get-ChildItem 'C:\memlabs\vmbuild\logs' -Filter 'VMBuild*.jsonl' |
    Where-Object { $_.LastWriteTime -gt (Get-Date).AddHours(-$Hours) } | Sort-Object LastWriteTime

$ev = New-Object System.Collections.Generic.List[object]
foreach ($f in $logs) {
    foreach ($l in (Get-Content $f.FullName)) {
        if ($l -notmatch 'Copy-ItemSafe|Copying tools bundle|tools bundle') { continue }
        $o = $null; try { $o = $l | ConvertFrom-Json } catch { continue }
        $m = ($o.msg -replace '\s+', ' ').Trim()
        $vm = if ($m -match '\[Copy-ItemSafe\] \[([^\]]+)\]') { $matches[1] }
        elseif ($m -match '^([A-Za-z0-9\-]+): (Copying|Reusing)') { $matches[1] } else { $null }
        $ev.Add([pscustomobject]@{ Log = $f.Name; T = [datetime]$o.t; VM = $vm; Lvl = $o.lvl; Msg = $m })
    }
}
"copy events: $($ev.Count) across $($logs.Count) logs"
""

"=== stall warnings (who, how far, how big) ==="
$ev | Where-Object { $_.Msg -match 'Copy stalled for' } | ForEach-Object {
    $pct = if ($_.Msg -match 'last: (\d+) items, (\d+)%') { $matches[2] } else { '?' }
    "{0}  {1,-16} stalled at {2}%   [{3}]" -f $_.T.ToString('MM-dd HH:mm:ss'), $_.VM, $pct, ($_.Log -replace 'VMBuild\.|\.jsonl', '')
}
""
"=== guest heartbeat 'no growth' samples ==="
$ev | Where-Object { $_.Msg -match 'no growth' } | Select-Object -Last 12 | ForEach-Object {
    "{0}  {1,-16} {2}" -f $_.T.ToString('MM-dd HH:mm:ss'), $_.VM, (($_.Msg -replace '.*Guest heartbeat: ', '') -replace '^(.{78}).*', '$1')
}
""
"=== did any stalled copy RECOVER? (events after a stall, same VM) ==="
$stalls = @($ev | Where-Object { $_.Msg -match 'Copy stalled for' })
foreach ($s in $stalls) {
    $after = @($ev | Where-Object { $_.VM -eq $s.VM -and $_.T -gt $s.T -and $_.Msg -notmatch 'stall-diag|Copy stalled' })
    $verdict = if ($after.Count -eq 0) { 'NOTHING FURTHER -- hung here' } else { ($after[0].Msg -replace '^(.{80}).*', '$1') }
    "{0} {1,-16} -> {2}" -f $s.T.ToString('HH:mm:ss'), $s.VM, $verdict
}
""
"=== stall thresholds actually in use ==="
$ev | Where-Object { $_.Msg -match 'stallTimeout=' } | Select-Object -Last 5 | ForEach-Object {
    "{0}  {1,-16} {2}" -f $_.T.ToString('MM-dd HH:mm:ss'), $_.VM, (($_.Msg -replace '.*\] ', '') -replace '^(.{70}).*', '$1')
}
""
"=== bundle sizes seen ==="
$ev | Where-Object { $_.Msg -match 'Copying tools bundle \(' } | ForEach-Object { if ($_.Msg -match 'bundle \(([\d.]+) MB, (\d+) items') { "$($matches[1]) MB / $($matches[2]) items" } } |
    Group-Object | ForEach-Object { "{0,4}x  {1}" -f $_.Count, $_.Name }
