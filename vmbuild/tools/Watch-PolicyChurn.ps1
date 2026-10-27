<#
.SYNOPSIS
    Watch MEMLABS clients for the ConfigMgr policy-churn signature: the projected
    policy set dropping, the Policy Platform detecting orphaned ("tattooed")
    settings, and remediation scripts running as a result.

.DESCRIPTION
    Reproduces the observation side of case 2608010010000636. Runs ENTIRELY FROM
    THE HYPER-V HOST and PSDirects into each client on an interval, so it keeps
    working across the client reboots and ccmexec restarts that the fault causes.

    Per poll, per client, it reads:

      PolicyPlatformClient.log   (TAB-delimited, NOT CMTrace)
        Retrieved N policy instance(s) ...   <- the projected policy set size
        Detected N tattoo(s).                <- N>0 means settings look orphaned
        UnintendInstance - Class name ...    <- which setting is being reverted
        Starting reification / Completed reification successfully
                                             <- a pass that starts but never
                                                completes was TRUNCATED, which is
                                                how the loop becomes permanent
        ERROR: 0x80041002                    <- CI definition gone; the revert
                                                fails instead of running a script

      DcmWmiProvider.log         (CMTrace)
        reading remediation script definition
        Script host returned exit code       <- unconditional "it ran" marker

      Registry
        HKLM\...\Reboot Management\RebootData   RebootBy / RebootValueInUTC

    The headline number is PolicyCount. A drop below its own steady state is the
    condition under which previously-intended settings get treated as orphaned.

    Read-only. Nothing in any guest is modified.

.PARAMETER DomainName
    The lab domain (e.g. pchurn.com). If omitted, lists the domains it can see.

.PARAMETER VMName
    Only watch these VM(s) (wildcards allowed). Default: every Running VM in the
    domain that is not a site server / infrastructure role.

.PARAMETER IntervalSeconds
    Seconds between polls. Default 60.

.PARAMETER DurationMinutes
    How long to keep watching. Default 240. Use 0 to run until Ctrl-C.

.PARAMETER OutputPath
    CSV + transcript folder. Default vmbuild\logs\policy-churn\<domain>-<stamp>.

.PARAMETER TimeoutSeconds
    Per-VM PSDirect timeout. Default 120.

.EXAMPLE
    cd C:\memlabs\vmbuild
    .\tools\Watch-PolicyChurn.ps1 -DomainName pchurn.com

.EXAMPLE
    # Start this BEFORE kicking the site upgrade, and leave it running
    .\tools\Watch-PolicyChurn.ps1 -DomainName pchurn.com -IntervalSeconds 30 -DurationMinutes 480
#>
[CmdletBinding()]
param(
    [string]$DomainName,
    [string[]]$VMName,
    [int]$IntervalSeconds = 60,
    [int]$DurationMinutes = 240,
    [string]$OutputPath,
    [int]$TimeoutSeconds = 120
)

$ErrorActionPreference = 'Stop'

$vmbuildRoot = Split-Path -Parent $PSScriptRoot
Set-Location $vmbuildRoot
$commonPath = Join-Path $vmbuildRoot 'Common.ps1'
$bomBytes = [System.IO.File]::ReadAllBytes($commonPath)[0..2]
if (-not ($bomBytes[0] -eq 0xEF -and $bomBytes[1] -eq 0xBB -and $bomBytes[2] -eq 0xBF)) {
    Write-Host "ERROR: Common.ps1 is missing UTF-8 BOM. PS5.1 will fail to parse it." -ForegroundColor Red
    Write-Host "Run: git checkout -- vmbuild/Common.ps1" -ForegroundColor Yellow
    exit 1
}
. $commonPath -InJob

