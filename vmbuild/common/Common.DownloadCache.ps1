# Common.DownloadCache.ps1
#
# Host-side download cache for the small "Tier-1" installers that DSC downloads
# per-VM (SSMS, .NET 4.8, ODBC, OleDB, SQLClient, VCredist[x86], ReportBuilder,
# PatchMyPC). Instead of every VM downloading these over its slow internal NAT
# (and PSDirect being slow for large files), we download each once on the host,
# bake them into a READ-ONLY Hyper-V virtual DVD, and mount that DVD to the VMs.
# The guest's Invoke-DownloadFile checks the DVD first and copies the file off it;
# on any miss it falls through to the normal download chain. Pure optimization.
#
# Concurrency model: ISOs are CONTENT-ADDRESSED and IMMUTABLE. The ISO file name
# encodes a hash of its contents (cache-<hash>.iso), so a mounted ISO is never
# rewritten. The cache always bakes the FULL Tier-1 toolset (independent of
# StartPhase and the deployment's role mix), so every deployment normally
# resolves the SAME content set and shares a SINGLE canonical ISO; only a
# transient download difference (a tool's URL temporarily unreachable) would ever
# produce a second one. Mount/eject is scoped to the deploying domain's own VMs;
# eviction never deletes an ISO that any VM on the host still has mounted.
#
# EXCLUDED by design: ADK/ADKPE (~1GB) and ConfigMgr media (newest CM is ISO-based;
# downloaded CM versions are legacy). Those keep their existing delivery paths.
#
# PS5.1-safe (this file is dot-sourced by Common.ps1, which is loaded under both
# Windows PowerShell 5.1 and PowerShell 7). All ISO/Hyper-V work only runs on the
# PS7 host.

$script:MemlabsCacheTier1Keys = @('DotNet', 'SSMS', 'ODBC', 'OleDB', 'SQLClient', 'VCredist', 'VCredistX86', 'ReportBuilder', 'PMPC')
$script:MemlabsCacheVolumeLabel = 'MEMLABSCACHE'

function Test-MemlabsDownloadCacheEnabled {
    # Kill switch.
    if ($env:MEMLABS_NO_DOWNLOAD_CACHE) { return $false }
    return $true
}

function Get-MemlabsCacheRoot {
    # The download store (azureFiles\cache). Created on demand. This is the
    # accumulating set of downloaded installers; the cache ISO is built from it.
    if ($env:MEMLABS_DOWNLOAD_CACHE) {
        $root = $env:MEMLABS_DOWNLOAD_CACHE
    }
    else {
        $root = Join-Path (Split-Path $PSScriptRoot -Parent) 'azureFiles\cache'
    }
    if (-not (Test-Path $root)) {
        New-Item -Path $root -ItemType Directory -Force | Out-Null
    }
    return $root
}

function Get-MemlabsCacheIsoDir {
    # Where cache-*.iso live (azureFiles, the parent of the store) so building an
    # ISO via AddTree over the store never tries to include the ISO itself.
    return (Split-Path (Get-MemlabsCacheRoot) -Parent)
}

function Get-MemlabsCacheLeaf {
    # Internal file name (in the store and on the ISO) for a cacheable key. The
    # extension is taken from the URL leaf when it has one (so the file is at least
    # human-recognizable); the guest never relies on this name -- it reads the file
    # name out of the manifest.
    param($Key, $Url)
    $ext = ''
    try {
        $leaf = Split-Path ([uri]$Url).AbsolutePath -Leaf
        if ($leaf -and $leaf.Contains('.')) { $ext = [System.IO.Path]::GetExtension($leaf) }
    }
    catch { $ext = '' }
    if (-not $ext) { $ext = '.dat' }
    return "$Key$ext"
}

function Get-MemlabsCacheUrlForKey {
    # Resolve a cacheable key to its URL from the resolved file list.
    param($Key)
    if (-not $Common.AzureFileList -or -not $Common.AzureFileList.Urls) { return $null }
    foreach ($u in $Common.AzureFileList.Urls) {
        $p = $u.psobject.properties[$Key]
        if ($p -and $p.Value) { return [string]$p.Value }
    }
    return $null
}

