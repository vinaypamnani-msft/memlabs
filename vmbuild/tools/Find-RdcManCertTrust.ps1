<#
.SYNOPSIS
    Find where RDCMan 3.12 persists "Trust this certificate for this server".

.DESCRIPTION
    RDCMan 3.12 prompts with its own certificate warning per VM. Ticking the
    checkbox makes the prompt stop for that server, so the decision is stored
    somewhere -- but NOT in the classic RDP client location: on a host where
    BI-PRIMARY had already been trusted, HKCU\...\Terminal Server Client\Servers
    held no entries at all.

    This locates the real store empirically. Give it a VM you have ALREADY
    trusted through the dialog; it reads that VM's live RDP listener certificate,
    derives every form the trust could be recorded in (SHA-1 / SHA-256 hex, raw
    bytes, base64), then hunts for those markers in the registry and on disk.

    A hit is conclusive: only the trust record can contain that VM's certificate
    hash. The VM name alone is not -- it appears in the .rdg for every VM,
    trusted or not -- so name matches are reported separately and ranked lower.

.PARAMETER VmName
    A VM whose certificate you have already trusted in the RDCMan dialog. This is
    the positive control; without one the scan cannot discriminate.

.PARAMETER ControlVmName
    Optional. A VM you have NOT trusted. Any location that contains the trusted
    VM's marker but not this one is the store; a location holding both is just
    an inventory (like the .rdg) and proves nothing.

.PARAMETER RdgPath
    The .rdg file to scan. Defaults to memlabs.rdg on the desktop.

.EXAMPLE
    .\Find-RdcManCertTrust.ps1 -VmName BI-PRIMARY -ControlVmName BI-CLIENT2

.NOTES
    Runs on the Hyper-V host, as the SAME user that runs RDCMan -- the store is
    almost certainly per-user, and scanning a different profile finds nothing.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$VmName,

    [Parameter(Mandatory = $false)]
    [string]$ControlVmName,

    [Parameter(Mandatory = $false)]
    [string]$RdgPath
)

$ErrorActionPreference = 'Stop'

$vmbuildRoot = Split-Path -Parent $PSScriptRoot
Set-Location $vmbuildRoot

$commonPath = Join-Path $vmbuildRoot 'Common.ps1'
if (-not (Test-Path -LiteralPath $commonPath)) { throw "Common.ps1 not found at $commonPath" }

# $Common is global and outlives the script that loaded it; its functions are not.
$needed = @('Get-List', 'Invoke-VmCommand')
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
if (-not (Test-CommonLoaded)) {
    throw "Common.ps1 did not provide $($needed -join ', ') plus a loaded vmbuildadmin credential. Run '. .\Common.ps1' from $vmbuildRoot, then re-run."
}

$certProbe = {
    $out = [ordered]@{ Thumbprint = $null; RawB64 = $null; Error = $null }
    try {
        $ts = Get-CimInstance -Namespace 'root/cimv2/TerminalServices' -ClassName Win32_TSGeneralSetting -Filter "TerminalName='RDP-Tcp'" -ErrorAction Stop
        $hash = "$($ts.SSLCertificateSHA1Hash)".ToUpperInvariant()
        if ([string]::IsNullOrWhiteSpace($hash)) { $out.Error = 'listener reports no thumbprint'; return [pscustomobject]$out }
        $out.Thumbprint = $hash
        foreach ($store in 'Cert:\LocalMachine\Remote Desktop', 'Cert:\LocalMachine\My') {
            $found = @(Get-ChildItem -Path $store -ErrorAction SilentlyContinue | Where-Object { $_.Thumbprint -eq $hash })
            if ($found.Count -gt 0) { $out.RawB64 = [Convert]::ToBase64String($found[0].RawData); break }
        }
        if (-not $out.RawB64) { $out.Error = "thumbprint $hash not found in Remote Desktop or My store" }
    }
    catch { $out.Error = $_.Exception.Message }
    return [pscustomobject]$out
}

