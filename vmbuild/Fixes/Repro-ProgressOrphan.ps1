<#
.SYNOPSIS
    Standalone repro/A-B harness for the Phase 2 "orphan progress bar" bug.

.DESCRIPTION
    Reproduces the production mechanism in isolation (no lab build required):

      * Spawns N child Start-Jobs that each emit a HIGH VOLUME of Write-Progress
        records at ActivityId 0 in a tight loop (mimics the Install-Tools /
        Invoke-VmCommand / DHCP-cmdlet flood that follows "Testing IP Address").
      * The parent polls each job's Progress stream and RE-renders a single
        managed bar per job (Id = job.Id) WITH a VM-name prefix, exactly like
        Write-JobProgress in Common.Phases.ps1.
      * The parent holds $Global:ProgressPreference = 'SilentlyContinue' between
        renders, exactly like Wait-Phase.

    The render step mirrors Write-Progress2Impl's -force path. Two modes:

      $UseLocalPref = $false  -> OLD behavior: flip $Global:ProgressPreference to
                                 'Continue' around the render. EXPECT an orphan
                                 bar (no VM prefix) to flicker at the bottom as
                                 PS7 auto-renders the child jobs' RAW ActivityId-0
                                 records during the Continue window.

      $UseLocalPref = $true   -> FIX: set a FUNCTION-LOCAL $ProgressPreference =
                                 'Continue' for the render while $Global stays
                                 'SilentlyContinue'. EXPECT no orphan bar.

.EXAMPLE
    # Reproduce the orphan bug:
    .\Repro-ProgressOrphan.ps1 -UseLocalPref:$false

.EXAMPLE
    # Verify the fix:
    .\Repro-ProgressOrphan.ps1 -UseLocalPref:$true

.NOTES
    Diagnostic/dev harness. Keep in the workspace. Run under PowerShell 7.
#>
[CmdletBinding()]
param(
    [bool]$UseLocalPref = $true,
    [int]$JobCount = 4,
    [int]$Seconds = 20
)

if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Warning "This harness reproduces a PS7 auto-render behavior; run it under PowerShell 7."
}

# Mirror Write-Progress2Impl's -force render. When $UseLocalPref the function-local
# $ProgressPreference is honored by Write-Progress while $Global stays Silent.
function Invoke-ManagedRender {
    param(
        [int]$Id,
        [string]$Activity,
        [string]$Status,
        [int]$Percent,
        [bool]$UseLocalPref
    )
    if ($UseLocalPref) {
        $ProgressPreference = 'Continue'
        Microsoft.PowerShell.Utility\Write-Progress -Id $Id -Activity $Activity -Status $Status -PercentComplete $Percent
    }
    else {
        $orig = $Global:ProgressPreference
        $Global:ProgressPreference = 'Continue'
        Microsoft.PowerShell.Utility\Write-Progress -Id $Id -Activity $Activity -Status $Status -PercentComplete $Percent
        $Global:ProgressPreference = $orig
    }
}

# Child job: flood ActivityId-0 progress records, like the post-IP Phase 2 work.
$childScript = {
    param($VmName, $Iterations)
    foreach ($i in 1..$Iterations) {
        Write-Progress -Id 0 -Activity "Injecting tools" -Status "Injecting Tool $i to $VmName (Stop1 False)" -PercentComplete (($i % 100))
        Start-Sleep -Milliseconds 25
    }
}

Write-Host ("Starting {0} jobs. UseLocalPref={1}. Watch the BOTTOM of the screen for an un-prefixed orphan bar." -f $JobCount, $UseLocalPref) -ForegroundColor Cyan

$Global:ProgressPreference = 'SilentlyContinue'

$jobs = @()
foreach ($n in 1..$JobCount) {
    $vmName = "ZZ-VM{0:D2}" -f $n
    $jobs += Start-Job -Name $vmName -ScriptBlock $childScript -ArgumentList $vmName, ([int]($Seconds * 40))
}

$deadline = (Get-Date).AddSeconds($Seconds)
try {
    while ((Get-Date) -lt $deadline -and ($jobs | Where-Object { $_.State -eq 'Running' })) {
        foreach ($job in $jobs) {
            $src = if ($job.ChildJobs.Count -gt 0) { $job.ChildJobs[0] } else { $job }
            $count = $src.Progress.Count
            if ($count -gt 0) {
                $last = $src.Progress[$count - 1]
                # Managed bar: prefix with VM name, render under the job's own Id.
                Invoke-ManagedRender -Id $job.Id -Activity ("{0}: {1}" -f $job.Name, $last.Activity) -Status $last.StatusDescription -Percent ([int]$last.PercentComplete) -UseLocalPref $UseLocalPref
            }
        }
        # Hold Global silent between renders, exactly like Wait-Phase.
        $Global:ProgressPreference = 'SilentlyContinue'
        Start-Sleep -Milliseconds 200
    }
}
finally {
    foreach ($job in $jobs) {
        Write-Progress -Id $job.Id -Activity $job.Name -Completed
    }
    $jobs | Stop-Job -ErrorAction SilentlyContinue
    $jobs | Remove-Job -Force -ErrorAction SilentlyContinue
    $Global:ProgressPreference = 'Continue'
    Write-Host "Done." -ForegroundColor Green
}
