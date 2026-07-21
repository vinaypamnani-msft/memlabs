<#
.SYNOPSIS
    Per-DP content distribution status for ConfigMgr packages (default: boot
    images) -- identifies WHICH distribution point is stuck and points at the
    right log to root-cause it.

.DESCRIPTION
    Run this EITHER on the memlabs HOST (the box that runs New-Lab) OR on the
    primary site server. On the host it dot-sources Common.ps1, finds the
    Primary (else CAS) site server VM via Get-List, and runs the probe INSIDE
    that VM over PowerShell Direct (so all WMI is local to the site server --
    no cross-machine DCOM). On a site server it just queries locally.

    It auto-detects the site code, then for each target package queries the SMS
    provider for per-DP state:

      * SMS_PackageStatusDistPointsSummarizer -> authoritative per-DP State
        (0 Installed / 1 InstallPending / 2 InstallRetrying / 3 InstallFailed /
         4 RemovalPending / 5 RemovalRetrying / 6 RemovalFailed /
         7 ContentValidating / 8 ContentValidationFailed) + SourceVersion.
      * SMS_DistributionDPStatus (best-effort) -> LastUpdateDate + any
        Description/MessageID the provider exposes for the DP.

    It resolves each ServerNALPath to the DP server name and, for any DP not
    'Installed', prints WHERE to look next (DataTransferService.log +
    smsdpprov.log on a Pull DP; PkgXferMgr.log/distmgr.log on the site server;
    sender/despooler on a Secondary). STRICTLY READ-ONLY -- only WMI reads.

    Default target is the boot images (the usual "distribution failed on 1 DP"
    Phase-11 warning). Use -PackageID or -All to widen.

.PARAMETER SiteCode
    Three-char site code. Auto-detected from HKLM\SOFTWARE\Microsoft\SMS\
    Identification when omitted.

.PARAMETER ComputerName
    SMS provider server. Defaults to the local machine (run on the primary).

.PARAMETER PackageID
    One or more specific PackageIDs to report. Overrides the boot-image default.

.PARAMETER All
    Report every package/content object with a distribution record.

.PARAMETER VmName
    When run from the host, the site server VM to query over PowerShell Direct.
    Auto-detected (Primary, else CAS) from Get-List when omitted.

.EXAMPLE
    .\Test-ContentDistribution.ps1
    # From the host or the site server: boot images, per-DP state + where to look.

.EXAMPLE
    .\Test-ContentDistribution.ps1 -VmName PL-MELT

.EXAMPLE
    .\Test-ContentDistribution.ps1 -PackageID BUN00002,BUN00005

.EXAMPLE
    .\Test-ContentDistribution.ps1 -All
#>

[CmdletBinding()]
param(
    [string]$SiteCode,
    [string]$ComputerName = $env:COMPUTERNAME,
    [string[]]$PackageID,
    [switch]$All,
    # When run from the memlabs HOST, the site server VM to query over PowerShell
    # Direct. Auto-detected (Primary, else CAS) from Get-List when omitted.
    [string]$VmName
)

$ErrorActionPreference = 'Stop'

function Write-Head { param([string]$T) Write-Host ""; Write-Host ("===== {0} =====" -f $T) -ForegroundColor Cyan }

# State code -> friendly name.
$stateNames = @{
    0 = 'Installed'; 1 = 'InstallPending'; 2 = 'InstallRetrying'; 3 = 'InstallFAILED';
    4 = 'RemovalPending'; 5 = 'RemovalRetrying'; 6 = 'RemovalFAILED';
    7 = 'ContentValidating'; 8 = 'ContentValidationFAILED'
}

