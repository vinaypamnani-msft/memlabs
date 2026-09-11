<#
.SYNOPSIS
    Collects cross-forest ConfigMgr client-PKI-certificate diagnostics into vmbuild\logs.

.DESCRIPTION
    One-shot diagnostic collector for the "cross-forest client never gets a
    ConfigMgr client-auth cert" problem (ccmsetup CCM_E_NO_CLIENT_PKI_CERT /
    80092004). Runs from the Hyper-V host and uses PowerShell Direct to reach:

      - The remote CA / OtherDC (default CST-DC1, cstest8 forest): dumps the
        ConfigMgrClientCertificate template ACL, tests whether the FOREIGN
        domain's "Domain Computers" principal resolves on the CA, reads the
        SID-native ACEs written by the current DSC implementation, and pulls
        the DSC status logs for the AddCertificateTemplate resource.

      - The cross-forest client (default CSB-W11CLIENT1, cstest8b forest):
        dumps LocalMachine\My certs, the CertificateServicesClient-
        AutoEnrollment Application-log events, and the autoenrollment GPO state.

    All output is written to a single timestamped file in vmbuild\logs so it can
    be parsed without further round-trips.

    Both lab domains share the same admin name/password, so one credential
    (entered interactively via Get-Credential -- never passed on the command
    line) is reused for both forests with the appropriate domain prefix.

.NOTES
    PS5.1-safe inside the in-guest scriptblocks (no ternary / null-conditional).
#>
[CmdletBinding()]
param(
    [string]$CaVm = 'CST-DC1',
    [string]$ClientVm = 'CSB-W11CLIENT1',
    [string]$PrimaryVm = 'CST-PRISITE',
    [string]$SiteCode = 'PRI',
    [string]$ClientNetwork = '10.8.8.0',
    [string]$CaDomainNetbios = 'cstest8',
    [string]$ClientDomainNetbios = 'cstest8b',
    [string]$TemplateName = 'ConfigMgrClientCertificate',
    [string]$AdminName = 'admin'
)

$ErrorActionPreference = 'Continue'
# Script lives in vmbuild\tools; write diagnostics to vmbuild\logs (one level up).
$logDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$outFile = Join-Path $logDir "crossforest-pki-diag-$stamp.txt"

function Add-Section {
    param([string]$Title, [object]$Body)
    $sep = ('=' * 78)
    Add-Content -Path $outFile -Value "`r`n$sep`r`n=== $Title`r`n$sep"
    if ($null -ne $Body) {
        Add-Content -Path $outFile -Value ($Body | Out-String)
    }
}

Add-Content -Path $outFile -Value "Cross-forest PKI client-cert diagnostic  ($stamp)"
Add-Content -Path $outFile -Value "CA/OtherDC=$CaVm ($CaDomainNetbios)   Client=$ClientVm ($ClientDomainNetbios)   Template=$TemplateName"

# One password for both forests (shared admin). Entered locally; never via the model.
$pw = (Get-Credential -UserName "$CaDomainNetbios\$AdminName" -Message "Enter the lab admin password (used for both forests)").Password
$caCred     = New-Object System.Management.Automation.PSCredential ("$CaDomainNetbios\$AdminName", $pw)
$clientCred = New-Object System.Management.Automation.PSCredential ("$ClientDomainNetbios\$AdminName", $pw)

