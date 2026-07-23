<#
.SYNOPSIS
    Collects ALL diagnostic info for the Two-Tier PKI Enterprise Subordinate CA
    install failing with 0x80072082 ERROR_DS_RANGE_CONSTRAINT (and the earlier
    certutil -dspublish 0x80070005 ACCESS_DENIED) on a freshly promoted DC that
    also hosts the Issuing CA.

.DESCRIPTION
    Runs ON THE HYPER-V HOST. Dot-sources Common.ps1 and uses Invoke-VmCommand to
    drive an in-guest collector on the Issuing-CA VM (which, in this topology, IS
    the DC -- e.g. PL-HOAGIE on pushlab.sandwich.lab).

    Motivation (see repo memory pki-ca-install-hardening.md, 2026-07-23 exhaustion):
    the hardened two-tier path burned all 18 attempts over ~3h post-dcpromo and
    every attempt failed INSTANTLY, which does NOT fit the "settle window" model.
    Two structural red flags need ground truth this collector captures:
      (1) certutil -dspublish failed 10/10 with ACCESS_DENIED and the Config-NC
          write-probe never went writable -> is the publish identity actually an
          Enterprise Admin? do the PKI containers grant it Write?
      (2) The in-build Field-Engineering capture returned NOTHING -> we need the
          guest certocm.log + Directory Service log directly, and (optionally) a
          fresh FE=5 repro to name the offending attribute.

    DEFAULT MODE IS READ-ONLY. It collects:
      - identity + FULL token group membership + explicit EA/DA/SA checks
      - AD/DC health (RootDSE, FSMO, dcdiag, service state)
      - the PKI containers under Public Key Services + their children
      - the effective DACL (owner + Write/GenericAll ACEs) on Public Key Services,
        Certification Authorities, NTAuthCertificates, Enrollment Services
      - a Config-NC WRITE PROBE (create+delete a throwaway container) with the
        EXACT error surfaced
      - a certutil -dspublish REPRO of the root + NTAuth publish (idempotent; this
        is the exact call that returned ACCESS_DENIED) with exit code + output
      - 'Cert Publishers' membership of the CA machine account
      - schema range constraints for the attributes the CA publishes
      - certocm.log tail + recent Directory Service events
      - certsvc / ADCS role / CA-configured state

    With -Repro it additionally: enables NTDS Field Engineering=5 + LDAP Interface
    Events=2, runs the EXACT failing Install-AdcsCertificationAuthority
    -CAType EnterpriseSubordinateCa -OutputCertRequestFile call, captures the full
    exception chain + the FULL Directory Service events since a marker (this is
    what names the offending DN/attribute), then tears down the partial config and
    restores the diag levels.

    All output is written to vmbuild\logs\PKI-SubDSDiag-<domainShort>-<stamp>.log.

.PARAMETER Domain
    Fully-qualified domain name. Default pushlab.sandwich.lab.

.PARAMETER CaVMName
    The VM hosting the Issuing/Subordinate CA (the DC in this topology).
    Default PL-HOAGIE. Use the ACTUAL Hyper-V VM name (with prefix).

.PARAMETER RootCaVMName
    The offline Standalone Root CA VM (for context/file checks). Default PL-PROVOLONE.

.PARAMETER CaName
    Override the subordinate CA common name. Default "<domainShort>-<CaVMName-noPrefix>-CA"
    (what Install-TwoTierPKI computes: "$domainShort-$issuingCAVMName-CA").

.PARAMETER ConfigPath
    Optional deployConfig .json. When given, Domain/CaVMName/RootCaVMName are derived
    from it (SubordinateCA/InstallCA flag, role StandaloneRootCA), with the vmOptions
    prefix applied to VM names.

.PARAMETER Repro
    Also re-run the failing subordinate CA install with max DS logging and capture the
    offending attribute, then tear the partial config back down. Off by default.

.EXAMPLE
    cd C:\memlabs\vmbuild
    .\tools\Diag-PKISubordinateConstraint.ps1

.EXAMPLE
    .\tools\Diag-PKISubordinateConstraint.ps1 -ConfigPath C:\temp\PushTest-A-MultiSubnet-Stress.json

.EXAMPLE
    .\tools\Diag-PKISubordinateConstraint.ps1 -Repro