$allVMs = @(Get-List -Type VM -SmartUpdate)
if (-not $DomainName) {
    Write-Host "`nNo -DomainName given. Domains I can see:" -ForegroundColor Yellow
    $allVMs | Group-Object -Property domain | Sort-Object Name | ForEach-Object {
        Write-Host ("  {0}  ({1} VM(s))" -f $_.Name, $_.Count)
    }
    return
}

$skipRoles = @('DC', 'BDC', 'OSDClient', 'StandaloneRootCA', 'Proxy', 'LinuxServer', 'LinuxClient', 'FileServer', 'SQLAO')
$targets = @($allVMs | Where-Object {
        $_.domain -eq $DomainName -and $_.state -eq 'Running' -and $skipRoles -notcontains $_.role
    })
if ($VMName) {
    $targets = @($targets | Where-Object { $vm = $_; ($VMName | Where-Object { $vm.vmName -like $_ }) })
}
if ($targets.Count -eq 0) {
    Write-Host "No matching Running VMs in '$DomainName'." -ForegroundColor Red
    return
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if (-not $OutputPath) { $OutputPath = Join-Path $vmbuildRoot "logs\policy-churn\$DomainName-$stamp" }
if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
$csvPath = Join-Path $OutputPath 'policy-churn.csv'

Write-Host "`n=== MEMLABS policy-churn watch ===" -ForegroundColor Cyan
Write-Host "Domain   : $DomainName"
Write-Host "Clients  : $(($targets | ForEach-Object { $_.vmName }) -join ', ')"
Write-Host "Interval : ${IntervalSeconds}s   Duration: $(if ($DurationMinutes -gt 0) { "${DurationMinutes}m" } else { 'until Ctrl-C' })"
Write-Host "Output   : $csvPath"
Write-Host ""

# Runs IN each client. Everything here must be PS5.1-safe.
$clientSB = {
    $out = [pscustomobject]@{
        Computer      = $env:COMPUTERNAME
        Error         = $null
        ClientVersion = $null
        PolicyCount   = $null
        PolicyTime    = $null
        Tattoos       = $null
        TattooTime    = $null
        ReifyStart    = 0
        ReifyDone     = 0
        Unintend      = 0
        NotFound      = 0
        LastUnintend  = $null
        ScriptReads   = 0
        ScriptRuns    = 0
        AuditLines    = 0
        LastAudit     = $null
        RebootBy      = $null
        RebootInUtc   = $null
        LastBootTime  = $null
    }

    try {
        $ccm = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\SMS\Mobile Client' -Name 'ProductVersion' -ErrorAction SilentlyContinue
        if ($ccm) { $out.ClientVersion = "$($ccm.ProductVersion)" }

        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
        if ($os) { $out.LastBootTime = $os.LastBootUpTime.ToString('yyyy-MM-dd HH:mm:ss') }

        # Volatile key -- absent for part of every reboot cycle, that is normal.
        $rd = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\SMS\Mobile Client\Reboot Management\RebootData' -ErrorAction SilentlyContinue
        if ($rd) {
            if ($null -ne $rd.RebootBy) { $out.RebootBy = "$($rd.RebootBy)" }
            if ($null -ne $rd.RebootValueInUTC) { $out.RebootInUtc = "$($rd.RebootValueInUTC)" }
        }

        # --- PolicyPlatformClient.log : TAB-delimited, not CMTrace ----------
        $ppLog = 'C:\Program Files\Microsoft Policy Platform\PolicyPlatformClient.log'
        if (-not (Test-Path $ppLog)) {
            $found = Get-ChildItem -Path 'C:\Program Files\Microsoft Policy Platform' -Filter 'PolicyPlatformClient.log' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) { $ppLog = $found.FullName }
        }
        if (Test-Path $ppLog) {
            # Tail only -- these logs reach MBs and we poll frequently.
            $tail = Get-Content -Path $ppLog -Tail 4000 -ErrorAction SilentlyContinue
            $stampRx = '^(\d{4}-\d{2}-\d{2})\s+(\d{2}:\d{2}:\d{2})'

            foreach ($line in $tail) {
                if ($line -match 'Retrieved (\d+) policy instance') {
                    $out.PolicyCount = [int]$Matches[1]
                    if ($line -match $stampRx) { $out.PolicyTime = "$($Matches[1]) $($Matches[2])" }
                }
                if ($line -match 'Detected (\d+) tattoo') {
                    $out.Tattoos = [int]$Matches[1]
                    if ($line -match $stampRx) { $out.TattooTime = "$($Matches[1]) $($Matches[2])" }
                }
                if ($line -match 'Starting reification') { $out.ReifyStart++ }
                if ($line -match 'Completed reification successfully') { $out.ReifyDone++ }
                if ($line -match 'UnintendInstance') {
                    $out.Unintend++
                    if ($line -match 'instance = \[(.+?)\]') { $out.LastUnintend = $Matches[1] }
                }
                if ($line -match '80041002') { $out.NotFound++ }
            }
        }
        else {
            $out.Error = 'PolicyPlatformClient.log not found'
        }

        # --- DcmWmiProvider.log : CMTrace ----------------------------------
        $dcmLog = 'C:\Windows\CCM\Logs\DcmWmiProvider.log'
        if (Test-Path $dcmLog) {
            $dtail = Get-Content -Path $dcmLog -Tail 3000 -ErrorAction SilentlyContinue
            foreach ($line in $dtail) {
                if ($line -match 'reading remediation script definition') { $out.ScriptReads++ }
                if ($line -match 'Script host returned exit code') { $out.ScriptRuns++ }
            }
        }

        # --- repro remediation audit: direct proof a remediation executed ----
        # Written only by the CIs perfloading creates from cmOptions.ReproTattooCICount.
        $auditLog = 'C:\ProgramData\MEMLABS-PolicyChurn\remediation-audit.log'
        if (Test-Path $auditLog) {
            $alines = @(Get-Content -Path $auditLog -ErrorAction SilentlyContinue)
            $out.AuditLines = $alines.Count
            if ($alines.Count -gt 0) { $out.LastAudit = $alines[-1] }
        }
    }
    catch {
        $out.Error = "$($_.Exception.Message)"
    }
    return $out
}