function Get-MemlabsRemoteFileSignature {
    # Best-effort HEAD probe (following redirects) returning the server's change
    # signals -- Content-Length, Last-Modified, ETag. Returns $null on any failure
    # so callers treat "can't probe" as "no change" and keep the cached copy.
    # The filelist carries no per-URL hashes, so this is how we detect that a
    # rolling "latest" redirect (aka.ms/...) changed underneath a stable URL.
    param([string] $Url)
    try {
        $resp = Invoke-WebRequest -Uri $Url -Method Head -MaximumRedirection 5 -TimeoutSec 15 -UseBasicParsing -ErrorAction Stop
        $h = $resp.Headers
        $val = {
            param($name)
            if ($h -and $h.ContainsKey($name)) {
                $v = $h[$name]
                if ($v -is [System.Array]) { return [string]($v | Select-Object -First 1) }
                return [string]$v
            }
            return ''
        }
        return [PSCustomObject]@{
            Size         = (& $val 'Content-Length')
            LastModified = (& $val 'Last-Modified')
            ETag         = (& $val 'ETag')
        }
    }
    catch { return $null }
}

function Get-MemlabsCacheNeededKeys {
    # The set of Tier-1 cacheable keys to bake into the cache ISO. By DESIGN this
    # is the COMPLETE Tier-1 toolset and is INDEPENDENT of StartPhase and of the
    # deployment's role mix: every deployment -- whether it starts at Phase 2 or
    # Phase 5, with or without SQL/site-server/PMPC roles -- asks for the SAME
    # content set, so they all share a SINGLE content-addressed cache-<hash>.iso
    # instead of accumulating per-phase / per-role subset ISOs.
    #
    # Always asking for the full set is safe: a key whose URL isn't in the
    # resolved filelist, or whose download fails, is simply skipped by the
    # populate loop in Get-MemlabsCacheIsoForDeploy, and the content hash reflects
    # whatever actually landed on the ISO. The extra installers are all small
    # Tier-1 items (ADK/ADKPE and CM media are excluded), so baking them all costs
    # little disk and a one-time download.
    #
    # $DeployConfig / $StartPhase are accepted for call-site compatibility but are
    # intentionally not used to narrow the set (that's what produced multiple
    # ISOs); the only thing that scopes inclusion is whether a tool is downloadable.
    param($DeployConfig, [int]$StartPhase = 1)
    return @($script:MemlabsCacheTier1Keys)
}