function Get-VmCertMarkers {
    param([string]$Name)
    $vm = @(Get-List -Type VM | Where-Object { $_.vmName -eq $Name }) | Select-Object -First 1
    if (-not $vm) { throw "VM '$Name' is not in the memlabs list." }
    $probe = Invoke-VmCommand -VmName $Name -VmDomainName $(if ($vm.domain) { "$($vm.domain)" } else { 'WORKGROUP' }) `
        -ScriptBlock $certProbe -DisplayName 'Read RDP listener certificate' -SuppressLog
    if (-not $probe.CommandResult -or $probe.ScriptBlockFailed -or $null -eq $probe.ScriptBlockOutput) {
        throw "Could not read $Name's certificate: $($probe.ErrorDetails)"
    }
    $c = $probe.ScriptBlockOutput
    if ($c.Error) { throw "$Name`: $($c.Error)" }

    $der = [Convert]::FromBase64String($c.RawB64)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try { $s256 = $sha256.ComputeHash($der) } finally { $sha256.Dispose() }
    $s1 = @()
    for ($i = 0; $i -lt $c.Thumbprint.Length; $i += 2) { $s1 += [Convert]::ToByte($c.Thumbprint.Substring($i, 2), 16) }

    $hex1 = $c.Thumbprint
    $hex256 = (($s256 | ForEach-Object { $_.ToString('X2') }) -join '')
    return [pscustomobject]@{
        VmName  = $Name
        Strings = @($hex1, $hex1.ToLowerInvariant(), $hex256, $hex256.ToLowerInvariant(),
            [Convert]::ToBase64String($s1), [Convert]::ToBase64String($s256), $c.RawB64)
        Bytes   = @(, [byte[]]$s1) + @(, [byte[]]$s256)
    }
}

function Test-BytesContain {
    param([byte[]]$Haystack, [byte[]]$Needle)
    if ($null -eq $Haystack -or $Haystack.Length -lt $Needle.Length) { return $false }
    $limit = $Haystack.Length - $Needle.Length
    for ($i = 0; $i -le $limit; $i++) {
        $ok = $true
        for ($j = 0; $j -lt $Needle.Length; $j++) {
            if ($Haystack[$i + $j] -ne $Needle[$j]) { $ok = $false; break }
        }
        if ($ok) { return $true }
    }
    return $false
}

function Test-MarkerHit {
    param($Markers, [object]$Value)
    if ($null -eq $Value) { return $false }
    if ($Value -is [byte[]]) {
        foreach ($n in $Markers.Bytes) { if (Test-BytesContain -Haystack $Value -Needle $n) { return $true } }
        return $false
    }
    $text = ($Value -join '')
    foreach ($s in $Markers.Strings) { if ($text.Contains($s)) { return $true } }
    return $false
}

Write-Host "Reading certificates..." -ForegroundColor Cyan
$target = Get-VmCertMarkers -Name $VmName
Write-Host "  $VmName (TRUSTED)  sha1=$($target.Strings[0])" -ForegroundColor Green
$control = $null
if ($ControlVmName) {
    $control = Get-VmCertMarkers -Name $ControlVmName
    Write-Host "  $ControlVmName (control)  sha1=$($control.Strings[0])" -ForegroundColor DarkGray
}

$hits = New-Object System.Collections.Generic.List[object]

# ---- registry -------------------------------------------------------------
$regRoots = @(
    'HKCU:\Software\Microsoft\Terminal Server Client'
    'HKCU:\Software\Microsoft\Remote Desktop Connection Manager'
    'HKCU:\Software\Microsoft\RDCMan'
    'HKCU:\Software\Sysinternals'
    'HKCU:\Software\Microsoft\Remote Desktop'
    'HKLM:\SOFTWARE\Microsoft\Terminal Server Client'
    'HKLM:\SOFTWARE\Policies\Microsoft\RDCMan'
)
Write-Host ""
Write-Host "Scanning registry..." -ForegroundColor Cyan
foreach ($root in $regRoots) {
    if (-not (Test-Path -LiteralPath $root)) { Write-Host "  (absent) $root" -ForegroundColor DarkGray; continue }
    $keys = @($root) + @(Get-ChildItem -LiteralPath $root -Recurse -ErrorAction SilentlyContinue | Select-Object -ExpandProperty PSPath)
    Write-Host "  $root  ($($keys.Count) key(s))" -ForegroundColor DarkGray
    foreach ($k in $keys) {
        $props = Get-ItemProperty -LiteralPath $k -ErrorAction SilentlyContinue
        if (-not $props) { continue }
        foreach ($p in $props.PSObject.Properties) {
            if ($p.Name -like 'PS*') { continue }
            $who = $null
            if (Test-MarkerHit -Markers $target -Value $p.Value) { $who = 'TRUSTED-VM-CERT' }
            elseif ($control -and (Test-MarkerHit -Markers $control -Value $p.Value)) { $who = 'control-vm-cert' }
            elseif (($p.Value -isnot [byte[]]) -and (($p.Value -join '') -match [regex]::Escape($VmName))) { $who = 'name-only' }
            if ($who) {
                $hits.Add([pscustomobject]@{ Kind = 'registry'; Match = $who; Where = ($k -replace '^Microsoft\.PowerShell\.Core\\Registry::', ''); Detail = $p.Name })
            }
        }
    }
}

