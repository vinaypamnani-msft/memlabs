<#
.SYNOPSIS
    Trigger and monitor an in-console ConfigMgr site update (e.g. 2503 -> 2603)
    on an already-built MEMLABS lab, from the Hyper-V host.

.DESCRIPTION
    New-Lab installs a baseline and updates to cmOptions.version in one pass, so
    there is no supported way to move a FINISHED lab to a newer in-console
    version. This script does that: it PSDirects into the top-level site server,
    finds the update package matching -TargetVersion, installs it, and follows
    the state machine until it reaches INSTALL_SUCCESS.

    Built for the policy-churn repro (case 2608010010000636): the site upgrade is
    what makes clients purge and re-request policy, and it is during that
    re-request -- while the projected policy set is still incomplete -- that the
    Policy Platform can decide previously-intended settings are orphaned and
    revert them. Run Watch-PolicyChurn.ps1 against the clients BEFORE starting
    this, so the drop is captured live.

    Read-only until -Install is passed. Without it the script only reports which
    updates the site can see and what state they are in.

.PARAMETER DomainName
    The lab domain (e.g. pchurn.com). If omitted, lists the domains it can see.

.PARAMETER TargetVersion
    In-console version to move to, e.g. '2603'. Matched against the update
    package name ("Configuration Manager 2603").

.PARAMETER Install
    Actually install. Without this the script is report-only.

.PARAMETER TimeoutMinutes
    How long to follow the install before giving up reporting. Default 180.
    Giving up here does NOT cancel the update; it keeps running on the site.

.PARAMETER PollSeconds
    Seconds between state polls. Default 60.

.EXAMPLE
    cd C:\memlabs\vmbuild
    .\tools\Start-CMSiteUpgrade.ps1 -DomainName pchurn.com

.EXAMPLE
    .\tools\Start-CMSiteUpgrade.ps1 -DomainName pchurn.com -TargetVersion 2603 -Install
