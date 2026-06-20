<#
.SYNOPSIS
  One-shot capture of EVERYTHING relevant to ConfigMgr PKI/HTTPS DP client-cert
  negotiation, from a KNOWN-GOOD PKI domain. Run once on the MemLabs HOST with the
  working domain booted. Uses Hyper-V PowerShell Direct so it works regardless of
  cross-domain trust.

.WHY
  We need to know how a WORKING PKI DP gets the client to present its certificate
  for BITS content download over HTTPS. Specifically whether client-cert negotiation
  lives at:
    (a) the IIS vdir sslFlags (SMS_DP_SMSPKG$ / SMS_DP_SMSSIG$),
    (b) the Default Web Site sslFlags (inherited), or
    (c) the HTTP.SYS SSL binding "Negotiate Client Certificate" flag (netsh http show sslcert).
  On the broken DP (ZZ-WAFFLE) the vdir sslFlags = 0. If the working DP ALSO shows
  vdir sslFlags = 0 but http.sys negotiate = Enabled, the vdir flag is a red herring
  and the real mechanism (and the real bug) is the http.sys binding.

.PARAMETER DPName
  Working domain's regular (non-pull) HTTPS DP VM name. REQUIRED.

.PARAMETER SiteServerName
  Working domain's Primary/site server VM name (for the DB-side DP SslState). Optional.

.PARAMETER ClientName
  A working client VM name in the working domain (for ccmsetup success evidence). Optional.

.PARAMETER SiteCode
  Working site code (e.g. ABC). Optional but recommended for the site-server query.

.PARAMETER PullDPName
  Optional: the working domain's PULL DP VM name, to capture both DP shapes.

.EXAMPLE
  .\Capture-WorkingPkiDp.ps1 -DPName WORK-DP01 -SiteServerName WORK-PS01 -ClientName WORK-CL01 -SiteCode ABC
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$DPName,
    [string]$SiteServerName,
    [string]$ClientName,
    [string]$SiteCode,
    [string]$PullDPName,
    [pscredential]$Credential
)

$ErrorActionPreference = 'Continue'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$outFile = "C:\temp\working-pki-dp-capture-$stamp.txt"
New-Item -ItemType Directory -Path 'C:\temp' -Force | Out-Null

if (-not $Credential) {
    $Credential = Get-Credential -Message "Working-domain admin (DOMAIN\admin or .\localadmin) for PowerShell Direct"
}

