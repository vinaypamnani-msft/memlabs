param([int]$Hours = 14)

$logs = Get-ChildItem 'C:\memlabs\vmbuild\logs' -Filter 'VMBuild*.jsonl' |
    Where-Object { $_.LastWriteTime -gt (Get-Date).AddHours(-$Hours) }

$auto = New-Object System.Collections.Generic.List[string]
foreach ($f in $logs) {
    foreach ($l in (Get-Content $f.FullName)) {
        if ($l -notmatch 'pipeline-create autopsy|pipeline-race diag') { continue }
        $o = $null; try { $o = $l | ConvertFrom-Json } catch { continue }
        $auto.Add((($o.msg -replace '\s+', ' ').Trim()))
    }
}

"autopsy lines: $($auto.Count)"
""
"=== one full example ==="
if ($auto.Count) { $auto[0] -split ' -- ' | ForEach-Object { "   $_" } }

""
"=== field value distribution across all autopsies ==="
$fields = @{}
foreach ($a in $auto) {
    foreach ($m in [regex]::Matches($a, '([A-Za-z0-9_]+)=(\[[^\]]*\]|[^\s]+)')) {
        $k = $m.Groups[1].Value
        $v = $m.Groups[2].Value
        if ($k -match '^(sess|err\d+)$') { continue }
        if (-not $fields.ContainsKey($k)) { $fields[$k] = @{} }
        $vv = $v -replace '\d+', '#'
        if ($vv.Length -gt 72) { $vv = $vv.Substring(0, 72) }
        $fields[$k][$vv] = [int]$fields[$k][$vv] + 1
    }
}
foreach ($k in ($fields.Keys | Sort-Object)) {
    $vals = $fields[$k]
    $top = @($vals.Keys) | Sort-Object { - $vals[$_] } | Select-Object -First 3
    "{0,-26} {1}" -f $k, (($top | ForEach-Object { "$_ x$($vals[$_])" }) -join '  |  ')
}