#>
[CmdletBinding()]
param(
    [string]$DomainName,
    [string]$TargetVersion,
    [switch]$Install,
    [int]$TimeoutMinutes = 180,
    [int]$PollSeconds = 60
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

$domainVMs = @($allVMs | Where-Object { $_.domain -eq $DomainName })
if ($domainVMs.Count -eq 0) {
    Write-Host "No VMs found for domain '$DomainName'." -ForegroundColor Red
    return
}

# Top-level site server = CAS if present, else the Primary with no parent.
$siteVM = $domainVMs | Where-Object { $_.role -eq 'CAS' -and -not $_.parentSiteCode } | Select-Object -First 1
if (-not $siteVM) {
    $siteVM = $domainVMs | Where-Object { $_.role -eq 'Primary' -and -not $_.parentSiteCode } | Select-Object -First 1
}
if (-not $siteVM) {
    Write-Host "No top-level CAS/Primary found in '$DomainName'." -ForegroundColor Red
    return
}

$siteVmNameRaw = $siteVM.vmName
if ($siteVmNameRaw -is [System.Array]) { $siteVmNameRaw = $siteVmNameRaw[0] }
[string]$siteVmName = "$siteVmNameRaw"

Write-Host "`n=== MEMLABS CM site upgrade ===" -ForegroundColor Cyan
Write-Host "Domain      : $DomainName"
Write-Host "Site server : $siteVmName ($($siteVM.role) $($siteVM.siteCode))"
Write-Host "Target      : $(if ($TargetVersion) { $TargetVersion } else { '(report only)' })"
Write-Host "Mode        : $(if ($Install) { 'INSTALL' } else { 'report only' })"
Write-Host ""

# Runs IN the site server. Connects to the CM PS drive, optionally kicks the
# install, and returns the current view of every update package.
$siteSB = {
    param($targetVersion, $doInstall)

    $out = [pscustomobject]@{
        Computer  = $env:COMPUTERNAME
        Error     = $null
        SiteCode  = $null
        Build     = $null
        Updates   = @()
        Triggered = $false
        Message   = $null
    }

    # State names lifted from InstallAndUpdateSCCM.ps1 so the two agree.
    $state = @{
        196608 = 'AVAILABLE'; 196609 = 'READYTOINSTALL'; 196610 = 'DOWNLOAD_IN_PROGRESS'
        196611 = 'DOWNLOAD_SUCCESS'; 196612 = 'INSTALL_SUCCESS'; 196613 = 'REPLICATION_IN_PROGRESS'
        196614 = 'REPLICATION_SUCCESS'; 196615 = 'PREREQ_IN_PROGRESS'; 196616 = 'PREREQ_SUCCESS'
        196617 = 'INSTALL_CMU_STARTED'; 196618 = 'INSTALL_CMU_SUCCESS'; 196619 = 'INSTALL_WAITING_CMU'
        196620 = 'INSTALL_INSTALLFILES'; 196621 = 'INSTALL_UPGRADESITECTRLIMAGE'
        196622 = 'INSTALL_CONFIGURESERVICEBROKER'; 196623 = 'INSTALL_INSTALLSYSTEM'
        196624 = 'INSTALL_CONSOLE'; 196625 = 'INSTALL_INSTALLBASESERVICES'
        196626 = 'INSTALL_UPDATE_SITES'; 196627 = 'INSTALL_SSB_ACTIVATION_ON'
        196628 = 'INSTALL_UPGRADEDATABASE'; 196629 = 'INSTALL_UPDATEADMINCONSOLE'
        196630 = 'INSTALL_WAITING_PARENT'; 262143 = 'INSTALL_FAILED'; 262142 = 'INSTALL_CMU_FAILED'
        327679 = 'DOWNLOAD_FAILED'; 327678 = 'REPLICATION_FAILED'; 327677 = 'PREREQ_FAILED'
    }

    try {
        $providerMachineName = $env:COMPUTERNAME
        $sitecode = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\SMS\Identification' -Name 'Site Code' -ErrorAction Stop).'Site Code'
        $out.SiteCode = $sitecode

        $modulePath = Join-Path (Split-Path $env:SMS_ADMIN_UI_PATH -Parent) 'ConfigurationManager.psd1'
        Import-Module $modulePath -ErrorAction Stop
        if (-not (Get-PSDrive -Name $sitecode -PSProvider CMSite -ErrorAction SilentlyContinue)) {
            $null = New-PSDrive -Name $sitecode -PSProvider CMSite -Root $providerMachineName -ErrorAction Stop
        }
        Set-Location "$sitecode`:" -ErrorAction Stop

        $siteObj = Get-CMSite -SiteCode $sitecode -ErrorAction SilentlyContinue
        if ($siteObj) { $out.Build = "$($siteObj.BuildNumber)" }

        $packs = @(Get-CMSiteUpdate -Fast -ErrorAction SilentlyContinue)
        foreach ($p in $packs) {
            $stateName = if ($state.ContainsKey([int]$p.State)) { $state[[int]$p.State] } else { "UNKNOWN($($p.State))" }
            $out.Updates += [pscustomobject]@{
                Name        = "$($p.Name)"
                State       = [int]$p.State
                StateName   = $stateName
                FullVersion = "$($p.FullVersion)"
                PackageGuid = "$($p.PackageGuid)"
            }
        }

        if ($doInstall -and $targetVersion) {
            $match = $packs | Where-Object { $_.Name -like "*$targetVersion*" } | Select-Object -First 1
            if (-not $match) {
                $out.Message = "No update package matching '*$targetVersion*'. Check the service connection point has synced."
                return $out
            }
            if ([int]$match.State -eq 196612) {
                $out.Message = "'$($match.Name)' is already INSTALL_SUCCESS. Nothing to do."
                return $out
            }
            Install-CMSiteUpdate -Name $match.Name -SkipPrerequisiteCheck -Force -ErrorAction Stop
            $out.Triggered = $true
            $out.Message = "Install-CMSiteUpdate invoked for '$($match.Name)'."
        }
    }
    catch {
        $out.Error = "$($_.Exception.Message)"
    }
    return $out
}

function Invoke-SiteQuery {
    param([string]$Version, [bool]$DoInstall)
    $res = Invoke-VmCommand -VmName $siteVmName -VmDomainName $DomainName -ScriptBlock $siteSB `
        -ArgumentList @($Version, $DoInstall) -DisplayName "CMSiteUpgrade" `
        -SuppressLog -AsJob -TimeoutSeconds 900
    if (-not $res -or $res.ScriptBlockFailed -or -not $res.ScriptBlockOutput) {
        $reason = if ($res -and $res.TimedOut) { 'timed out' } elseif ($res -and $res.ScriptBlockFailed) { 'scriptblock failed' } else { 'no session/output' }
        Write-Host "  PSDirect to $siteVmName : $reason" -ForegroundColor Red
        return $null
    }
    return $res.ScriptBlockOutput
}

$data = Invoke-SiteQuery -Version $TargetVersion -DoInstall:$Install.IsPresent
if (-not $data) { return }
if ($data.Error) {
    Write-Host "Site error: $($data.Error)" -ForegroundColor Red
    return
}

Write-Host "Site $($data.SiteCode) build $($data.Build)" -ForegroundColor Green
Write-Host "`nUpdates visible to the site:" -ForegroundColor Yellow
if ($data.Updates.Count -eq 0) {
    Write-Host "  (none -- the service connection point may not have synced yet)" -ForegroundColor DarkYellow
}
foreach ($u in ($data.Updates | Sort-Object Name)) {
    Write-Host ("  {0,-45} {1,-28} {2}" -f $u.Name, $u.StateName, $u.FullVersion)
}
if ($data.Message) { Write-Host "`n$($data.Message)" -ForegroundColor Cyan }

if (-not $Install) {
    Write-Host "`nReport only. Re-run with -TargetVersion <ver> -Install to start the upgrade." -ForegroundColor Cyan
    return
}
if (-not $data.Triggered) { return }

# --- follow the state machine -------------------------------------------
$terminal = @(196612)
$failed = @(262143, 262142, 327679, 327678, 327677)
$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
$lastState = ''

Write-Host "`nFollowing install (timeout ${TimeoutMinutes}m, poll ${PollSeconds}s). Ctrl-C is safe -- the update keeps going." -ForegroundColor Yellow

while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds $PollSeconds
    $poll = Invoke-SiteQuery -Version $TargetVersion -DoInstall $false
    if (-not $poll -or $poll.Error) { continue }

    $pack = $poll.Updates | Where-Object { $_.Name -like "*$TargetVersion*" } | Select-Object -First 1
    if (-not $pack) { continue }

    if ($pack.StateName -ne $lastState) {
        Write-Host ("  {0}  {1,-30} build {2}" -f (Get-Date -Format 'HH:mm:ss'), $pack.StateName, $poll.Build) -ForegroundColor Gray
        $lastState = $pack.StateName
    }

    if ($terminal -contains $pack.State) {
        Write-Host "`nUpdate reached INSTALL_SUCCESS. Site build is now $($poll.Build)." -ForegroundColor Green
        Write-Host "Clients will now purge and re-request policy -- this is the churn window." -ForegroundColor Cyan
        return
    }
    if ($failed -contains $pack.State) {
        Write-Host "`nUpdate reached $($pack.StateName). Check cmupdate.log / CMUpdate on $siteVmName." -ForegroundColor Red
        return
    }
}

Write-Host "`nStopped following after ${TimeoutMinutes}m (last state: $lastState). The update is still running on the site." -ForegroundColor Yellow
