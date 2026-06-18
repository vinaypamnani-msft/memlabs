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
    [int]$SyncTimeoutMinutes = 90,

    # Wipe SUSDB + WsusContent and re-run wsusutil postinstall on the guest
    # before pre-flight. Use when re-running the generator on a VM whose
    # WSUS has already been synced (categories>0 or updates>0).
    [Parameter(Mandatory = $false)]
    [switch]$Reset,

    # Skip pre-flight gate and the StartSynchronization kick: attach to an
    # already-running categories sync on the guest and poll it to completion,
    # then export. Use when a previous run timed out mid-sync. Mutually
    # exclusive with -Reset.
    [Parameter(Mandatory = $false)]
    [switch]$Resume
)

if ($Reset.IsPresent -and $Resume.IsPresent) {
    throw "[Baseline] -Reset and -Resume are mutually exclusive."
}

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

Write-Log "[Baseline] Target VM:    $VmName"
Write-Log "[Baseline] Domain:       $DomainName"
Write-Log "[Baseline] Output dir:   $OutputDir"
Write-Log "[Baseline] Timeout:      $SyncTimeoutMinutes min"
Write-Log "[Baseline] Reset:        $($Reset.IsPresent)"
Write-Log "[Baseline] Resume:       $($Resume.IsPresent)"

