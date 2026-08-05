# A missing mandatory parameter PROMPTS. Inside a job there is no interactive host,
# so the prompt never returns and the job sits in state=Blocked forever.
$sb = {
    function Get-VM2Mandatory {
        param([Parameter(Mandatory = $true)][string]$Name)
        return "got:$Name"
    }
    # No -Name. This is the shape that hung the builds.
    $r = Get-VM2Mandatory -ErrorAction SilentlyContinue
    return "returned:$r"
}

$j = Start-Job -ScriptBlock $sb
Start-Sleep -Seconds 5
"job state after 5s : $($j.State)      <- Blocked means it is prompting"
$j | Stop-Job -ErrorAction SilentlyContinue
$j | Remove-Job -Force -ErrorAction SilentlyContinue

# Non-mandatory + explicit guard returns immediately instead.
$sb2 = {
    function Get-VM2Guarded {
        param([Parameter(Mandatory = $false)][string]$Name)
        if (-not $Name) { return 'GUARD: -Name required' }
        return "got:$Name"
    }
    return (Get-VM2Guarded)
}
$j2 = Start-Job -ScriptBlock $sb2
$null = Wait-Job $j2 -Timeout 15
"guarded job state  : $($j2.State)"
"guarded job output : $(Receive-Job $j2)"
$j2 | Remove-Job -Force -ErrorAction SilentlyContinue
