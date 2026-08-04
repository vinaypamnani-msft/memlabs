param([int]$Hours = 14, [int]$Top = 500)

$logs = Get-ChildItem 'C:\memlabs\vmbuild\logs' -Filter 'VMBuild*.jsonl' |
    Where-Object { $_.LastWriteTime -gt (Get-Date).AddHours(-$Hours) }

"logs in window: $($logs.Count)"
$logs | Sort-Object LastWriteTime | Select-Object -Last 6 |
    ForEach-Object { "   {0}  {1}" -f $_.LastWriteTime.ToString('MM-dd HH:mm'), $_.Name }

$rows = New-Object System.Collections.Generic.List[object]
foreach ($f in $logs) {
    foreach ($l in (Get-Content $f.FullName)) {
        if ($l -notmatch '"lvl":"(ERROR|WARN)"') { continue }
        $o = $null; try { $o = $l | ConvertFrom-Json } catch { continue }
        if ($o.lvl -ne 'ERROR' -and $o.lvl -ne 'WARN') { continue }
        $k = ($o.msg -replace '[0-9a-fA-F]{8}-[0-9a-fA-F-]{27}', '<guid>' -replace '\d+', '#' -replace '\s+', ' ').Trim()
        if ($k.Length -gt 110) { $k = $k.Substring(0, 110) }
        $rows.Add([pscustomobject]@{ Lvl = $o.lvl; Key = $k })
    }
}

foreach ($lvl in @('ERROR', 'WARN')) {
    ""
    "=== $lvl ==="
    $g = $rows.ToArray() | Where-Object { $_.Lvl -eq $lvl } | Group-Object Key | Sort-Object Count -Descending
    "distinct classes: $($g.Count)"
    $g | Select-Object -First $Top | ForEach-Object { "{0,6}  {1}" -f $_.Count, $_.Name }
}
