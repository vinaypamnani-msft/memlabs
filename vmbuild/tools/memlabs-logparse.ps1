<#
    Shared MemLabs .jsonl parsing for the temp/ analysis scripts.
    Dot-source:  . 'C:\memlabs\temp\memlabs-logparse.ps1'
#>

$script:MlInvariant = [System.Globalization.CultureInfo]::InvariantCulture
$script:MlUtcStyles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
$script:MlRxHead = [regex]::new('^\{"t":"(?<t>[^"]+)","lvl":"(?<lvl>[A-Z]+)","comp":"(?<comp>(?:[^"\\]|\\.)*)"', 'Compiled')

function Convert-MlJsonEscape {
    param([string]$Value)
    if ($Value.IndexOf('\') -lt 0) { return $Value }
    $sb = [System.Text.StringBuilder]::new($Value.Length)
    for ($i = 0; $i -lt $Value.Length; $i++) {
        $c = $Value[$i]
        if ($c -ne '\') { [void]$sb.Append($c); continue }
        $i++
        if ($i -ge $Value.Length) { break }
        switch ($Value[$i]) {
            'n' { [void]$sb.Append("`n") }
            'r' { [void]$sb.Append("`r") }
            't' { [void]$sb.Append("`t") }
            '"' { [void]$sb.Append('"') }
            '\' { [void]$sb.Append('\') }
            'u' {
                if ($i + 4 -lt $Value.Length) {
                    [void]$sb.Append([char][Convert]::ToInt32($Value.Substring($i + 1, 4), 16))
                    $i += 4
                }
            }
            default { [void]$sb.Append($Value[$i]) }
        }
    }
    return $sb.ToString()
}

function Read-MemlabsJsonl {
    <# Reads a VMBuild .jsonl. FileShare ReadWrite so a live run can be read mid-write. #>
    param([Parameter(Mandatory)][string]$Path)
    $rows = [System.Collections.Generic.List[object]]::new()
    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $sr = New-Object System.IO.StreamReader($fs)
        try {
            while ($null -ne ($line = $sr.ReadLine())) {
                if ($line.Length -lt 20 -or $line[$line.Length - 1] -ne '}') { continue }
                $h = $script:MlRxHead.Match($line)
                if (-not $h.Success) { continue }
                $i = $line.IndexOf(',"msg":"')
                if ($i -lt 0) { continue }
                $stamp = $null
                try {
                    # 'Z' in the format is the UTC designator; AdjustToUniversal keeps the value in UTC.
                    $stamp = [datetime]::ParseExact($h.Groups['t'].Value, 'yyyy-MM-ddTHH:mm:ss.fffZ',
                        $script:MlInvariant, $script:MlUtcStyles).ToLocalTime()
                }
                catch { continue }
                $rows.Add([pscustomobject]@{
                        T    = $stamp
                        Lvl  = $h.Groups['lvl'].Value
                        Comp = Convert-MlJsonEscape $h.Groups['comp'].Value
                        Msg  = Convert-MlJsonEscape $line.Substring($i + 8, $line.Length - ($i + 8) - 2)
                    })
            }
        }
        finally { $sr.Dispose() }
    }
    finally { $fs.Dispose() }
    return $rows
}

function Split-MemlabsRuns {
    <#
        One .jsonl can hold several New-Lab invocations: rotation is by size, and the
        'run' id is per-PROCESS (a second New-Lab in the same shell reuses it).
        'Deployment log started:' is the only authoritative run boundary. Late job-process
        flushes are clamped off at '### SCRIPT FINISHED' so an idle tail is not billed
        to the last phase.
    #>
    param([Parameter(Mandatory)][object[]]$Rows)

    $banners = @()
    for ($i = 0; $i -lt $Rows.Count; $i++) {
        if ($Rows[$i].Msg.StartsWith('Deployment log started:')) { $banners += $i }
    }
    if (-not $banners.Count) { return @() }

    $out = [System.Collections.Generic.List[object[]]]::new()
    for ($b = 0; $b -lt $banners.Count; $b++) {
        $from = $banners[$b]
        $to = if ($b + 1 -lt $banners.Count) { $banners[$b + 1] - 1 } else { $Rows.Count - 1 }
        $seg = @($Rows[$from..$to])
        $finIdx = -1
        for ($i = 0; $i -lt $seg.Count; $i++) {
            if ($seg[$i].Msg.StartsWith('### SCRIPT FINISHED')) { $finIdx = $i; break }
        }
        if ($finIdx -ge 0) {
            $cut = $seg[$finIdx].T.AddSeconds(30)
            $seg = @($seg | Where-Object { $_.T -le $cut })
        }
        $out.Add(@($seg | Sort-Object T))
    }
    # Comma keeps the jagged array intact -- a bare return unrolls it into loose rows.
    return , $out.ToArray()
}
