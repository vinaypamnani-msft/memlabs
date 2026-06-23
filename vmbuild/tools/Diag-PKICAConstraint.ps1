<#
.SYNOPSIS
    Diagnoses the Enterprise Root CA install failing with
    0x80072082 ERROR_DS_RANGE_CONSTRAINT during the AD publish step.

.DESCRIPTION
    Runs ON THE HYPER-V HOST. Dot-sources Common.ps1 and uses Invoke-VmCommand to
    drive an in-guest diagnostic on the CA/DC VM (FAB-DC1 by default). The in-guest
    block:

      1. BEFORE  - captures AD/DC health, the PKI containers, the schema range
                   constraints for the attributes the CA publishes, certocm.log,
                   the current Directory Service event tail, NTDS diag levels.
      2. ENABLE  - turns NTDS Diagnostics "15 Field Engineering"=5 and
                   "16 LDAP Interface Events"=2 (records a UTC + local marker time).
      3. REPRO   - runs the EXACT failing command:
                   Install-AdcsCertificationAuthority -CAType EnterpriseRootCa ...
                   capturing the full exception chain AND the cmdlet return object.
      4. AFTER   - captures the NEW certocm.log tail and the FULL Directory Service
                   event log since the marker (no message filter) -- this is what
                   names the exact offending DN + attribute that ntdsa rejected.
      5. RESTORE - puts the NTDS diag levels back.
      6. CLEANUP - on FAILURE, Uninstall-AdcsCertificationAuthority -Force so the
                   next real run starts clean. On SUCCESS, leaves the CA configured
                   (re-run New-Lab.ps1 -startPhase 2 to finish CDP/AIA/templates).

    All output is written to a log file in vmbuild\logs\ so it can be reviewed.

.PARAMETER Domain
    Fully-qualified domain name. Default fabrikam.com.

.PARAMETER CaVMName
    The VM hosting the CA. Default FAB-DC1.

.PARAMETER DcVMName
    The domain controller VM (for AD-readiness context). Default = CaVMName.

.PARAMETER CaName
    Override the CA common name. Default is "<domainShort>-<CaVMName>-CA"
    (exactly what Install-SingleTierPKI computes).

.PARAMETER ConfigPath
    Optional path to a deployConfig .json. When given, CaVMName/DcVMName/Domain are
    derived from it (InstallCA flag / role DC), overriding the defaults.

.PARAMETER SkipInstall
    Only capture BEFORE state + schema constraints; do NOT run the failing command.

.EXAMPLE
    cd C:\memlabs\vmbuild
    .\tools\Diag-PKICAConstraint.ps1

.EXAMPLE
    .\tools\Diag-PKICAConstraint.ps1 -ConfigPath C:\temp\Mega-A.json
#>
param(
    [string]$Domain = "fabrikam.com",
    [string]$CaVMName = "FAB-DC1",
    [string]$DcVMName,
    [string]$CaName,
    [string]$ConfigPath,
    [switch]$SkipInstall
)

$ErrorActionPreference = 'Stop'

# Common.ps1 lives in vmbuild\ (the parent of this tools\ folder).
$vmbuildRoot = Split-Path -Parent $PSScriptRoot
Set-Location $vmbuildRoot

# Validate Common.ps1 has UTF-8 BOM before dot-sourcing (PS5.1 needs BOM for non-ASCII).
$commonPath = Join-Path $vmbuildRoot 'Common.ps1'
$bomBytes = [System.IO.File]::ReadAllBytes($commonPath)[0..2]
if (-not ($bomBytes[0] -eq 0xEF -and $bomBytes[1] -eq 0xBB -and $bomBytes[2] -eq 0xBF)) {
    Write-Host "ERROR: Common.ps1 is missing UTF-8 BOM. Run: git checkout -- vmbuild/Common.ps1" -ForegroundColor Red
    exit 1
}

. $commonPath -InJob