# -Reset: wipe SUSDB + WsusContent and re-run wsusutil postinstall. Lets us
# re-run the generator against an already-synced VM without rebuilding it.
if ($Reset.IsPresent) {
    Write-Log "[Baseline] -Reset specified: stopping WSUS, dropping SUSDB, clearing content, re-running postinstall..." -Warning
    $resetResult = Invoke-VmCommand -VmName $VmName -VmDomainName $DomainName -TimeoutSeconds 1800 -DisplayName "Baseline: reset WSUS" -ScriptBlock {
        try {
            # Read WSUS configuration from registry. ContentDir + SqlServerName
            # tell us where SUSDB lives (WID vs local/remote SQL).
            $setupKey = 'HKLM:\Software\Microsoft\Update Services\Server\Setup'
            $regProps = $null
            try { $regProps = Get-ItemProperty $setupKey -ErrorAction Stop } catch {}
            $contentDir = if ($regProps -and $regProps.ContentDir) { $regProps.ContentDir } else { 'C:\WSUS' }
            $sqlServerName = if ($regProps -and $regProps.SqlServerName) { [string]$regProps.SqlServerName } else { '' }

            # Classify backend: WID instance name is literally MICROSOFT##WID
            # (usually qualified as <COMPUTER>\MICROSOFT##WID). Anything else
            # is a real SQL instance, local or remote.
            $isWid = ($sqlServerName -match 'MICROSOFT##WID' -or $sqlServerName -eq '')
            if ($isWid) {
                $sqlDisplay = "WID ($sqlServerName)"
                $sqlClientServer = 'np:\\.\pipe\MICROSOFT##WID\tsql\query'
            } else {
                $sqlDisplay = "SQL ($sqlServerName)"
                $sqlClientServer = $sqlServerName
            }
            Write-Verbose "[Reset] Backend: $sqlDisplay  ContentDir: $contentDir"

            # Stop WSUS so SUSDB has no live connections.
            Stop-Service WsusService -Force -ErrorAction SilentlyContinue

            if ($isWid) {
                # Ensure WID is running (it hosts SUSDB locally).
                $widSvc = Get-Service -Name 'MSSQL$MICROSOFT##WID' -ErrorAction SilentlyContinue
                if (-not $widSvc) { throw "WID service 'MSSQL`$MICROSOFT##WID' not found, but registry says SUSDB is on WID." }
                if ($widSvc.Status -ne 'Running') {
                    Set-Service -Name 'MSSQL$MICROSOFT##WID' -StartupType Automatic -ErrorAction SilentlyContinue
                    Start-Service -Name 'MSSQL$MICROSOFT##WID' -ErrorAction Stop
                }
                $pipeDeadline = (Get-Date).AddSeconds(30)
                while (-not (Test-Path '\\.\pipe\MICROSOFT##WID\tsql\query') -and (Get-Date) -lt $pipeDeadline) {
                    Start-Sleep -Milliseconds 500
                }
                if (-not (Test-Path '\\.\pipe\MICROSOFT##WID\tsql\query')) { throw "WID pipe never appeared." }
            }

            # Drop SUSDB via SqlClient (works against WID over the pipe, against
            # local/remote SQL over TCP). System.Data.SqlClient is always present
            # in PowerShell 5.1.
            $connStr = "Server=$sqlClientServer;Database=master;Integrated Security=True;Connect Timeout=30;TrustServerCertificate=True"
            $conn = New-Object System.Data.SqlClient.SqlConnection $connStr
            $conn.Open()
            try {
                $cmd = $conn.CreateCommand()
                $cmd.CommandTimeout = 120
                $cmd.CommandText = @"
IF DB_ID('SUSDB') IS NOT NULL
BEGIN
  ALTER DATABASE SUSDB SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
  DROP DATABASE SUSDB;
END
"@
                [void]$cmd.ExecuteNonQuery()
            }
            finally { $conn.Close() }

            # Clear content.
            if (Test-Path $contentDir) {
                Get-ChildItem -Path $contentDir -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            } else {
                New-Item -ItemType Directory -Path $contentDir -Force | Out-Null
            }

            # Re-run postinstall to recreate SUSDB. Mirror the DSC's argument
            # shape: SQL_INSTANCE_NAME only when not on WID.
            $wsusUtil = Join-Path $env:ProgramFiles 'Update Services\Tools\WsusUtil.exe'
            if (-not (Test-Path $wsusUtil)) { throw "WsusUtil.exe not found at $wsusUtil" }
            if ($isWid) {
                $piArgs = @('postinstall', "CONTENT_DIR=$contentDir")
            } else {
                $piArgs = @('postinstall', "SQL_INSTANCE_NAME=$sqlServerName", "CONTENT_DIR=$contentDir")
            }
            $postinstallLog = Join-Path $env:TEMP 'WsusBaselineReset_postinstall.log'
            $proc = Start-Process -FilePath $wsusUtil -ArgumentList $piArgs -Wait -PassThru -NoNewWindow -RedirectStandardOutput $postinstallLog -ErrorAction Stop
            if ($proc.ExitCode -ne 0) {
                $tail = ''
                if (Test-Path $postinstallLog) { $tail = (Get-Content $postinstallLog -Tail 10 -ErrorAction SilentlyContinue) -join "`n" }
                throw "wsusutil postinstall exit=$($proc.ExitCode). Args: $($piArgs -join ' '). Tail: $tail"
            }

            Start-Service WsusService -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 10
            [PSCustomObject]@{ Ok = $true; ContentDir = $contentDir; SqlBackend = $sqlDisplay }
        }
        catch {
            [PSCustomObject]@{ Ok = $false; Error = $_.Exception.Message }
        }
    }
    if (-not $resetResult -or -not $resetResult.ScriptBlockOutput -or -not $resetResult.ScriptBlockOutput.Ok) {
        $errMsg = if ($resetResult -and $resetResult.ScriptBlockOutput) { $resetResult.ScriptBlockOutput.Error } else { 'no output' }
        throw "[Baseline] -Reset failed: $errMsg"
    }
    Write-Log "[Baseline] Reset complete (backend=$($resetResult.ScriptBlockOutput.SqlBackend), ContentDir=$($resetResult.ScriptBlockOutput.ContentDir)). Re-running pre-flight..." -Success
}

