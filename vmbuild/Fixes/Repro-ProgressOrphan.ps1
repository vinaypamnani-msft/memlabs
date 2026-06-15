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
    [int]$Seconds = 20,
    # When set, the child jobs (and the parent render loop) call a real DHCP
    # CIM cmdlet on every iteration. CIM cmdlets resolve ProgressPreference
    # from the GLOBAL scope of their runspace and emit genuine progress
    # records -- the ingredient the synthetic Write-Progress flood lacks. A
    # fresh Start-Job runspace defaults $Global:ProgressPreference to
    # 'Continue', so these records land in the child's Progress stream and
    # PS7 can auto-render them during the parent's -force flip window.
    [bool]$WithDhcp = $true,
    # DHCP scope to read. Auto-detected from the host's first scope when blank.
    [string]$ScopeId = ""
)

if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Warning "This harness reproduces a PS7 auto-render behavior; run it under PowerShell 7."
}

# Resolve a DHCP scope to exercise the CIM-progress path. If DHCP isn't
# available, fall back to the synthetic-only flood with a warning.
if ($WithDhcp) {
    if (-not (Get-Command Get-DhcpServerv4Scope -ErrorAction SilentlyContinue)) {
        Write-Warning "DhcpServer module/cmdlets not available; running synthetic-only (no DHCP CIM records)."
        $WithDhcp = $false
    }
    elseif (-not $ScopeId) {
        $ScopeId = (Get-DhcpServerv4Scope -ErrorAction SilentlyContinue | Select-Object -First 1).ScopeId.IPAddressToString
        if (-not $ScopeId) {
            Write-Warning "No DHCP scope found on this host; running synthetic-only (no DHCP CIM records)."
            $WithDhcp = $false
        }
        else {
            Write-Host ("Using DHCP scope {0} for CIM progress flood." -f $ScopeId) -ForegroundColor DarkGray
        }
    }
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
# When $WithDhcp, also call a real DHCP CIM cmdlet each iteration. The child
# does NOT set $Global:ProgressPreference (mirrors the unwrapped Phase 2 call
# sites), so the fresh runspace default 'Continue' lets the CIM progress
# records enter the child's Progress stream -- exactly what PS7 auto-renders.
$childScript = {
    param($VmName, $Iterations, $WithDhcp, $ScopeId)
    foreach ($i in 1..$Iterations) {
        if ($WithDhcp -and $ScopeId) {
            Get-DhcpServerv4Reservation -ScopeId $ScopeId -ErrorAction SilentlyContinue | Out-Null
        }
        Write-Progress -Id 0 -Activity "Injecting tools" -Status "Injecting Tool $i to $VmName (Stop1 False)" -PercentComplete (($i % 100))
        Start-Sleep -Milliseconds 25
    }
}

Write-Host ("Starting {0} jobs. UseLocalPref={1} WithDhcp={2}. Watch the BOTTOM of the screen for an un-prefixed orphan bar." -f $JobCount, $UseLocalPref, $WithDhcp) -ForegroundColor Cyan

$Global:ProgressPreference = 'SilentlyContinue'

$jobs = @()
foreach ($n in 1..$JobCount) {
    $vmName = "ZZ-VM{0:D2}" -f $n
    $jobs += Start-Job -Name $vmName -ScriptBlock $childScript -ArgumentList $vmName, ([int]($Seconds * 40)), $WithDhcp, $ScopeId
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
        # Parent-side DHCP CIM call, mirroring Set-DeployConfigIPAddresses /
        # Remove-DHCPReservation that overlap Wait-Phase. CIM cmdlets resolve
        # ProgressPreference from the parent's GLOBAL scope; with the old
        # global-flip a render window can overlap this and surface an orphan.
        if ($WithDhcp -and $ScopeId) {
            Get-DhcpServerv4Reservation -ScopeId $ScopeId -ErrorAction SilentlyContinue | Out-Null
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