# ---------------------------------------------------------------------------
# Scriptblock that runs INSIDE the DP guest. PS 5.1-safe (no ?? / ?. / ternary).
# Returns one big string so nothing gets truncated by object formatting.
# ---------------------------------------------------------------------------
$dpSB = {
    $sb = New-Object System.Text.StringBuilder
    function Add([string]$t) { [void]$sb.AppendLine($t) }
    Add("==================== DP: $env:COMPUTERNAME ====================")
    Add("Captured: $(Get-Date -Format o)")
    Add("OS: $((Get-CimInstance Win32_OperatingSystem).Caption)")

    Add("`n----- Windows features (IIS auth / metabase) -----")
    try {
        Import-Module ServerManager -ErrorAction SilentlyContinue
        $feat = Get-WindowsFeature Web-Metabase, Web-WMI, Web-Windows-Auth, Web-Cert-Auth, Web-Client-Auth, Web-Url-Auth, Web-Filtering -ErrorAction SilentlyContinue
        foreach ($f in $feat) { Add(("{0,-22} {1}" -f $f.Name, $f.InstallState)) }
    } catch { Add("feature query error: $($_.Exception.Message)") }

    Import-Module WebAdministration -ErrorAction SilentlyContinue
    $appcmd = "$env:windir\system32\inetsrv\appcmd.exe"
    $vdirs = 'SMS_DP_SMSPKG$', 'SMS_DP_SMSSIG$', 'NOCERT_SMS_DP_SMSPKG$', 'NOCERT_SMS_DP_SMSSIG$'

    Add("`n----- Default Web Site: effective sslFlags + auth -----")
    try {
        $siteFlags = (Get-WebConfigurationProperty -PSPath 'IIS:\Sites\Default Web Site' -Filter 'system.webServer/security/access' -Name sslFlags -ErrorAction SilentlyContinue).Value
        Add("Default Web Site sslFlags = [$siteFlags]")
    } catch { Add("site sslFlags error: $($_.Exception.Message)") }

    Add("`n----- Per-vdir effective sslFlags + anon/windows auth (WebAdministration) -----")
    foreach ($v in $vdirs) {
        $p = "IIS:\Sites\Default Web Site\$v"
        if (Test-Path $p) {
            $ssl  = (Get-WebConfigurationProperty -PSPath $p -Filter 'system.webServer/security/access' -Name sslFlags -ErrorAction SilentlyContinue).Value
            $anon = (Get-WebConfigurationProperty -PSPath $p -Filter 'system.webServer/security/authentication/anonymousAuthentication' -Name enabled -ErrorAction SilentlyContinue).Value
            $win  = (Get-WebConfigurationProperty -PSPath $p -Filter 'system.webServer/security/authentication/windowsAuthentication' -Name enabled -ErrorAction SilentlyContinue).Value
            Add(("{0,-26} sslFlags=[{1}]  Anon={2}  Win={3}" -f $v, $ssl, $anon, $win))
        } else {
            Add(("{0,-26} (vdir not present)" -f $v))
        }
    }

    Add("`n----- appcmd merged 'access' section per vdir (ground truth IIS applies) -----")
    foreach ($v in $vdirs) {
        if (Test-Path "IIS:\Sites\Default Web Site\$v") {
            Add(">> $v")
            Add((& $appcmd list config "Default Web Site/$v" /section:access 2>&1 | Out-String))
            Add((& $appcmd list config "Default Web Site/$v" /section:system.webServer/security/authentication/clientCertificateMappingAuthentication 2>&1 | Out-String))
        }
    }

    Add("`n----- iisClientCertificateMappingAuthentication (one-to-one mapping) at site -----")
    try {
        $m = Get-WebConfiguration -PSPath 'IIS:\Sites\Default Web Site' -Filter 'system.webServer/security/authentication/iisClientCertificateMappingAuthentication' -ErrorAction SilentlyContinue
        Add("iisClientCertMapping enabled = [$($m.enabled)] manyToOne=[$($m.manyToOneCertificateMappingsEnabled)] oneToOne=[$($m.oneToOneCertificateMappingsEnabled)]")
    } catch { Add("certmap error: $($_.Exception.Message)") }

    Add("`n----- IIS site bindings (https + SNI sslFlags) -----")
    try {
        Get-WebBinding -Name 'Default Web Site' | ForEach-Object {
            Add(("protocol={0} info={1} sslFlags={2}" -f $_.protocol, $_.bindingInformation, $_.sslFlags))
        }
    } catch { Add("binding error: $($_.Exception.Message)") }

    Add("`n***** HTTP.SYS SSL cert bindings (netsh http show sslcert) *****")
    Add("***** Look at 'Negotiate Client Certificate', 'DS Mapper Usage', 'Verify Client Certificate Revocation' *****")
    Add((& netsh http show sslcert 2>&1 | Out-String))

    Add("`n----- DP SSL state in registry (HKLM\SOFTWARE\Microsoft\SMS\DP) -----")
    $regKeys = 'HKLM:\SOFTWARE\Microsoft\SMS\DP', 'HKLM:\SOFTWARE\Wow6432Node\Microsoft\SMS\DP'
    foreach ($rk in $regKeys) {
        if (Test-Path $rk) {
            Add(">> $rk")
            Add((Get-ItemProperty -Path $rk | Select-Object -Property * -ExcludeProperty PS* | Format-List | Out-String))
        }
    }

    Add("`n----- smsdpprov.log: cert/sslFlags lines (did SslNegotiateCert ever run here?) -----")
    $logCandidates = @('E:', 'F:', 'D:', 'G:', 'C:') | ForEach-Object { "$_\SMS_DP`$\sms\logs\smsdpprov.log" }
    $found = $false
    foreach ($lp in $logCandidates) {
        if (Test-Path $lp) {
            $found = $true
            Add("log = $lp")
            $hits = Select-String -Path $lp -Pattern 'Negotiate Client Certificates|SslNegotiateCert|sslFlags|Require Client Certificates|Require SSL|dwSSLState|SSLState' -ErrorAction SilentlyContinue
            if ($hits) { Add(($hits | Select-Object -Last 60 | ForEach-Object { $_.Line }) -join "`n") }
            else { Add("(no matching lines)") }
            break
        }
    }
    if (-not $found) { Add("(smsdpprov.log not found on E/F/D/G/C)") }

    Add("`n----- Bound HTTPS cert (thumbprint + EKU) in LocalMachine\My -----")
    try {
        Get-ChildItem Cert:\LocalMachine\My | ForEach-Object {
            $eku = ($_.EnhancedKeyUsageList | ForEach-Object { $_.FriendlyName }) -join ','
            Add(("Thumb={0} Subject={1} EKU=[{2}]" -f $_.Thumbprint, $_.Subject, $eku))
        }
    } catch { Add("cert enum error: $($_.Exception.Message)") }

    $sb.ToString()
}