# --- Resolve targets ---------------------------------------------------------
if ($ConfigPath -and (Test-Path $ConfigPath)) {
    try {
        $cfg = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
        $caVM = $cfg.virtualMachines | Where-Object { $_.InstallCA } | Select-Object -First 1
        $dcVM = $cfg.virtualMachines | Where-Object { $_.role -eq 'DC' } | Select-Object -First 1
        if ($caVM) { $CaVMName = $caVM.vmName }
        if ($dcVM) { $DcVMName = $dcVM.vmName }
        if ($cfg.vmOptions.domainName) { $Domain = $cfg.vmOptions.domainName }
        Write-Host "Loaded config from $ConfigPath" -ForegroundColor Cyan
    }
    catch {
        Write-Host "WARNING: could not parse $ConfigPath ($($_.Exception.Message)); using parameter defaults." -ForegroundColor Yellow
    }
}

if (-not $DcVMName) { $DcVMName = $CaVMName }
$domainShort = $Domain.Split('.')[0]
if (-not $CaName) { $CaName = "$domainShort-$CaVMName-CA" }
$doInstall = -not $SkipInstall.IsPresent

$logDir = Join-Path $vmbuildRoot 'logs'
if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logFile = Join-Path $logDir "PKI-DSDiag-$($domainShort)-$stamp.log"

Write-Host ""
Write-Host "PKI RANGE_CONSTRAINT diagnostic" -ForegroundColor Cyan
Write-Host "  Domain    : $Domain"
Write-Host "  CA VM     : $CaVMName"
Write-Host "  DC VM     : $DcVMName"
Write-Host "  CA Name   : $CaName"
Write-Host "  RunInstall: $doInstall  (use -SkipInstall to only capture state)"
Write-Host "  Log file  : $logFile"
Write-Host ""

