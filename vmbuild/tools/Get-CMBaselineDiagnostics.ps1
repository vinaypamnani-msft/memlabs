<#
.SYNOPSIS
    Collect the data needed to diagnose why MEMLABS Configuration Baselines
    (imported by perfloading.ps1) report "Error" or "Non-Compliant" on clients.

    Runs ENTIRELY FROM THE HYPER-V HOST. It dot-sources the memlabs Common.ps1
    and uses Invoke-VmCommand (PowerShell Direct) to reach into every VM it
    wants data from -- no WinRM, no network logon, no agent on the guest.

.DESCRIPTION
    perfloading.ps1 imports a set of Configuration Items from
    azureFiles\support\baselines.zip, wraps each in a Configuration Baseline,
    and deploys it to "All Systems" with enforcement. Several of those CIs use
    PowerShell discovery/remediation scripts (hence the MEMLABS-powershellbypass
    client setting). The CAB rule definitions are binary and not in the repo, so
    the only way to know WHY a given baseline is Error vs Non-Compliant is to
    read each client's own DCM compliance detail plus the matching CI rule XML
    from the site server. This script gathers both, from one place.

    For the named domain it:
      1. Enumerates every Running Windows VM (Get-List) and PSDirects into each
         to pull its DCM state: per-baseline SMS_DesiredConfiguration +
         ComplianceDetails XML (which distinguishes "a rule evaluated False" =
         Non-Compliant from "a discovery script/WMI threw" = Error), per-CI
         SMS_DCMCIComplianceState, the effective PowerShell execution policy
         (OS + CM client setting), and the tail of the relevant CCM\Logs\*.log.
      2. PSDirects into each CAS/Primary site server to dump every baseline's
         linked-CI count (flags the empty-baseline bug) and the CI SDMPackageXML
         (the actual rule: setting source, expected value, remediation on/off,
         supported platforms).

    Everything is written to the host under vmbuild\logs\baseline-diag\. Nothing
    in any guest is modified (read-only; -TriggerEvaluation only asks the DCM
    agent to re-evaluate, which it does on its own schedule anyway).

.PARAMETER DomainName
    The lab domain (e.g. adatum.com). If omitted, the script lists the domains
    it can see and exits.

.PARAMETER NamePattern
    Only collect baselines whose name matches this wildcard. Default '*'.

.PARAMETER TriggerEvaluation
    Ask each client's DCM agent to re-evaluate its baselines (and wait ~90s)
    before collecting, so the compliance detail is current rather than stale.

.PARAMETER ClientsOnly
    Only do the per-client DCM collection (skip the site-server CI-XML dump).

.PARAMETER SiteOnly
    Only do the site-server CI-XML dump (skip the per-client collection).

.PARAMETER OutputPath
    Folder to write into. Default: vmbuild\logs\baseline-diag\<domain>-<stamp>.