# ---------------------------------------------------------------------------
# Site-server scriptblock: DB-side DP SslState (compare to broken DP's 63).
# ---------------------------------------------------------------------------
$ssSB = {
    param($SiteCode)
    $sb = New-Object System.Text.StringBuilder
    function Add([string]$t) { [void]$sb.AppendLine($t) }
    Add("==================== SITE SERVER: $env:COMPUTERNAME ====================")
    if (-not $SiteCode) {
        try { $SiteCode = (Get-CimInstance -Namespace 'root\sms' -ClassName SMS_ProviderLocation -ErrorAction Stop | Select-Object -First 1).SiteCode } catch {}
    }
    Add("SiteCode = $SiteCode")
    $ns = "root\sms\site_$SiteCode"
    Add("`n----- SMS_DistributionPointInfo (Name / SslState / IsPullDP) -----")
    try {
        Get-CimInstance -Namespace $ns -ClassName SMS_DistributionPointInfo -ErrorAction Stop |
            Select-Object Name, SslState, IsPullDP, IsPXE, IsActive |
            ForEach-Object { Add(("{0,-45} SslState={1} Pull={2} PXE={3}" -f $_.Name, $_.SslState, $_.IsPullDP, $_.IsPXE)) }
    } catch { Add("DPInfo error: $($_.Exception.Message)") }

    Add("`n----- SMS_SCI_SysResUse DP role props (CertificateContextData length / Props) -----")
    try {
        $r = Get-CimInstance -Namespace $ns -ClassName SMS_SCI_SysResUse -Filter "RoleName='SMS Distribution Point'" -ErrorAction Stop
        foreach ($row in $r) {
            Add(">> $($row.NALPath)")
            foreach ($pl in $row.Props) {
                if ($pl.PropertyName -match 'SSL|Cert|Https|Internet|Anonymous') {
                    Add(("   {0} = Value:{1} Value1:{2}" -f $pl.PropertyName, $pl.Value, $pl.Value1))
                }
            }
        }
    } catch { Add("SCI error: $($_.Exception.Message)") }

    Add("`n***** Enhanced HTTP / token state (the CCMTOKENAUTH path) *****")
    # Site-wide eHTTP + client-cert communication settings live in SMS_SCI_SCProperty
    # under the SMS_HIERARCHY_MANAGER / SMS_POLICY_PROVIDER components. Dump anything
    # token / eHTTP / cert / CRL / communication related so we can diff working vs broken.
    try {
        $props = Get-CimInstance -Namespace $ns -ClassName SMS_SCI_SCProperty -ErrorAction Stop |
            Where-Object { $_.PropertyName -match 'Token|eHTTP|EnhancedHTTP|HTTPSOnly|ClientCert|UsePKI|CRL|CommunicationMode|Enable' }
        if ($props) {
            foreach ($p in $props) { Add(("   [{0}] {1} = Value:{2} Value1:{3}" -f $p.ItemName, $p.PropertyName, $p.Value, $p.Value1)) }
        } else { Add("   (no token/eHTTP SCProperty matched)") }
    } catch { Add("SCProperty error: $($_.Exception.Message)") }
    # Site definition flags
    try {
        $sd = Get-CimInstance -Namespace $ns -ClassName SMS_SCI_SiteDefinition -ErrorAction SilentlyContinue
        foreach ($d in $sd) {
            foreach ($pl in $d.Props) {
                if ($pl.PropertyName -match 'Token|eHTTP|HTTPS|ClientCert|PKI|CRL|Communication') {
                    Add(("   SiteDef {0} = Value:{1} Value1:{2}" -f $pl.PropertyName, $pl.Value, $pl.Value1))
                }
            }
        }
    } catch {}
    # mpcontrol / token-signing cert health
    Add("`n----- MP token / SMS Issuing cert in LocalMachine (SMS Token / Issuing) -----")
    try {
        Get-ChildItem Cert:\LocalMachine\SMS -ErrorAction SilentlyContinue | ForEach-Object {
            Add(("   SMS store: Thumb={0} Subject={1} NotAfter={2}" -f $_.Thumbprint, $_.Subject, $_.NotAfter))
        }
    } catch {}
    Add("`n----- Site server local time (clock skew check) -----")
    Add("   LocalTime(UTC) = $((Get-Date).ToUniversalTime().ToString('o'))")
    $sb.ToString()
}