# ---- files ----------------------------------------------------------------
$fileRoots = @(
    (Join-Path $env:LOCALAPPDATA 'Microsoft\Remote Desktop Connection Manager')
    (Join-Path $env:APPDATA 'Microsoft\Remote Desktop Connection Manager')
    (Join-Path $env:LOCALAPPDATA 'Sysinternals')
)
if (-not $RdgPath) { $RdgPath = Join-Path ([Environment]::GetFolderPath('Desktop')) 'memlabs.rdg' }

Write-Host ""
Write-Host "Scanning files..." -ForegroundColor Cyan
$files = New-Object System.Collections.Generic.List[string]
foreach ($r in $fileRoots) {
    if (-not (Test-Path -LiteralPath $r)) { Write-Host "  (absent) $r" -ForegroundColor DarkGray; continue }
    $found = @(Get-ChildItem -LiteralPath $r -Recurse -File -Force -ErrorAction SilentlyContinue)
    Write-Host "  $r  ($($found.Count) file(s))" -ForegroundColor DarkGray
    foreach ($f in $found) {
        Write-Host ("      {0,-19} {1,10}  {2}" -f $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm'), $f.Length, $f.FullName.Substring($r.Length + 1)) -ForegroundColor DarkGray
        $files.Add($f.FullName)
    }
}
if (Test-Path -LiteralPath $RdgPath) { Write-Host "  $RdgPath" -ForegroundColor DarkGray; $files.Add($RdgPath) }
else { Write-Host "  (absent) $RdgPath" -ForegroundColor DarkGray }

foreach ($path in $files) {
    $bytes = $null
    try { $bytes = [System.IO.File]::ReadAllBytes($path) } catch { continue }
    # Decode both UTF-16 alignments: a literal starting at an odd offset is
    # invisible to a single-alignment decode.
    $text = [System.Text.Encoding]::UTF8.GetString($bytes) +
    [System.Text.Encoding]::Unicode.GetString($bytes, 0, $bytes.Length - ($bytes.Length % 2)) +
    $(if ($bytes.Length -gt 1) { [System.Text.Encoding]::Unicode.GetString($bytes, 1, $bytes.Length - 1 - (($bytes.Length - 1) % 2)) } else { '' })

    $who = $null
    if ((Test-MarkerHit -Markers $target -Value $text) -or (Test-MarkerHit -Markers $target -Value $bytes)) { $who = 'TRUSTED-VM-CERT' }
    elseif ($control -and ((Test-MarkerHit -Markers $control -Value $text) -or (Test-MarkerHit -Markers $control -Value $bytes))) { $who = 'control-vm-cert' }
    elseif ($text -match [regex]::Escape($VmName)) { $who = 'name-only' }
    if ($who) { $hits.Add([pscustomobject]@{ Kind = 'file'; Match = $who; Where = $path; Detail = "$($bytes.Length) bytes" }) }
}

# ---- verdict --------------------------------------------------------------
Write-Host ""
$certHits = @($hits | Where-Object { $_.Match -eq 'TRUSTED-VM-CERT' })
$nameHits = @($hits | Where-Object { $_.Match -eq 'name-only' })

if ($certHits.Count -gt 0) {
    Write-Host "FOUND -- these contain $VmName's certificate hash:" -ForegroundColor Green
    $certHits | Format-Table Kind, Where, Detail -AutoSize | Out-String | Write-Host
    if ($control) {
        $both = @($hits | Where-Object { $_.Match -eq 'control-vm-cert' } | Select-Object -ExpandProperty Where)
        $only = @($certHits | Where-Object { $_.Where -notin $both })
        Write-Host "Discriminating (trusted VM only, control absent): $($only.Count) of $($certHits.Count)" -ForegroundColor Cyan
        $only | Format-Table Kind, Where, Detail -AutoSize | Out-String | Write-Host
    }
}
else {
    Write-Host "NOT FOUND -- $VmName's certificate hash is in none of the scanned locations." -ForegroundColor Red
    Write-Host "The store is outside the scanned set, or RDCMan records the decision without the hash." -ForegroundColor Red
    if ($nameHits.Count -gt 0) {
        Write-Host ""
        Write-Host "Name-only matches (weak -- the .rdg names every VM, trusted or not):" -ForegroundColor DarkYellow
        $nameHits | Format-Table Kind, Where, Detail -AutoSize | Out-String | Write-Host
    }
    exit 2
}
exit 0