function Get-MemlabsCacheIsoForDeploy {
    # Populate the store with this deployment's needed installers and return the
    # path to a content-addressed ISO containing them (building it if necessary).
    # Returns $null when the cache is disabled, nothing is needed, or anything
    # fails -- callers must treat $null as "no cache, deploy normally".
    param($DeployConfig, [int]$StartPhase = 1)

    if (-not (Test-MemlabsDownloadCacheEnabled)) { return $null }

    try {
        $keys = Get-MemlabsCacheNeededKeys -DeployConfig $DeployConfig -StartPhase $StartPhase
        if (-not $keys -or $keys.Count -eq 0) { return $null }

        $store = Get-MemlabsCacheRoot
        $entries = @()

        foreach ($key in $keys) {
            $url = Get-MemlabsCacheUrlForKey -Key $key
            if (-not $url) { continue }
            $leaf = Get-MemlabsCacheLeaf -Key $key -Url $url
            $path = Join-Path $store $leaf
            $sidecarPath = "$path.src"

            # No time-based expiry: the store keeps files indefinitely. We
            # re-download ONLY when the source actually changed, detected by
            # comparing the configured URL plus the server's HEAD signature
            # (Content-Length / Last-Modified / ETag) against what we recorded
            # in the per-file sidecar when we last fetched it. This catches a
            # filelist URL bump (pinned keys) AND a rolling 'latest' redirect
            # changing underneath a stable URL (SSMS, VCredist, PMPC, ...).
            $force = $false
            $remoteSig = $null
            $preExisting = Test-Path $path
            if (-not $preExisting) {
                $force = $true
            }
            else {
                $prev = $null
                if (Test-Path $sidecarPath) {
                    try { $prev = Get-Content -Path $sidecarPath -Raw -ErrorAction Stop | ConvertFrom-Json } catch { $prev = $null }
                }
                if (-not $prev -or [string]$prev.url -ne $url) {
                    $force = $true
                }
                else {
                    $remoteSig = Get-MemlabsRemoteFileSignature -Url $url
                    if ($remoteSig) {
                        if ($remoteSig.Size -and ([string]$prev.size -ne [string]$remoteSig.Size)) { $force = $true }
                        if ($remoteSig.LastModified -and ([string]$prev.lastModified -ne [string]$remoteSig.LastModified)) { $force = $true }
                        if ($remoteSig.ETag -and ([string]$prev.etag -ne [string]$remoteSig.ETag)) { $force = $true }
                    }
                    # HEAD unavailable (server doesn't answer / no headers) => keep the cached copy.
                }
            }

            # (Re)download with completeness verification. A FORCED re-download
            # goes to a temp file first so a failed/partial fetch (URL down /
            # offline / truncated) never clobbers the good cached copy -- we only
            # swap it in once it's verified complete. Completeness = the bytes on
            # disk match the server's Content-Length (from HEAD) when that's
            # known; if the server doesn't report a size we fall back to a
            # non-empty check. A pre-populated host with all files current does
            # no network at all (handled by the not-forced skip-if-exists path).
            $freshDownload = $false
            if ($force) {
                if (-not $remoteSig) { $remoteSig = Get-MemlabsRemoteFileSignature -Url $url }
                [int64]$expectedSize = 0
                if ($remoteSig -and $remoteSig.Size) { [void][int64]::TryParse([string]$remoteSig.Size, [ref]$expectedSize) }

                if ($preExisting) {
                    $tmp = "$path.download"
                    if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
                    $ok = Get-File -Source $url -Destination $tmp -Action Downloading -Silent -ForceDownload
                    $tmpLen = 0; if (Test-Path $tmp) { $tmpLen = (Get-Item $tmp).Length }
                    $complete = $ok -and ($tmpLen -gt 0) -and (($expectedSize -le 0) -or ($tmpLen -eq $expectedSize))
                    if ($complete) {
                        Move-Item -Path $tmp -Destination $path -Force
                        $freshDownload = $true
                    }
                    else {
                        if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
                        if ($expectedSize -gt 0 -and $tmpLen -gt 0 -and $tmpLen -ne $expectedSize) {
                            Write-Log "DownloadCache: '$key' re-download incomplete ($tmpLen of $expectedSize bytes); keeping previously-cached copy." -LogOnly
                        }
                        else {
                            Write-Log "DownloadCache: '$key' re-download failed (URL down?); keeping previously-cached copy." -LogOnly
                        }
                    }
                }
                else {
                    $ok = Get-File -Source $url -Destination $path -Action Downloading -Silent -ForceDownload
                    $dlLen = 0; if (Test-Path $path) { $dlLen = (Get-Item $path).Length }
                    $complete = $ok -and ($dlLen -gt 0) -and (($expectedSize -le 0) -or ($dlLen -eq $expectedSize))
                    if ($complete) {
                        $freshDownload = $true
                    }
                    else {
                        # Truncated/bad download and nothing to fall back to: drop it
                        # so a half file never lands on the ISO (the guest downloads
                        # directly), and leave no sidecar so the next run retries.
                        if ($expectedSize -gt 0 -and $dlLen -gt 0 -and $dlLen -ne $expectedSize) {
                            Write-Log "DownloadCache: '$key' download incomplete ($dlLen of $expectedSize bytes); discarding." -LogOnly
                        }
                        if (Test-Path $path) { Remove-Item $path -Force -ErrorAction SilentlyContinue }
                    }
                }
            }
            else {
                # Not forced: the cached copy is current (or HEAD was unreachable,
                # so we keep it). Get-File is skip-if-exists, so this is a no-op
                # network-wise when the file is already present.
                $ok = Get-File -Source $url -Destination $path -Action Downloading -Silent
                if ($ok -and -not $preExisting -and (Test-Path $path)) { $freshDownload = $true }
            }

            if (-not (Test-Path $path)) {
                Write-Log "DownloadCache: skipping '$key' (no cached copy and download failed); guests will fetch it directly." -LogOnly
                continue
            }
            $fi = Get-Item $path
            if ($fi.Length -le 0) { continue }

            # Record the source signature only on a real fresh download so the
            # next run can detect a change (and so an offline fallback keeps the
            # sidecar matching the copy we actually still have on disk).
            if ($freshDownload) {
                if (-not $remoteSig) { $remoteSig = Get-MemlabsRemoteFileSignature -Url $url }
                $sidecar = [ordered]@{
                    url           = $url
                    size          = if ($remoteSig) { [string]$remoteSig.Size } else { '' }
                    lastModified  = if ($remoteSig) { [string]$remoteSig.LastModified } else { '' }
                    etag          = if ($remoteSig) { [string]$remoteSig.ETag } else { '' }
                    downloadedUtc = (Get-Date).ToUniversalTime().ToString('o')
                }
                try { ($sidecar | ConvertTo-Json) | Out-File -FilePath $sidecarPath -Encoding utf8 -Force } catch {}
            }

            $entries += [ordered]@{ Key = $key; Url = $url; File = $leaf; Size = $fi.Length; Ticks = $fi.LastWriteTimeUtc.Ticks; Path = $path; Sha1 = $null }
        }

        if ($entries.Count -eq 0) { return $null }

        $isoDir = Get-MemlabsCacheIsoDir

        # FAST PATH (warm cache): a "light signature" over key+size+mtime (no file
        # hashing) maps to a pointer file recording the already-built ISO. This is
        # what every per-VM call hits once the cache is warm, so we never re-hash
        # large installers (e.g. SSMS) on every VM. Only the first build hashes.
        $lightSig = (($entries | Sort-Object { $_.Url } | ForEach-Object { "$($_.Url)|$($_.Size)|$($_.Ticks)" }) -join "`n")
        $lightHash = Get-MemlabsCacheStringHash -Text $lightSig
        $ptrPath = Join-Path $store ".ptr-$lightHash.txt"
        if (Test-Path $ptrPath) {
            $ptIso = (Get-Content -Path $ptrPath -First 1 -ErrorAction SilentlyContinue)
            if ($ptIso) { $ptIso = $ptIso.Trim() }
            if ($ptIso -and (Test-Path $ptIso)) { return $ptIso }
        }

        # SLOW PATH: hash each file (for the manifest + the immutable, content-
        # addressed ISO name), then build the ISO if it doesn't already exist.
        foreach ($e in $entries) {
            $e.Sha1 = (Get-FileHash -Algorithm SHA1 -Path $e.Path).Hash.ToLowerInvariant()
        }
        $sig = (($entries | Sort-Object { $_.Url } | ForEach-Object { "$($_.Url)|$($_.Sha1)|$($_.Size)" }) -join "`n")
        $hash = (Get-MemlabsCacheStringHash -Text $sig).Substring(0, 12)
        $isoPath = Join-Path $isoDir "cache-$hash.iso"

        if (-not (Test-Path $isoPath)) {
            # Serialize the build (IMAPI COM is not thread-safe; same mutex the
            # Linux seed-ISO builder uses). The mutex is reentrant on this thread,
            # so the nested acquisition inside New-NoCloudSeedIsoWithImapi is fine.
            $mutex = [System.Threading.Mutex]::new($false, 'Global\MemlabsImapi2fsLock')
            $null = $mutex.WaitOne()
            try {
                if (-not (Test-Path $isoPath)) {
                    $stage = Join-Path $isoDir "cache-build-$hash-$PID"
                    if (Test-Path $stage) { Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue }
                    New-Item -Path $stage -ItemType Directory -Force | Out-Null

                    $manifest = [ordered]@{
                        version = 1
                        created = (Get-Date).ToUniversalTime().ToString('o')
                        files   = [ordered]@{}
                    }
                    foreach ($e in $entries) {
                        Copy-Item -Path $e.Path -Destination (Join-Path $stage $e.File) -Force
                        $manifest.files[$e.Url] = [ordered]@{ file = $e.File; size = $e.Size; sha1 = $e.Sha1 }
                    }
                    ($manifest | ConvertTo-Json -Depth 6) | Out-File (Join-Path $stage 'manifest.json') -Encoding utf8 -Force

                    $tmpIso = "$isoPath.$PID.tmp"
                    if (Test-Path $tmpIso) { Remove-Item $tmpIso -Force -ErrorAction SilentlyContinue }
                    New-NoCloudSeedIsoWithImapi -SourceDir $stage -OutputIsoPath $tmpIso -VolumeLabel $script:MemlabsCacheVolumeLabel
                    if (-not (Test-Path $tmpIso)) { throw "ISO build produced no output for $isoPath" }

                    if (-not (Test-Path $isoPath)) {
                        Move-Item -Path $tmpIso -Destination $isoPath -Force
                    }
                    else {
                        Remove-Item $tmpIso -Force -ErrorAction SilentlyContinue
                    }
                    Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
                    Write-Log "DownloadCache: built $([System.IO.Path]::GetFileName($isoPath)) with $($entries.Count) file(s) [$([string]::Join(', ', $keys))]." -LogOnly
                }
            }
            finally {
                $mutex.ReleaseMutex()
                $mutex.Dispose()
            }
        }

        # Record the warm-cache pointer so future per-VM calls skip the hashing.
        try { Set-Content -Path $ptrPath -Value $isoPath -Force -ErrorAction SilentlyContinue } catch {}
        return $isoPath
    }
    catch {
        Write-Log "DownloadCache: Get-MemlabsCacheIsoForDeploy failed: $($_.Exception.Message). Continuing without cache." -Warning
        return $null
    }
}

