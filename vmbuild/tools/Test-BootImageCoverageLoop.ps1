<#
.SYNOPSIS
    Arms, inspects and times the Phase 8 boot-image coverage path on an EXISTING lab, so a
    change to it can be tested in ~15 minutes instead of a 4.5-hour hierarchy build.

    Why this exists: every iteration on the boot-image gate previously cost a full fresh
    build, and an untested change to it (dd658177, reverted in b3716e48) burned one --
    it moved content distribution to the owning CAS and left Update-CMDistributionPoint
    on the child, so SourceVersion never advanced and Phase 8 failed 45 minutes later.

.DESCRIPTION
    Three modes. Default is a read-only state report.

      -State (default)  Report the boot image's state on the child primary: SourceVersion,
                        StoredPkgVersion, per-DP targeting rows and per-DP summarizer
                        State/SourceVersion. This is the tuple the Phase 8 gate reads.

      -Reset            Put the boot image back to its pre-Phase-8 shape so the next Phase 8
                        re-runs the real path: disable command support (so the next enable
                        actually changes something and can bump SourceVersion) and remove the
                        OSD DP content destination (so $missingOsdDps is non-empty and the
                        distribution branch runs instead of "already on all OSD DP(s)").
                        Reversible: Phase 8 recreates both.

      -Watch            Poll the same tuple until every OSD DP reports State=0 at the current
                        SourceVersion, and print how long it took. Run this alongside Phase 8.

    SCOPE -- what this does NOT reproduce: the PkgStatus_G identity split. That needs the
    child and the owning CAS to both author a status row for the child site, which depends on
    timing this cannot force. So a green run here proves the MECHANICS (version advances,
    content lands, gate passes); it does not prove the split-brain is prevented. For the
    PkgStatus_G / PkgStatusHist / fnIsPkgVersionAvailable evidence, use
    Get-DrsLogs.ps1 -PackageId <bootImageId>, which already has the SQL instance discovery.

.EXAMPLE
    .\Test-BootImageCoverageLoop.ps1 -Domain burnin.sandwich.lab
.EXAMPLE
    .\Test-BootImageCoverageLoop.ps1 -Domain burnin.sandwich.lab -Reset
    # then: New-Lab.ps1 -Configuration <cfg> -Phase 8
.EXAMPLE
    .\Test-BootImageCoverageLoop.ps1 -Domain burnin.sandwich.lab -Watch
#>
[CmdletBinding()]
param(
    [string]$Domain,
    [string]$PrimaryName,
    [string]$PackageId,
    [switch]$Reset,
    [switch]$Watch,
    [int]$IntervalSeconds = 20,
    [int]$MaxMinutes = 50
)

$ErrorActionPreference = 'Stop'

$vmbuildRoot = Split-Path -Parent $PSScriptRoot
Set-Location $vmbuildRoot

$commonPath = Join-Path $vmbuildRoot 'Common.ps1'
$bom = [System.IO.File]::ReadAllBytes($commonPath)[0..2]
if (-not ($bom[0] -eq 0xEF -and $bom[1] -eq 0xBB -and $bom[2] -eq 0xBF)) {
    Write-Host "ERROR: Common.ps1 is missing UTF-8 BOM (PS5.1 parse hazard). Run: git checkout -- vmbuild/Common.ps1" -ForegroundColor Red
    exit 1
}
. $commonPath -InJob

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logPath = Join-Path $vmbuildRoot ("logs\bootimage-loop-{0}.log" -f $stamp)
$say = {
    param([string]$Text, [string]$Colour = 'Gray')
    $line = '{0}  {1}' -f (Get-Date -Format 'HH:mm:ss'), $Text
    Write-Host $line -ForegroundColor $Colour
    try { Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8 -ErrorAction Stop } catch { }
}

# ---- topology ----
$allVms = @(Get-List -Type VM -SmartUpdate)
if ($Domain) { $allVms = @($allVms | Where-Object { $_.domain -eq $Domain }) }
$primaries = @($allVms | Where-Object { $_.role -eq 'Primary' })
if ($PrimaryName) { $primaries = @($primaries | Where-Object { $_.vmName -eq $PrimaryName }) }
if ($primaries.Count -eq 0) { & $say "FATAL: no Primary found$(if ($Domain) { " in domain $Domain" })." 'Red'; return }
if ($primaries.Count -gt 1) { & $say "FATAL: $($primaries.Count) primaries found ($($primaries.vmName -join ', ')); re-run with -PrimaryName." 'Red'; return }
$primary = $primaries[0]
$dom = $primary.domain