# ---------------------------------------------------------------------------
#  CA / OtherDC collection (runs in-guest on CST-DC1 -- PS5.1)
# ---------------------------------------------------------------------------
$caScript = {
    param($TemplateName, $ClientDomainNetbios)
    $out = [System.Collections.Generic.List[string]]::new()
    function W { param($t) $script:out.Add([string]$t) }
    function Get-TemplateAclGrantState {
        param([object[]]$AccessRules, [string]$SidValue)

        $enrollGuid = [guid]'0e10c968-78fb-11d2-90d4-00c04f79dc55'
        $autoEnrollGuid = [guid]'a05b8cc2-17bc-4802-a710-e7c15ab866a2'
        $granted = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $matchingCount = 0
        foreach ($ace in @($AccessRules | Where-Object { $null -ne $_ })) {
            try {
                if ($ace.IdentityReference -is [System.Security.Principal.SecurityIdentifier]) {
                    $aceSid = $ace.IdentityReference.Value
                }
                else {
                    $aceSid = $ace.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value
                }
            }
            catch { $aceSid = "$($ace.IdentityReference)" }
            if ($aceSid -ne $SidValue) { continue }
            $matchingCount++
            if ("$($ace.AccessControlType)" -ne 'Allow') { continue }

            $rights = [System.DirectoryServices.ActiveDirectoryRights]$ace.ActiveDirectoryRights
            $genericAll = ($rights -band [System.DirectoryServices.ActiveDirectoryRights]::GenericAll) -eq [System.DirectoryServices.ActiveDirectoryRights]::GenericAll
            if ($genericAll -or (($rights -band [System.DirectoryServices.ActiveDirectoryRights]::GenericRead) -eq [System.DirectoryServices.ActiveDirectoryRights]::GenericRead)) {
                [void]$granted.Add('Read')
            }
            if ($genericAll) {
                [void]$granted.Add('Enroll')
                [void]$granted.Add('AutoEnroll')
                continue
            }
            if (($rights -band [System.DirectoryServices.ActiveDirectoryRights]::ExtendedRight) -ne [System.DirectoryServices.ActiveDirectoryRights]::ExtendedRight) { continue }
            $objectType = [guid]$ace.ObjectType
            if ($objectType -eq $enrollGuid) { [void]$granted.Add('Enroll') }
            elseif ($objectType -eq $autoEnrollGuid) { [void]$granted.Add('AutoEnroll') }
        }
        $required = @('Read', 'Enroll', 'AutoEnroll')
        $missing = @($required | Where-Object { -not $granted.Contains($_) })
        return [pscustomobject]@{
            Complete = $missing.Count -eq 0
            MatchingCount = $matchingCount
            Granted = @($required | Where-Object { $granted.Contains($_) })
            Missing = $missing
        }
    }

    W "### certutil -v -template $TemplateName (security descriptor + ACEs) ###"
    try { W ((& certutil -v -template $TemplateName 2>&1 | Out-String)) } catch { W "ERR certutil: $($_.Exception.Message)" }

    W "### Resolve the foreign Domain Computers SID on this CA ###"
    try {
        Import-Module ActiveDirectory -ErrorAction Stop
        $clientDomainSid = (Get-ADDomain -Identity $ClientDomainNetbios -ErrorAction Stop).DomainSID.Value
        $sid = [System.Security.Principal.SecurityIdentifier]"$clientDomainSid-515"
        W "OK: foreign Domain Computers RID 515 -> $($sid.Value)"
    } catch { W "FAIL: cannot resolve foreign Domain Computers RID 515: $($_.Exception.GetType().Name): $($_.Exception.Message)" }

    W "### SID-native template ACL readback (current production path) ###"
    try {
        $configContext = "$(([ADSI]'LDAP://RootDSE').configurationNamingContext)"
        if ($configContext -notmatch '^CN=Configuration,DC=') { throw "Unusable configurationNamingContext '$configContext'" }
        $templatePath = "LDAP://CN=$TemplateName,CN=Certificate Templates,CN=Public Key Services,CN=Services,$configContext"
        if (-not [System.DirectoryServices.DirectoryEntry]::Exists($templatePath)) { throw "Template '$TemplateName' is absent." }
        $template = [ADSI]$templatePath
        $accessRules = @($template.psbase.ObjectSecurity.Access | Where-Object { $null -ne $_ })
        foreach ($ace in $accessRules) {
            try { $aceSid = $ace.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value }
            catch { $aceSid = "$($ace.IdentityReference)" }
            if ($aceSid -eq $sid.Value) {
                W ("  {0}  rights={1}  objectType={2}  SID={3}" -f $ace.AccessControlType, $ace.ActiveDirectoryRights, $ace.ObjectType, $aceSid)
            }
        }
        $grantState = Get-TemplateAclGrantState -AccessRules $accessRules -SidValue $sid.Value
        if ($grantState.Complete) {
            W "OK: SID-native ACL grants Read, Enroll, and AutoEnroll across $($grantState.MatchingCount) matching ACE(s)"
        }
        else {
            W "FAIL: SID-native ACL has $($grantState.MatchingCount) matching ACE(s), grants [$($grantState.Granted -join ', ')], missing [$($grantState.Missing -join ', ')]"
        }
    } catch { W "SID-native ACL readback error: $($_.Exception.GetType().FullName): $($_.Exception.Message)" }

    W "### DSC status logs mentioning AddCertificateTemplate / ConfigMgrClientCertificate ###"
    try {
        $dscLogs = Get-ChildItem 'C:\staging\DSC' -Filter '*.log' -Recurse -ErrorAction SilentlyContinue
        foreach ($l in $dscLogs) {
            $hits = Select-String -Path $l.FullName -Pattern 'AddCertificateTemplate|ConfigMgrClientCertificate|Add-CertificateTemplateAcl|Domain Computers' -ErrorAction SilentlyContinue
            if ($hits) {
                W "--- $($l.Name) ---"
                foreach ($h in ($hits | Select-Object -Last 40)) { W $h.Line }
            }
        }
    } catch { W "DSC log scan error: $($_.Exception.Message)" }

    W "### Enterprise issuing CAs published in this forest (pKIEnrollmentService) ###"
    try {
        $cfg = ([ADSI]"LDAP://RootDSE").configurationNamingContext.Value
        $es = [ADSI]"LDAP://CN=Enrollment Services,CN=Public Key Services,CN=Services,$cfg"
        foreach ($c in $es.Children) { W ("  {0}  dNSHostName={1}" -f $c.Properties['cn'].Value, $c.Properties['dNSHostName'].Value) }
    } catch { W "Enrollment Services read error: $($_.Exception.Message)" }

    return ($out -join "`r`n")
}

