<#
.SYNOPSIS
    Per-DP content distribution status for ConfigMgr packages (default: boot
    images) -- identifies WHICH distribution point is stuck and points at the
    right log to root-cause it.

.DESCRIPTION
    Run this ON THE PRIMARY SITE SERVER (or any box with the SMS provider). It
    auto-detects the site code, then for each target package queries the SMS
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

.EXAMPLE
    .\Test-ContentDistribution.ps1
    # Boot images: per-DP state + which DP is stuck and where to look.

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
    [switch]$All
)

$ErrorActionPreference = 'Stop'

function Write-Head { param([string]$T) Write-Host ""; Write-Host ("===== {0} =====" -f $T) -ForegroundColor Cyan }

# -- Site code --------------------------------------------------------------
if (-not $SiteCode) {
    try {
        $SiteCode = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\SMS\Identification' -Name 'Site Code' -ErrorAction Stop).'Site Code'
    }
    catch {
        throw "Could not auto-detect the site code (HKLM\SOFTWARE\Microsoft\SMS\Identification). Run on the site server or pass -SiteCode."
    }
}
$ns = "root\SMS\site_$SiteCode"
Write-Host "SMS provider: $ComputerName   namespace: $ns" -ForegroundColor White

# State code -> friendly name.
$stateNames = @{
    0 = 'Installed'; 1 = 'InstallPending'; 2 = 'InstallRetrying'; 3 = 'InstallFAILED';
    4 = 'RemovalPending'; 5 = 'RemovalRetrying'; 6 = 'RemovalFAILED';
    7 = 'ContentValidating'; 8 = 'ContentValidationFAILED'
}

# -- Resolve which packages to report ---------------------------------------
if ($PackageID) {
    $targetIds = $PackageID
    Write-Host "Targets: $($targetIds -join ', ')" -ForegroundColor White
}
elseif ($All) {
    $targetIds = $null   # report everything the summarizer has
    Write-Host "Targets: ALL packages with a distribution record" -ForegroundColor White
}
else {
    # Default: boot images.
    $boot = @(Get-WmiObject -ComputerName $ComputerName -Namespace $ns -Class SMS_BootImagePackage -ErrorAction SilentlyContinue |
        Select-Object PackageID, Name)
    if (-not $boot) {
        throw "No boot images found in $ns. Pass -PackageID or -All."
    }
    $targetIds = $boot.PackageID
    Write-Host "Targets (boot images): $(( $boot | ForEach-Object { "$($_.Name) [$($_.PackageID)]" }) -join '; ')" -ForegroundColor White
}

# -- Map ServerNALPath -> DP server name (once) -----------------------------
# ServerNALPath looks like ["Display=\\PL-PATTYDP.dom\"]MSWNET:...\\PL-PATTYDP.dom\
function Get-DpName { param([string]$nal)
    if ($nal -match '\\\\([^\\"\]]+)') { return $Matches[1] }
    return $nal
}

# -- Pull the DP status detail (best-effort; provider schema varies) ---------
$dpDetail = @{}
try {
    $filter = $null
    if ($targetIds) { $filter = ($targetIds | ForEach-Object { "PackageID='$_'" }) -join ' OR ' }
    $rows = Get-WmiObject -ComputerName $ComputerName -Namespace $ns -Class SMS_DistributionDPStatus -Filter $filter -ErrorAction Stop
    foreach ($r in $rows) {
        $dp = Get-DpName $r.ServerNALPath
        $key = "$($r.PackageID)|$dp"
        $dpDetail[$key] = $r
    }
}
catch { Write-Host "(SMS_DistributionDPStatus not available: $($_.Exception.Message))" -ForegroundColor DarkGray }

# -- Per-package, per-DP summarizer state -----------------------------------
$anyStuck = $false
$pkgIds = if ($targetIds) { $targetIds } else {
    @(Get-WmiObject -ComputerName $ComputerName -Namespace $ns -Class SMS_PackageStatusDistPointsSummarizer -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty PackageID -Unique)
}

foreach ($pkgId in $pkgIds) {
    Write-Head "Package $pkgId"
    $rows = @(Get-WmiObject -ComputerName $ComputerName -Namespace $ns -Class SMS_PackageStatusDistPointsSummarizer `
            -Filter "PackageID='$pkgId'" -ErrorAction SilentlyContinue)
    if (-not $rows) { Write-Host "  (no distribution records)" -ForegroundColor DarkGray; continue }

    foreach ($row in $rows) {
        $dp = Get-DpName $row.ServerNALPath
        $stateName = if ($stateNames.ContainsKey([int]$row.State)) { $stateNames[[int]$row.State] } else { "State=$($row.State)" }
        $color = if ([int]$row.State -eq 0) { 'Green' } elseif ([int]$row.State -in 3, 6, 8) { 'Red' } else { 'Yellow' }

        $detail = $dpDetail["$pkgId|$dp"]
        $lastUpd = if ($detail -and $detail.LastUpdateDate) {
            try { ([Management.ManagementDateTimeConverter]::ToDateTime($detail.LastUpdateDate)).ToString('u') } catch { $detail.LastUpdateDate }
        } else { '?' }
        $desc = if ($detail) { foreach ($p in 'Description', 'LastStatusMessage', 'MessageID') { if ($detail.PSObject.Properties.Name -contains $p -and $detail.$p) { $detail.$p; break } } }

        Write-Host ("  {0,-28} {1,-24} srcVer={2}  lastUpdate={3}" -f $dp, $stateName, $row.SourceVersion, $lastUpd) -ForegroundColor $color
        if ($desc) { Write-Host ("      -> $desc") -ForegroundColor DarkGray }

        if ([int]$row.State -ne 0) {
            $anyStuck = $true
        }
    }
}

# -- Guidance ---------------------------------------------------------------
if ($anyStuck) {
    Write-Head "Where to look next (per stuck DP)"
    Write-Host "  Site server (this box):  distmgr.log, PkgXferMgr.log  (grep the PackageID)" -ForegroundColor Gray
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