& $say "primary=$($primary.vmName) site=$($primary.siteCode) domain=$dom  log -> $logPath" 'Cyan'

# Reads the exact tuple the Phase 8 coverage gate reads, so this and the gate cannot disagree.
$stateBlock = {
    param($siteCode, $pkgId)
    $ns = "root\SMS\site_$siteCode"
    $out = New-Object System.Collections.Generic.List[string]
    $serverFromNal = { param($nal) if ("$nal" -match '\\\\([^\\"]+)') { $Matches[1] } else { '' } }

    $boot = $null
    if ($pkgId) {
        $boot = Get-WmiObject -Namespace $ns -Class SMS_BootImagePackage -Filter "PackageID='$pkgId'" -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    else {
        $boot = @(Get-WmiObject -Namespace $ns -Class SMS_BootImagePackage -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -eq 'Boot image (x64)' }) | Select-Object -First 1
    }
    if (-not $boot) { $out.Add('__ABSENT__ no x64 boot image found'); return $out.ToArray() }

    $pkg = "$($boot.PackageID)"
    # SMS_Package is a SIBLING of SMS_BootImagePackage under SMS_PackageBaseclass, so filtering
    # it by a boot image's PackageID returns nothing -- StoredPkgVersion and SourceSite printed
    # blank on every run until 2026-08-20. Get() also populates the lazy EnableLabShell.
    try { $boot.Get() } catch { }
    $srcVer = "$($boot.SourceVersion)"
    $labShell = "$($boot.EnableLabShell)"
    $stored = "$($boot.StoredPkgVersion)"
    $srcSite = "$($boot.SourceSite)"
    $out.Add("PKG $pkg SourceVersion=$srcVer StoredPkgVersion=$stored EnableLabShell=$labShell SourceSite=$srcSite")

    $targets = @(Get-WmiObject -Namespace $ns -Class SMS_DistributionPoint -Filter "PackageID='$pkg'" -ErrorAction SilentlyContinue)
    if ($targets.Count -eq 0) { $out.Add('TARGET none -- no content destination exists') }
    foreach ($t in $targets) { $out.Add("TARGET $(& $serverFromNal $t.ServerNALPath)") }

    $rows = @(Get-WmiObject -Namespace $ns -Class SMS_PackageStatusDistPointsSummarizer -Filter "PackageID='$pkg'" -ErrorAction SilentlyContinue)
    if ($rows.Count -eq 0) { $out.Add('DPSTATE none -- no summarizer row') }
    foreach ($r in $rows) { $out.Add("DPSTATE $(& $serverFromNal $r.ServerNALPath) State=$($r.State) DPVersion=$($r.SourceVersion)") }
    return $out.ToArray()
}

$resetBlock = {
    param($siteCode, $pkgId)
    $out = New-Object System.Collections.Generic.List[string]
    try {
        Import-Module (Join-Path (Split-Path $env:SMS_ADMIN_UI_PATH) 'ConfigurationManager.psd1') -ErrorAction Stop
        if (-not (Get-PSDrive -Name $siteCode -PSProvider CMSite -ErrorAction SilentlyContinue)) {
            [void](New-PSDrive -Name $siteCode -PSProvider CMSite -Root $env:COMPUTERNAME -ErrorAction Stop)
        }
        Set-Location "$($siteCode):\" -ErrorAction Stop
    }
    catch { $out.Add("__ABSENT__ could not open the CM drive: $($_.Exception.Message)"); return $out.ToArray() }

    $ns = "root\SMS\site_$siteCode"
    $boot = $null
    if ($pkgId) { $boot = Get-WmiObject -Namespace $ns -Class SMS_BootImagePackage -Filter "PackageID='$pkgId'" -ErrorAction SilentlyContinue | Select-Object -First 1 }
    else { $boot = @(Get-WmiObject -Namespace $ns -Class SMS_BootImagePackage -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'Boot image (x64)' }) | Select-Object -First 1 }
    if (-not $boot) { $out.Add('__ABSENT__ no x64 boot image found'); return $out.ToArray() }
    $pkg = "$($boot.PackageID)"

    $serverFromNal = { param($nal) if ("$nal" -match '\\\\([^\\"]+)') { $Matches[1] } else { '' } }
    $targets = @(Get-WmiObject -Namespace $ns -Class SMS_DistributionPoint -Filter "PackageID='$pkg'" -ErrorAction SilentlyContinue)
    foreach ($t in $targets) {
        $dp = & $serverFromNal $t.ServerNALPath
        if (-not $dp) { continue }
        try {
            Remove-CMContentDistribution -BootImageId $pkg -DistributionPointName $dp -Force -ErrorAction Stop
            $out.Add("RESET removed content destination $dp")
        }
        catch { $out.Add("RESET FAILED to remove $dp : $($_.Exception.Message)") }
    }
    if ($targets.Count -eq 0) { $out.Add('RESET no content destination to remove (already clear)') }

    try {
        Set-CMBootImage -Id $pkg -EnableCommandSupport $false -ErrorAction Stop
        $out.Add('RESET disabled command support (next Phase 8 enable can bump SourceVersion)')
    }
    catch { $out.Add("RESET FAILED to disable command support: $($_.Exception.Message)") }
    return $out.ToArray()
}

