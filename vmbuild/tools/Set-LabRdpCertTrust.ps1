<#
.SYNOPSIS
    Pre-trust the self-signed RDP listener certificate of every lab VM so RDCMan /
    mstsc stop showing the "The identity of <VM> cannot be verified" warning.

.DESCRIPTION
    Every MemLabs VM presents an auto-generated self-signed RDP certificate. The
    RDP client rejects it twice over: it is not chained to a trusted CA, and its
    CN is the FQDN while RDCMan connects by short name. RDCMan 3.12 prompts on
    both, once per VM.

    Ticking "Trust this certificate for this server" in that dialog pins the
    certificate under

        HKCU:\Software\Microsoft\Terminal Server Client\Servers\<name>  ->  CertHash

    This script does the same thing ahead of time, for every VM at once: it reads
    each guest's live RDP listener certificate over PowerShell Direct, hashes it,
    and writes the pin for every name the VM can be addressed by (short name,
    FQDN, last known IP). Pinning covers BOTH errors, so the name mismatch stops
    mattering as well.

    MEASURED CAVEAT (2026-08-23): on a host where BI-PRIMARY had already been
    trusted through the RDCMan 3.12 dialog, this key held NO entries at all. So
    RDCMan 3.12 persists its trust somewhere else and these pins do not suppress
    its prompt. They still work for mstsc.exe and anything else on the RDP client
    stack. Use Find-RdcManCertTrust.ps1 to locate RDCMan's actual store.

    The hash width is not guessed. Windows 11 / Server 2022+ clients pin SHA-256
    (32 bytes) while older ones pin SHA-1 (20); the script reads the width already
    used by existing entries on this host and matches it, so the value it writes
    is the value this client will look for.

    Run it after a deploy, or any time a VM's certificate is regenerated (they
    expire every ~6 months and are silently reissued).

.PARAMETER DomainName
    Only process VMs in this lab domain. Default: all domains.

.PARAMETER VmName
    Only process these VMs. Default: every running Windows lab VM.

.PARAMETER Report
    Read-only. Show each VM's certificate and whether this host already trusts it.
    Makes no changes. Use this to confirm a pin took effect.

.PARAMETER Bypass
    Additionally set HKLM AuthenticationLevelOverride = 0, which tells the RDP
    client never to warn on server authentication failure -- for ANY server, not
    just lab VMs. Blunt and machine-wide; requires elevation. Prefer pinning.

.PARAMETER HashAlgorithm
    Force the pin width instead of matching what this host already uses.

.EXAMPLE
    .\Set-LabRdpCertTrust.ps1 -Report
    Show what each VM presents and what is currently pinned. No changes.

.EXAMPLE
    .\Set-LabRdpCertTrust.ps1
    Pin every running Windows lab VM's certificate.

.EXAMPLE
    .\Set-LabRdpCertTrust.ps1 -DomainName contoso.com -VmName BI-CLIENT2
    Pin a single VM.

.NOTES
    Runs on the Hyper-V host. RDCMan reads these pins at connect time, so close
    and reopen an already-connected session for the change to take effect.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $false)]
    [string]$DomainName,

    [Parameter(Mandatory = $false)]
    [string[]]$VmName,

    [Parameter(Mandatory = $false)]
    [switch]$Report,

    [Parameter(Mandatory = $false)]
    [switch]$Bypass,

    [Parameter(Mandatory = $false)]
    [ValidateSet('Auto', 'SHA1', 'SHA256')]
    [string]$HashAlgorithm = 'Auto'
)

$ErrorActionPreference = 'Stop'

# ---- locate roots; this script lives in vmbuild\tools, Common.ps1 is in vmbuild ----
$vmbuildRoot = Split-Path -Parent $PSScriptRoot
Set-Location $vmbuildRoot

$commonPath = Join-Path $vmbuildRoot 'Common.ps1'
if (-not (Test-Path -LiteralPath $commonPath)) { throw "Common.ps1 not found at $commonPath" }
$bom = [System.IO.File]::ReadAllBytes($commonPath)[0..2]
if (-not ($bom[0] -eq 0xEF -and $bom[1] -eq 0xBB -and $bom[2] -eq 0xBF)) {
    throw 'Common.ps1 is missing its UTF-8 BOM (PS5.1 parse hazard). Run: git checkout -- vmbuild/Common.ps1'
}

