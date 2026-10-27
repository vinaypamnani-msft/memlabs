<#
.SYNOPSIS
    Rebuilds azureFiles\support\baselines.zip with the MEMLABS Configuration Item
    discovery/remediation scripts corrected to EMIT A BOOLEAN VALUE to stdout.

.DESCRIPTION
    Root cause (confirmed via Get-CMBaselineDiagnostics on fabrikam.com): 5 of the
    7 MEMLABS script CIs are Boolean settings whose rule is "value Equals True", but
    their discovery scripts used `Exit 0` / `Exit 1` and wrote NOTHING to stdout.
    ConfigMgr script-CI discovery reads the discovered value from the script's
    OUTPUT STREAM and ignores the process exit code, so an Exit-only script yields
    an empty value -> DiscoveryFailure=True -> the baseline reports Non-Compliant
    (Exit 0) or a hard Error 0x80070001 "Incorrect function" (non-zero Exit, e.g.
    wuauserv stopped on Win11). The 2 working CIs (CCMCache Free Space, CM Log
    Settings) already emit their value via Write-Output/Write-Host.

    This tool downloads (or reuses) baselines.zip, expands each .cab, rewrites the
    broken script bodies to `Write-Output $true` / `Write-Output $false` while
    preserving every other byte of the CI XML, repackages each .cab with makecab,
    and rebuilds baselines.zip. It then prints the new MD5 so the Azure file
    manifest ("Prepopulate Baselines") can be updated and the rebuilt zip uploaded.

    The two already-correct cabs (CCMCache Free Space, CM Log Settings) are passed
    through unchanged.

.NOTES
    Run from the vmbuild root (or anywhere -- paths are resolved off $PSScriptRoot).
    Requires makecab.exe + expand.exe (in-box on Windows). The SAS token in
    StorageConfig is read-only, so this tool does NOT upload; it only rebuilds the
    artifact locally and reports the new hash.
#>
[CmdletBinding()]
param(
    [string]$BaselinesZip,
    [string]$OutputZip
)

$ErrorActionPreference = 'Stop'

$vmbuildRoot = Split-Path -Parent $PSScriptRoot
if (-not $BaselinesZip) { $BaselinesZip = Join-Path $vmbuildRoot 'azureFiles\support\baselines.zip' }
if (-not $OutputZip) { $OutputZip = $BaselinesZip }