#>
param(
    [string]$Domain = "pushlab.sandwich.lab",
    [string]$CaVMName = "PL-HOAGIE",
    [string]$RootCaVMName = "PL-PROVOLONE",
    [string]$CaName,
    [string]$ConfigPath,
    [switch]$Repro
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

# Initialize storage so $Common.LocalAdmin (vmbuildadmin credential) is populated
# from the cached vmbuildadmin.txt. Get-VmSession needs $Common.LocalAdmin.Password
# to build the domain credential.
#   - If this session is ALREADY initialized (you dot-sourced Common.ps1 yourself),
#     reuse it as-is -- re-running init cold with an expired/offline token can drop
#     the credential.
#   - Otherwise try a fast init.
# Do NOT use -InJob: it skips storage init and leaves $Common.LocalAdmin null.
if ($global:Common -and $global:Common.LocalAdmin -and $global:Common.LocalAdmin.Password) {
    Write-Host "Using already-initialized session (Common.LocalAdmin present)." -ForegroundColor DarkGray
}
else {
    . $commonPath -FastInit
}

if (-not $Common.LocalAdmin -or -not $Common.LocalAdmin.Password) {
    Write-Host "ERROR: local admin (vmbuildadmin) credential not loaded (expected cache at $(Join-Path $vmbuildRoot 'cache\vmbuildadmin.txt'))." -ForegroundColor Red
    Write-Host "  Initialize this session first, then re-run the tool:" -ForegroundColor Yellow
    Write-Host "      . .\Common.ps1 -FastInit" -ForegroundColor Cyan
    Write-Host "      .\tools\Diag-PKISubordinateConstraint.ps1 -Repro" -ForegroundColor Cyan
    Write-Host "  (If it still fails, your storage token has expired -- refresh it and retry.)" -ForegroundColor Yellow
    exit 1
}

# --- Resolve targets ---------------------------------------------------------
if ($ConfigPath -and (Test-Path $ConfigPath)) {
    try {
        $cfg = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
        $prefix = "$($cfg.vmOptions.prefix)"
        $caVM = $cfg.virtualMachines | Where-Object { $_.SubordinateCA } | Select-Object -First 1
        if (-not $caVM) { $caVM = $cfg.virtualMachines | Where-Object { $_.InstallCA } | Select-Object -First 1 }
        $rootVM = $cfg.virtualMachines | Where-Object { $_.role -eq 'StandaloneRootCA' } | Select-Object -First 1
        if ($caVM) { $CaVMName = "$prefix$($caVM.vmName)" }
        if ($rootVM) { $RootCaVMName = "$prefix$($rootVM.vmName)" }
        if ($cfg.vmOptions.domainName) { $Domain = $cfg.vmOptions.domainName }
        Write-Host "Loaded config from $ConfigPath (prefix='$prefix')" -ForegroundColor Cyan
    }
    catch {
        Write-Host "WARNING: could not parse $ConfigPath ($($_.Exception.Message)); using parameter defaults." -ForegroundColor Yellow
    }
}

$domainShort = $Domain.Split('.')[0]
# Install-TwoTierPKI computes: "$domainShort-$issuingCAVMName-CA" where issuingCAVMName
# is the (prefixed) VM name. Match that exactly by default.
if (-not $CaName) { $CaName = "$domainShort-$CaVMName-CA" }
$doRepro = $Repro.IsPresent

$logDir = Join-Path $vmbuildRoot 'logs'
if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logFile = Join-Path $logDir "PKI-SubDSDiag-$($domainShort)-$stamp.log"

Write-Host ""
Write-Host "Two-Tier PKI Subordinate RANGE_CONSTRAINT / dspublish ACCESS_DENIED diagnostic" -ForegroundColor Cyan
Write-Host "  Domain     : $Domain"
Write-Host "  CA/DC VM   : $CaVMName"
Write-Host "  Root CA VM : $RootCaVMName"
Write-Host "  Sub CA Name: $CaName"
Write-Host "  Repro      : $doRepro  (default read-only; -Repro re-runs the failing install)"
Write-Host "  Log file   : $logFile"
Write-Host ""

# --- In-guest collector (runs on the CA/DC; must be PS5.1-safe, ASCII-only) --
$diagScript = {
    param($CAName, $DomainName, $DoRepro)

    $ErrorActionPreference = 'Continue'
    $rep = [System.Collections.Generic.List[string]]::new()
    function _R($m) { $rep.Add("$m") }
    function _H($m) { $rep.Add(""); $rep.Add("==================== $m ===================="); }

    $configNC = $null
    $schemaNC = $null
    $defaultNC = $null

    function Get-SchemaAttr {
        param([string]$SchemaNC, [string]$Ldap)
        $o = [ordered]@{ Name = $Ldap; Found = $false }
        try {
            $root = [ADSI]("LDAP://" + $SchemaNC)
            $ds = New-Object System.DirectoryServices.DirectorySearcher($root)
            $ds.Filter = "(&(objectClass=attributeSchema)(lDAPDisplayName=$Ldap))"
            foreach ($p in 'rangeLower', 'rangeUpper', 'attributeSyntax', 'oMSyntax', 'isSingleValued') {
                $null = $ds.PropertiesToLoad.Add($p)
            }
            $r = $ds.FindOne()
            if ($r) {
                $o.Found = $true
                foreach ($p in 'rangeLower', 'rangeUpper', 'attributeSyntax', 'oMSyntax', 'isSingleValued') {
                    if ($r.Properties[$p].Count -gt 0) { $o[$p] = ($r.Properties[$p] -join ',') } else { $o[$p] = '' }
                }
            }
        }
        catch { $o.Error = $_.Exception.Message }
        return ($o.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '  '
    }

    function Get-DaclAce {
        param([string]$DN)
        $lines = @()
        try {
            $de = New-Object System.DirectoryServices.DirectoryEntry("LDAP://$DN")
            $sec = $de.ObjectSecurity
            if (-not $sec) { return @("$DN : (no ObjectSecurity)") }
            $lines += "$DN"
            $lines += "  Owner: $($sec.GetOwner([System.Security.Principal.NTAccount]).Value)"
            foreach ($ace in $sec.GetAccessRules($true, $true, [System.Security.Principal.NTAccount])) {
                $rights = "$($ace.ActiveDirectoryRights)"
                # Only surface the ACEs that matter for a publish: write-ish / full.
                if ($rights -match 'Write|GenericAll|GenericWrite|CreateChild|WriteDacl|WriteOwner|Self') {
                    $lines += ("    {0} {1} {2}" -f $ace.AccessControlType, $ace.IdentityReference.Value, $rights)
                }
            }
        }
        catch { $lines += "$DN : DACL error $($_.Exception.Message)" }
        return $lines
    }

    function Get-FileTail {
        param([string]$Path, [int]$Lines = 80)
        try {
            if (Test-Path $Path) { return (Get-Content -Path $Path -Tail $Lines -ErrorAction SilentlyContinue) }
            return @("(not present: $Path)")
        }
        catch { return @("Get-FileTail error on ${Path}: $($_.Exception.Message)") }
    }

    function Get-DSEventsSince {
        param([datetime]$Since, [int]$Max = 120)
        $out = @()
        try {
            $evts = Get-WinEvent -FilterHashtable @{ LogName = 'Directory Service'; StartTime = $Since } -ErrorAction SilentlyContinue
            if ($evts) {
                $evts = $evts | Sort-Object TimeCreated | Select-Object -First $Max
                foreach ($e in $evts) {
                    $flat = ($e.Message -replace '\s+', ' ')
                    if ($flat.Length -gt 500) { $flat = $flat.Substring(0, 500) }
                    $out += ("{0} Id={1} {2} [{3}] {4}" -f $e.TimeCreated.ToString('HH:mm:ss'), $e.Id, $e.LevelDisplayName, $e.ProviderName, $flat)
                }
            }
        }
        catch { $out += "Get-DSEventsSince error: $($_.Exception.Message)" }
        if ($out.Count -eq 0) { $out += "(no Directory Service events in window)" }
        return $out
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

    # ===================== BEGIN COLLECTION =====================
    _H "HOST / TIME"
    try {
        _R "Hostname: $env:COMPUTERNAME   Now(local): $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')   Now(UTC): $((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss'))"
        $os = Get-CimInstance Win32_OperatingSystem
        _R "OS: $($os.Caption)  Build: $($os.BuildNumber)"
        _R "LastBoot: $($os.LastBootUpTime)   OSUptimeMin: $([int]((Get-Date) - $os.LastBootUpTime).TotalMinutes)"
        $ls = Get-Process -Name lsass -ErrorAction SilentlyContinue
        if ($ls) { _R "lsass StartTime: $($ls.StartTime)   sinceMin: $([int]((Get-Date) - $ls.StartTime).TotalMinutes)" }
    }
    catch { _R "host info error: $($_.Exception.Message)" }

    # --- The KEY question: is the running identity effectively an Enterprise Admin? ---
    _H "IDENTITY + TOKEN GROUP MEMBERSHIP (dspublish ACCESS_DENIED smoking gun)"
    try {
        $wi = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        _R "WindowsIdentity: $($wi.Name)   AuthType: $($wi.AuthenticationType)   Impersonation: $($wi.ImpersonationLevel)"
        _R "IsSystem: $($wi.IsSystem)   User SID: $($wi.User.Value)"
    }
    catch { _R "identity error: $($_.Exception.Message)" }
    try {
        $whoami = whoami /groups /fo list 2>&1 | Out-String
        # Explicit checks for the well-known admin groups by RID (domain-relative).
        $hasEA = ($whoami -match '-519\b') -or ($whoami -match 'Enterprise Admins')
        $hasDA = ($whoami -match '-512\b') -or ($whoami -match 'Domain Admins')
        $hasSA = ($whoami -match '-518\b') -or ($whoami -match 'Schema Admins')
        _R "TOKEN HAS Enterprise Admins (RID 519): $hasEA"
        _R "TOKEN HAS Domain Admins   (RID 512): $hasDA"
        _R "TOKEN HAS Schema Admins   (RID 518): $hasSA"
        _R "--- whoami /groups (full) ---"
        foreach ($ln in ($whoami -split "`r?`n")) { if ($ln.Trim()) { _R "  $ln" } }
    }
    catch { _R "whoami error: $($_.Exception.Message)" }

    _H "SERVICES"
    foreach ($svc in 'NTDS', 'Netlogon', 'certsvc', 'DNS', 'kdc') {
        try { $s = Get-Service -Name $svc -ErrorAction SilentlyContinue; _R ("{0}: {1}" -f $svc, $(if ($s) { $s.Status } else { 'absent' })) } catch { _R "$svc : $($_.Exception.Message)" }
    }

    _H "RootDSE"
    try {
        $rootDSE = [ADSI]"LDAP://RootDSE"
        $configNC = "$($rootDSE.configurationNamingContext)"
        $schemaNC = "$($rootDSE.schemaNamingContext)"
        $defaultNC = "$($rootDSE.defaultNamingContext)"
        _R "defaultNamingContext: $defaultNC"
        _R "configurationNamingContext: $configNC"
        _R "schemaNamingContext: $schemaNC"
        _R "dsServiceName: $($rootDSE.dsServiceName)"
        _R "isSynchronized: $($rootDSE.isSynchronized)   isGlobalCatalogReady: $($rootDSE.isGlobalCatalogReady)"
        _R "highestCommittedUSN: $($rootDSE.highestCommittedUSN)"
    }
    catch { _R "RootDSE error: $($_.Exception.Message)" }

    _H "FOREST/DOMAIN FUNCTIONAL LEVEL + SCHEMA VERSION"
    try {
        if ($schemaNC) { $schemaHead = [ADSI]("LDAP://" + $schemaNC); _R "schema objectVersion: $($schemaHead.objectVersion)" }
        if ($configNC) { $partitions = [ADSI]("LDAP://CN=Partitions," + $configNC); _R "forest msDS-Behavior-Version: $($partitions.'msDS-Behavior-Version')" }
        if ($defaultNC) { $dom = [ADSI]("LDAP://" + $defaultNC); _R "domain msDS-Behavior-Version: $($dom.'msDS-Behavior-Version')" }
    }
    catch { _R "func level error: $($_.Exception.Message)" }

    _H "FSMO OWNERS"
    try {
        if ($configNC) { _R "Schema master: $(([ADSI]("LDAP://CN=Schema," + $configNC)).fsmoRoleOwner)" }
        if ($defaultNC) {
            _R "Infrastructure master: $(([ADSI]("LDAP://CN=Infrastructure," + $defaultNC)).fsmoRoleOwner)"
            _R "RID master: $(([ADSI]("LDAP://CN=RID Manager$,CN=System," + $defaultNC)).fSMORoleOwner)"
            _R "PDC: $(([ADSI]("LDAP://" + $defaultNC)).fSMORoleOwner)"
        }
    }
    catch { _R "FSMO error: $($_.Exception.Message)" }

    _H "DCDIAG (Connectivity, Advertising, Services, NetLogons, RidManager, KnowsOfRoleHolders)"
    try {
        $dd = dcdiag /test:Connectivity /test:Advertising /test:Services /test:NetLogons /test:RidManager /test:KnowsOfRoleHolders 2>&1 | Out-String
        foreach ($ln in ($dd -split "`r?`n")) { if ($ln -match 'passed|failed|error|warning|Starting test|. . . ') { _R "  $($ln.Trim())" } }
    }
    catch { _R "dcdiag error: $($_.Exception.Message)" }

    _H "PKI CONTAINERS under Public Key Services (+ children)"
    $pksDN = $null
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

    _H "EFFECTIVE DACL (Write/Full ACEs) on the publish targets"
    if ($pksDN) {
        Get-DaclAce -DN $pksDN | ForEach-Object { _R $_ }
        foreach ($c in 'CN=Certification Authorities', 'CN=NTAuthCertificates', 'CN=Enrollment Services', 'CN=AIA') {
            Get-DaclAce -DN ("$c,$pksDN") | ForEach-Object { _R $_ }
        }
    }

    _H "CONFIG-NC WRITE PROBE (create+delete a throwaway container under Public Key Services)"
    if ($pksDN) {
        try {
            $pks = [ADSI]("LDAP://" + $pksDN)
            $probeName = "memlabs-pkiprobe-" + ([guid]::NewGuid().ToString('N').Substring(0, 8))
            $child = $pks.Create("container", "CN=$probeName")
            $child.SetInfo()
            try { $pks.Delete("container", "CN=$probeName") } catch {}
            _R "WRITE PROBE RESULT: SUCCESS (Config-NC accepts a write from this identity NOW)."
        }
        catch {
            $m = "$($_.Exception.Message)"
            $hr = $null; try { $hr = "0x$('{0:X8}' -f $_.Exception.InnerException.HResult)" } catch {}
            _R "WRITE PROBE RESULT: FAILED  HR=$hr  Msg=$m"
        }
    }

    _H "CERT PUBLISHERS membership (CA machine account)"
    try {
        $cp = [ADSI]("LDAP://CN=Cert Publishers,CN=Users," + $defaultNC)
        $members = @($cp.member) | ForEach-Object { $_ }
        _R "Cert Publishers members: $($members -join ' ; ')"
        _R "This machine ($env:COMPUTERNAME`$) present: $([bool]($members -match [regex]::Escape("CN=$env:COMPUTERNAME,")))"
    }
    catch { _R "Cert Publishers error: $($_.Exception.Message)" }

    _H "ROOT CA FILES staged on this VM (needed for dspublish)"
    try {
        $rf = Get-ChildItem -Path 'C:\temp\RootCAFiles' -ErrorAction SilentlyContinue
        if ($rf) { foreach ($f in $rf) { _R "  $($f.Name)  ($($f.Length) bytes)" } } else { _R "  (C:\temp\RootCAFiles empty or missing)" }
    }
    catch { _R "root files error: $($_.Exception.Message)" }

    _H "CERTUTIL -DSPUBLISH REPRO (the exact call that returned ACCESS_DENIED; idempotent)"
    try {
        $rootCrt = Get-ChildItem -Path 'C:\temp\RootCAFiles\*.crt' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($rootCrt) {
            _R "Publishing RootCA: $($rootCrt.FullName)"
            $o1 = & certutil.exe -dspublish -f "$($rootCrt.FullName)" RootCA 2>&1 | Out-String
            _R "  RootCA exit=$LASTEXITCODE"
            foreach ($ln in ($o1 -split "`r?`n")) { if ($ln.Trim()) { _R "    $ln" } }
            $o2 = & certutil.exe -dspublish -f "$($rootCrt.FullName)" NTAuthCA 2>&1 | Out-String
            _R "  NTAuthCA exit=$LASTEXITCODE"
            foreach ($ln in ($o2 -split "`r?`n")) { if ($ln.Trim()) { _R "    $ln" } }
        }
        else { _R "  No root .crt in C:\temp\RootCAFiles - cannot repro dspublish." }
    }
    catch { _R "dspublish repro error: $($_.Exception.Message)" }

    _H "SCHEMA RANGE CONSTRAINTS for published attributes"
    if ($schemaNC) {
        foreach ($a in 'cACertificate', 'certificateTemplates', 'nTSecurityDescriptor', 'flags', 'displayName', 'cn', 'dNSHostName', 'cACertificateDN', 'cAConnect', 'cAWEBURL', 'authorityRevocationList', 'certificateRevocationList', 'crossCertificatePair', 'cRLObject', 'deltaRevocationList', 'msPKI-Enrollment-Servers', 'msPKI-Site-Name') {
            _R (Get-SchemaAttr -SchemaNC $schemaNC -Ldap $a)
        }
    }

    _H "CERTSVC / ADCS ROLE STATE"
    try {
        $svc = Get-Service -Name certsvc -ErrorAction SilentlyContinue
        _R "certsvc: $(if ($svc) { $svc.Status } else { 'absent' })   Test-CaConfigured: $(Test-CaConfigured)"
        $feat = Get-WindowsFeature -Name Adcs-Cert-Authority -ErrorAction SilentlyContinue
        if ($feat) { _R "Adcs-Cert-Authority feature Installed: $($feat.Installed)" }
        $reqDir = Get-ChildItem -Path 'C:\temp\IntCAFiles', 'C:\temp' -Filter '*.req' -ErrorAction SilentlyContinue
        if ($reqDir) { foreach ($r in $reqDir) { _R "  CSR present: $($r.FullName) ($($r.Length) bytes)" } } else { _R "  (no .req CSR staged)" }
    }
    catch { _R "certsvc state error: $($_.Exception.Message)" }

    _H "NTDS DIAGNOSTIC LEVELS (current)"
    _R "15 Field Engineering = $(Get-NtdsDiag '15 Field Engineering')"
    _R "16 LDAP Interface Events = $(Get-NtdsDiag '16 LDAP Interface Events')"
    _R "9 Internal Processing = $(Get-NtdsDiag '9 Internal Processing')"

    _H "certocm.log tail (last 80)"
    Get-FileTail -Path 'C:\Windows\certocm.log' -Lines 80 | ForEach-Object { _R $_ }

    _H "Directory Service events - recent (last 40)"
    try {
        Get-WinEvent -LogName 'Directory Service' -MaxEvents 40 -ErrorAction SilentlyContinue | Sort-Object TimeCreated |
        ForEach-Object { $f = ($_.Message -replace '\s+', ' '); if ($f.Length -gt 300) { $f = $f.Substring(0, 300) }; _R ("{0} Id={1} {2} {3}" -f $_.TimeCreated.ToString('MM-dd HH:mm:ss'), $_.Id, $_.LevelDisplayName, $f) }
    }
    catch { _R "DS tail error: $($_.Exception.Message)" }

    if (-not $DoRepro) {
        _H "READ-ONLY MODE (no -Repro): collection complete, no install attempted"
        return @{ Success = $false; Report = $rep.ToArray() }
    }

    # ===================== OPTIONAL REPRO =====================
    _H "REPRO: enable NTDS Field Engineering=5, LDAP Interface Events=2"
    $priorFE = Get-NtdsDiag '15 Field Engineering'
    $priorLDAP = Get-NtdsDiag '16 LDAP Interface Events'
    Set-NtdsDiag '15 Field Engineering' 5
    Set-NtdsDiag '16 LDAP Interface Events' 2
    $markerLocal = Get-Date
    _R "marker(local): $($markerLocal.ToString('yyyy-MM-dd HH:mm:ss'))   marker(UTC): $($markerLocal.ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss'))"
    Start-Sleep -Seconds 2

    _H "REPRO: ensure ADCS role + tear down any partial config, prepare CSR path"
    try { Install-WindowsFeature Adcs-Cert-Authority -IncludeManagementTools | Out-Null; _R "Adcs-Cert-Authority ensured." } catch { _R "feature install error: $($_.Exception.Message)" }
    try { Uninstall-AdcsCertificationAuthority -Force -ErrorAction SilentlyContinue | Out-Null; _R "Pre-uninstall of any partial config done." } catch { _R "pre-uninstall note: $($_.Exception.Message)" }
    $reqDir = 'C:\temp\IntCAFiles'
    try { if (-not (Test-Path $reqDir)) { New-Item -Path $reqDir -ItemType Directory -Force | Out-Null } } catch {}
    $reqFile = Join-Path $reqDir "$CAName.req"

    _H "REPRO: Install-AdcsCertificationAuthority -CAType EnterpriseSubordinateCa (exact failing call)"
    $threw = $false
    $installReturn = $null
    try {
        $installReturn = Install-AdcsCertificationAuthority -CAType EnterpriseSubordinateCa `
            -CACommonName $CAName `
            -CryptoProviderName "RSA#Microsoft Software Key Storage Provider" `
            -KeyLength 2048 `
            -HashAlgorithmName SHA256 `
            -OutputCertRequestFile $reqFile `
            -Force -Verbose 4>&1
    }
    catch {
        $threw = $true
        $ex = $_.Exception
        _R "EXCEPTION thrown by cmdlet."
        _R "  Type: $($ex.GetType().FullName)"
        _R "  HResult: 0x$('{0:X8}' -f $ex.HResult)"
        _R "  Message: $($ex.Message)"
        $inner = $ex.InnerException; $depth = 0
        while ($inner -and $depth -lt 6) {
            _R "  Inner[$depth] $($inner.GetType().FullName): 0x$('{0:X8}' -f $inner.HResult) : $($inner.Message)"
            $inner = $inner.InnerException; $depth++
        }
    }
    _R "Cmdlet returned (threw=$threw):"
    if ($null -ne $installReturn) {
        try { ($installReturn | Format-List * | Out-String) -split "`r?`n" | Where-Object { $_.Trim() } | ForEach-Object { _R "  $_" } } catch { _R "  (could not format return)" }
    }
    else { _R "  <null>" }

    Start-Sleep -Seconds 3
    $caOk = Test-CaConfigured
    _R "Test-CaConfigured after attempt: $caOk   CSR present: $([bool](Test-Path $reqFile))"

    _H "REPRO AFTER: certocm.log tail (last 120)"
    Get-FileTail -Path 'C:\Windows\certocm.log' -Lines 120 | ForEach-Object { _R $_ }

    _H "REPRO AFTER: FULL Directory Service events since marker (offending attribute lands here)"
    Get-DSEventsSince -Since $markerLocal -Max 150 | ForEach-Object { _R $_ }

    _H "REPRO RESTORE: NTDS diag levels + tear down partial config"
    $rFE = 0; if ($null -ne $priorFE) { $rFE = [int]$priorFE }
    $rLDAP = 0; if ($null -ne $priorLDAP) { $rLDAP = [int]$priorLDAP }
    Set-NtdsDiag '15 Field Engineering' $rFE
    Set-NtdsDiag '16 LDAP Interface Events' $rLDAP
    _R "Restored FE=$rFE LDAP=$rLDAP"
    if (-not $caOk) {
        try { Uninstall-AdcsCertificationAuthority -Force -ErrorAction SilentlyContinue | Out-Null; _R "Removed partial CA config so the real re-run starts clean." } catch { _R "cleanup note: $($_.Exception.Message)" }
    }
    else {
        _R "CA IS CONFIGURED (repro worked) - leaving it. Re-run New-Lab.ps1 -startPhase 2 to finish the chain."
    }

    return @{ Success = $caOk; Report = $rep.ToArray() }
}

# --- Run it ------------------------------------------------------------------
# A log is ALWAYS written from here on, no matter what fails, so a fast/empty run
# still leaves evidence. Do NOT let $ErrorActionPreference='Stop' abort silently.
$ErrorActionPreference = 'Continue'

$modeMsg = if ($doRepro) { "READ + REPRO (re-runs the failing install)" } else { "READ-ONLY collection" }
$diag = New-Object System.Collections.Generic.List[string]
function Log-Line { param([string]$m, [string]$c = 'Gray') Write-Host $m -ForegroundColor $c; $diag.Add($m) }

$header = @(
    "Two-Tier PKI Subordinate RANGE_CONSTRAINT / dspublish ACCESS_DENIED diagnostic",
    "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
    "Domain=$Domain  CaVM=$CaVMName  RootCaVM=$RootCaVMName  SubCaName=$CaName  Repro=$doRepro  Mode=$modeMsg",
    "============================================================================"
)
$header | Set-Content -Path $logFile -Encoding UTF8

# --- Preflight: does the VM exist and is it running? -------------------------
$vm = $null
try { $vm = Get-VM -Name $CaVMName -ErrorAction SilentlyContinue } catch {}
if (-not $vm) {
    Log-Line "PREFLIGHT FAIL: Hyper-V VM '$CaVMName' not found on this host." 'Red'
    Log-Line "  Running lab VMs:" 'Yellow'
    try { Get-VM | Where-Object { $_.State -eq 'Running' } | Select-Object -ExpandProperty Name | Sort-Object | ForEach-Object { Log-Line "    $_" } } catch { Log-Line "    (Get-VM failed: $($_.Exception.Message))" }
    Log-Line "  -> Pass the correct -CaVMName (with prefix, e.g. PL-HOAGIE) or -ConfigPath." 'Yellow'
    $diag | Add-Content -Path $logFile -Encoding UTF8
    Write-Host ""; Write-Host "Log written to: $logFile" -ForegroundColor Green
    return
}
Log-Line "Preflight: VM '$CaVMName' State=$($vm.State)  Uptime=$($vm.Uptime)"
if ($vm.State -ne 'Running') {
    Log-Line "PREFLIGHT FAIL: VM '$CaVMName' is not Running (State=$($vm.State)). Start it, then re-run." 'Red'
    $diag | Add-Content -Path $logFile -Encoding UTF8
    Write-Host ""; Write-Host "Log written to: $logFile" -ForegroundColor Green
    return
}

# --- Establish a session and sanity-check it (proven host-tool pattern) -------
$session = $null
try {
    $session = Get-VmSession -VmName $CaVMName -VmDomainName $Domain
}
catch {
    Log-Line "Get-VmSession threw: $($_.Exception.Message)" 'Red'
}
if (-not $session) {
    Log-Line "SESSION FAIL: Get-VmSession returned null for $CaVMName / $Domain (domain-cred PSDirect path failed)." 'Red'
    Log-Line "  The DC/CA may be mid-reboot, the domain creds may be wrong, or the guest may be unreachable." 'Yellow'
    $diag | Add-Content -Path $logFile -Encoding UTF8
    Write-Host ""; Write-Host "Log written to: $logFile" -ForegroundColor Green
    return
}
try {
    $ping = Invoke-Command -Session $session -ScriptBlock { "$env:COMPUTERNAME|$([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)" } -ErrorAction Stop
    Log-Line "Session OK: guest replied '$ping'"
}
catch {
    Log-Line "SESSION SANITY FAIL: Invoke-Command on the session threw: $($_.Exception.Message)" 'Red'
    $diag | Add-Content -Path $logFile -Encoding UTF8
    Write-Host ""; Write-Host "Log written to: $logFile" -ForegroundColor Green
    return
}

# --- Run the collector directly on the session (returns the hashtable) --------
Write-Host "Invoking in-guest collector on $CaVMName [$modeMsg]..." -ForegroundColor Cyan
$out = $null
try {
    $out = Invoke-Command -Session $session -ScriptBlock $diagScript -ArgumentList $CaName, $Domain, $doRepro -ErrorAction Stop
}
catch {
    Log-Line "COLLECTOR THREW: $($_.Exception.Message)" 'Red'
    if ($_.ScriptStackTrace) { Log-Line "  $($_.ScriptStackTrace -replace '\s+', ' ')" }
}

if ($out -and $out.Report) {
    $diag | Add-Content -Path $logFile -Encoding UTF8
    $out.Report | Add-Content -Path $logFile -Encoding UTF8
    Write-Host ""
    Write-Host "Diagnostic complete. Repro-CA-configured=$($out.Success)" -ForegroundColor Green
    Write-Host "Log written to: $logFile" -ForegroundColor Green
    Write-Host ""
    Write-Host "Review these sections first:" -ForegroundColor Cyan
    Write-Host "  - IDENTITY + TOKEN GROUP MEMBERSHIP  (is the publish identity an Enterprise Admin?)"
    Write-Host "  - CONFIG-NC WRITE PROBE              (does the DC accept a Config-NC write now?)"
    Write-Host "  - EFFECTIVE DACL                     (does EA/this identity have Write on the containers?)"
    Write-Host "  - CERTUTIL -DSPUBLISH REPRO          (the ACCESS_DENIED call, live)"
}
else {
    Log-Line "NO REPORT RETURNED. Raw result type: $(if ($null -ne $out) { $out.GetType().FullName } else { '<null>' })" 'Yellow'
    if ($null -ne $out) { Log-Line (($out | Format-List * | Out-String)) }
    $diag | Add-Content -Path $logFile -Encoding UTF8
    Write-Host ""
    Write-Host "WARNING: in-guest collector returned no report. See $logFile for the captured detail." -ForegroundColor Yellow
}
