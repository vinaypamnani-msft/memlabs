# Shared parser for collected guest ConfigMgr logs. Two shapes appear:
#   legacy  "msg  $$<comp><MM-dd-yyyy HH:mm:ss.fff+240><thread=..>"   (guest LOCAL time)
#   CMTrace "<![LOG[msg]LOG]!><time=".." date="..">"
function Read-CmLog {
    param([string]$Path, [string]$Pattern)
    $rxLegacy = [regex]'^(?<msg>.*?)\s*\$\$<(?<comp>[^>]*)><(?<dt>[^>]+?)(?:[+-]\d+)?><'
    $rxXml = [regex]'^<!\[LOG\[(?<msg>.*?)\]LOG\]!><time="(?<tm>[^"+\-]+)[^"]*"\s+date="(?<dt>[^"]+)"\s+component="(?<comp>[^"]*)"'
    foreach ($line in (Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)) {
        $m = $rxLegacy.Match($line)
        if ($m.Success) {
            $msg = $m.Groups['msg'].Value
            if ($Pattern -and $msg -notmatch $Pattern) { continue }
            [pscustomobject]@{ When = $m.Groups['dt'].Value; Comp = $m.Groups['comp'].Value; Msg = ($msg -replace '\s+', ' ').Trim() }
            continue
        }
        $m = $rxXml.Match($line)
        if ($m.Success) {
            $msg = $m.Groups['msg'].Value
            if ($Pattern -and $msg -notmatch $Pattern) { continue }
            [pscustomobject]@{ When = "$($m.Groups['dt'].Value) $($m.Groups['tm'].Value)"; Comp = $m.Groups['comp'].Value; Msg = ($msg -replace '\s+', ' ').Trim() }
        }
    }
}