# Steady-state policy count per client, learned from the first clean reading.
$baseline = @{}
# Repro remediation-audit line count per client, so a RISE can be called out.
$auditSeen = @{}
$rows = New-Object System.Collections.Generic.List[object]
$endTime = if ($DurationMinutes -gt 0) { (Get-Date).AddMinutes($DurationMinutes) } else { [datetime]::MaxValue }

Write-Host ("{0,-9} {1,-10} {2,-8} {3,-7} {4,-7} {5,-11} {6,-9} {7}" -f 'Time', 'VM', 'Policy', 'Tattoo', 'Reify', 'Scripts', 'RebootBy', 'Note') -ForegroundColor DarkGray
Write-Host ("-" * 100) -ForegroundColor DarkGray

while ((Get-Date) -lt $endTime) {
    $pollTime = Get-Date

    foreach ($vm in $targets) {
        $vmNameRaw = $vm.vmName
        if ($vmNameRaw -is [System.Array]) { $vmNameRaw = $vmNameRaw[0] }
        [string]$vmn = "$vmNameRaw"

        $res = Invoke-VmCommand -VmName $vmn -VmDomainName $DomainName -ScriptBlock $clientSB `
            -DisplayName "PolicyChurn" -SuppressLog -AsJob -TimeoutSeconds $TimeoutSeconds

        if (-not $res -or $res.ScriptBlockFailed -or -not $res.ScriptBlockOutput) {
            # A client mid-reboot is expected during this fault, not an error.
            $why = if ($res -and $res.TimedOut) { 'timeout' } else { 'unreachable' }
            Write-Host ("{0,-9} {1,-10} {2}" -f $pollTime.ToString('HH:mm:ss'), $vmn, "-- $why (rebooting?)") -ForegroundColor DarkYellow
            continue
        }

        $d = $res.ScriptBlockOutput
        $note = @()

        if ($d.Error) { $note += $d.Error }

        if ($null -ne $d.PolicyCount) {
            if (-not $baseline.ContainsKey($vmn)) {
                $baseline[$vmn] = $d.PolicyCount
            }
            elseif ($d.PolicyCount -gt $baseline[$vmn]) {
                $baseline[$vmn] = $d.PolicyCount
            }
            elseif ($d.PolicyCount -lt ($baseline[$vmn] * 0.9)) {
                $note += "POLICY DROP (peak $($baseline[$vmn]))"
            }
        }

        if ($d.Tattoos -gt 0) { $note += "TATTOOS=$($d.Tattoos)" }
        if ($d.ReifyStart -gt $d.ReifyDone) { $note += "TRUNCATED x$($d.ReifyStart - $d.ReifyDone)" }
        if ($d.NotFound -gt 0) { $note += "0x80041002 x$($d.NotFound)" }
        if ($d.RebootBy -and $d.RebootBy -ne '0') { $note += "REBOOTBY=$($d.RebootBy)" }

        # Rising audit count = a repro remediation actually executed this cycle.
        if (-not $auditSeen.ContainsKey($vmn)) { $auditSeen[$vmn] = 0 }
        if ($d.AuditLines -gt $auditSeen[$vmn]) {
            $note += "REMEDIATION RAN x$($d.AuditLines - $auditSeen[$vmn])"
            $auditSeen[$vmn] = $d.AuditLines
        }

        if ($d.LastUnintend) { $note += "last unintend: $($d.LastUnintend)" }

        $colour = 'Gray'
        if ($d.Tattoos -gt 0 -or ($d.RebootBy -and $d.RebootBy -ne '0')) { $colour = 'Red' }
        elseif ($note.Count -gt 0) { $colour = 'Yellow' }

        Write-Host ("{0,-9} {1,-10} {2,-8} {3,-7} {4,-7} {5,-11} {6,-9} {7}" -f `
                $pollTime.ToString('HH:mm:ss'), $vmn, $d.PolicyCount, $d.Tattoos,
            "$($d.ReifyDone)/$($d.ReifyStart)", "$($d.ScriptRuns)/$($d.ScriptReads)",
            $d.RebootBy, ($note -join '; ')) -ForegroundColor $colour

        $rows.Add([pscustomobject]@{
                PollTime      = $pollTime.ToString('yyyy-MM-dd HH:mm:ss')
                VM            = $vmn
                ClientVersion = $d.ClientVersion
                PolicyCount   = $d.PolicyCount
                PolicyPeak    = $(if ($baseline.ContainsKey($vmn)) { $baseline[$vmn] } else { $null })
                PolicyTime    = $d.PolicyTime
                Tattoos       = $d.Tattoos
                TattooTime    = $d.TattooTime
                ReifyStart    = $d.ReifyStart
                ReifyDone     = $d.ReifyDone
                Unintend      = $d.Unintend
                LastUnintend  = $d.LastUnintend
                NotFound      = $d.NotFound
                ScriptReads   = $d.ScriptReads
                ScriptRuns    = $d.ScriptRuns
                AuditLines    = $d.AuditLines
                LastAudit     = $d.LastAudit
                RebootBy      = $d.RebootBy
                RebootInUtc   = $d.RebootInUtc
                LastBootTime  = $d.LastBootTime
                Note          = ($note -join '; ')
            })
    }

    # Rewrite each pass so the CSV survives a Ctrl-C.
    $rows | Export-Csv -Path $csvPath -NoTypeInformation -Force
    Start-Sleep -Seconds $IntervalSeconds
}

Write-Host "`nDone. $($rows.Count) sample(s) written to:" -ForegroundColor Green
Write-Host "  $csvPath"