# --- In-guest diagnostic scriptblock (runs on the CA/DC; must be PS5.1-safe) --
$diagScript = {
    param($CAName, $DomainName, $DoInstall)

    $ErrorActionPreference = 'Continue'
    $rep = [System.Collections.Generic.List[string]]::new()
    function _R($m) { $rep.Add($m) }
    function _H($m) { $rep.Add(""); $rep.Add("==================== $m ===================="); }

    function Get-SchemaAttr {
        param([string]$SchemaNC, [string]$Ldap)
        $o = [ordered]@{ Name = $Ldap; Found = $false }
        try {
            $root = [ADSI]("LDAP://" + $SchemaNC)
            $ds = New-Object System.DirectoryServices.DirectorySearcher($root)
            $ds.Filter = "(&(objectClass=attributeSchema)(lDAPDisplayName=$Ldap))"
            foreach ($p in 'lDAPDisplayName', 'rangeLower', 'rangeUpper', 'attributeSyntax', 'oMSyntax', 'isSingleValued', 'searchFlags', 'systemFlags', 'attributeID') {
                $null = $ds.PropertiesToLoad.Add($p)
            }
            $r = $ds.FindOne()
            if ($r) {
                $o.Found = $true
                foreach ($p in 'rangeLower', 'rangeUpper', 'attributeSyntax', 'oMSyntax', 'isSingleValued', 'searchFlags', 'systemFlags', 'attributeID') {
                    if ($r.Properties[$p].Count -gt 0) { $o[$p] = ($r.Properties[$p] -join ',') } else { $o[$p] = '' }
                }
            }
        }
        catch { $o.Error = $_.Exception.Message }
        return ($o.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '  '
    }

    function Get-DSEventsSince {
        param([datetime]$Since, [int]$Max = 80)
        $out = @()
        try {
            $evts = Get-WinEvent -FilterHashtable @{ LogName = 'Directory Service'; StartTime = $Since } -ErrorAction SilentlyContinue
            if ($evts) {
                $evts = $evts | Sort-Object TimeCreated | Select-Object -First $Max
                foreach ($e in $evts) {
                    $flat = ($e.Message -replace '\s+', ' ')
                    if ($flat.Length -gt 400) { $flat = $flat.Substring(0, 400) }
                    $out += ("{0} Id={1} {2} [{3}] {4}" -f $e.TimeCreated.ToString('HH:mm:ss'), $e.Id, $e.LevelDisplayName, $e.ProviderName, $flat)
                }
            }
        }
        catch { $out += "Get-DSEventsSince error: $($_.Exception.Message)" }
        if ($out.Count -eq 0) { $out += "(no Directory Service events in window)" }
        return $out
    }

    function Get-FileTail {
        param([string]$Path, [int]$Lines = 80)
        try {
            if (Test-Path $Path) { return (Get-Content -Path $Path -Tail $Lines -ErrorAction SilentlyContinue) }
            return @("(not present: $Path)")
        }
        catch { return @("Get-FileTail error on ${Path}: $($_.Exception.Message)") }
    }

    function Test-CaConfigured {
        $cfgRoot = 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration'
        if (-not (Test-Path $cfgRoot)) { return $false }
        $active = (Get-ItemProperty -Path $cfgRoot -Name 'Active' -ErrorAction SilentlyContinue).Active
        if ([string]::IsNullOrWhiteSpace($active)) { return $false }
        if (-not (Test-Path (Join-Path $cfgRoot $active))) { return $false }
        return $true
    }

    $diagPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Diagnostics'
    function Get-NtdsDiag([string]$Name) {
        try { return (Get-ItemProperty -Path $diagPath -Name $Name -ErrorAction SilentlyContinue).$Name } catch { return $null }
    }
    function Set-NtdsDiag([string]$Name, [int]$Val) {
        try { Set-ItemProperty -Path $diagPath -Name $Name -Value $Val -Type DWord -Force -ErrorAction SilentlyContinue } catch {}
    }

    $caOk = $false
    $configNC = $null
    $schemaNC = $null

    # ----- BEFORE -----
    _H "BEFORE: host / identity / time"
    try {
        _R "Hostname: $env:COMPUTERNAME   Now(local): $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')   Now(UTC): $((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss'))"
        _R "Identity: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"
        $os = Get-CimInstance Win32_OperatingSystem
        _R "LastBoot: $($os.LastBootUpTime)   OSUptimeMin: $([int]((Get-Date) - $os.LastBootUpTime).TotalMinutes)"
    }
    catch { _R "host info error: $($_.Exception.Message)" }

    try {
        $ntds = Get-Service -Name NTDS -ErrorAction SilentlyContinue
        _R "NTDS service: $(if ($ntds) { $ntds.Status } else { 'absent' })"
        $ntdsProc = Get-Process -Name lsass -ErrorAction SilentlyContinue
        if ($ntdsProc) { _R "lsass StartTime: $($ntdsProc.StartTime)   sinceMin: $([int]((Get-Date) - $ntdsProc.StartTime).TotalMinutes)" }
        $nl = Get-Service -Name Netlogon -ErrorAction SilentlyContinue
        _R "Netlogon: $(if ($nl) { $nl.Status } else { 'absent' })"
    }
    catch { _R "service info error: $($_.Exception.Message)" }

    _H "BEFORE: RootDSE"
    try {
        $rootDSE = [ADSI]"LDAP://RootDSE"
        $configNC = "$($rootDSE.configurationNamingContext)"
        $schemaNC = "$($rootDSE.schemaNamingContext)"
        _R "configurationNamingContext: $configNC"
        _R "schemaNamingContext: $schemaNC"
        _R "dsServiceName: $($rootDSE.dsServiceName)"
        _R "isSynchronized: $($rootDSE.isSynchronized)   isGlobalCatalogReady: $($rootDSE.isGlobalCatalogReady)"
        _R "highestCommittedUSN: $($rootDSE.highestCommittedUSN)"
        _R "supportedCapabilities count: $(@($rootDSE.supportedCapabilities).Count)"
    }
    catch { _R "RootDSE error: $($_.Exception.Message)" }

    _H "BEFORE: forest/domain/schema versions"
    try {
        if ($schemaNC) {
            $schemaHead = [ADSI]("LDAP://" + $schemaNC)
            _R "schema objectVersion: $($schemaHead.objectVersion)"
        }
        $partitions = [ADSI]("LDAP://CN=Partitions," + $configNC)
        _R "forestFunctionality(msDS-Behavior-Version on Partitions): $($partitions.'msDS-Behavior-Version')"
    }
    catch { _R "version error: $($_.Exception.Message)" }

    _H "BEFORE: FSMO (fsmoRoleOwner)"
    try {
        $schemaMaster = ([ADSI]("LDAP://CN=Schema," + $configNC)).fsmoRoleOwner
        _R "Schema master: $schemaMaster"
        $infraDN = "CN=Infrastructure," + ([ADSI]"LDAP://RootDSE").defaultNamingContext
        $infra = [ADSI]("LDAP://" + $infraDN)
        _R "Infrastructure master: $($infra.fsmoRoleOwner)"
        $rid = [ADSI]("LDAP://CN=RID Manager$,CN=System," + ([ADSI]"LDAP://RootDSE").defaultNamingContext)
        _R "RID master: $($rid.fSMORoleOwner)"
    }
    catch { _R "FSMO error: $($_.Exception.Message)" }

    _H "BEFORE: PKI containers under Public Key Services"
    try {
        $pksDN = "CN=Public Key Services,CN=Services," + $configNC
        $pks = [ADSI]("LDAP://" + $pksDN)
        _R "Public Key Services DN reachable: $($pks.distinguishedName)"
        foreach ($c in 'CN=Enrollment Services', 'CN=Certification Authorities', 'CN=NTAuthCertificates', 'CN=AIA', 'CN=KRA', 'CN=OID', 'CN=Certificate Templates') {
            try {
                $node = [ADSI]("LDAP://" + $c + "," + $pksDN)
                $dn = "$($node.distinguishedName)"
                if ($dn) {
                    $kids = @($node.Children) | ForEach-Object { $_.cn } | Where-Object { $_ }
                    _R ("{0} : EXISTS, children=[{1}]" -f $c, ($kids -join ', '))
                }
                else { _R "$c : (no DN returned)" }
            }
            catch { _R "$c : MISSING/ERROR ($($_.Exception.Message))" }
        }
    }
    catch { _R "PKI container error: $($_.Exception.Message)" }

    _H "BEFORE: schema range constraints for attributes the CA publishes"
    if ($schemaNC) {
        foreach ($a in 'cACertificate', 'cACertificateDN', 'certificateTemplates', 'nTSecurityDescriptor', 'flags', 'displayName', 'cn', 'dNSHostName', 'pKIExpirationPeriod', 'pKIOverlapPeriod', 'pKICriticalExtensions', 'pKIDefaultKeySpec', 'pKIKeyUsage', 'pKIMaxIssuingDepth', 'msPKI-Cert-Template-OID', 'msPKI-Minimal-Key-Size', 'msPKI-RA-Signature', 'msPKI-Enrollment-Flag', 'msPKI-Private-Key-Flag', 'authorityRevocationList', 'certificateRevocationList', 'crossCertificatePair', 'cAConnect', 'cAWEBURL', 'cRLDistributionPoint') {
            _R (Get-SchemaAttr -SchemaNC $schemaNC -Ldap $a)
        }
    }

    _H "BEFORE: certsvc state"
    try {
        $svc = Get-Service -Name certsvc -ErrorAction SilentlyContinue
        _R "certsvc: $(if ($svc) { $svc.Status } else { 'absent' })   Test-CaConfigured: $(Test-CaConfigured)"
        $feat = Get-WindowsFeature -Name Adcs-Cert-Authority -ErrorAction SilentlyContinue
        if ($feat) { _R "Adcs-Cert-Authority feature Installed: $($feat.Installed)" }
    }
    catch { _R "certsvc state error: $($_.Exception.Message)" }

    _H "BEFORE: NTDS diagnostic levels"
    $priorFE = Get-NtdsDiag '15 Field Engineering'
    $priorLDAP = Get-NtdsDiag '16 LDAP Interface Events'
    $priorIP = Get-NtdsDiag '9 Internal Processing'
    _R "15 Field Engineering = $priorFE"
    _R "16 LDAP Interface Events = $priorLDAP"
    _R "9 Internal Processing = $priorIP"

    _H "BEFORE: certocm.log tail"
    Get-FileTail -Path 'C:\Windows\certocm.log' -Lines 40 | ForEach-Object { _R $_ }

    _H "BEFORE: Directory Service event tail (last 8)"
    try {
        Get-WinEvent -LogName 'Directory Service' -MaxEvents 8 -ErrorAction SilentlyContinue | Sort-Object TimeCreated |
        ForEach-Object { $f = ($_.Message -replace '\s+', ' '); if ($f.Length -gt 200) { $f = $f.Substring(0, 200) }; _R ("{0} Id={1} {2}" -f $_.TimeCreated.ToString('HH:mm:ss'), $_.Id, $f) }
    }
    catch { _R "DS tail error: $($_.Exception.Message)" }

    if (-not $DoInstall) {
        _H "SkipInstall set - state capture only"
        return @{ Success = $false; Report = $rep.ToArray() }
    }

    # ----- ENABLE max DS logging -----
    _H "ENABLE: NTDS Field Engineering=5, LDAP Interface Events=2, Internal Processing=1"
    Set-NtdsDiag '15 Field Engineering' 5
    Set-NtdsDiag '16 LDAP Interface Events' 2
    Set-NtdsDiag '9 Internal Processing' 1
    $markerLocal = Get-Date
    _R "marker(local): $($markerLocal.ToString('yyyy-MM-dd HH:mm:ss'))   marker(UTC): $($markerLocal.ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss'))"
    Start-Sleep -Seconds 2

    # ----- REPRO the exact failing command -----
    _H "REPRO: prepare role + CAPolicy.inf, tear down any partial config"
    try { Install-WindowsFeature Adcs-Cert-Authority -IncludeManagementTools | Out-Null; _R "Adcs-Cert-Authority feature ensured." } catch { _R "feature install error: $($_.Exception.Message)" }
    try {
        $caPolicy = @"
[Version]
Signature="`$Windows NT`$"

[certsrv_server]
RenewalKeyLength=2048
RenewalValidityPeriod=Years
RenewalValidityPeriodUnits=5
CRLPeriod=Weeks
CRLPeriodUnits=2
CRLDeltaPeriod=Days
CRLDeltaPeriodUnits=0
LoadDefaultTemplates=0
"@
        Set-Content -Path "C:\Windows\CAPolicy.inf" -Value $caPolicy -Force
        _R "CAPolicy.inf written."
    }
    catch { _R "CAPolicy.inf error: $($_.Exception.Message)" }
    try { Uninstall-AdcsCertificationAuthority -Force -ErrorAction SilentlyContinue | Out-Null; _R "Pre-uninstall of any partial config done." } catch { _R "pre-uninstall note: $($_.Exception.Message)" }

    _H "REPRO: Install-AdcsCertificationAuthority -CAType EnterpriseRootCa ..."
    $installReturn = $null
    $threw = $false
    try {
        $installReturn = Install-AdcsCertificationAuthority -CAType EnterpriseRootCa `
            -CACommonName $CAName `
            -CryptoProviderName "RSA#Microsoft Software Key Storage Provider" `
            -KeyLength 2048 `
            -HashAlgorithmName SHA256 `
            -ValidityPeriod Years `
            -ValidityPeriodUnits 5 `
            -Force -Verbose 4>&1
    }
    catch {
        $threw = $true
        _R "EXCEPTION thrown by cmdlet."
        $ex = $_.Exception
        _R "  Type: $($ex.GetType().FullName)"
        _R "  HResult: 0x$('{0:X8}' -f $ex.HResult)"
        _R "  Message: $($ex.Message)"
        $inner = $ex.InnerException
        $depth = 0
        while ($inner -and $depth -lt 6) {
            _R "  Inner[$depth] $($inner.GetType().FullName): 0x$('{0:X8}' -f $inner.HResult) : $($inner.Message)"
            $inner = $inner.InnerException; $depth++
        }
        if ($_.ScriptStackTrace) { _R "  ScriptStackTrace: $($_.ScriptStackTrace -replace '\s+', ' ')" }
    }

    _R ""
    _R "Cmdlet returned (threw=$threw):"
    if ($null -ne $installReturn) {
        try { ($installReturn | Format-List * | Out-String) -split "`r?`n" | Where-Object { $_.Trim() } | ForEach-Object { _R "  $_" } } catch { _R "  (could not format return: $($_.Exception.Message))" }
    }
    else { _R "  <null>" }

    Start-Sleep -Seconds 3
    $caOk = Test-CaConfigured
    _R ""
    _R "Test-CaConfigured after attempt: $caOk"

    # ----- AFTER capture -----
    _H "AFTER: certocm.log tail (last 120)"
    Get-FileTail -Path 'C:\Windows\certocm.log' -Lines 120 | ForEach-Object { _R $_ }

    _H "AFTER: FULL Directory Service events since marker (the offending attribute should be here)"
    Get-DSEventsSince -Since $markerLocal -Max 120 | ForEach-Object { _R $_ }

    _H "AFTER: Application-log CertificationAuthority/ESENT events since marker"
    try {
        Get-WinEvent -FilterHashtable @{ LogName = 'Application'; StartTime = $markerLocal } -ErrorAction SilentlyContinue |
        Where-Object { $_.ProviderName -match 'CertificationAuthority|CertSvc|ESENT|Microsoft-Windows-CertificateServices' } |
        Sort-Object TimeCreated | Select-Object -First 40 |
        ForEach-Object { $f = ($_.Message -replace '\s+', ' '); if ($f.Length -gt 300) { $f = $f.Substring(0, 300) }; _R ("{0} Id={1} [{2}] {3}" -f $_.TimeCreated.ToString('HH:mm:ss'), $_.Id, $_.ProviderName, $f) }
    }
    catch { _R "App-log capture error: $($_.Exception.Message)" }

    # ----- RESTORE diag -----
    _H "RESTORE: NTDS diagnostic levels"
    $rFE = 0; if ($null -ne $priorFE) { $rFE = [int]$priorFE }
    $rLDAP = 0; if ($null -ne $priorLDAP) { $rLDAP = [int]$priorLDAP }
    $rIP = 0; if ($null -ne $priorIP) { $rIP = [int]$priorIP }
    Set-NtdsDiag '15 Field Engineering' $rFE
    Set-NtdsDiag '16 LDAP Interface Events' $rLDAP
    Set-NtdsDiag '9 Internal Processing' $rIP
    _R "Restored FE=$rFE LDAP=$rLDAP IP=$rIP"

    # ----- CLEANUP -----
    _H "CLEANUP"
    if ($caOk) {
        _R "CA IS CONFIGURED (it worked this time) - leaving it installed. Re-run New-Lab.ps1 -startPhase 2 to finish CDP/AIA/DNS/templates (idempotent)."
    }
    else {
        try { Uninstall-AdcsCertificationAuthority -Force -ErrorAction SilentlyContinue | Out-Null; _R "Failed attempt: removed partial CA config so the next run starts clean." } catch { _R "cleanup uninstall note: $($_.Exception.Message)" }
    }

    return @{ Success = $caOk; Report = $rep.ToArray() }
}

# --- Run it ------------------------------------------------------------------
Write-Host "Invoking in-guest diagnostic on $CaVMName (this runs the failing command)..." -ForegroundColor Cyan
$result = Invoke-VmCommand -VmName $CaVMName -VmDomainName $Domain `
    -ScriptBlock $diagScript `
    -ArgumentList $CaName, $Domain, $doInstall `
    -DisplayName "PKI RANGE_CONSTRAINT diagnostic" `
    -TimeoutSeconds 600

$out = $null
if ($result -and $result.ScriptBlockOutput) { $out = $result.ScriptBlockOutput } else { $out = $result }

$header = @(
    "PKI RANGE_CONSTRAINT diagnostic",
    "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
    "Domain=$Domain  CaVM=$CaVMName  DcVM=$DcVMName  CaName=$CaName  RunInstall=$doInstall",
    "============================================================================"
)
$header | Set-Content -Path $logFile -Encoding UTF8

if ($out -and $out.Report) {
    $out.Report | Add-Content -Path $logFile -Encoding UTF8
    Write-Host ""
    Write-Host "Diagnostic complete. Success(CA configured)=$($out.Success)" -ForegroundColor Green
    Write-Host "Log written to: $logFile" -ForegroundColor Green
}
else {
    "NO REPORT RETURNED. Raw result follows:" | Add-Content -Path $logFile -Encoding UTF8
    ($result | Format-List * | Out-String) | Add-Content -Path $logFile -Encoding UTF8
    Write-Host ""
    Write-Host "WARNING: in-guest diagnostic returned no report. See $logFile for the raw Invoke-VmCommand result." -ForegroundColor Yellow
}