.PARAMETER TimeoutSeconds
    Per-VM PSDirect job timeout. Default 300 (covers -TriggerEvaluation's wait).

.EXAMPLE
    cd C:\memlabs\vmbuild
    .\tools\Get-CMBaselineDiagnostics.ps1 -DomainName adatum.com -TriggerEvaluation

.EXAMPLE
    .\tools\Get-CMBaselineDiagnostics.ps1            # lists the domains it sees
#>
[CmdletBinding()]
param(
    [string]$DomainName,
    [string]$NamePattern = '*',
    [switch]$TriggerEvaluation,
    [switch]$ClientsOnly,
    [switch]$SiteOnly,
    [string]$OutputPath,
    [int]$TimeoutSeconds = 300
)

$ErrorActionPreference = 'Stop'

# --- Load memlabs Common.ps1 (lives in vmbuild\, the parent of tools\) -------
$vmbuildRoot = Split-Path -Parent $PSScriptRoot
Set-Location $vmbuildRoot
$commonPath = Join-Path $vmbuildRoot 'Common.ps1'
$bomBytes = [System.IO.File]::ReadAllBytes($commonPath)[0..2]
if (-not ($bomBytes[0] -eq 0xEF -and $bomBytes[1] -eq 0xBB -and $bomBytes[2] -eq 0xBF)) {
    Write-Host "ERROR: Common.ps1 is missing UTF-8 BOM. PS5.1 will fail to parse it." -ForegroundColor Red
    Write-Host "Run: git checkout -- vmbuild/Common.ps1" -ForegroundColor Yellow
    exit 1
}
. $commonPath -InJob   # initializes $Common (incl. $Common.LocalAdmin) + Get-List + Invoke-VmCommand

# --- Resolve the domain / VM list -------------------------------------------
$allVMs = @(Get-List -Type VM -SmartUpdate)
if (-not $DomainName) {
    Write-Host "`nNo -DomainName given. Domains I can see:" -ForegroundColor Yellow
    $allVMs | Group-Object -Property domain | Sort-Object Name | ForEach-Object {
        Write-Host ("  {0}  ({1} VM(s))" -f $_.Name, $_.Count)
    }
    Write-Host "`nRe-run with -DomainName <domain>." -ForegroundColor Cyan
    return
}

$domainVMs = @($allVMs | Where-Object { $_.domain -eq $DomainName })
if ($domainVMs.Count -eq 0) {
    Write-Host "No VMs found for domain '$DomainName'. Known domains:" -ForegroundColor Red
    $allVMs | Group-Object -Property domain | ForEach-Object { Write-Host "  $($_.Name)" }
    return
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if (-not $OutputPath) {
    $OutputPath = Join-Path $vmbuildRoot "logs\baseline-diag\$DomainName-$stamp"
}
if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }

Write-Host "`n=== MEMLABS Configuration Baseline diagnostics ===" -ForegroundColor Cyan
Write-Host "Domain : $DomainName"
Write-Host "Output : $OutputPath"
Write-Host ""

# Roles that never run a CM client (skip on the client pass).
$skipClientRoles = @('OSDClient', 'AADClient', 'StandaloneRootCA', 'Linux')
$complianceMap = @{ 0 = 'Non-Compliant'; 1 = 'Compliant'; 2 = 'Submitted'; 3 = 'Unknown'; 4 = 'Detecting'; 5 = 'NotEvaluated' }
$psPolMap = @{ 0 = 'AllSigned'; 1 = 'Bypass'; 2 = 'Restricted'; 3 = 'Unrestricted' }

# =====================================================================
# Client-side scriptblock (runs IN each guest via PowerShell Direct).
# Returns a single PSCustomObject of strings/arrays -- serializes cleanly.
# =====================================================================
$clientSB = {
    param($pattern, $doTrigger)
    $dcmNs = 'root\ccm\dcm'
    $out = [pscustomobject]@{
        Computer   = $env:COMPUTERNAME
        Error      = $null
        Baselines  = @()
        CIStates   = @()
        ExecPolicy = @()
        CMPsPolicy = $null
        Logs       = @()
    }
    try {
        $bls = @(Get-CimInstance -Namespace $dcmNs -ClassName SMS_DesiredConfiguration -ErrorAction Stop | Where-Object { $_.Name -like $pattern })
    }
    catch {
        $out.Error = "DCM read failed (client installed?): $($_.Exception.Message)"
        return $out
    }
    if ($doTrigger -and $bls.Count -gt 0) {
        foreach ($b in $bls) {
            try { Invoke-CimMethod -Namespace $dcmNs -ClassName SMS_DesiredConfiguration -MethodName TriggerEvaluation -Arguments @{ Name = $b.Name; Version = $b.Version } -ErrorAction SilentlyContinue | Out-Null } catch { }
        }
        Start-Sleep -Seconds 90
        $bls = @(Get-CimInstance -Namespace $dcmNs -ClassName SMS_DesiredConfiguration -ErrorAction SilentlyContinue | Where-Object { $_.Name -like $pattern })
    }
    foreach ($b in $bls) {
        $out.Baselines += [pscustomobject]@{
            Name                 = $b.Name
            Version              = $b.Version
            LastComplianceStatus = $b.LastComplianceStatus
            LastEvalTime         = "$($b.LastEvalTime)"
            IsMachineTarget      = $b.IsMachineTarget
            PolicyType           = $b.PolicyType
            ComplianceDetails    = $b.ComplianceDetails
        }
    }
    try {
        $out.CIStates = @(Get-CimInstance -Namespace $dcmNs -ClassName SMS_DCMCIComplianceState -ErrorAction SilentlyContinue | ForEach-Object {
                [pscustomobject]@{ DisplayName = $_.DisplayName; ComplianceState = $_.ComplianceState; LastChange = "$($_.LastComplianceStatusChange)" }
            })
    }
    catch { }
    try { $out.ExecPolicy = @(Get-ExecutionPolicy -List | ForEach-Object { "$($_.Scope)=$($_.ExecutionPolicy)" }) } catch { }
    try {
        $cfg = Get-CimInstance -Namespace 'root\ccm\Policy\Machine\ActualConfig' -ClassName CCM_ConfigurationManagementClientConfig -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cfg -and ($null -ne $cfg.PowerShellExecutionPolicy)) { $out.CMPsPolicy = $cfg.PowerShellExecutionPolicy }
    }
    catch { }
    $ccmLogDir = Join-Path $env:WinDir 'CCM\Logs'
    foreach ($n in @('DCMAgent.log', 'DCMReporting.log', 'CIAgent.log', 'CITaskMgr.log', 'CIStateStore.log', 'CIDownloader.log', 'PolicyEvaluator.log')) {
        $p = Join-Path $ccmLogDir $n
        if (Test-Path $p) {
            try { $out.Logs += [pscustomobject]@{ Name = $n; Text = ((Get-Content $p -Tail 1500 -ErrorAction SilentlyContinue) -join "`r`n") } } catch { }
        }
    }
    return $out
}