# ---------------------------------------------------------------------------
# Client scriptblock: ccmsetup success evidence + how it authenticated to the DP.
# ---------------------------------------------------------------------------
$clSB = {
    $sb = New-Object System.Text.StringBuilder
    function Add([string]$t) { [void]$sb.AppendLine($t) }
    Add("==================== CLIENT: $env:COMPUTERNAME ====================")

    Add("`n----- Clock / time skew (tokens + Kerberos are time-sensitive) -----")
    Add("   LocalTime(UTC) = $((Get-Date).ToUniversalTime().ToString('o'))")
    try { Add((& w32tm /query /status 2>&1 | Out-String)) } catch {}

    Add("`n----- Client PKI cert(s) in LocalMachine\My (issuer must be MP-trusted) -----")
    try {
        Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue | ForEach-Object {
            $eku = ($_.EnhancedKeyUsageList | ForEach-Object { $_.FriendlyName }) -join ','
            Add(("   Thumb={0} Subj={1} Issuer={2} EKU=[{3}] NotAfter={4}" -f $_.Thumbprint, $_.Subject, $_.Issuer, $eku, $_.NotAfter))
        }
    } catch {}

    $pattern = 'BITS|0x800704dd|800704dd|InternetMode|GetDPLocations|Authorization|Negotiate|client cert|CCMTOKENAUTH|SMS_DP_SMSPKG|token|Successfully downloaded|return code|sslFlags|BG_AUTH'

    # Live ccmsetup.log
    $log = 'C:\Windows\ccmsetup\Logs\ccmsetup.log'
    if (Test-Path $log) {
        Add("`n----- ccmsetup.log (live): download / auth / token / BITS lines -----")
        $hits = Select-String -Path $log -Pattern $pattern -ErrorAction SilentlyContinue
        if ($hits) { Add(($hits | Select-Object -Last 80 | ForEach-Object { $_.Line }) -join "`n") }
        Add("`n----- ccmsetup.log (live) tail (30) -----")
        Add((Get-Content $log -Tail 30 | Out-String))
    } else { Add("(no live ccmsetup.log)") }

    # Rolled ccmsetup-*.log files (where the ORIGINAL 0x800704dd most likely lives)
    Add("`n----- ROLLED ccmsetup-*.log: lines around 0x800704dd / token / auth -----")
    try {
        $rolled = Get-ChildItem 'C:\Windows\ccmsetup\Logs\ccmsetup-*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime
        if ($rolled) {
            foreach ($rf in $rolled) {
                $rh = Select-String -Path $rf.FullName -Pattern $pattern -ErrorAction SilentlyContinue
                if ($rh) {
                    Add(">> $($rf.Name)")
                    Add(($rh | Select-Object -Last 50 | ForEach-Object { $_.Line }) -join "`n")
                }
            }
        } else { Add("(no rolled ccmsetup-*.log)") }
    } catch { Add("rolled-log error: $($_.Exception.Message)") }

    # ClientLocation / token acquisition (only present once client is partly up)
    foreach ($cl in @('LocationServices.log','ClientIDManagerStartup.log','CcmMessaging.log')) {
        $p = "C:\Windows\CCM\Logs\$cl"
        if (Test-Path $p) {
            Add("`n----- $cl : token / auth / DP / cert lines -----")
            $h = Select-String -Path $p -Pattern 'token|CCMTOKENAUTH|SMS_DP_SMSPKG|client cert|Authorization|Negotiate|MP_|GetToken|registration' -ErrorAction SilentlyContinue
            if ($h) { Add(($h | Select-Object -Last 40 | ForEach-Object { $_.Line }) -join "`n") }
        }
    }
    $sb.ToString()
}