# ---------------------------------------------------------------------------
#  Client collection (runs in-guest on CSB-W11CLIENT1 -- PS5.1)
# ---------------------------------------------------------------------------
$clientScript = {
    $out = [System.Collections.Generic.List[string]]::new()
    function W { param($t) $script:out.Add([string]$t) }

    W "### LocalMachine\My certificates ###"
    try {
        $certs = Get-ChildItem Cert:\LocalMachine\My -ErrorAction Stop
        if (-not $certs) { W "(none)" }
        foreach ($c in $certs) {
            $eku = ($c.EnhancedKeyUsageList | ForEach-Object { $_.FriendlyName }) -join ','
            W ("Subject={0} | Issuer={1} | EKU={2} | NotAfter={3}" -f $c.Subject, $c.Issuer, $eku, $c.NotAfter)
        }
    } catch { W "ERR: $($_.Exception.Message)" }

    W "### certutil -pulse (force autoenrollment) ###"
    try { W ((& certutil -pulse 2>&1 | Out-String)) } catch { W "ERR: $($_.Exception.Message)" }
    Start-Sleep -Seconds 6

    W "### CertificateServicesClient-AutoEnrollment events (Application log, last 12) ###"
    try {
        $ev = Get-WinEvent -LogName Application -MaxEvents 400 -ErrorAction SilentlyContinue |
              Where-Object { $_.ProviderName -like '*AutoEnrollment*' } | Select-Object -First 12
        foreach ($e in $ev) {
            W ("[{0}] Id={1} {2}" -f $e.TimeCreated, $e.Id, $e.LevelDisplayName)
            W ((($e.Message -split "`r?`n") | Select-Object -First 4) -join ' / ')
            W "---"
        }
        if (-not $ev) { W "(no AutoEnrollment events found)" }
    } catch { W "ERR: $($_.Exception.Message)" }

    W "### certutil -template ConfigMgr* visibility ###"
    try { W ((& certutil -template 2>&1 | Out-String | Select-String 'ConfigMgr' -Context 0,3 | Out-String)) } catch { W "ERR: $($_.Exception.Message)" }

    W "### Autoenrollment GPO policy registry ###"
    try {
        $k = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Cryptography\AutoEnrollment' -ErrorAction SilentlyContinue
        W ($k | Out-String)
    } catch { W "ERR: $($_.Exception.Message)" }

    W "### Client IPv4 addresses (confirm this client's boundary subnet) ###"
    try {
        $ips = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
               Where-Object { $_.IPAddress -notlike '169.*' -and $_.IPAddress -ne '127.0.0.1' }
        W (($ips | Select-Object IPAddress, PrefixLength, InterfaceAlias | Out-String))
    } catch { W "ERR: $($_.Exception.Message)" }

    W "### Is the remote CA root trusted on this client? (certutil -store Root | cstest8 CA) ###"
    try { W ((& certutil -store Root 2>&1 | Out-String | Select-String 'cstest8|CST-DC1' -Context 1,1 | Out-String)) } catch { W "ERR: $($_.Exception.Message)" }

    W "### ccmsetup.log -- GetDPLocations / content-location / cert lines (last 50 matches) ###"
    try {
        $cs = 'C:\Windows\ccmsetup\Logs\ccmsetup.log'
        if (Test-Path $cs) {
            $pat = 'GetDPLocations|ContentLocation|distribution point|80092004|NO_CLIENT_PKI_CERT|client certificate|0x87d00454|certificate by issuer|403|HTTP/1.1 |https://|MP_|boundary|Sending request|Retrieved|Found |No (DP|MP|content)'
            $hits = Select-String -Path $cs -Pattern $pat -ErrorAction SilentlyContinue
            foreach ($h in ($hits | Select-Object -Last 50)) { W ($h.Line) }
            W "--- ccmsetup.log raw last 20 lines ---"
            foreach ($l in (Get-Content $cs -Tail 20 -ErrorAction SilentlyContinue)) { W $l }
        } else { W "(ccmsetup.log not found at $cs)" }
    } catch { W "ERR: $($_.Exception.Message)" }

    return ($out -join "`r`n")
}

