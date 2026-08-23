<#
.SYNOPSIS
    Capture each lab VM's RDP listener certificate hash onto its VM Note, so the
    generated .rdg pre-trusts every VM and RDCMan stops prompting.

.DESCRIPTION
    RDCMan 3.12 records "Trust this certificate for this server" inside the .rdg, as a
    <trustedCertificates> node on each <server>. MemLabs rebuilds every server node from
    the template on each regeneration, so a trust clicked in the UI is destroyed by the
    next deploy, add-VM, remove-VM or snapshot operation.

    MemLabs now owns that value instead: the hash is captured onto the VM Note (Hyper-V
    metadata, readable with the VM OFF) and written into the .rdg on every regeneration.
    Phase 11 captures it during a build, and the generator captures it opportunistically
    for a running VM that has none.

    This tool is the manual path -- backfilling an existing lab that predates the feature,
    or refreshing after a certificate is reissued (they rotate roughly every 6 months, and
    a stale hash silently stops suppressing the prompt).

    A VM must be RUNNING to be captured. Stopped VMs keep whatever the note already holds,
    which is exactly why the .rdg can still be regenerated for them.

.PARAMETER DomainName
    Only process VMs in this lab domain. Default: all domains.

.PARAMETER VmName
    Only process these VMs. Default: every running Windows lab VM.

.PARAMETER Report
    Read-only. Show what each VM has stored and whether it is running. No guest calls,
    no changes.

.PARAMETER Force
    Re-read from the guest even when the note already has a hash. Use after a certificate
    is reissued. Without it, VMs that already have a value are left alone.

.PARAMETER SkipRdgUpdate
    Capture only; do not regenerate the .rdg afterwards.

.EXAMPLE
    .\Set-LabRdpCertTrust.ps1 -Report
    Show what is stored for each VM. No changes.

.EXAMPLE
    .\Set-LabRdpCertTrust.ps1
    Capture missing hashes from running VMs and regenerate the .rdg.

.EXAMPLE
    .\Set-LabRdpCertTrust.ps1 -Force
    Re-read every running VM's certificate, e.g. after they were reissued.

.NOTES
    Runs on the Hyper-V host. RDCMan reads the .rdg at load time -- close and reopen it
    (or reload the file group) for regenerated trust to take effect.
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
    [switch]$Force,

    [Parameter(Mandatory = $false)]
    [switch]$SkipRdgUpdate
)

$ErrorActionPreference = 'Stop'

$vmbuildRoot = Split-Path -Parent $PSScriptRoot
Set-Location $vmbuildRoot

$commonPath = Join-Path $vmbuildRoot 'Common.ps1'
if (-not (Test-Path -LiteralPath $commonPath)) { throw "Common.ps1 not found at $commonPath" }
$bom = [System.IO.File]::ReadAllBytes($commonPath)[0..2]
if (-not ($bom[0] -eq 0xEF -and $bom[1] -eq 0xBB -and $bom[2] -eq 0xBF)) {
    throw 'Common.ps1 is missing its UTF-8 BOM (PS5.1 parse hazard). Run: git checkout -- vmbuild/Common.ps1'
}

# $Common is GLOBAL and outlives the script that loaded it, but Common.ps1's functions are
# dot-sourced into that script's scope and die with it. So a session where any other tool
# has already run leaves a fully populated $Common with no Get-List -- readiness has to be
# gated on the functions, not on the credential alone.
#
# Never load with -InJob either: it skips storage init, leaves $Common.LocalAdmin null, and
# then every Invoke-VmCommand returns a bare $false.
$needed = @('Get-List', 'Update-VmRdpCertNote', 'New-RDCManFileFromHyperV')
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

# ---- resolve targets -------------------------------------------------------
$targets = @(Get-List -Type VM -SmartUpdate)
if ($DomainName) { $targets = @($targets | Where-Object { "$($_.domain)" -eq $DomainName }) }
if ($VmName) { $targets = @($targets | Where-Object { $_.vmName -in $VmName }) }

$linux = @($targets | Where-Object { Test-VmIsLinux -Vm $_ })
if ($linux.Count -gt 0) {
    Write-Host "  SKIP $($linux.Count) Linux VM(s) -- xrdp certificates are not readable over PowerShell Direct: $(($linux.vmName) -join ', ')" -ForegroundColor DarkYellow
}
$targets = @($targets | Where-Object { -not (Test-VmIsLinux -Vm $_) })

if ($targets.Count -eq 0) {
    Write-Host "ERROR: no Windows lab VM matched (DomainName='$DomainName' VmName='$($VmName -join ",")'). Nothing was measured." -ForegroundColor Red
    exit 2
}

Write-Host "Targets: $($targets.Count) Windows VM(s)." -ForegroundColor Cyan

# ---- capture ---------------------------------------------------------------
$results = New-Object System.Collections.Generic.List[object]
$captured = 0
$failed = 0

foreach ($vm in ($targets | Sort-Object vmName)) {
    $before = if ($vm.rdpCertSha256) { "$($vm.rdpCertSha256)" } else { $null }
    $running = ($vm.State -eq 'Running')
    $after = $before
    $action = 'none'

    if ($Report) {
        $action = if ($before) { 'stored' } else { 'MISSING' }
    }
    elseif ($before -and -not $Force) {
        $action = 'stored'
    }
    elseif (-not $running) {
        # Cannot read a stopped guest. Absent is not the same as up to date -- say which.
        $action = if ($before) { 'stopped (kept)' } else { 'stopped (NO HASH)' }
        if (-not $before) { $failed++ }
    }
    elseif ($PSCmdlet.ShouldProcess($vm.vmName, 'Capture RDP listener certificate hash')) {
        $after = Update-VmRdpCertNote -VmName $vm.vmName -VmDomainName $vm.Domain -Force:$Force
        if (-not $after) {
            $action = 'FAILED'
            $failed++
        }
        elseif ($after -ne $before) {
            $action = if ($before) { 'refreshed' } else { 'captured' }
            $captured++
        }
        else {
            $action = 'unchanged'
        }
    }

    $results.Add([pscustomobject]@{
            VM      = $vm.vmName
            State   = "$($vm.State)"
            Sha256  = if ($after) { $after.Substring(0, 16) + '...' } else { '(none)' }
            Action  = $action
        })
}

$results | Format-Table -AutoSize | Out-String | Write-Host

$withHash = @($results | Where-Object { $_.Sha256 -ne '(none)' }).Count
$color = if ($failed -gt 0) { 'Yellow' } else { 'Green' }
Write-Host "$withHash of $($results.Count) VM(s) have a stored hash ($captured captured this run); $failed without one." -ForegroundColor $color

# ---- regenerate ------------------------------------------------------------
if (-not $Report -and -not $SkipRdgUpdate -and $captured -gt 0) {
    if ($PSCmdlet.ShouldProcess($Global:Common.RdcManFilePath, 'Regenerate RDCMan file')) {
        Write-Host "Regenerating $($Global:Common.RdcManFilePath)..." -ForegroundColor Cyan
        New-RDCManFileFromHyperV -rdcmanfile $Global:Common.RdcManFilePath -OverWrite:$false
        Write-Host 'Done. Close and reopen the file group in RDCMan for the new trust to take effect.' -ForegroundColor Yellow
    }
}

if ($failed -gt 0) { exit 2 }
exit 0
