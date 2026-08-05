param([int]$Hours = 26)

$logs = Get-ChildItem 'C:\memlabs\vmbuild\logs' -Filter 'VMBuild*.jsonl' |
    Where-Object { $_.LastWriteTime -gt (Get-Date).AddHours(-$Hours) } |
    Sort-Object LastWriteTime

"{0,-12} {1,-10} {2,7} {3,7} {4,8}  {5}" -f 'log', 'commit', 'pipeErr', 'autopsy', 'phases', 'leak ledger / notes'
"-" * 118

foreach ($f in $logs) {
    $sha = ''; $pipe = 0; $autopsy = 0; $phases = 0; $ledger = ''; $owners = ''; $byCaller = ''; $stale = 0
    foreach ($l in (Get-Content $f.FullName)) {
        if ($l -match '"msg":"\s*Git:[^"]*@\s*([0-9a-f]{6,})') { if (-not $sha) { $sha = $matches[1] } }
        if ($l -match 'creating the pipeline') { $pipe++ }
        if ($l -match 'pipeline-create autopsy') { $autopsy++ }
        if ($l -match 'no longer exists on disk|stale launcher|running code that') { $stale++ }
        if ($l -match 'session ledger:') {
            $o = $null; try { $o = $l | ConvertFrom-Json } catch { }
            if ($o) { $ledger = ($o.msg -replace '.*session ledger:\s*', '' -replace '\s+', ' ').Trim() }
        }
        if ($l -match 'runspace owners:') {
            $o = $null; try { $o = $l | ConvertFrom-Json } catch { }
            if ($o) { $owners = ($o.msg -replace '.*runspace owners:\s*', '' -replace '\s+', ' ').Trim() }
        }
        if ($l -match 'undisposed by caller:') {
            $o = $null; try { $o = $l | ConvertFrom-Json } catch { }
            if ($o) { $byCaller = ($o.msg -replace '.*undisposed by caller:\s*', '' -replace '\s+', ' ').Trim() }
        }
        if ($l -match '"msg":"\[Phase \d+\] Starting') { $phases++ }
    }
    $name = $f.Name -replace '^VMBuild\.', '' -replace '\.jsonl$', '' -replace '\.com', ''
    if ($name.Length -gt 12) { $name = $name.Substring($name.Length - 12) }
    $note = if ($ledger) { $ledger } else { '' }
    "{0,-12} {1,-10} {2,7} {3,7} {4,8}  {5}" -f $name, $sha, $pipe, $autopsy, $phases, $note
    if ($owners) { "{0,-12} {1,-10} {2}" -f '', '', "   owners: $owners" }
    if ($byCaller) { "{0,-12} {1,-10} {2}" -f '', '', "   undisposed: $byCaller" }
    if ($stale) { "{0,-12} {1,-10} {2}" -f '', '', "   STALE-LAUNCHER lines: $stale" }
}
