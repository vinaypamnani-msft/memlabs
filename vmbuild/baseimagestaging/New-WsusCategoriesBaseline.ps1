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
#   - WsusCategoriesBaseline.export.log   : wsusutil's own log (kept for diagnostics)
#
# After this script completes the operator must:
#   1. (Optional but recommended) Test the cab end-to-end against a fresh
#      WSUS VM with `-Upload` (see below) before publishing.
#   2. Add the cab to vmbuild\azureFiles\_filelist.json under tools (md5
#      gates integrity; optional GeneratedUtc field is allowed for human
#      reference).
#   3. Upload it to the storage account at the same relative path.
#   Subsequent deploys with cmOptions.WsusImportBaseline=$true (the default)
#   will pick the cab up automatically via Get-FilesForConfiguration. The
#   pre-DSC copy logs a staleness warning if the host cab is >540 days old
#   (based on its LastWriteTime).
#
# -Upload (test mode):
#   Skips generation entirely. Pushes an existing host cab (default
#   $OutputDir\WsusCategoriesBaseline.cab, override with -CabPath) to the
#   guest at C:\staging\wsus\WsusCategoriesBaseline.cab -- the exact path
#   the WSUSSync DSC resource reads from in Phase 7 -- runs `wsusutil
#   import`, and prints pre/post taxonomy counts and the delta. Use this
#   to validate a freshly-generated cab against a clean WSUS VM before
#   uploading it to Azure Files. Combine with -Reset to wipe + retest on
#   the same VM.

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
    [switch]$Resume,

    # Test mode: skip generation. Push an existing host cab to the guest at
    # the same path WSUSSync DSC reads from, run `wsusutil import`, and
    # report pre/post taxonomy counts. Combine with -Reset to wipe + retest.
    # Mutually exclusive with -Resume.
    [Parameter(Mandatory = $false)]
    [switch]$Upload,

    # Optional override for -Upload mode: path to the host cab to push +
    # import. Defaults to $OutputDir\WsusCategoriesBaseline.cab.
    [Parameter(Mandatory = $false)]
    [string]$CabPath
)

