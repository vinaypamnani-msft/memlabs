"PS version : $($PSVersionTable.PSVersion)"
"CLR        : $([System.Environment]::Version)"
""
$l = New-Object System.Collections.Generic.List[object]
$l.Add([pscustomobject]@{ A = 1 })
$l.Add([pscustomobject]@{ A = 2 })
"List[object] count = $($l.Count)"

foreach ($case in @(
        @{ n = '@($l)'; f = { @($l) } }
        @{ n = '$l.ToArray()'; f = { $l.ToArray() } }
        @{ n = '[object[]]$l'; f = { [object[]]$l } }
        @{ n = '$l | ForEach-Object {$_}'; f = { $l | ForEach-Object { $_ } } }
        @{ n = '@() + $l'; f = { @() + $l } }
    )) {
    try { $r = & $case.f; "{0,-26} OK   count={1}" -f $case.n, @($r).Count }
    catch { "{0,-26} FAIL {1}" -f $case.n, $_.Exception.Message }
}

""
"--- same but List[string] ---"
$s = New-Object System.Collections.Generic.List[string]
$s.Add('x')
try { $r = @($s); "@(List[string])            OK   count=$($r.Count)" } catch { "@(List[string])            FAIL $($_.Exception.Message)" }

""
"--- hashtable value that IS a List[object] ---"
$h = @{}
$h['k'] = $l
try { $r = @($h['k']); "@(hash[List[object]])      OK   count=$($r.Count)" } catch { "@(hash[List[object]])      FAIL $($_.Exception.Message)" }
try { $r = $h['k'].ToArray(); "hash[..].ToArray()         OK   count=$($r.Count)" } catch { "hash[..].ToArray()         FAIL $($_.Exception.Message)" }