# =====================================================================
# Site-side scriptblock (runs ON each CAS/Primary via PowerShell Direct).
# =====================================================================
$siteSB = {
    param($pattern)
    $out = [pscustomobject]@{ Computer = $env:COMPUTERNAME; Error = $null; Baselines = @() }
    $mod = $env:SMS_ADMIN_UI_PATH
    if ($mod) { $mod = Join-Path (Split-Path $mod) 'ConfigurationManager.psd1' }
    if ($mod -and (Test-Path $mod)) { Import-Module $mod -ErrorAction SilentlyContinue }
    if (-not (Get-Module ConfigurationManager)) { $out.Error = 'ConfigurationManager module not available on this box'; return $out }
    $site = Get-PSDrive -PSProvider CMSite -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $site) { $out.Error = 'No CMSite PSDrive (console never connected here)'; return $out }
    Push-Location ("$($site.Name):\")
    try {
        $bls = @(Get-CMBaseline -Fast | Where-Object { $_.LocalizedDisplayName -like $pattern })
        foreach ($bl in $bls) {
            $linked = 0
            $ciXml = $null
            try {
                $full = Get-CMBaseline -Name $bl.LocalizedDisplayName
                [xml]$x = $full.SDMPackageXML
                $linked = @($x.SelectNodes("//*[local-name()='ConfigurationItemReference']")).Count
            }
            catch { }
            try {
                $ciFull = Get-CMConfigurationItem -Name $bl.LocalizedDisplayName | Select-Object -First 1
                if ($ciFull) { $ciXml = $ciFull.SDMPackageXML }
            }
            catch { }
            $out.Baselines += [pscustomobject]@{ Name = $bl.LocalizedDisplayName; CI_ID = $bl.CI_ID; LinkedCount = $linked; CiXml = $ciXml }
        }
    }
    finally { Pop-Location }
    return $out
}

# --- helper: safe filename ---------------------------------------------------
function ConvertTo-SafeName { param([string]$n) return ($n -replace '[^\w\-]', '_') }

