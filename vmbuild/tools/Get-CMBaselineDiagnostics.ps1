<#
.SYNOPSIS
    Collect everything needed to diagnose why MEMLABS Configuration Baselines
    (imported by perfloading.ps1) report "Error" or "Non-Compliant" on a client.

.DESCRIPTION
    perfloading.ps1 imports a set of Configuration Items from
    azureFiles\support\baselines.zip (C:\tools\baselines\*.cab on the site
    server), wraps each in a Configuration Baseline, and deploys it to
    "All Systems" with enforcement enabled. Several of those CIs use PowerShell
    discovery/remediation scripts, which is why perfloading also pushes a
    "PowerShell execution policy = Bypass" client setting.

    The CAB rule definitions are binary and not in the repo, so the only way to
    know WHY a given baseline is Error vs Non-Compliant is to read the client's
    own DCM compliance detail plus the matching CI rule XML from the site. This
    script gathers exactly that.

    Run it TWO ways and diff the two output folders:

      * ON A CLIENT (default): dumps per-baseline compliance state + the
        detailed compliance report XML (which distinguishes "a rule evaluated
        False" = Non-Compliant from "a discovery script threw" = Error), the
        effective PowerShell execution policy (OS + CM client setting), and the
        tail of the relevant CCM\Logs\*.log files.

      * ON THE SITE SERVER with -FromSiteServer: dumps each baseline's linked
        CI(s) and the CI SDMPackageXML (the actual rule: setting source,
        expected value, remediation on/off, supported platforms) so you can see
        what each rule is supposed to check. This also flags baselines that have
        NO CI linked (the classic empty-baseline bug when the CI name != cab
        filename).

    Nothing is modified. Read-only collection only. PowerShell 5.1 safe.

.PARAMETER OutputPath
    Folder to write the report + copied logs into.
    Default: <script>\..\logs\baseline-diag\<COMPUTERNAME>-<timestamp>

.PARAMETER NamePattern
    Only report baselines whose name matches this wildcard. Default '*'
    (perfloading names are arbitrary cab basenames, so default to all).

.PARAMETER TriggerEvaluation
    Trigger a fresh baseline evaluation and wait briefly before collecting, so
    the compliance detail reflects current state rather than a stale cycle.

.PARAMETER FromSiteServer
    Run the SITE-side collection (CI rule XML + baseline->CI linkage) instead of
    the client-side collection. Requires the ConfigurationManager console module
    (run from an admin PowerShell on the Primary/CAS, or import the module).

.EXAMPLE
    # On a misbehaving client
    .\Get-CMBaselineDiagnostics.ps1 -TriggerEvaluation

.EXAMPLE
    # On the Primary site server
    .\Get-CMBaselineDiagnostics.ps1 -FromSiteServer
#>
[CmdletBinding()]
param(
    [string]$OutputPath,
    [string]$NamePattern = '*',
    [switch]$TriggerEvaluation,
    [switch]$FromSiteServer
)

$ErrorActionPreference = 'Continue'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

if (-not $OutputPath) {
    $root = Split-Path -Parent $PSScriptRoot   # vmbuild\
    $OutputPath = Join-Path $root "logs\baseline-diag\$($env:COMPUTERNAME)-$stamp"
}
if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }

$report = New-Object System.Collections.Generic.List[string]
function Add-Line { param([string]$Text) $report.Add($Text); Write-Host $Text }

Add-Line "=== MEMLABS Configuration Baseline diagnostics ==="
Add-Line "Computer : $($env:COMPUTERNAME)"
Add-Line "When     : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Add-Line "Mode     : $(if ($FromSiteServer) { 'SITE SERVER (CI rule definitions)' } else { 'CLIENT (compliance detail)' })"
Add-Line "Output   : $OutputPath"
Add-Line ""

# Compliance status decode (root\ccm\dcm SMS_DesiredConfiguration.LastComplianceStatus)
$complianceMap = @{
    0 = 'Non-Compliant'
    1 = 'Compliant'
    2 = 'Submitted'
    3 = 'Unknown'
    4 = 'Detecting'
    5 = 'NotEvaluated'
}