# Never load with -InJob here: it skips storage init, leaves $Common.LocalAdmin null, and
# then every Invoke-VmCommand returns a bare $false -- which reads as "the lab is broken"
# rather than "the tool never authenticated".
#
# $Common is GLOBAL and outlives the script that loaded it, but Common.ps1's functions are
# dot-sourced into that script's scope and die with it. So a session where any other tool
# has already run leaves a fully populated $Common with no Get-List -- readiness has to be
# gated on the functions, not on the credential alone.
$needed = @('Get-List', 'Invoke-VmCommand', 'Test-VmIsLinux')
function Test-CommonLoaded {
    if (-not ($Common -and $Common.LocalAdmin -and $Common.LocalAdmin.Password)) { return $false }
    foreach ($fn in $needed) { if (-not (Get-Command $fn -ErrorAction SilentlyContinue)) { return $false } }
    return $true
}

if (-not (Test-CommonLoaded)) { . $commonPath -FastInit }
if (-not (Test-CommonLoaded) -and (Get-Command Get-LocalAdminCredential -ErrorAction SilentlyContinue)) {
    if ($Common) { $Common.Initialized = $false }
    try { $null = Get-LocalAdminCredential } catch { Write-Host "  Get-LocalAdminCredential failed: $($_.Exception.Message)" -ForegroundColor DarkYellow }
}
if (-not (Test-CommonLoaded)) {
    if ($Common) { $Common.Initialized = $false }
    . $commonPath
}
$missing = @($needed | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) })
if ($missing.Count -gt 0) {
    throw "Common.ps1 loaded but these functions are not defined: $($missing -join ', '). Run '. .\Common.ps1' from $vmbuildRoot, then re-run."
}
if (-not ($Common -and $Common.LocalAdmin -and $Common.LocalAdmin.Password)) {
    throw ("Local admin (vmbuildadmin) credential not loaded -- every guest call would fail silently. " +
        "cacheExists={0}. Open a new PowerShell window and retry." -f (Test-Path (Join-Path $vmbuildRoot 'cache\vmbuildadmin.txt')))
}

$serversKey = 'HKCU:\Software\Microsoft\Terminal Server Client\Servers'

function Get-PinnedCertHash {
    param([string]$Name)
    $key = Join-Path $serversKey $Name
    if (-not (Test-Path -LiteralPath $key)) { return $null }
    $props = Get-ItemProperty -LiteralPath $key
    if ($props.PSObject.Properties.Name -notcontains 'CertHash') { return $null }
    return [byte[]]$props.CertHash
}

# The pin width this client looks for. Existing entries were written by the local
# RDP client itself, so they are the authoritative sample -- guessing here would
# write a value nothing ever reads.
function Resolve-PinWidth {
    if ($HashAlgorithm -eq 'SHA1') { return 20 }
    if ($HashAlgorithm -eq 'SHA256') { return 32 }

    $widths = @()
    if (Test-Path -LiteralPath $serversKey) {
        foreach ($k in @(Get-ChildItem -LiteralPath $serversKey)) {
            $h = Get-PinnedCertHash -Name $k.PSChildName
            if ($h) { $widths += $h.Length }
        }
    }
    if ($widths.Count -eq 0) {
        # No sample. Every OS that can host MemLabs pins SHA-256.
        Write-Host '  No existing pins to calibrate against; assuming SHA-256 (32 bytes).' -ForegroundColor DarkGray
        return 32
    }
    $modal = ($widths | Group-Object | Sort-Object Count -Descending | Select-Object -First 1).Name
    return [int]$modal
}