function Invoke-Site {
    param([scriptblock]$Block, [object[]]$ArgList, [string]$Tag)
    $r = $null
    try {
        $r = Invoke-VmCommand -VmName $primary.vmName -VmDomainName $dom -ScriptBlock $Block `
            -ArgumentList $ArgList -SuppressLog -AsJob -TimeoutSeconds 180 -DisplayName $Tag
    }
    catch { & $say "$Tag threw: $($_.Exception.Message)" 'Red'; return $null }
    if (-not $r -or $r.ScriptBlockFailed -or $null -eq $r.ScriptBlockOutput) {
        & $say "$Tag produced no output (failed=$($r.ScriptBlockFailed) timedOut=$($r.TimedOut))" 'Red'
        return $null
    }
    return @($r.ScriptBlockOutput)
}

$collected = 0

if ($Reset) {
    & $say '--- RESET (removes the OSD DP content destination and disables command support) ---' 'Yellow'
    $lines = Invoke-Site -Block $resetBlock -ArgList @($primary.siteCode, $PackageId) -Tag 'bootimage reset'
    if ($lines) { $collected++; foreach ($l in $lines) { & $say "  $l" } }
}

& $say '--- STATE ---' 'Yellow'
$stateLines = Invoke-Site -Block $stateBlock -ArgList @($primary.siteCode, $PackageId) -Tag 'bootimage state'
if ($stateLines) { $collected++; foreach ($l in $stateLines) { & $say "  $l" } }

if ($Watch) {
    & $say "--- WATCH (every ${IntervalSeconds}s, max ${MaxMinutes}m) ---" 'Yellow'
    $started = Get-Date
    $deadline = $started.AddMinutes($MaxMinutes)
    $converged = $false
    $lastKey = ''
    while ((Get-Date) -lt $deadline -and -not $converged) {
        Start-Sleep -Seconds $IntervalSeconds
        $lines = Invoke-Site -Block $stateBlock -ArgList @($primary.siteCode, $PackageId) -Tag 'bootimage watch'
        if (-not $lines) { continue }
        $collected++
        $key = ($lines -join '|')
        if ($key -ne $lastKey) {
            $lastKey = $key
            foreach ($l in $lines) { & $say "  $l" }
        }
        $srcVer = ''
        foreach ($l in $lines) { if ($l -match 'SourceVersion=(\d+)') { $srcVer = $Matches[1]; break } }
        $dpStates = @($lines | Where-Object { $_ -like 'DPSTATE *' })
        if ($srcVer -and $dpStates.Count -gt 0) {
            # Anchored: without the $, DPVersion=3 would also match DPVersion=30.
            $bad = @($dpStates | Where-Object { $_ -notmatch "State=0 DPVersion=$srcVer$" })
            if ($bad.Count -eq 0) {
                $converged = $true
                & $say ("CONVERGED after {0:hh\:mm\:ss}: every OSD DP is State=0 at SourceVersion=$srcVer" -f ((Get-Date) - $started)) 'Green'
            }
        }
    }
    if (-not $converged) { & $say "NOT CONVERGED within ${MaxMinutes}m -- this is the failure the Phase 8 gate reports." 'Red' }
}

if ($collected -eq 0) {
    & $say 'NOTHING MEASURED: every in-guest call failed -- this run is not evidence.' 'Red'
    exit 1
}
& $say "done. log: $logPath" 'Green'
