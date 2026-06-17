# New-WsusCategoriesBaseline.ps1
#
# Operator-run helper that produces a `wsusutil export` cab containing only
# the Products / Classifications / Languages / Detectoid taxonomy from a
# clean WSUS server (no products subscribed, no update metadata). The cab
# is then imported in Phase 7 by the WSUSSync DSC resource on every fresh
# deploy, in place of the slow / flaky first MU categories sync.
#
# Cadence: regenerate when (a) a new Microsoft product memlabs needs has
# shipped, or (b) the existing cab is older than ~18 months. Until then the
# same cab is reused for every deploy.
#
# Required inputs:
#   -VmName     : a freshly-deployed standalone WSUS VM (Phase 6 finished,
#                 Phase 7 NOT yet run, so categories table is empty). The
#                 simplest setup is a 1-VM lab with Role=WSUS.
#   -DomainName : domain the VM is joined to (used by Invoke-VmCommand).
#
# Output (in -OutputDir, default vmbuild\azureFiles\tools\wsus\):
#   - WsusCategoriesBaseline.cab          : the exported metadata cab
#   - WsusCategoriesBaseline.meta.json    : provenance sidecar (sha256, date, counts)
#   - WsusCategoriesBaseline.export.log   : wsusutil's own log (kept for diagnostics)
#
# After this script completes the operator must:
#   1. Add the cab + sidecar to vmbuild\azureFiles\_filelist.json under tools.
#   2. Upload them to the storage account at the same relative path.
#   Subsequent deploys with cmOptions.WsusImportBaseline=$true (the default)
#   will pick the cab up automatically via Get-FilesForConfiguration.

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$VmName,

    [Parameter(Mandatory = $true)]
    [string]$DomainName,

    [Parameter(Mandatory = $false)]
    [string]$OutputDir,

    [Parameter(Mandatory = $false)]
    [int]$SyncTimeoutMinutes = 90
)

$ErrorActionPreference = 'Stop'
$enableVerbose = $PSCmdlet.MyInvocation.BoundParameters["Verbose"].IsPresent

# Bootstrap: dot-source vmbuild\Common.ps1 (mirrors New-BaseImage.ps1 pattern).
$RootPath = Split-Path -Path $PSScriptRoot -Parent
. $RootPath\Common.ps1 -VerboseEnabled:$enableVerbose
if ($Common.FatalError) {
    Write-Log "Critical Failure! $($Common.FatalError)" -Failure
    return
}

if (-not $OutputDir) {
    $OutputDir = Join-Path $Common.AzureFilesPath "tools\wsus"
}
if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}
$OutputDir = (Resolve-Path $OutputDir).Path

Write-Log "[Baseline] Target VM:    $VmName" -OutputStream
Write-Log "[Baseline] Domain:       $DomainName" -OutputStream
Write-Log "[Baseline] Output dir:   $OutputDir" -OutputStream
Write-Log "[Baseline] Timeout:      $SyncTimeoutMinutes min" -OutputStream

# Pre-flight: VM must be a clean WSUS server with categories empty. Fail
# loudly otherwise -- exporting from a partially-synced or product-subscribed
# WSUS would inflate the cab and contaminate every future deploy.
$preflight = Invoke-VmCommand -VmName $VmName -VmDomainName $DomainName -DisplayName "Baseline: pre-flight check" -ScriptBlock {
    try {
        $wsus = Get-WsusServer -ErrorAction Stop
        $sub = $wsus.GetSubscription()
        $cats = $sub.GetUpdateCategories()
        $catCount = if ($cats) { $cats.Count } else { 0 }
        $clas = $sub.GetUpdateClassifications()
        $clasCount = if ($clas) { $clas.Count } else { 0 }
        $status = $wsus.GetStatus()
        $os = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').ProductName
        [PSCustomObject]@{
            Ok                = $true
            Categories        = $catCount
            Classifications   = $clasCount
            UpdateCount       = $status.UpdateCount
            WsusServerVersion = $wsus.Version.ToString()
            OsVersion         = $os
        }
    }
    catch {
        [PSCustomObject]@{ Ok = $false; Error = $_.Exception.Message }
    }
}
if (-not $preflight -or -not $preflight.ScriptBlockOutput -or -not $preflight.ScriptBlockOutput.Ok) {
    $errMsg = if ($preflight -and $preflight.ScriptBlockOutput) { $preflight.ScriptBlockOutput.Error } else { "no output" }
    throw "[Baseline] Pre-flight failed against $VmName : $errMsg"
}
$pre = $preflight.ScriptBlockOutput
Write-Log "[Baseline] Pre-flight OK. WSUS=$($pre.WsusServerVersion), OS='$($pre.OsVersion)', Categories=$($pre.Categories), Classifications=$($pre.Classifications), UpdateCount=$($pre.UpdateCount)" -OutputStream
if ($pre.Categories -gt 0 -or $pre.UpdateCount -gt 0) {
    throw "[Baseline] $VmName already has categories ($($pre.Categories)) or updates ($($pre.UpdateCount)). Generator requires a clean WSUS (0/0). Use a freshly-built single-VM Role=WSUS lab."
}