# Runs in the guest. Returns the RDP listener certificate as base64 DER, or an
# error string -- never $null silently.
$certProbe = {
    $out = [ordered]@{ Thumbprint = $null; Subject = $null; NotAfter = $null; RawB64 = $null; Source = $null; Error = $null }
    try {
        $hash = $null
        try {
            $ts = Get-CimInstance -Namespace 'root/cimv2/TerminalServices' -ClassName Win32_TSGeneralSetting -Filter "TerminalName='RDP-Tcp'" -ErrorAction Stop
            $hash = "$($ts.SSLCertificateSHA1Hash)"
            $out.Source = 'Win32_TSGeneralSetting'
        }
        catch {
            $rk = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
            $raw = (Get-ItemProperty -LiteralPath $rk -Name SSLCertificateSHA1Hash -ErrorAction Stop).SSLCertificateSHA1Hash
            $hash = (([byte[]]$raw | ForEach-Object { $_.ToString('X2') }) -join '')
            $out.Source = 'WinStations registry'
        }

        if ([string]::IsNullOrWhiteSpace($hash)) {
            $out.Error = 'RDP listener reports no certificate thumbprint.'
            return [pscustomobject]$out
        }
        $out.Thumbprint = $hash.ToUpperInvariant()

        $cert = $null
        foreach ($store in 'Cert:\LocalMachine\Remote Desktop', 'Cert:\LocalMachine\My') {
            $found = @(Get-ChildItem -Path $store -ErrorAction SilentlyContinue | Where-Object { $_.Thumbprint -eq $out.Thumbprint })
            if ($found.Count -gt 0) { $cert = $found[0]; break }
        }
        if ($null -eq $cert) {
            $out.Error = "Listener thumbprint $($out.Thumbprint) is not present in the Remote Desktop or My store."
            return [pscustomobject]$out
        }

        $out.Subject = $cert.Subject
        $out.NotAfter = $cert.NotAfter.ToString('o')
        $out.RawB64 = [Convert]::ToBase64String($cert.RawData)
    }
    catch {
        $out.Error = $_.Exception.Message
    }
    return [pscustomobject]$out
}