# ---------------------------------------------------------------------------
# Drive it. Try PowerShell Direct (-VMName); fall back to -ComputerName.
# ---------------------------------------------------------------------------
function Invoke-Capture {
    param([string]$VmName, [scriptblock]$Block, [object[]]$ArgList)
    Write-Host "  capturing $VmName ..." -ForegroundColor Cyan
    try {
        return Invoke-Command -VMName $VmName -Credential $Credential -ScriptBlock $Block -ArgumentList $ArgList -ErrorAction Stop
    } catch {
        Write-Host "    PowerShell Direct failed ($($_.Exception.Message)); trying -ComputerName" -ForegroundColor Yellow
        try {
            return Invoke-Command -ComputerName $VmName -Credential $Credential -ScriptBlock $Block -ArgumentList $ArgList -ErrorAction Stop
        } catch {
            return "CAPTURE FAILED for $VmName : $($_.Exception.Message)"
        }
    }
}

$all = New-Object System.Text.StringBuilder
[void]$all.AppendLine("MemLabs working-PKI-DP capture  $stamp")
[void]$all.AppendLine("DPName=$DPName SiteServer=$SiteServerName Client=$ClientName SiteCode=$SiteCode PullDP=$PullDPName")
[void]$all.AppendLine("")

[void]$all.AppendLine((Invoke-Capture -VmName $DPName -Block $dpSB))
if ($PullDPName)     { [void]$all.AppendLine((Invoke-Capture -VmName $PullDPName     -Block $dpSB)) }
if ($SiteServerName) { [void]$all.AppendLine((Invoke-Capture -VmName $SiteServerName -Block $ssSB -ArgList @($SiteCode))) }
if ($ClientName)     { [void]$all.AppendLine((Invoke-Capture -VmName $ClientName     -Block $clSB)) }

$all.ToString() | Set-Content -Path $outFile -Encoding UTF8
Write-Host "`nSaved: $outFile" -ForegroundColor Green
Write-Host "Open it, or paste it back here." -ForegroundColor Green