if ($Reset.IsPresent -and $Resume.IsPresent) {
    throw "[Baseline] -Reset and -Resume are mutually exclusive."
}
if ($Upload.IsPresent -and $Resume.IsPresent) {
    throw "[Baseline] -Upload and -Resume are mutually exclusive."
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
Write-Log "[Baseline] Upload:       $($Upload.IsPresent)"

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

# -Upload: short-circuit. Skip generation; push an existing host cab to the
# guest at C:\staging\wsus\WsusCategoriesBaseline.cab (the exact path the
# WSUSSync DSC resource reads from in Phase 7), snapshot pre-import
# taxonomy, run `wsusutil import`, snapshot post-import taxonomy, and
# report the delta. Validates a freshly-generated cab end-to-end before
# the operator uploads it to Azure Files.
if ($Upload.IsPresent) {
    if (-not $CabPath) {
        $CabPath = Join-Path $OutputDir "WsusCategoriesBaseline.cab"
    }
    if (-not (Test-Path -LiteralPath $CabPath)) {
        throw "[Baseline] -Upload: cab not found at $CabPath. Run the generator first, or pass -CabPath."
    }
    $cabFile = Get-Item -LiteralPath $CabPath
    $cabMd5 = (Get-FileHash -LiteralPath $CabPath -Algorithm MD5).Hash
    $cabSizeMB = [math]::Round($cabFile.Length / 1MB, 2)
    Write-Log "[Baseline] -Upload source: $CabPath ($cabSizeMB MB, MD5=$cabMd5, mtime=$($cabFile.LastWriteTimeUtc.ToString('o')))"

    # Pre-import snapshot. Mirrors the DSC gate: if subscribed categories
    # are already populated, DSC skips import -- surface the same gate here
    # so the test reflects what production would do. Allows -Reset to be
    # combined with -Upload to wipe the VM first.
    $preU = Invoke-VmCommand -VmName $VmName -VmDomainName $DomainName -DisplayName "Upload: pre-import snapshot" -ScriptBlock {
        try {
            $wsus = Get-WsusServer -ErrorAction Stop
            $sub = $wsus.GetSubscription()
            $taxonomyCats = @($wsus.GetUpdateCategories()).Count
            $taxonomyClas = @($wsus.GetUpdateClassifications()).Count
            $subCats = @($sub.GetUpdateCategories()).Count
            $subClas = @($sub.GetUpdateClassifications()).Count
            $status = $wsus.GetStatus()
            $hist = @($sub.GetSynchronizationHistory())
            [PSCustomObject]@{
                Ok               = $true
                TaxonomyCats     = $taxonomyCats
                TaxonomyClas     = $taxonomyClas
                SubscribedCats   = $subCats
                SubscribedClas   = $subClas
                UpdateCount      = $status.UpdateCount
                SyncHistoryCount = $hist.Count
                WsusVersion      = $wsus.Version.ToString()
            }
        }
        catch { [PSCustomObject]@{ Ok = $false; Error = $_.Exception.Message } }
    }
    if (-not $preU -or -not $preU.ScriptBlockOutput -or -not $preU.ScriptBlockOutput.Ok) {
        $errMsg = if ($preU -and $preU.ScriptBlockOutput) { $preU.ScriptBlockOutput.Error } else { "no output" }
        throw "[Baseline] -Upload: pre-import snapshot failed: $errMsg"
    }
    $pre = $preU.ScriptBlockOutput
    Write-Log "[Baseline] Pre-import:  WSUS=$($pre.WsusVersion), TaxonomyCats=$($pre.TaxonomyCats), TaxonomyClas=$($pre.TaxonomyClas), SubscribedCats=$($pre.SubscribedCats), UpdateCount=$($pre.UpdateCount), SyncHistory=$($pre.SyncHistoryCount)"
    # Gate mirrors the generator pre-flight: allow SubscribedCats > 0
    # (a fresh `wsusutil postinstall` seeds a small bookkeeping row in
    # dbo.UpdateCategories that surfaces here as 1) and refuse only when
    # UpdateCount > 0 or SyncHistoryCount > 0 -- the authoritative signals
    # that an MU sync has actually happened and the catalog is mixed.
    if ($pre.UpdateCount -gt 0 -or $pre.SyncHistoryCount -gt 0) {
        throw "[Baseline] -Upload: VM is not clean (UpdateCount=$($pre.UpdateCount), SyncHistory=$($pre.SyncHistoryCount)). WSUS has already synced from MU; importing the baseline on top would mix taxonomies. Re-run with -Reset -Upload or use a fresh WSUS VM."
    }
    if ($pre.SubscribedCats -gt 0) {
        Write-Log "[Baseline] -Upload: SubscribedCats=$($pre.SubscribedCats) on a never-synced WSUS (UpdateCount=0, SyncHistory=0). This is the postinstall seed row; proceeding with import." -Warning
    }

    # Push cab to the guest at the exact path DSC consumes.
    $guestCabDir = 'C:\staging\wsus'
    $guestCab = "$guestCabDir\WsusCategoriesBaseline.cab"
    $guestImportLog = "$guestCabDir\WsusCategoriesBaseline.import.log"
    Write-Log "[Baseline] Preparing guest staging dir + copying cab to ${VmName}:$guestCab"
    $prep = Invoke-VmCommand -VmName $VmName -VmDomainName $DomainName -DisplayName "Upload: prep staging dir" -ScriptBlock {
        param($dir, $cab, $log)
        try {
            if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            if (Test-Path $cab) { Remove-Item -LiteralPath $cab -Force -ErrorAction SilentlyContinue }
            if (Test-Path $log) { Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue }
            [PSCustomObject]@{ Ok = $true }
        }
        catch { [PSCustomObject]@{ Ok = $false; Error = $_.Exception.Message } }
    } -ArgumentList $guestCabDir, $guestCab, $guestImportLog
    if (-not $prep -or -not $prep.ScriptBlockOutput -or -not $prep.ScriptBlockOutput.Ok) {
        $errMsg = if ($prep -and $prep.ScriptBlockOutput) { $prep.ScriptBlockOutput.Error } else { "no output" }
        throw "[Baseline] -Upload: failed to prepare guest staging dir: $errMsg"
    }

    $copyOk = Copy-ItemSafe -VmName $VmName -VMDomainName $DomainName -Path $CabPath -Destination $guestCabDir -Force
    if ($copyOk -eq $false) { throw "[Baseline] -Upload: Copy-ItemSafe failed pushing $CabPath to ${VmName}:$guestCabDir." }

    # Verify the guest-side MD5 to catch any transfer corruption before import.
    $verify = Invoke-VmCommand -VmName $VmName -VmDomainName $DomainName -DisplayName "Upload: verify cab MD5" -ScriptBlock {
        param($p)
        try {
            if (-not (Test-Path $p)) { return [PSCustomObject]@{ Ok = $false; Error = "cab not at $p after copy" } }
            $h = (Get-FileHash -LiteralPath $p -Algorithm MD5).Hash
            $f = Get-Item -LiteralPath $p
            [PSCustomObject]@{ Ok = $true; Md5 = $h; Bytes = $f.Length }
        }
        catch { [PSCustomObject]@{ Ok = $false; Error = $_.Exception.Message } }
    } -ArgumentList $guestCab
    if (-not $verify -or -not $verify.ScriptBlockOutput -or -not $verify.ScriptBlockOutput.Ok) {
        $errMsg = if ($verify -and $verify.ScriptBlockOutput) { $verify.ScriptBlockOutput.Error } else { "no output" }
        throw "[Baseline] -Upload: post-copy verify failed: $errMsg"
    }
    $v = $verify.ScriptBlockOutput
    if ($v.Md5 -ne $cabMd5) {
        throw "[Baseline] -Upload: guest MD5 ($($v.Md5)) != host MD5 ($cabMd5). Transfer corrupted."
    }
    Write-Log "[Baseline] Cab on guest verified: $($v.Bytes) bytes, MD5=$($v.Md5)."

    # Run wsusutil import. Same invocation the DSC resource uses.
    Write-Log "[Baseline] Running wsusutil import on $VmName (may take several minutes)..."
    $import = Invoke-VmCommand -VmName $VmName -VmDomainName $DomainName -TimeoutSeconds 1800 -DisplayName "Upload: wsusutil import" -ScriptBlock {
        param($cab, $log)
        try {
            $wsusUtil = Join-Path $env:ProgramFiles 'Update Services\Tools\WsusUtil.exe'
            if (-not (Test-Path $wsusUtil)) { return [PSCustomObject]@{ Ok = $false; ExitCode = -1; Error = "WsusUtil.exe not found at $wsusUtil" } }
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $proc = Start-Process -FilePath $wsusUtil -ArgumentList @('import', $cab, $log) -Wait -PassThru -NoNewWindow -ErrorAction Stop
            $sw.Stop()
            $tail = ''
            if (Test-Path $log) {
                $tailLines = Get-Content $log -Tail 10 -ErrorAction SilentlyContinue
                if ($tailLines) { $tail = ($tailLines -join "`n") }
            }
            [PSCustomObject]@{ Ok = ($proc.ExitCode -eq 0); ExitCode = $proc.ExitCode; ElapsedSec = [int]$sw.Elapsed.TotalSeconds; LogTail = $tail; LogPath = $log }
        }
        catch { [PSCustomObject]@{ Ok = $false; ExitCode = -1; Error = $_.Exception.Message } }
    } -ArgumentList $guestCab, $guestImportLog
    if (-not $import -or -not $import.ScriptBlockOutput) {
        throw "[Baseline] -Upload: wsusutil import returned no output."
    }
    $imp = $import.ScriptBlockOutput
    if (-not $imp.Ok) {
        $tail = if ($imp.LogTail) { "`n--- import log tail ---`n$($imp.LogTail)" } else { "" }
        $detail = if ($imp.Error) { $imp.Error } else { "exit=$($imp.ExitCode)" }
        throw "[Baseline] -Upload: wsusutil import failed ($detail).$tail"
    }
    Write-Log "[Baseline] wsusutil import OK (exit=0, $($imp.ElapsedSec)s)." -Success
    if ($imp.LogTail) {
        Write-Log "[Baseline] Import log tail:"
        foreach ($l in ($imp.LogTail -split "`r?`n")) { if ($l.Trim()) { Write-Log "    $l" } }
    }

    # Post-import snapshot.
    $postU = Invoke-VmCommand -VmName $VmName -VmDomainName $DomainName -DisplayName "Upload: post-import snapshot" -ScriptBlock {
        try {
            $wsus = Get-WsusServer -ErrorAction Stop
            $sub = $wsus.GetSubscription()
            $taxonomyCats = @($wsus.GetUpdateCategories()).Count
            $taxonomyClas = @($wsus.GetUpdateClassifications()).Count
            $subCats = @($sub.GetUpdateCategories()).Count
            $subClas = @($sub.GetUpdateClassifications()).Count
            [PSCustomObject]@{ Ok = $true; TaxonomyCats = $taxonomyCats; TaxonomyClas = $taxonomyClas; SubscribedCats = $subCats; SubscribedClas = $subClas }
        }
        catch { [PSCustomObject]@{ Ok = $false; Error = $_.Exception.Message } }
    }
    if (-not $postU -or -not $postU.ScriptBlockOutput -or -not $postU.ScriptBlockOutput.Ok) {
        $errMsg = if ($postU -and $postU.ScriptBlockOutput) { $postU.ScriptBlockOutput.Error } else { "no output" }
        throw "[Baseline] -Upload: post-import snapshot failed: $errMsg"
    }
    $post = $postU.ScriptBlockOutput
    $dCats = $post.TaxonomyCats - $pre.TaxonomyCats
    $dClas = $post.TaxonomyClas - $pre.TaxonomyClas

    Write-Log ""
    Write-Log "[Baseline] -Upload test complete." -Success
    Write-Log "  Cab:                  $CabPath ($cabSizeMB MB, MD5=$cabMd5)"
    Write-Log "  Pre-import  Taxonomy: Cats=$($pre.TaxonomyCats), Clas=$($pre.TaxonomyClas), SubscribedCats=$($pre.SubscribedCats)"
    Write-Log "  Post-import Taxonomy: Cats=$($post.TaxonomyCats), Clas=$($post.TaxonomyClas), SubscribedCats=$($post.SubscribedCats)"
    Write-Log "  Delta:                Cats=+$dCats, Clas=+$dClas, ImportTime=$($imp.ElapsedSec)s"
    if ($post.TaxonomyCats -le 0) {
        Write-Log "[Baseline] FAIL: post-import taxonomy is empty. The DSC resource would treat this as a failure and fall back to MU sync." -Failure
    }
    elseif ($post.SubscribedCats -le 0) {
        Write-Log "[Baseline] WARNING: TaxonomyCats=$($post.TaxonomyCats) but SubscribedCats=0. The DSC resource checks SubscribedCats and would treat this as 'no categories present' and fall back to MU sync. The cab populated the catalog but no entries are flagged as subscribed -- regenerate the cab or revisit the import-side gating." -Warning
    }
    else {
        Write-Log "[Baseline] PASS: cab is good. The WSUSSync DSC resource would accept this and skip MU categories sync." -Success
    }
    return
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

# Pull cab + log back to host via Copy-ItemFromVM (uses Get-VmSession which
# constructs DOMAIN\admin from $Common.LocalAdmin). A bare
# 'New-PSSession -VMName ... -Credential $Common.LocalAdmin' fails on
# domain-joined VMs because PSDirect authenticates against the guest's
# local SAM, and the local admin account is disabled after dcpromo/join.
$outCab = Join-Path $OutputDir "WsusCategoriesBaseline.cab"
$outLog = Join-Path $OutputDir "WsusCategoriesBaseline.export.log"
Write-Log "[Baseline] Copying cab to host: $outCab"

$copiedCab = Copy-ItemFromVM -VMName $VmName -VMDomainName $DomainName -Path $exportGuestPath -Destination $OutputDir
if (-not $copiedCab) { throw "[Baseline] Failed to copy cab from $VmName : $exportGuestPath" }
$copiedLog = Copy-ItemFromVM -VMName $VmName -VMDomainName $DomainName -Path $exportGuestLog -Destination $OutputDir
if (-not $copiedLog) { Write-Log "[Baseline] Warning: failed to copy export log from $VmName ($exportGuestLog). Continuing." -Warning }

# Compute the host MD5 (what _filelist.json gates downloads on) so we can
# print a ready-to-paste entry for the operator.
$hostMd5 = (Get-FileHash -Path $outCab -Algorithm MD5).Hash
$generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
$filelistEntry = [PSCustomObject]@{
    Name               = 'WSUS Categories Baseline'
    md5                = $hostMd5
    URL                = 'tools\wsus\WsusCategoriesBaseline.cab'
    IsPublic           = $false
    Optional           = $true
    Target             = 'tools\wsus'
    ExtractFolderIfZip = $false
    GeneratedUtc       = $generatedUtc
    SourceVm           = $VmName
    SourceOs           = $pre.OsVersion
    WsusVersion        = $pre.WsusServerVersion
    Sha256             = $exp.Sha256
    SizeBytes          = $exp.Bytes
    Categories         = $exp.Categories
    Classifications    = $exp.Classifications
}
$filelistJson = $filelistEntry | ConvertTo-Json -Depth 4

Write-Log ""
Write-Log "[Baseline] Done." -Success
Write-Log "  Cab:      $outCab ($sizeMB MB)"
Write-Log "  Log:      $outLog"
Write-Log "  MD5:      $hostMd5"
Write-Log ""
Write-Log "[Baseline] Next steps:"
Write-Log "  1. (Recommended) Test the cab end-to-end against a fresh WSUS VM:"
Write-Log "       .\New-WsusCategoriesBaseline.ps1 -VmName <fresh-wsus-vm> -DomainName <domain> -Upload"
Write-Log "     (or combine -Reset -Upload to wipe + retest on the same VM)."
Write-Log "  2. Add the cab to vmbuild\azureFiles\_filelist.json under 'Tools' (ready-to-paste entry below)."
Write-Log "  3. Upload it to the storage account at tools\wsus\WsusCategoriesBaseline.cab."
Write-Log "  4. Future deploys with cmOptions.WsusImportBaseline=`$true (default) pick it up automatically."
Write-Log ""
Write-Log "[Baseline] _filelist.json entry:"
foreach ($line in $filelistJson -split "`r?`n") { Write-Log "    $line" }