$summary = New-Object System.Collections.Generic.List[string]
$summary.Add("=== MEMLABS Configuration Baseline diagnostics ===")
$summary.Add("Domain : $DomainName")
$summary.Add("When   : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
$summary.Add("")

# =====================================================================
# Pass 1: per-client DCM collection
# =====================================================================
if (-not $SiteOnly) {
    $clientVMs = @($domainVMs | Where-Object { $_.role -notin $skipClientRoles -and $_.state -eq 'Running' } | Sort-Object vmName)
    Write-Host "Client pass: $($clientVMs.Count) Running VM(s)" -ForegroundColor Yellow
    $summary.Add("----- CLIENT compliance ($($clientVMs.Count) VM(s)) -----")

    foreach ($vm in $clientVMs) {
        $vmName = $vm.vmName
        Write-Host "  PSDirect -> $vmName ..." -ForegroundColor DarkGray -NoNewline
        $res = Invoke-VmCommand -VmName $vmName -VmDomainName $DomainName -ScriptBlock $clientSB `
            -ArgumentList @($NamePattern, [bool]$TriggerEvaluation) -DisplayName "BaselineDiag-Client" `
            -SuppressLog -AsJob -TimeoutSeconds $TimeoutSeconds

        if (-not $res -or $res.ScriptBlockFailed -or -not $res.ScriptBlockOutput) {
            $reason = if ($res -and $res.TimedOut) { 'timed out' } elseif ($res -and $res.ScriptBlockFailed) { 'scriptblock failed' } else { 'no session/output' }
            Write-Host " $reason" -ForegroundColor Red
            $summary.Add("  $vmName : SKIPPED ($reason)")
            continue
        }
        $data = $res.ScriptBlockOutput
        if ($data.Error) {
            Write-Host " $($data.Error)" -ForegroundColor DarkYellow
            $summary.Add("  $vmName : $($data.Error)")
            continue
        }

        $vmDir = Join-Path $OutputPath "clients\$vmName"
        if (-not (Test-Path $vmDir)) { New-Item -ItemType Directory -Path $vmDir -Force | Out-Null }

        $rep = New-Object System.Collections.Generic.List[string]
        $rep.Add("Computer : $($data.Computer)")
        $rep.Add("Baselines: $(@($data.Baselines).Count)")
        $rep.Add("")

        $badCount = 0
        foreach ($b in @($data.Baselines)) {
            $code = $b.LastComplianceStatus
            $stateName = $complianceMap[[int]$code]
            if (-not $stateName) { $stateName = "raw=$code" }
            if ($stateName -ne 'Compliant') { $badCount++ }
            $rep.Add("----- $($b.Name) (v$($b.Version)) -----")
            $rep.Add("  LastComplianceStatus : $code ($stateName)")
            $rep.Add("  LastEvalTime         : $($b.LastEvalTime)")
            if ($b.ComplianceDetails) {
                $xmlFile = Join-Path $vmDir ("compliance-{0}.xml" -f (ConvertTo-SafeName $b.Name))
                Set-Content -Path $xmlFile -Value $b.ComplianceDetails -Encoding UTF8
                $rep.Add("  ComplianceDetails    -> $(Split-Path $xmlFile -Leaf)")
                $hits = Select-String -Path $xmlFile -Pattern 'Error|Exception|0x[0-9A-Fa-f]{8}|ScriptExecution|not be loaded|execution policy' -ErrorAction SilentlyContinue | Select-Object -First 6
                foreach ($h in $hits) {
                    $t = $h.Line.Trim(); if ($t.Length -gt 200) { $t = $t.Substring(0, 200) }
                    $rep.Add("    detail> $t")
                }
            }
            else {
                $rep.Add("  (no ComplianceDetails yet -- try -TriggerEvaluation)")
            }
            $rep.Add("")
        }

        if (@($data.CIStates).Count -gt 0) {
            $rep.Add("----- Per-CI compliance (SMS_DCMCIComplianceState) -----")
            foreach ($s in @($data.CIStates)) { $rep.Add("  $($s.DisplayName)  state=$($s.ComplianceState)  lastChange=$($s.LastChange)") }
            $rep.Add("")
        }

        $rep.Add("----- PowerShell execution policy -----")
        foreach ($e in @($data.ExecPolicy)) { $rep.Add("  OS  $e") }
        if ($null -ne $data.CMPsPolicy) {
            $pName = $psPolMap[[int]$data.CMPsPolicy]; if (-not $pName) { $pName = "raw=$($data.CMPsPolicy)" }
            $rep.Add("  CM client setting PowerShellExecutionPolicy = $($data.CMPsPolicy) ($pName)")
            if ([int]$data.CMPsPolicy -ne 1 -and [int]$data.CMPsPolicy -ne 3) {
                $rep.Add("  *** NOT Bypass/Unrestricted -- script-based CIs will likely ERROR until MEMLABS-powershellbypass applies. ***")
            }
        }
        else {
            $rep.Add("  CM client setting PowerShellExecutionPolicy = (not set / policy not received)")
            $rep.Add("  *** MEMLABS-powershellbypass has not reached this client -- script CIs will ERROR. ***")
        }
        $rep.Add("")

        if (@($data.Logs).Count -gt 0) {
            $logDest = Join-Path $vmDir 'ccmlogs'
            if (-not (Test-Path $logDest)) { New-Item -ItemType Directory -Path $logDest -Force | Out-Null }
            foreach ($lg in @($data.Logs)) { Set-Content -Path (Join-Path $logDest $lg.Name) -Value $lg.Text -Encoding UTF8 }
            $rep.Add("CCM logs copied: $((@($data.Logs)).Name -join ', ')")
        }

        $rep | Set-Content -Path (Join-Path $vmDir 'baseline-report.txt') -Encoding UTF8
        Write-Host " $(@($data.Baselines).Count) baseline(s), $badCount not-compliant/error" -ForegroundColor Green
        $summary.Add("  $vmName : $(@($data.Baselines).Count) baseline(s), $badCount not-compliant/error")
    }
    $summary.Add("")
}

# =====================================================================
# Pass 2: site-server CI rule XML
# =====================================================================
if (-not $ClientsOnly) {
    $siteVMs = @($domainVMs | Where-Object { $_.role -in @('CAS', 'Primary') -and $_.state -eq 'Running' } | Sort-Object vmName)
    Write-Host "Site pass: $($siteVMs.Count) site server(s)" -ForegroundColor Yellow
    $summary.Add("----- SITE CI definitions ($($siteVMs.Count) site server(s)) -----")

    foreach ($vm in $siteVMs) {
        $vmName = $vm.vmName
        Write-Host "  PSDirect -> $vmName ..." -ForegroundColor DarkGray -NoNewline
        $res = Invoke-VmCommand -VmName $vmName -VmDomainName $DomainName -ScriptBlock $siteSB `
            -ArgumentList @($NamePattern) -DisplayName "BaselineDiag-Site" `
            -SuppressLog -AsJob -TimeoutSeconds $TimeoutSeconds

        if (-not $res -or $res.ScriptBlockFailed -or -not $res.ScriptBlockOutput) {
            $reason = if ($res -and $res.TimedOut) { 'timed out' } elseif ($res -and $res.ScriptBlockFailed) { 'scriptblock failed' } else { 'no session/output' }
            Write-Host " $reason" -ForegroundColor Red
            $summary.Add("  $vmName : SKIPPED ($reason)")
            continue
        }
        $data = $res.ScriptBlockOutput
        if ($data.Error) {
            Write-Host " $($data.Error)" -ForegroundColor DarkYellow
            $summary.Add("  $vmName : $($data.Error)")
            continue
        }

        $siteDir = Join-Path $OutputPath "site\$vmName"
        if (-not (Test-Path $siteDir)) { New-Item -ItemType Directory -Path $siteDir -Force | Out-Null }

        $rep = New-Object System.Collections.Generic.List[string]
        $rep.Add("Site server: $($data.Computer)")
        $rep.Add("Baselines  : $(@($data.Baselines).Count)")
        $rep.Add("")
        $empty = 0
        foreach ($bl in @($data.Baselines)) {
            $rep.Add("----- $($bl.Name) (CI_ID=$($bl.CI_ID)) -----")
            if ([int]$bl.LinkedCount -eq 0) {
                $empty++
                $rep.Add("  *** WARNING: baseline has NO Configuration Item linked (empty baseline). ***")
            }
            else {
                $rep.Add("  Linked Configuration Items: $($bl.LinkedCount)")
            }
            if ($bl.CiXml) {
                $xmlFile = Join-Path $siteDir ("CI-{0}.sdmpackage.xml" -f (ConvertTo-SafeName $bl.Name))
                Set-Content -Path $xmlFile -Value $bl.CiXml -Encoding UTF8
                $rep.Add("  CI rule XML -> $(Split-Path $xmlFile -Leaf)")
            }
            else {
                $rep.Add("  WARNING: no CI named '$($bl.Name)' found (lookup by name failed).")
            }
            $rep.Add("")
        }
        $rep | Set-Content -Path (Join-Path $siteDir 'site-report.txt') -Encoding UTF8
        Write-Host " $(@($data.Baselines).Count) baseline(s), $empty empty" -ForegroundColor Green
        $summary.Add("  $vmName : $(@($data.Baselines).Count) baseline(s), $empty with NO CI linked")
    }
    $summary.Add("")
}

$summary | Set-Content -Path (Join-Path $OutputPath 'summary.txt') -Encoding UTF8
Write-Host "`nDone. Report tree under: $OutputPath" -ForegroundColor Cyan
Write-Host "Diff a client's compliance-*.xml against the site's CI-*.sdmpackage.xml to pinpoint each baseline." -ForegroundColor DarkGray