# ---- resolve targets -------------------------------------------------------
$running = @(Get-VM -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Running' } | Select-Object -ExpandProperty Name)
$all = @(Get-List -Type VM)

$targets = @($all | Where-Object { $_.vmName -in $running })
if ($DomainName) { $targets = @($targets | Where-Object { "$($_.domain)" -eq $DomainName }) }
if ($VmName) { $targets = @($targets | Where-Object { $_.vmName -in $VmName }) }

$linux = @($targets | Where-Object { Test-VmIsLinux -Vm $_ })
if ($linux.Count -gt 0) {
    Write-Host "  SKIP $($linux.Count) Linux VM(s) -- xrdp certificates are not readable over PowerShell Direct: $(($linux.vmName) -join ', ')" -ForegroundColor DarkYellow
}
$targets = @($targets | Where-Object { -not (Test-VmIsLinux -Vm $_) })

if ($targets.Count -eq 0) {
    Write-Host "ERROR: no running Windows lab VM matched (DomainName='$DomainName' VmName='$($VmName -join ",")'). Nothing was measured." -ForegroundColor Red
    exit 2
}

$pinWidth = Resolve-PinWidth
$algo = if ($pinWidth -eq 20) { 'SHA1' } else { 'SHA256' }
Write-Host "Pin width for this host: $pinWidth bytes ($algo). Targets: $($targets.Count) VM(s)." -ForegroundColor Cyan

# ---- collect + apply -------------------------------------------------------
$results = New-Object System.Collections.Generic.List[object]
$failed = 0

foreach ($vm in $targets) {
    $vmDomain = if ($vm.domain) { "$($vm.domain)" } else { 'WORKGROUP' }
    $probe = Invoke-VmCommand -VmName $vm.vmName -VmDomainName $vmDomain -ScriptBlock $certProbe `
        -DisplayName 'Read RDP listener certificate' -SuppressLog

    if (-not $probe.CommandResult -or $probe.ScriptBlockFailed -or $null -eq $probe.ScriptBlockOutput) {
        Write-Host "  FAIL $($vm.vmName): could not read the RDP certificate. $($probe.ErrorDetails)" -ForegroundColor Red
        $failed++
        continue
    }

    $cert = $probe.ScriptBlockOutput
    if ($cert.Error) {
        Write-Host "  FAIL $($vm.vmName): $($cert.Error)" -ForegroundColor Red
        $failed++
        continue
    }

    $der = [Convert]::FromBase64String($cert.RawB64)
    $hasher = if ($pinWidth -eq 20) { [System.Security.Cryptography.SHA1]::Create() } else { [System.Security.Cryptography.SHA256]::Create() }
    try { $pin = $hasher.ComputeHash($der) } finally { $hasher.Dispose() }

    # Every name RDCMan or mstsc might use for this VM. Pins are per-name.
    $names = New-Object System.Collections.Generic.List[string]
    $names.Add("$($vm.vmName)")
    if ($vm.domain) { $names.Add("$($vm.vmName).$($vm.domain)") }
    if ($vm.LastKnownIP) { $names.Add("$($vm.LastKnownIP)") }

    foreach ($name in ($names | Select-Object -Unique)) {
        $existing = Get-PinnedCertHash -Name $name
        $alreadyTrusted = ($null -ne $existing) -and (-not (Compare-Object $existing $pin))

        $results.Add([pscustomobject]@{
                VM      = $vm.vmName
                Name    = $name
                Subject = $cert.Subject
                Expires = ([datetime]$cert.NotAfter).ToString('yyyy-MM-dd')
                Trusted = $alreadyTrusted
                Action  = 'none'
            })

        if ($Report -or $alreadyTrusted) { continue }

        if ($PSCmdlet.ShouldProcess($name, "Pin RDP certificate $($cert.Thumbprint)")) {
            $key = Join-Path $serversKey $name
            if (-not (Test-Path -LiteralPath $key)) { $null = New-Item -Path $key -Force }
            Set-ItemProperty -LiteralPath $key -Name 'CertHash' -Value $pin -Type Binary

            # Read back -- a write that did not land must not report success.
            $verify = Get-PinnedCertHash -Name $name
            if ($null -eq $verify -or (Compare-Object $verify $pin)) {
                Write-Host "  FAIL $($vm.vmName): pin for '$name' did not read back correctly." -ForegroundColor Red
                $failed++
                $results[$results.Count - 1].Action = 'FAILED'
            }
            else {
                $results[$results.Count - 1].Action = 'pinned'
                $results[$results.Count - 1].Trusted = $true
            }
        }
    }
}

# ---- machine-wide bypass (optional) ---------------------------------------
if ($Bypass) {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Host '  FAIL -Bypass needs an elevated session; AuthenticationLevelOverride was NOT set.' -ForegroundColor Red
        $failed++
    }
    elseif ($PSCmdlet.ShouldProcess('HKLM Terminal Server Client', 'Set AuthenticationLevelOverride = 0')) {
        $hklm = 'HKLM:\SOFTWARE\Microsoft\Terminal Server Client'
        if (-not (Test-Path -LiteralPath $hklm)) { $null = New-Item -Path $hklm -Force }
        Set-ItemProperty -LiteralPath $hklm -Name 'AuthenticationLevelOverride' -Value 0 -Type DWord
        $check = (Get-ItemProperty -LiteralPath $hklm -Name 'AuthenticationLevelOverride').AuthenticationLevelOverride
        if ($check -ne 0) {
            Write-Host "  FAIL AuthenticationLevelOverride did not read back as 0 (got '$check')." -ForegroundColor Red
            $failed++
        }
        else {
            Write-Host '  AuthenticationLevelOverride = 0 -- this RDP client will no longer warn on ANY untrusted server.' -ForegroundColor Yellow
        }
    }
}

# ---- report ----------------------------------------------------------------
$results | Sort-Object VM, Name | Format-Table -AutoSize | Out-String | Write-Host

$pinned = @($results | Where-Object { $_.Action -eq 'pinned' }).Count
$trusted = @($results | Where-Object { $_.Trusted }).Count
$color = if ($failed -gt 0) { 'Red' } else { 'Green' }
Write-Host "$trusted of $($results.Count) name(s) trusted ($pinned newly pinned); $failed failure(s)." -ForegroundColor $color

if ($pinned -gt 0) {
    Write-Host 'RDCMan reads pins at connect time -- disconnect and reconnect affected sessions.' -ForegroundColor Yellow
}
if ($failed -gt 0) { exit 2 }
exit 0