# Drive a categories sync on the guest. Subscribe to a minimal product set
# (SQL Server 2005 + Tools, mirroring the existing WSUSSync resource), kick
# the sync, wait for it to complete, then disable the subscriptions again so
# the exported cab is pure taxonomy with no subscribed products.
Write-Log "[Baseline] Driving minimal-scope categories sync (timeout: $SyncTimeoutMinutes min)..." -OutputStream
$sync = Invoke-VmCommand -VmName $VmName -VmDomainName $DomainName -TimeoutSeconds (($SyncTimeoutMinutes + 5) * 60) -DisplayName "Baseline: drive categories sync" -ScriptBlock {
    param($timeoutMinutes)
    $wsus = Get-WsusServer -ErrorAction Stop
    $sub = $wsus.GetSubscription()

    # Harden WsusPool. The default 1.8 GB privateMemory cap recycles the pool
    # mid-sync (HTTP 503) -- documented as a recurring root cause of stuck
    # syncs. Uncap before we start.
    try {
        Import-Module WebAdministration -ErrorAction SilentlyContinue
        Set-ItemProperty -Path 'IIS:\AppPools\WsusPool' -Name recycling.periodicRestart.privateMemory -Value 0 -ErrorAction SilentlyContinue
        Restart-WebAppPool -Name WsusPool -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 5
    } catch {}

    Get-WsusProduct | Set-WsusProduct -Disable
    Get-WsusProduct | Where-Object { $_.Product.Title -eq "SQL Server 2005" } | Set-WsusProduct
    Get-WsusClassification | Set-WsusClassification -Disable
    Get-WsusClassification | Where-Object { $_.Classification.Title -eq "Tools" } | Set-WsusClassification

    $sub.StartSynchronization()
    $deadline = (Get-Date).AddMinutes([int]$timeoutMinutes)
    while ((Get-Date) -lt $deadline) {
        $status = $sub.GetSynchronizationStatus().ToString()
        $cats = $sub.GetUpdateCategories()
        $catCount = if ($cats) { $cats.Count } else { 0 }
        if ($status -ne 'Running' -and $catCount -gt 0) {
            $hist = @($sub.GetSynchronizationHistory() | Sort-Object StartTime -Descending | Select-Object -First 1)
            $result = if ($hist.Count -gt 0) { $hist[0].Result.ToString() } else { '<no-history>' }
            return [PSCustomObject]@{
                Ok         = ($result -eq 'Succeeded')
                Status     = $status
                Categories = $catCount
                LastResult = $result
            }
        }
        Start-Sleep -Seconds 30
    }
    return [PSCustomObject]@{
        Ok         = $false
        Status     = $sub.GetSynchronizationStatus().ToString()
        Categories = (@($sub.GetUpdateCategories()).Count)
        LastResult = 'TIMEOUT'
    }
} -ArgumentList $SyncTimeoutMinutes
if (-not $sync -or -not $sync.ScriptBlockOutput -or -not $sync.ScriptBlockOutput.Ok) {
    $s = if ($sync) { $sync.ScriptBlockOutput | Out-String } else { "<no output>" }
    throw "[Baseline] Categories sync did not complete cleanly: $s"
}
$syncResult = $sync.ScriptBlockOutput
Write-Log "[Baseline] Sync complete. Status=$($syncResult.Status), Categories=$($syncResult.Categories), LastResult=$($syncResult.LastResult)" -OutputStream