function Get-MemlabsCacheStringHash {
    # Lowercase hex SHA1 of a UTF-8 string (used for both the light-signature
    # pointer and the content-addressed ISO name).
    param([string] $Text)
    $sha1 = [System.Security.Cryptography.SHA1]::Create()
    try {
        return [System.BitConverter]::ToString($sha1.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text))).Replace('-', '').ToLowerInvariant()
    }
    finally { $sha1.Dispose() }
}

function Mount-MemlabsCacheIsoToVm {
    # Mount the cache ISO read-only on a VM's DVD drive (Gen2 SCSI = hot-add OK).
    # Idempotent: a no-op if this ISO is already mounted.
    #
    # IMPORTANT -- single-DVD invariant: the create-time CM/OS media copy
    # (Common.ScriptBlocks.ps1) and the Phase 4 SQL ISO mount (Mount-SqlIsoForPhase)
    # both drive the VM's DVD with Set-VMDvdDrive WITHOUT a controller selector,
    # which is only unambiguous when the VM has exactly ONE DVD drive. So the cache
    # must never create a SECOND drive. It mounts only to an existing EMPTY drive,
    # or -- only when the VM has no DVD drive at all (0 -> 1 is unambiguous) -- adds
    # one. If the single drive is busy (CM/SQL/OS ISO present), the cache YIELDS
    # this pass and re-mounts on a later phase once the drive is free. The cache is
    # opportunistic, so being transiently evicted by a CM/SQL mount/eject is fine
    # (the guest just falls back to a direct download until the cache is back).
    param([string]$VmName, [string]$IsoPath)
    if (-not $IsoPath -or -not (Test-Path $IsoPath)) { return $false }
    try {
        $dvds = @(Get-VMDvdDrive -VMName $VmName -ErrorAction Stop)
        foreach ($d in $dvds) {
            if ($d.Path -and $d.Path -eq $IsoPath) { return $true }
        }
        $empty = $dvds | Where-Object { -not $_.Path } | Select-Object -First 1
        if ($empty) {
            Set-VMDvdDrive -VMName $VmName -ControllerNumber $empty.ControllerNumber -ControllerLocation $empty.ControllerLocation -Path $IsoPath -ErrorAction Stop
            return $true
        }
        if ($dvds.Count -eq 0) {
            Add-VMDvdDrive -VMName $VmName -Path $IsoPath -ErrorAction Stop
            return $true
        }
        # The only DVD drive is occupied by a CM/SQL/OS ISO. Do NOT add a 2nd drive
        # (it would break the no-controller Set-VMDvdDrive calls above); defer.
        Write-Log "DownloadCache: $VmName DVD drive busy; deferring cache mount to a later phase." -LogOnly
        return $false
    }
    catch {
        Write-Log "DownloadCache: failed to mount cache ISO to $VmName : $($_.Exception.Message)" -LogOnly
        return $false
    }
}