# ---------------------------------------------------------------------------
# The probe. Runs ENTIRELY inside the site server (locally when this script is
# run on the site server, or via PowerShell Direct when run from the host), so
# it only ever does LOCAL WMI reads -- no cross-machine DCOM. Returns a plain
# object; all rendering/coloring happens on the caller side.
# ---------------------------------------------------------------------------
$probe = {
    param([string]$SiteCode, [string[]]$PackageID, [bool]$All)

    $out = [pscustomobject]@{ Error = $null; SiteCode = $SiteCode; Targets = @(); Rows = @() }

    if (-not $SiteCode) {
        try {
            $SiteCode = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\SMS\Identification' -Name 'Site Code' -ErrorAction Stop).'Site Code'
        }
        catch {
            $out.Error = "Could not auto-detect the site code (HKLM\SOFTWARE\Microsoft\SMS\Identification) on '$env:COMPUTERNAME'. This box is not a site server -- pass -SiteCode or -VmName."
            return $out
        }
    }
    $out.SiteCode = $SiteCode
    $ns = "root\SMS\site_$SiteCode"

    # ServerNALPath looks like ["Display=\\PL-PATTYDP.dom\"]MSWNET:...\\PL-PATTYDP.dom\
    function Get-DpNameLocal { param([string]$nal)
        if ($nal -match '\\\\([^\\"\]]+)') { return $Matches[1] }
        return $nal
    }

    # Resolve which packages to report.
    if ($PackageID) {
        $targetIds = $PackageID
    }
    elseif ($All) {
        $targetIds = $null   # report everything the summarizer has
    }
    else {
        $boot = @(Get-WmiObject -Namespace $ns -Class SMS_BootImagePackage -ErrorAction SilentlyContinue | Select-Object PackageID, Name)
        if (-not $boot) {
            $out.Error = "No boot images found in $ns. Pass -PackageID or -All."
            return $out
        }
        $targetIds = $boot.PackageID
        $out.Targets = @($boot | ForEach-Object { "$($_.Name) [$($_.PackageID)]" })
    }

    # Best-effort DP status detail (LastUpdateDate / Description); schema varies.
    $dpDetail = @{}
    try {
        $filter = $null
        if ($targetIds) { $filter = ($targetIds | ForEach-Object { "PackageID='$_'" }) -join ' OR ' }
        foreach ($r in @(Get-WmiObject -Namespace $ns -Class SMS_DistributionDPStatus -Filter $filter -ErrorAction Stop)) {
            $dpDetail["$($r.PackageID)|$(Get-DpNameLocal $r.ServerNALPath)"] = $r
        }
    }
    catch {}

    $pkgIds = if ($targetIds) { $targetIds } else {
        @(Get-WmiObject -Namespace $ns -Class SMS_PackageStatusDistPointsSummarizer -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty PackageID -Unique)
    }

    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($pkgId in $pkgIds) {
        $recs = @(Get-WmiObject -Namespace $ns -Class SMS_PackageStatusDistPointsSummarizer `
                -Filter "PackageID='$pkgId'" -ErrorAction SilentlyContinue)
        if (-not $recs) {
            $rows.Add([pscustomobject]@{ PackageID = $pkgId; DP = $null; State = -1; SourceVersion = $null; LastUpdate = $null; Description = $null })
            continue
        }
        foreach ($rec in $recs) {
            $dp = Get-DpNameLocal $rec.ServerNALPath
            $detail = $dpDetail["$pkgId|$dp"]
            $lastUpd = if ($detail -and $detail.LastUpdateDate) {
                try { ([Management.ManagementDateTimeConverter]::ToDateTime($detail.LastUpdateDate)).ToString('u') } catch { "$($detail.LastUpdateDate)" }
            } else { '?' }
            $desc = $null
            if ($detail) { foreach ($p in 'Description', 'LastStatusMessage', 'MessageID') { if ($detail.PSObject.Properties.Name -contains $p -and $detail.$p) { $desc = "$($detail.$p)"; break } } }
            $rows.Add([pscustomobject]@{
                    PackageID     = $pkgId
                    DP            = $dp
                    State         = [int]$rec.State
                    SourceVersion = $rec.SourceVersion
                    LastUpdate    = $lastUpd
                    Description   = $desc
                })
        }
    }
    $out.Rows = $rows.ToArray()
    return $out
}

# ---------------------------------------------------------------------------
# Run the probe: locally if this box has the SMS provider, otherwise bootstrap
# memlabs Common.ps1 and run it inside the site server VM over PowerShell Direct.
# ---------------------------------------------------------------------------
$haveLocalProvider = Test-Path 'HKLM:\SOFTWARE\Microsoft\SMS\Identification'

if ($haveLocalProvider -and -not $VmName) {
    Write-Host "SMS provider: $ComputerName (local)" -ForegroundColor White
    $result = & $probe $SiteCode $PackageID ([bool]$All)
}
else {
    # Host path: dot-source Common.ps1 (only if not already loaded) for Get-List /
    # Invoke-VmCommand, then find and target the site server VM.
    if (-not (Get-Command Invoke-VmCommand -ErrorAction SilentlyContinue)) {
        . (Join-Path $PSScriptRoot '..\Common.ps1') -VerboseEnabled:$false -InJob:$false
    }

    $allVms = @(Get-List -Type VM)
    if ($VmName) {
        $siteVm = $allVms | Where-Object { $_.vmName -eq $VmName } | Select-Object -First 1
        if (-not $siteVm) { throw "VM '$VmName' not found in Get-List. Check the name." }
    }
    else {
        $candidates = @($allVms | Where-Object { $_.role -in 'Primary', 'CAS' })
        if ($SiteCode) { $candidates = @($candidates | Where-Object { $_.siteCode -eq $SiteCode }) + @($candidates | Where-Object { $_.siteCode -ne $SiteCode }) }
        # Prefer a Primary (owns package distribution) over a CAS.
        $siteVm = @($candidates | Where-Object { $_.role -eq 'Primary' })[0]
        if (-not $siteVm) { $siteVm = $candidates | Select-Object -First 1 }
        if (-not $siteVm) { throw "No Primary/CAS site server VM found via Get-List. Pass -VmName explicitly (run on the site server, or name the VM)." }
    }

    Write-Host "SMS provider: $($siteVm.vmName) [$($siteVm.domain)] (over PowerShell Direct)" -ForegroundColor White
    $inv = Invoke-VmCommand -VmName $siteVm.vmName -VmDomainName $siteVm.domain `
        -ScriptBlock $probe -ArgumentList @($SiteCode, $PackageID, [bool]$All) `
        -DisplayName 'Test-ContentDistribution probe' -SuppressLog
    if (-not $inv -or $inv.ScriptBlockFailed) {
        throw "Failed to run the probe inside '$($siteVm.vmName)': $($inv.ErrorDetails)"
    }
    $result = $inv.ScriptBlockOutput
}

if (-not $result) { throw "Probe returned no result." }
if ($result.Error) { throw $result.Error }

$ns = "root\SMS\site_$($result.SiteCode)"
Write-Host "Site code: $($result.SiteCode)   namespace: $ns" -ForegroundColor White
if ($PackageID) { Write-Host "Targets: $($PackageID -join ', ')" -ForegroundColor White }
elseif ($All) { Write-Host "Targets: ALL packages with a distribution record" -ForegroundColor White }
elseif ($result.Targets) { Write-Host "Targets (boot images): $($result.Targets -join '; ')" -ForegroundColor White }

# -- Render -----------------------------------------------------------------
$anyStuck = $false
foreach ($grp in ($result.Rows | Group-Object PackageID)) {
    Write-Head "Package $($grp.Name)"
    foreach ($row in $grp.Group) {
        if ($row.State -lt 0) { Write-Host "  (no distribution records)" -ForegroundColor DarkGray; continue }
        $stateName = if ($stateNames.ContainsKey($row.State)) { $stateNames[$row.State] } else { "State=$($row.State)" }
        $color = if ($row.State -eq 0) { 'Green' } elseif ($row.State -in 3, 6, 8) { 'Red' } else { 'Yellow' }
        Write-Host ("  {0,-28} {1,-24} srcVer={2}  lastUpdate={3}" -f $row.DP, $stateName, $row.SourceVersion, $row.LastUpdate) -ForegroundColor $color
        if ($row.Description) { Write-Host ("      -> $($row.Description)") -ForegroundColor DarkGray }
        if ($row.State -ne 0) { $anyStuck = $true }
    }
}

# -- Guidance ---------------------------------------------------------------
if ($anyStuck) {
    Write-Head "Where to look next (per stuck DP)"
    Write-Host "  Site server:             distmgr.log, PkgXferMgr.log  (grep the PackageID)" -ForegroundColor Gray
    Write-Host "  Pull DP:                 DataTransferService.log, smsdpprov.log  (content pull from source DP)" -ForegroundColor Gray
    Write-Host "  Secondary-site DP:       on the Secondary: despool.log / distmgr.log; on the Primary: sender.log" -ForegroundColor Gray
    Write-Host "  Common cross-subnet/PKI causes: DP cert/trust (UsePKI), the DP's IIS/WebDAV/BITS not serving," -ForegroundColor Gray
    Write-Host "  no route from DP to source DP:8080/443, or the source DP missing the content." -ForegroundColor Gray
    Write-Host ""
    Write-Host "RESULT: at least one DP is NOT 'Installed' -- see the red/yellow rows above." -ForegroundColor Yellow
}
else {
    Write-Host ""
    Write-Host "RESULT: all DPs report 'Installed' for the target package(s)." -ForegroundColor Green
}