# ---------------------------------------------------------------------------
#  Primary / SMS-provider collection (runs in-guest on CST-PRISITE -- PS5.1)
#  Diagnoses the GetDPLocations content-location path: boundaries, boundary
#  groups (members + site systems) and the Client Package distribution.
# ---------------------------------------------------------------------------
$primaryScript = {
    param($SiteCode, $ClientNetwork)
    $out = [System.Collections.Generic.List[string]]::new()
    function W { param($t) $script:out.Add([string]$t) }
    $ns = "root\SMS\site_$SiteCode"
    W "SMS provider namespace: $ns   (looking for cross-forest client network: $ClientNetwork)"

    W "### Boundaries (SMS_Boundary) ###"
    try {
        $b = @(Get-WmiObject -Namespace $ns -Class SMS_Boundary -ErrorAction Stop)
        if (-not $b) { W "(none)" }
        foreach ($x in $b) {
            $typeName = switch ([int]$x.BoundaryType) { 0 {'IPSubnet'} 1 {'ADSite'} 2 {'IPv6'} 3 {'IPRange'} default {"Type$($x.BoundaryType)"} }
            $flag = ''
            if ($ClientNetwork -and ($x.Value -like "*$($ClientNetwork.TrimEnd('0'))*" -or $x.Value -like "*$ClientNetwork*")) { $flag = '   <== matches client network' }
            W ("  [{0}] {1} = {2}   (BoundaryID={3}){4}" -f $typeName, $x.DisplayName, $x.Value, $x.BoundaryID, $flag)
        }
    } catch { W "ERR SMS_Boundary: $($_.Exception.Message)" }

    W "### Boundary Groups + members + site systems ###"
    try {
        $bgs = @(Get-WmiObject -Namespace $ns -Class SMS_BoundaryGroup -ErrorAction Stop)
        if (-not $bgs) { W "(none)" }
        foreach ($g in $bgs) {
            W ("BG '{0}'  (GroupID={1}, DefaultSiteCode={2})" -f $g.Name, $g.GroupID, $g.DefaultSiteCode)
            try {
                $mem = @(Get-WmiObject -Namespace $ns -Class SMS_BoundaryGroupMembers -Filter "GroupID=$($g.GroupID)" -ErrorAction SilentlyContinue)
                if (-not $mem) { W "    boundaries: (none)" }
                foreach ($m in $mem) {
                    $bnd = Get-WmiObject -Namespace $ns -Class SMS_Boundary -Filter "BoundaryID=$($m.BoundaryID)" -ErrorAction SilentlyContinue
                    if ($bnd) { W ("    boundary: {0} = {1}" -f $bnd.DisplayName, $bnd.Value) } else { W "    boundary: BoundaryID=$($m.BoundaryID) (not found)" }
                }
            } catch { W "    ERR members: $($_.Exception.Message)" }
            try {
                $ss = @(Get-WmiObject -Namespace $ns -Class SMS_BoundaryGroupSiteSystems -Filter "GroupID=$($g.GroupID)" -ErrorAction SilentlyContinue)
                if (-not $ss) { W "    site systems: (NONE -- this BG returns NO content location!)" }
                foreach ($s in $ss) { W ("    site system: {0}" -f $s.ServerNALPath) }
            } catch { W "    ERR site systems: $($_.Exception.Message)" }
        }
    } catch { W "ERR SMS_BoundaryGroup: $($_.Exception.Message)" }

    W "### ConfigMgr Client Package distribution (the package GetDPLocations looks up) ###"
    try {
        $pkgs = @(Get-WmiObject -Namespace $ns -Class SMS_Package -Filter "Name='Configuration Manager Client Package'" -ErrorAction Stop)
        if (-not $pkgs) { W "(Configuration Manager Client Package not found by name)" }
        foreach ($p in $pkgs) {
            W ("Package '{0}'  PackageID={1}" -f $p.Name, $p.PackageID)
            $st = @(Get-WmiObject -Namespace $ns -Class SMS_PackageStatusDistPointsSummarizer -Filter "PackageID='$($p.PackageID)'" -ErrorAction SilentlyContinue)
            if (-not $st) { W "  (no distribution rows -- NOT distributed to ANY DP!)" }
            foreach ($s in $st) {
                $stateName = switch ([int]$s.State) { 0 {'Installed'} 1 {'InstallPending'} 2 {'InstallRetrying'} 3 {'InstallFailed'} 7 {'ContentValidating'} 8 {'ContentValidationFailed'} default {"State$($s.State)"} }
                W ("  DP={0}  State={1}" -f $s.ServerNALPath, $stateName)
            }
        }
    } catch { W "ERR package: $($_.Exception.Message)" }

    W "### Management Points / Distribution Points (SMS_SCI_SysResUse) ###"
    try {
        $sysres = @(Get-WmiObject -Namespace $ns -Class SMS_SCI_SysResUse -ErrorAction SilentlyContinue |
                    Where-Object { $_.RoleName -in 'SMS Management Point', 'SMS Distribution Point' })
        foreach ($r in $sysres) { W ("  {0}: {1}  (SiteCode={2})" -f $r.RoleName, $r.NetworkOSPath, $r.SiteCode) }
        if (-not $sysres) { W "(no MP/DP rows)" }
    } catch { W "ERR sysres: $($_.Exception.Message)" }

    return ($out -join "`r`n")
}

