param([int]$Hours = 14)

$logs = Get-ChildItem 'C:\memlabs\vmbuild\logs' -Filter 'VMBuild*.jsonl' |
    Where-Object { $_.LastWriteTime -gt (Get-Date).AddHours(-$Hours) }

$rows = New-Object System.Collections.Generic.List[object]
foreach ($f in $logs) {
    foreach ($l in (Get-Content $f.FullName)) {
        if ($l -notmatch 'pipeline-create autopsy') { continue }
        $o = $null; try { $o = $l | ConvertFrom-Json } catch { continue }
        $m = $o.msg
        $age = if ($m -match 'sessionAge=(\d+)ms') { [int]$matches[1] } else { -1 }
        $since = if ($m -match 'sincePrevPipeline=(\d+)ms') { [int]$matches[1] } else { -1 }
        $prev = if ($m -match "prevKind=([^\s]+)") { $matches[1] } else { '?' }
        $op = if ($m -match "'([^']+)' pipeline-create autopsy") { $matches[1] } else { '?' }
        $rows.Add([pscustomobject]@{ Age = $age; Since = $since; Prev = $prev; Op = $op })
    }
}

"samples: $($rows.Count)"
""
function Show-Bucket($name, $vals) {
    $b = [ordered]@{ '0-1s' = 0; '1-5s' = 0; '5-15s' = 0; '15-60s' = 0; '1-5m' = 0; '>5m' = 0; 'n/a' = 0 }
    foreach ($v in $vals) {
        if ($v -lt 0) { $b['n/a']++ }
        elseif ($v -lt 1000) { $b['0-1s']++ }
        elseif ($v -lt 5000) { $b['1-5s']++ }
        elseif ($v -lt 15000) { $b['5-15s']++ }
        elseif ($v -lt 60000) { $b['15-60s']++ }
        elseif ($v -lt 300000) { $b['1-5m']++ }
        else { $b['>5m']++ }
    }
    "=== $name ==="
    foreach ($k in $b.Keys) { "{0,-8} {1,5}  {2}" -f $k, $b[$k], ('#' * [Math]::Min(60, [int]($b[$k] / [Math]::Max(1, $rows.Count) * 120))) }
    ""
}

Show-Bucket 'sessionAge at failure (module-autoload theory -> clusters LOW)' ($rows.Age)
Show-Bucket 'sincePrevPipeline at failure (teardown-race theory -> clusters LOW)' ($rows.Since)

"=== failing operation ==="
$rows | Group-Object Op | Sort-Object Count -Desc | Select-Object -First 8 | ForEach-Object { "{0,5}  {1}" -f $_.Count, $_.Name }
""
"=== preceding pipeline kind ==="
$rows | Group-Object Prev | Sort-Object Count -Desc | Select-Object -First 8 | ForEach-Object { "{0,5}  {1}" -f $_.Count, $_.Name }