function Dismount-MemlabsCacheIsoFromVm {
    # Eject only OUR cache-*.iso from this VM (leaves any OS/other DVD untouched).
    param([string]$VmName)
    try {
        foreach ($d in @(Get-VMDvdDrive -VMName $VmName -ErrorAction SilentlyContinue)) {
            if ($d.Path -and ([System.IO.Path]::GetFileName($d.Path)) -like 'cache-*.iso') {
                Set-VMDvdDrive -VMName $VmName -ControllerNumber $d.ControllerNumber -ControllerLocation $d.ControllerLocation -Path $null -ErrorAction SilentlyContinue
            }
        }
    }
    catch {}
}

function Remove-StaleMemlabsCacheIso {
    # Evict old cache ISOs. Host-wide safe: never deletes an ISO any VM still has
    # mounted, never deletes the newest, and never deletes one younger than a day.
    param([string]$KeepIsoPath)
    try {
        $all = @(Get-ChildItem -Path (Get-MemlabsCacheIsoDir) -Filter 'cache-*.iso' -File -ErrorAction SilentlyContinue)
        if ($all.Count -le 1) { return }

        $mounted = @{}
        foreach ($d in (Get-VM | Get-VMDvdDrive -ErrorAction SilentlyContinue)) {
            if ($d.Path) { $mounted[$d.Path.ToLowerInvariant()] = $true }
        }

        $newest = $all | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        foreach ($iso in $all) {
            if ($KeepIsoPath -and $iso.FullName -eq $KeepIsoPath) { continue }
            if ($iso.FullName -eq $newest.FullName) { continue }
            if ($mounted.ContainsKey($iso.FullName.ToLowerInvariant())) { continue }
            if ((New-TimeSpan -Start $iso.LastWriteTime -End (Get-Date)).TotalDays -lt 1) { continue }
            Remove-Item $iso.FullName -Force -ErrorAction SilentlyContinue
            Write-Log "DownloadCache: evicted stale cache ISO $($iso.Name)." -LogOnly
        }
    }
    catch {}
}