# ------------------------------------------------------------------ SITE MODE
if ($FromSiteServer) {

    # Locate + import the ConfigurationManager module and CD into the site drive.
    $cmModule = $env:SMS_ADMIN_UI_PATH
    if ($cmModule) {
        $cmModule = Join-Path (Split-Path $cmModule) 'ConfigurationManager.psd1'
    }
    if ($cmModule -and (Test-Path $cmModule)) {
        Import-Module $cmModule -ErrorAction SilentlyContinue
    }
    if (-not (Get-Module ConfigurationManager)) {
        Add-Line "ERROR: ConfigurationManager module not loaded. Run from an admin PowerShell on the site server (or import ConfigurationManager.psd1 first)."
        $report | Set-Content -Path (Join-Path $OutputPath 'baseline-report.txt') -Encoding UTF8
        return
    }

    $site = Get-PSDrive -PSProvider CMSite -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $site) {
        Add-Line "ERROR: No CMSite PSDrive found. Connect the console once so the site drive exists."
        $report | Set-Content -Path (Join-Path $OutputPath 'baseline-report.txt') -Encoding UTF8
        return
    }
    Push-Location ("{0}:\" -f $site.Name)
    try {
        $baselines = @(Get-CMBaseline -Fast | Where-Object { $_.LocalizedDisplayName -like $NamePattern })
        Add-Line "Found $($baselines.Count) baseline(s) matching '$NamePattern'."
        Add-Line ""
        foreach ($bl in $baselines) {
            $blName = $bl.LocalizedDisplayName
            Add-Line "----- Baseline: $blName (CI_ID=$($bl.CI_ID)) -----"

            # Pull the baseline's own XML to enumerate the CIs it references.
            $full = Get-CMBaseline -Name $blName
            $linkedCount = 0
            try {
                [xml]$blXml = $full.SDMPackageXML
                # OS / Application / SoftwareUpdate references all live under the
                # Baseline node; count every ConfigurationItemReference child.
                $allRefs = $blXml.SelectNodes("//*[local-name()='ConfigurationItemReference']")
                $linkedCount = @($allRefs).Count
            }
            catch { }

            if ($linkedCount -eq 0) {
                Add-Line "  *** WARNING: baseline has NO Configuration Item linked (empty baseline). ***"
                Add-Line "      This is the classic 'CI name != cab filename' / wrong -Add*ConfigurationItem bug."
            }
            else {
                Add-Line "  Linked Configuration Items: $linkedCount"
            }

            # Dump the matching CI's rule XML by name (perfloading uses same name for CI + baseline).
            $ci = Get-CMConfigurationItem -Name $blName -Fast -ErrorAction SilentlyContinue
            if ($ci) {
                $ciFull = Get-CMConfigurationItem -Name $blName
                $xmlFile = Join-Path $OutputPath ("CI-{0}.sdmpackage.xml" -f ($blName -replace '[^\w\-]', '_'))
                try {
                    $ciFull.SDMPackageXML | Set-Content -Path $xmlFile -Encoding UTF8
                    Add-Line "  CI rule XML  -> $(Split-Path $xmlFile -Leaf)"
                }
                catch {
                    Add-Line "  WARNING: could not read SDMPackageXML: $($_.Exception.Message)"
                }
            }
            else {
                Add-Line "  WARNING: no Configuration Item named '$blName' found (lookup by name failed)."
            }

            # Deployment compliance summary (how many clients in each state).
            try {
                $sc = $site.Name
                $dep = Get-WmiObject -Namespace "root\SMS\site_$sc" -Class SMS_DCMDeploymentCompliantStatus -Filter "ConfigurationItemID='$($bl.CI_ID)'" -ErrorAction SilentlyContinue
                $err = Get-WmiObject -Namespace "root\SMS\site_$sc" -Class SMS_DCMDeploymentErrorStatus -Filter "ConfigurationItemID='$($bl.CI_ID)'" -ErrorAction SilentlyContinue
                Add-Line "  Compliance rows: compliant=$(@($dep).Count) error=$(@($err).Count)"
            }
            catch { }
            Add-Line ""
        }
    }
    finally { Pop-Location }

    $report | Set-Content -Path (Join-Path $OutputPath 'baseline-report.txt') -Encoding UTF8
    Add-Line "Site-side collection complete. CI rule XML + report in: $OutputPath"
    return
}