# ---- Corrected script bodies, keyed by "<cab base name>|<Discovery|Remediation>" ----
# Every branch ends by writing a Boolean to the output stream (no Exit codes).
$fixes = @{
    'MEMLABS-Check .Net4.8 is installed|Discovery'  = @'
# Check for .NET Framework 4.8 (emit Boolean to stdout -- CM reads the discovered
# value from output, NOT the exit code)
$netFrameworkKey = "HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full"
if (Test-Path $netFrameworkKey) {
    $releaseValue = (Get-ItemProperty -Path $netFrameworkKey).Release
    if ($releaseValue -ge 528040) { Write-Output $true } else { Write-Output $false }
} else {
    Write-Output $false
}
'@

    'MEMLABS-Check disk space|Discovery'            = @'
# Check C: free space > 10 GB (emit Boolean to stdout)
$drive = Get-PSDrive -Name C
if ($drive.Free -gt 10GB) { Write-Output $true } else { Write-Output $false }
'@

    'MEMLABS-Check last boot was with in 7 days|Discovery' = @'
# Check last boot within 7 days (emit Boolean to stdout)
$lastBootTime = (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime
if ($null -eq $lastBootTime) {
    Write-Output $false
} else {
    $daysSinceLastBoot = (Get-Date) - $lastBootTime
    if ($daysSinceLastBoot.TotalDays -le 7) { Write-Output $true } else { Write-Output $false }
}
'@

    'MEMLABS-Check windows firewall|Discovery'      = @'
# Check Windows Firewall service (MpsSvc) running (emit Boolean to stdout)
$firewallService = Get-Service -Name "MpsSvc" -ErrorAction SilentlyContinue
if ($firewallService -and $firewallService.Status -eq "Running") { Write-Output $true } else { Write-Output $false }
'@

    'MEMLABS-Check windows firewall|Remediation'    = @'
# Ensure Windows Firewall service (MpsSvc) is running (emit Boolean to stdout)
$firewallService = Get-Service -Name "MpsSvc" -ErrorAction SilentlyContinue
if ($firewallService -and $firewallService.Status -ne "Running") {
    try { Start-Service -Name "MpsSvc" -ErrorAction Stop; Write-Output $true } catch { Write-Output $false }
} elseif ($firewallService -and $firewallService.Status -eq "Running") {
    Write-Output $true
} else {
    Write-Output $false
}
'@

    'MEMLABS-Check Windows update|Discovery'         = @'
# Check Windows Update service (wuauserv) running (emit Boolean to stdout)
$updateService = Get-Service -Name "wuauserv" -ErrorAction SilentlyContinue
if ($updateService -and $updateService.Status -eq "Running") { Write-Output $true } else { Write-Output $false }
'@

    'MEMLABS-Check Windows update|Remediation'       = @'
# Ensure Windows Update service (wuauserv) is running (emit Boolean to stdout)
$updateService = Get-Service -Name "wuauserv" -ErrorAction SilentlyContinue
if ($updateService -and $updateService.Status -ne "Running") {
    try { Start-Service -Name "wuauserv" -ErrorAction Stop; Write-Output $true } catch { Write-Output $false }
} elseif ($updateService -and $updateService.Status -eq "Running") {
    Write-Output $true
} else {
    Write-Output $false
}
'@
}

if (-not (Test-Path $BaselinesZip)) {
    throw "baselines.zip not found at $BaselinesZip. Download it first (Get-File -Source `"`$(`$StorageConfig.StorageLocation)/support/baselines.zip`" -Destination $BaselinesZip -Action Downloading)."
}

$work = Join-Path $env:TEMP ("baselines-repair-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
$expandDir = Join-Path $work 'expand'
$cabDir = Join-Path $work 'cabs'
$rebuiltCabs = Join-Path $work 'rebuilt'
New-Item -ItemType Directory -Path $expandDir, $cabDir, $rebuiltCabs -Force | Out-Null

Write-Host "Expanding $BaselinesZip ..." -ForegroundColor Cyan
Expand-Archive -Path $BaselinesZip -DestinationPath $cabDir -Force
$cabFiles = Get-ChildItem -Path $cabDir -Recurse -Filter '*.cab'
Write-Host "Found $($cabFiles.Count) cab(s)." -ForegroundColor Cyan

# The leaf folder the cabs live in inside the zip (e.g. 'baselines')
$cabParent = Split-Path -Leaf (Split-Path -Parent $cabFiles[0].FullName)

foreach ($cab in $cabFiles) {
    $cabBase = [System.IO.Path]::GetFileNameWithoutExtension($cab.Name)
    $ex = Join-Path $expandDir $cabBase
    New-Item -ItemType Directory -Path $ex -Force | Out-Null
    & expand.exe $cab.FullName -F:* $ex | Out-Null

    $xmlFile = Get-ChildItem -Path $ex -Filter '*.xml' | Select-Object -First 1
    $raw = [System.IO.File]::ReadAllText($xmlFile.FullName)
    $changed = $false

    foreach ($bodyType in 'Discovery', 'Remediation') {
        $key = "$cabBase|$bodyType"
        if (-not $fixes.ContainsKey($key)) { continue }
        $newScript = $fixes[$key]
        $tag = "${bodyType}ScriptBody"
        $pattern = "(?s)(<$tag\b[^>]*>)(.*?)(</$tag>)"
        $evaluator = {
            param($m)
            # MatchEvaluator returns the replacement literally -- no $-expansion,
            # which is essential because the scripts are full of $variables.
            $m.Groups[1].Value + "`n" + $script:newScriptLocal + "`n" + $m.Groups[3].Value
        }
        $script:newScriptLocal = $newScript
        $updated = [System.Text.RegularExpressions.Regex]::Replace($raw, $pattern, $evaluator)
        if ($updated -ne $raw) {
            $raw = $updated
            $changed = $true
            Write-Host ("  [{0}] {1} script corrected" -f $cabBase, $bodyType) -ForegroundColor Green
        }
    }

    if ($changed) {
        # Write back without adding a BOM (CM exported these as UTF-8 no BOM)
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($xmlFile.FullName, $raw, $utf8NoBom)

        # Repackage the cab with both member files, preserving their leaf names.
        $ddf = Join-Path $ex 'rebuild.ddf'
        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add('.OPTION EXPLICIT')
        $lines.Add(".Set CabinetNameTemplate=$($cab.Name)")
        $lines.Add(".Set DiskDirectoryTemplate=$rebuiltCabs")
        $lines.Add('.Set CompressionType=MSZIP')
        $lines.Add('.Set Cabinet=ON')
        $lines.Add('.Set Compress=ON')
        $lines.Add('.Set MaxDiskSize=0')
        foreach ($member in Get-ChildItem -Path $ex -File | Where-Object { $_.Extension -in '.xml', '.resx' }) {
            $lines.Add('"' + $member.FullName + '"')
        }
        [System.IO.File]::WriteAllLines($ddf, $lines)
        & makecab.exe /F $ddf | Out-Null
        if (-not (Test-Path (Join-Path $rebuiltCabs $cab.Name))) {
            throw "makecab failed to produce $($cab.Name)"
        }
    }
    else {
        # Unchanged cab (already-correct CI) -- copy through as-is.
        Copy-Item -Path $cab.FullName -Destination (Join-Path $rebuiltCabs $cab.Name) -Force
        Write-Host ("  [{0}] passed through unchanged" -f $cabBase) -ForegroundColor DarkGray
    }
}

# Reassemble the zip with the same internal folder layout (<cabParent>\*.cab)
$stage = Join-Path $work 'stage'
$stageInner = Join-Path $stage $cabParent
New-Item -ItemType Directory -Path $stageInner -Force | Out-Null
Copy-Item -Path (Join-Path $rebuiltCabs '*.cab') -Destination $stageInner -Force

if (Test-Path $OutputZip) { Remove-Item $OutputZip -Force }
Compress-Archive -Path (Join-Path $stage $cabParent) -DestinationPath $OutputZip -Force

$md5 = (Get-FileHash -Path $OutputZip -Algorithm MD5).Hash
Write-Host ""
Write-Host "Rebuilt: $OutputZip" -ForegroundColor Cyan
Write-Host "New MD5: $md5" -ForegroundColor Yellow
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. Upload this baselines.zip to Azure: <storage>/files/support/baselines.zip" -ForegroundColor Gray
Write-Host "  2. Update the 'Prepopulate Baselines' md5 in the file manifest to $md5" -ForegroundColor Gray
Write-Host "  Work dir (inspect/cleanup): $work" -ForegroundColor DarkGray
