# Can we tear down a job that is Blocked on a host prompt, or does Stop-Job hang too?
function New-BlockedJob {
    Start-Job -ScriptBlock {
        function Need-Name { param([Parameter(Mandatory = $true)][string]$Name) $Name }
        Need-Name    # no -Name => prompts => Blocked
    }
}

$j = New-BlockedJob
$deadline = (Get-Date).AddSeconds(20)
while ((Get-Date) -lt $deadline -and $j.State -ne 'Blocked') { Start-Sleep -Milliseconds 250; $j = Get-Job -Id $j.Id }
"state before teardown : $($j.State)"

$sw = [System.Diagnostics.Stopwatch]::StartNew()
try { Stop-Job $j -ErrorAction SilentlyContinue } catch { "Stop-Job threw: $_" }
$stopMs = $sw.ElapsedMilliseconds
"Stop-Job took        : ${stopMs}ms   state now=$((Get-Job -Id $j.Id -ErrorAction SilentlyContinue).State)"

$sw.Restart()
try { Remove-Job $j -Force -ErrorAction SilentlyContinue } catch { "Remove-Job threw: $_" }
"Remove-Job took      : $($sw.ElapsedMilliseconds)ms"
"job still present    : $([bool](Get-Job -Id $j.Id -ErrorAction SilentlyContinue))"
""
if ($stopMs -lt 5000) { "VERDICT: teardown is safe to do inline (< 5s)" }
else { "VERDICT: teardown BLOCKS -- must remove from the tracking list first" }

Get-Job | Where-Object { $_.State -eq 'Blocked' } | Remove-Job -Force -ErrorAction SilentlyContinue