# ---------------------------------------------------------------- CLIENT MODE
$dcmNs = 'root\ccm\dcm'

$baselines = @()
try {
    $baselines = @(Get-CimInstance -Namespace $dcmNs -ClassName SMS_DesiredConfiguration -ErrorAction Stop |
            Where-Object { $_.Name -like $NamePattern })
}
catch {
    Add-Line "ERROR: cannot read $dcmNs SMS_DesiredConfiguration: $($_.Exception.Message)"
    Add-Line "Is the ConfigMgr client (CcmExec) installed and running on this machine?"
}

Add-Line "Found $($baselines.Count) deployed baseline(s) matching '$NamePattern'."
Add-Line ""

# Optionally trigger a fresh evaluation so detail isn't stale.
if ($TriggerEvaluation -and $baselines.Count -gt 0) {
    Add-Line "Triggering evaluation for $($baselines.Count) baseline(s)..."
    foreach ($bl in $baselines) {
        try {
            Invoke-CimMethod -Namespace $dcmNs -ClassName SMS_DesiredConfiguration -MethodName TriggerEvaluation `
                -Arguments @{ Name = $bl.Name; Version = $bl.Version } -ErrorAction SilentlyContinue | Out-Null
        }
        catch { }
    }
    Add-Line "Waiting 90s for evaluation to settle..."
    Start-Sleep -Seconds 90
    $baselines = @(Get-CimInstance -Namespace $dcmNs -ClassName SMS_DesiredConfiguration -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like $NamePattern })
    Add-Line ""
}

foreach ($bl in $baselines) {
    $code = $bl.LastComplianceStatus
    $stateName = $complianceMap[[int]$code]
    if (-not $stateName) { $stateName = "raw=$code" }
    Add-Line "----- $($bl.Name) (v$($bl.Version)) -----"
    Add-Line "  LastComplianceStatus : $code ($stateName)"
    Add-Line "  LastEvalTime         : $($bl.LastEvalTime)"
    Add-Line "  IsMachineTarget      : $($bl.IsMachineTarget)   PolicyType: $($bl.PolicyType)"

    # The detailed compliance report (ComplianceDetails) is the gold: it lists
    # each CI / rule with its individual result AND any error text, which is the
    # ONLY reliable way to tell "rule evaluated False" (Non-Compliant) apart from
    # "discovery script/WMI query threw" (Error).
    if ($bl.ComplianceDetails) {
        $safeName = ($bl.Name -replace '[^\w\-]', '_')
        $detailFile = Join-Path $OutputPath ("compliance-{0}.xml" -f $safeName)
        try {
            $bl.ComplianceDetails | Set-Content -Path $detailFile -Encoding UTF8
            Add-Line "  ComplianceDetails    -> $(Split-Path $detailFile -Leaf)"
            # Surface any error/exception text inline so the report is useful at a glance.
            $hit = Select-String -Path $detailFile -Pattern 'Error|Exception|0x[0-9A-Fa-f]{8}|ScriptExecution|not be loaded|execution policy' -ErrorAction SilentlyContinue |
                Select-Object -First 6
            foreach ($h in $hit) {
                $t = $h.Line.Trim()
                if ($t.Length -gt 200) { $t = $t.Substring(0, 200) }
                Add-Line "    detail> $t"
            }
        }
        catch {
            Add-Line "  WARNING: could not write ComplianceDetails: $($_.Exception.Message)"
        }
    }
    else {
        Add-Line "  (no ComplianceDetails yet — baseline may not have evaluated; try -TriggerEvaluation)"
    }
    Add-Line ""
}

# Per-CI compliance state (finer than per-baseline).
try {
    $ciStates = @(Get-CimInstance -Namespace $dcmNs -ClassName SMS_DCMCIComplianceState -ErrorAction SilentlyContinue)
    if ($ciStates.Count -gt 0) {
        Add-Line "----- Per-CI compliance (SMS_DCMCIComplianceState) -----"
        foreach ($s in $ciStates) {
            Add-Line "  $($s.DisplayName)  state=$($s.ComplianceState)  lastEval=$($s.LastComplianceStatusChange)"
        }
        Add-Line ""
    }
}
catch { }

# ---- Effective PowerShell execution policy (the #1 cause of script-CI Error) ----
Add-Line "----- PowerShell execution policy -----"
try {
    $epList = Get-ExecutionPolicy -List | ForEach-Object { "  OS  $($_.Scope) = $($_.ExecutionPolicy)" }
    foreach ($e in $epList) { Add-Line $e }
}
catch { Add-Line "  (Get-ExecutionPolicy -List failed: $($_.Exception.Message))" }

# CM client agent setting (root\ccm\Policy\Machine\ActualConfig). 0=AllSigned 1=Bypass 2=Restricted 3=Unrestricted (per CM client policy schema)
try {
    $psPolMap = @{ 0 = 'AllSigned'; 1 = 'Bypass'; 2 = 'Restricted'; 3 = 'Unrestricted' }
    $cfg = Get-CimInstance -Namespace 'root\ccm\Policy\Machine\ActualConfig' -ClassName CCM_ConfigurationManagementClientConfig -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cfg -and ($null -ne $cfg.PowerShellExecutionPolicy)) {
        $p = $cfg.PowerShellExecutionPolicy
        $pName = $psPolMap[[int]$p]
        if (-not $pName) { $pName = "raw=$p" }
        Add-Line "  CM client setting PowerShellExecutionPolicy = $p ($pName)"
        if ([int]$p -ne 1 -and [int]$p -ne 3) {
            Add-Line "  *** This is NOT Bypass/Unrestricted — script-based CIs will likely report ERROR until the MEMLABS-powershellbypass client setting applies. ***"
        }
    }
    else {
        Add-Line "  CM client setting PowerShellExecutionPolicy = (not set / policy not yet received)"
        Add-Line "  *** The MEMLABS-powershellbypass client setting has not reached this client — script CIs will ERROR. ***"
    }
}
catch { Add-Line "  (CM client policy read failed: $($_.Exception.Message))" }
Add-Line ""

# ---- Copy the relevant CCM logs (tail) ----
$ccmLogDir = Join-Path $env:WinDir 'CCM\Logs'
$wanted = @('DCMAgent.log', 'DCMReporting.log', 'CIAgent.log', 'CITaskMgr.log', 'CIStateStore.log', 'CIDownloader.log', 'PolicyAgent.log', 'PolicyEvaluator.log')
Add-Line "----- CCM logs (tail copied to output) -----"
if (Test-Path $ccmLogDir) {
    $logDest = Join-Path $OutputPath 'ccmlogs'
    if (-not (Test-Path $logDest)) { New-Item -ItemType Directory -Path $logDest -Force | Out-Null }
    foreach ($name in $wanted) {
        $src = Join-Path $ccmLogDir $name
        if (Test-Path $src) {
            try {
                Get-Content -Path $src -Tail 2000 -ErrorAction SilentlyContinue |
                    Set-Content -Path (Join-Path $logDest $name) -Encoding UTF8
                Add-Line "  copied $name"
            }
            catch { Add-Line "  WARNING: could not copy $name : $($_.Exception.Message)" }
        }
    }
}
else {
    Add-Line "  WARNING: $ccmLogDir not found (client not installed?)"
}
Add-Line ""

$report | Set-Content -Path (Join-Path $OutputPath 'baseline-report.txt') -Encoding UTF8
Add-Line "Client-side collection complete."
Add-Line "Report + compliance XML + logs in: $OutputPath"
Add-Line ""
Add-Line "NEXT: re-run with -FromSiteServer on the Primary to capture the CI rule XML, then diff against the client compliance detail."