# Pre-flight: VM must be a clean WSUS server with no MU sync history. Fail
# loudly otherwise -- exporting from a partially-synced or product-subscribed
# WSUS would inflate the cab and contaminate every future deploy. We allow
# Categories > 0 (a fresh `wsusutil postinstall` seeds a small bookkeeping
# row in dbo.UpdateCategories) and use UpdateCount=0 + SyncHistory=0 as the
# authoritative "nothing's been synced from MU" signals.
$preflight = Invoke-VmCommand -VmName $VmName -VmDomainName $DomainName -DisplayName "Baseline: pre-flight check" -ScriptBlock {
    try {
        $wsus = Get-WsusServer -ErrorAction Stop
        $sub = $wsus.GetSubscription()
        $cats = $sub.GetUpdateCategories()
        $catCount = if ($cats) { $cats.Count } else { 0 }
        $clas = $sub.GetUpdateClassifications()
        $clasCount = if ($clas) { $clas.Count } else { 0 }
        $status = $wsus.GetStatus()
        $hist = @($sub.GetSynchronizationHistory())
        $os = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').ProductName
        [PSCustomObject]@{
            Ok                = $true
            Categories        = $catCount
            Classifications   = $clasCount
            UpdateCount       = $status.UpdateCount
            SyncHistoryCount  = $hist.Count
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
Write-Log "[Baseline] Pre-flight OK. WSUS=$($pre.WsusServerVersion), OS='$($pre.OsVersion)', Categories=$($pre.Categories), Classifications=$($pre.Classifications), UpdateCount=$($pre.UpdateCount), SyncHistory=$($pre.SyncHistoryCount)"
if (-not $Resume.IsPresent) {
    if ($pre.UpdateCount -gt 0 -or $pre.SyncHistoryCount -gt 0) {
        throw "[Baseline] $VmName has UpdateCount=$($pre.UpdateCount) and SyncHistoryCount=$($pre.SyncHistoryCount). Generator requires a WSUS that has never synced from MU. Re-run with -Reset, or use a freshly-built single-VM Role=WSUS lab."
    }
}
else {
    Write-Log "[Baseline] -Resume: skipping clean-WSUS pre-flight gate."
}

# Drive a categories sync on the guest. Subscribe to a minimal product set
# (SQL Server 2005 + Tools, mirroring the existing WSUSSync resource), kick
# the sync, then poll from the host every 60s so progress is visible.
if ($Resume.IsPresent) {
    Write-Log "[Baseline] -Resume: attaching to existing categories sync (skipping hardening + StartSynchronization)..."
}
else {
Write-Log "[Baseline] Hardening WsusPool and kicking minimal-scope categories sync..."
$kick = Invoke-VmCommand -VmName $VmName -VmDomainName $DomainName -TimeoutSeconds 300 -DisplayName "Baseline: start categories sync" -ScriptBlock {
    try {
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
        [PSCustomObject]@{ Ok = $true; Status = $sub.GetSynchronizationStatus().ToString() }
    }
    catch {
        [PSCustomObject]@{ Ok = $false; Error = $_.Exception.Message }
    }
}
if (-not $kick -or -not $kick.ScriptBlockOutput -or -not $kick.ScriptBlockOutput.Ok) {
    $errMsg = if ($kick -and $kick.ScriptBlockOutput) { $kick.ScriptBlockOutput.Error } else { "no output" }
    throw "[Baseline] Failed to start categories sync: $errMsg"
}
Write-Log "[Baseline] Sync started (status=$($kick.ScriptBlockOutput.Status)). Polling every 60s..."
}

# Poll from host. Each poll is a short Invoke-VmCommand so we see live progress
# in the console instead of one ~60-min silent block.
$pollDeadline = (Get-Date).AddMinutes($SyncTimeoutMinutes)
$syncResult = $null
$pollIdx = 0
while ((Get-Date) -lt $pollDeadline) {
    # On -Resume, poll immediately so operator sees current sync state without
    # waiting a full minute; subsequent iterations use the normal 60s cadence.
    if (-not ($Resume.IsPresent -and $pollIdx -eq 0)) {
        Start-Sleep -Seconds 60
    }
    $pollIdx++
    $poll = Invoke-VmCommand -VmName $VmName -VmDomainName $DomainName -TimeoutSeconds 120 -DisplayName "Baseline: poll #$pollIdx" -SuppressLog -ScriptBlock {
        try {
            $wsus = Get-WsusServer -ErrorAction Stop
            $sub = $wsus.GetSubscription()
            $status = $sub.GetSynchronizationStatus().ToString()
            $phase = ''
            try { $phase = $sub.GetSynchronizationProgress().Phase.ToString() } catch {}
            # Taxonomy: ALL categories now in the WSUS DB (what the cab will
            # export). $sub.GetUpdateCategories() returns only SUBSCRIBED
            # categories and is 0 here because the first sync had no products
            # subscribed yet -- it populates the taxonomy regardless.
            $taxonomyCats = @($wsus.GetUpdateCategories()).Count
            $taxonomyClas = @($wsus.GetUpdateClassifications()).Count
            $hist = @($sub.GetSynchronizationHistory() | Sort-Object StartTime -Descending | Select-Object -First 1)
            $lastResult = if ($hist.Count -gt 0) { $hist[0].Result.ToString() } else { '<no-history>' }
            [PSCustomObject]@{ Ok = $true; Status = $status; Phase = $phase; TaxonomyCats = $taxonomyCats; TaxonomyClas = $taxonomyClas; LastResult = $lastResult }
        }
        catch {
            [PSCustomObject]@{ Ok = $false; Error = $_.Exception.Message }
        }
    }
    if (-not $poll -or -not $poll.ScriptBlockOutput) {
        Write-Log "[Baseline] Poll #$pollIdx returned no output; continuing..." -Warning
        continue
    }
    $p = $poll.ScriptBlockOutput
    if (-not $p.Ok) {
        Write-Log "[Baseline] Poll #$pollIdx error: $($p.Error)" -Warning
        continue
    }
    $elapsedMin = [math]::Round((New-TimeSpan -Start ($pollDeadline.AddMinutes(-$SyncTimeoutMinutes)) -End (Get-Date)).TotalMinutes, 1)
    Write-Log "[Baseline] [$elapsedMin min] Status=$($p.Status) Phase=$($p.Phase) TaxonomyCats=$($p.TaxonomyCats) TaxonomyClas=$($p.TaxonomyClas) LastResult=$($p.LastResult)"
    # Break once the sync is no longer running AND a history record exists.
    # We intentionally do NOT gate on taxonomy counts -- a successful sync
    # that returns 0 categories is still a definitive terminal state and
    # the LastResult check below will surface the problem.
    if ($p.Status -ne 'Running' -and $p.LastResult -ne '<no-history>') {
        $syncResult = $p
        break
    }
}
if (-not $syncResult) {
    throw "[Baseline] Categories sync did not complete within $SyncTimeoutMinutes minutes."
}
if ($syncResult.LastResult -ne 'Succeeded') {
    throw "[Baseline] Categories sync ended with LastResult='$($syncResult.LastResult)' (status=$($syncResult.Status), taxonomyCats=$($syncResult.TaxonomyCats))."
}
if ($syncResult.TaxonomyCats -le 0) {
    throw "[Baseline] Sync reported Succeeded but the WSUS taxonomy is empty (TaxonomyCats=0). Refusing to export an empty cab."
}
Write-Log "[Baseline] Sync complete. Status=$($syncResult.Status), TaxonomyCats=$($syncResult.TaxonomyCats), TaxonomyClas=$($syncResult.TaxonomyClas), LastResult=$($syncResult.LastResult)"

# Disable subscriptions and run wsusutil export on the guest.
$exportGuestPath = "C:\staging\wsus_export\WsusCategoriesBaseline.cab"
$exportGuestLog = "C:\staging\wsus_export\WsusCategoriesBaseline.export.log"
Write-Log "[Baseline] Cleaning subscriptions and running wsusutil export..."
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
        # Record DB-wide taxonomy counts (what the cab actually contains).
        # $sub.GetUpdateCategories() would return 0 here because we just
        # unsubscribed everything to keep the cab pure-taxonomy.
        $cats = @($wsus.GetUpdateCategories())
        $clas = @($wsus.GetUpdateClassifications())
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
Write-Log "[Baseline] Export OK. Size=$sizeMB MB, SHA256=$($exp.Sha256), Categories=$($exp.Categories), Classifications=$($exp.Classifications)"

# Pull cab + log back to host via PSDirect session using the lab local admin.
$outCab = Join-Path $OutputDir "WsusCategoriesBaseline.cab"
$outLog = Join-Path $OutputDir "WsusCategoriesBaseline.export.log"
$outMeta = Join-Path $OutputDir "WsusCategoriesBaseline.meta.json"
Write-Log "[Baseline] Copying cab to host: $outCab"

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

Write-Log ""
Write-Log "[Baseline] Done." -Success
Write-Log "  Cab:      $outCab ($sizeMB MB)"
Write-Log "  Sidecar:  $outMeta"
Write-Log "  Log:      $outLog"
Write-Log ""
Write-Log "[Baseline] Next steps:"
Write-Log "  1. Add the cab + sidecar to vmbuild\azureFiles\_filelist.json under 'tools'."
Write-Log "  2. Upload them to the storage account at the same relative path."
Write-Log "  3. Future deploys with cmOptions.WsusImportBaseline=`$true (default) will pick this up automatically."
