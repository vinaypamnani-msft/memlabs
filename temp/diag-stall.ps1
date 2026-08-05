param([string]$Log = 'C:\memlabs\vmbuild\logs\VMBuild.pstest4.com.jsonl')

$o = @(Get-Content $Log | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } })
"events: $($o.Count)"
$last = $o[-1]
"last event: $(([datetime]$last.t).ToString('HH:mm:ss')) UTC"
""

# Which phase were we in, and which VM jobs started vs finished.
$started = @{}
$done = @{}
foreach ($e in $o) {
    $m = $e.msg
    if ($m -match '^\[Phase (\d+)\]: ([A-Za-z0-9\-]+) \[([^\]]+)\] : Completed in') { $done["$($matches[2])"] = $matches[1] }
    if ($m -match '^\[Phase (\d+)\]: ([A-Za-z0-9\-]+) \[([^\]]+)\] : Starting') { $started["$($matches[2])"] = $matches[1] }
    if ($m -match '^\[Phase (\d+)\] Starting Phase') { $curPhase = $matches[1] }
}
"phase markers: started=$($started.Count) completed=$($done.Count)"
""

"=== last 12 distinct non-DscTiming messages ==="
$o | Where-Object { $_.msg -notmatch '^\[DscTiming\]' } | Select-Object -Last 12 |
    ForEach-Object { "{0} {1,-5} {2}" -f ([datetime]$_.t).ToString('HH:mm:ss'), $_.lvl, (($_.msg -replace '\s+', ' ').Trim() -replace '^(.{115}).*', '$1') }
""

"=== VMs with a Phase job that never reported Completed ==="
$compl = @{}
foreach ($e in $o) { if ($e.msg -match '([A-Za-z0-9\-]+) \[[^\]]+\] : Completed in') { $compl[$matches[1]] = $true } }
$seen = @{}
foreach ($e in $o) { if ($e.msg -match '^\[Phase \d+\]: ([A-Za-z0-9\-]+):') { $seen[$matches[1]] = $true } }
foreach ($vm in ($seen.Keys | Sort-Object)) { if (-not $compl[$vm]) { "   NEVER COMPLETED: $vm" } }
""

"=== retry outcomes (my 0138aa37 change) ==="
$rec = @($o | Where-Object { $_.msg -match 'recovered on same-session retry' }).Count
$fail = @($o | Where-Object { $_.msg -match 'same-session retry ALSO failed' }).Count
"   recovered=$rec   alsoFailed=$fail"
""
"=== last message per VM (top 12 by latest) ==="
$o | Where-Object { $_.msg -match '^\[Phase \d+\]: ([A-Za-z0-9\-]+)' } |
    Group-Object { if ($_.msg -match '^\[Phase \d+\]: ([A-Za-z0-9\-]+)') { $matches[1] } } |
    ForEach-Object { $l = $_.Group[-1]; [pscustomobject]@{ VM = $_.Name; T = ([datetime]$l.t); Msg = (($l.msg -replace '\s+', ' ').Trim() -replace '^(.{88}).*', '$1') } } |
    Sort-Object T -Descending | Select-Object -First 12 |
    ForEach-Object { "{0}  {1,-16} {2}" -f $_.T.ToString('HH:mm:ss'), $_.VM, $_.Msg }