Write-Host "Collecting from CA/OtherDC '$CaVm' ..." -ForegroundColor Cyan
try {
    $caOut = Invoke-Command -VMName $CaVm -Credential $caCred -ScriptBlock $caScript -ArgumentList $TemplateName, $ClientDomainNetbios -ErrorAction Stop
    Add-Section -Title "CA / OtherDC: $CaVm ($CaDomainNetbios)" -Body $caOut
} catch {
    Add-Section -Title "CA / OtherDC: $CaVm -- COLLECTION FAILED" -Body $_.Exception.Message
}

Write-Host "Collecting from client '$ClientVm' ..." -ForegroundColor Cyan
try {
    $clOut = Invoke-Command -VMName $ClientVm -Credential $clientCred -ScriptBlock $clientScript -ErrorAction Stop
    Add-Section -Title "Client: $ClientVm ($ClientDomainNetbios)" -Body $clOut
} catch {
    Add-Section -Title "Client: $ClientVm -- COLLECTION FAILED" -Body $_.Exception.Message
}

Write-Host "Collecting from Primary / SMS provider '$PrimaryVm' (site $SiteCode) ..." -ForegroundColor Cyan
try {
    $prOut = Invoke-Command -VMName $PrimaryVm -Credential $caCred -ScriptBlock $primaryScript -ArgumentList $SiteCode, $ClientNetwork -ErrorAction Stop
    Add-Section -Title "Primary / SMS provider: $PrimaryVm (site $SiteCode)" -Body $prOut
} catch {
    Add-Section -Title "Primary / SMS provider: $PrimaryVm -- COLLECTION FAILED" -Body $_.Exception.Message
}

Write-Host ""
Write-Host "Diagnostic written to:" -ForegroundColor Green
Write-Host "  $outFile"