# Disable subscriptions and run wsusutil export on the guest.
$exportGuestPath = "C:\staging\wsus_export\WsusCategoriesBaseline.cab"
$exportGuestLog = "C:\staging\wsus_export\WsusCategoriesBaseline.export.log"
Write-Log "[Baseline] Cleaning subscriptions and running wsusutil export..." -OutputStream
$export = Invoke-VmCommand -VmName $VmName -VmDomainName $DomainName -TimeoutSeconds 1800 -DisplayName "Baseline: wsusutil export" -ScriptBlock {
    param($cabPath, $logPath)
    try {
        $wsus = Get-WsusServer -ErrorAction Stop
        # Strip subscribed products / classifications so the cab is pure taxonomy.
        Get-WsusProduct | Set-WsusProduct -Disable
        Get-WsusClassification | Set-WsusClassification -Disable

        $exportDir = Split-Path -Parent $cabPath
        if (-not (Test-Path $exportDir)) { New-Item -ItemType Directory -Path $exportDir -Force | Out-Null }
        Get-ChildItem -Path $exportDir -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

        $wsusUtil = Join-Path $env:ProgramFiles 'Update Services\Tools\WsusUtil.exe'
        if (-not (Test-Path $wsusUtil)) { throw "WsusUtil.exe not found at $wsusUtil" }

        $proc = Start-Process -FilePath $wsusUtil -ArgumentList @('export', $cabPath, $logPath) -Wait -PassThru -NoNewWindow -ErrorAction Stop
        if ($proc.ExitCode -ne 0) {
            $tail = ''
            if (Test-Path $logPath) { $tail = (Get-Content $logPath -Tail 10 -ErrorAction SilentlyContinue) -join "`n" }
            throw "wsusutil export exit=$($proc.ExitCode). Tail: $tail"
        }
        if (-not (Test-Path $cabPath)) { throw "wsusutil export reported success but cab not found at $cabPath" }

        $cabFile = Get-Item $cabPath
        $sub = $wsus.GetSubscription()
        $cats = @($sub.GetUpdateCategories())
        $clas = @($sub.GetUpdateClassifications())
        $hash = (Get-FileHash -Path $cabPath -Algorithm SHA256).Hash
        [PSCustomObject]@{
            Ok              = $true
            CabPath         = $cabPath
            LogPath         = $logPath
            Bytes           = $cabFile.Length
            Sha256          = $hash
            Categories      = $cats.Count
            Classifications = $clas.Count
        }
    }
    catch {
        [PSCustomObject]@{ Ok = $false; Error = $_.Exception.Message }
    }
} -ArgumentList $exportGuestPath, $exportGuestLog
if (-not $export -or -not $export.ScriptBlockOutput -or -not $export.ScriptBlockOutput.Ok) {
    $errMsg = if ($export -and $export.ScriptBlockOutput) { $export.ScriptBlockOutput.Error } else { "no output" }
    throw "[Baseline] wsusutil export failed: $errMsg"
}
$exp = $export.ScriptBlockOutput
$sizeMB = [math]::Round($exp.Bytes / 1MB, 1)
Write-Log "[Baseline] Export OK. Size=$sizeMB MB, SHA256=$($exp.Sha256), Categories=$($exp.Categories), Classifications=$($exp.Classifications)" -OutputStream

# Pull cab + log back to host via PSDirect session using the lab local admin.
$outCab = Join-Path $OutputDir "WsusCategoriesBaseline.cab"
$outLog = Join-Path $OutputDir "WsusCategoriesBaseline.export.log"
$outMeta = Join-Path $OutputDir "WsusCategoriesBaseline.meta.json"
Write-Log "[Baseline] Copying cab to host: $outCab" -OutputStream

$session = New-PSSession -VMName $VmName -Credential $Common.LocalAdmin -ErrorAction Stop
try {
    Copy-Item -FromSession $session -Path $exportGuestPath -Destination $outCab -Force
    Copy-Item -FromSession $session -Path $exportGuestLog  -Destination $outLog -Force
}
finally {
    Remove-PSSession $session -ErrorAction SilentlyContinue
}

# Sidecar: provenance metadata for the WSUSSync DSC resource and Phase 11 validation.
$meta = [PSCustomObject]@{
    generatedUtc     = (Get-Date).ToUniversalTime().ToString('o')
    sourceVm         = $VmName
    sourceOs         = $pre.OsVersion
    wsusVersion      = $pre.WsusServerVersion
    sha256           = $exp.Sha256
    sizeBytes        = $exp.Bytes
    categories       = $exp.Categories
    classifications  = $exp.Classifications
    generatorVersion = '1.0'
}
$meta | ConvertTo-Json -Depth 5 | Out-File -FilePath $outMeta -Encoding utf8 -Force

Write-Log "" -OutputStream
Write-Log "[Baseline] Done." -OutputStream -Success
Write-Log "  Cab:      $outCab ($sizeMB MB)" -OutputStream
Write-Log "  Sidecar:  $outMeta" -OutputStream
Write-Log "  Log:      $outLog" -OutputStream
Write-Log "" -OutputStream
Write-Log "[Baseline] Next steps:" -OutputStream
Write-Log "  1. Add the cab + sidecar to vmbuild\azureFiles\_filelist.json under 'tools'." -OutputStream
Write-Log "  2. Upload them to the storage account at the same relative path." -OutputStream
Write-Log "  3. Future deploys with cmOptions.WsusImportBaseline=`$true (default) will pick this up automatically." -OutputStream
