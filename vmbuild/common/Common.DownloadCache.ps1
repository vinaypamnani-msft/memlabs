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
$script:MemlabsDscVolumeLabel = 'MEMLABSDSC'

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
        $resolvableKeys = @()

        # Sweep orphaned per-PID staging dirs (cache-build-<hash>-<PID>) left by a
        # prior crashed/killed/failed build. The build's own try/finally cleans the
        # CURRENT process's dir, but a dir whose owning PID is already dead has no
        # one to clean it -- so we remove any cache-build-* dir whose trailing PID
        # is not a live process. Live builds (their PID still running) are skipped,
        # so a concurrent builder is never disturbed. Runs on every call, including
        # the pre-phase pre-build in New-Lab, so leftovers self-clean next deploy.
        try {
            foreach ($bd in (Get-ChildItem -Path (Get-MemlabsCacheIsoDir) -Directory -Filter 'cache-build-*' -ErrorAction SilentlyContinue)) {
                $bpid = ($bd.Name -split '-')[-1]
                $alive = $false
                if ($bpid -as [int]) {
                    if (Get-Process -Id ([int]$bpid) -ErrorAction SilentlyContinue) { $alive = $true }
                }
                if (-not $alive) { Remove-Item $bd.FullName -Recurse -Force -ErrorAction SilentlyContinue }
            }
        }
        catch { }

        foreach ($key in $keys) {
            $url = Get-MemlabsCacheUrlForKey -Key $key
            if (-not $url) { continue }
            $resolvableKeys += $key
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

        # COMPLETENESS GATE: only ever build an ISO from the FULL resolvable tool
        # set. The ISO is content-addressed over the files actually included, so
        # baking a partial set (e.g. one tool's download transiently failed this
        # pass while the rest succeeded) mints a DIFFERENT-hash ISO than the full
        # set -- which is exactly how a second ISO appears once the missing tool
        # later lands in the store. If anything expected is still missing, DON'T
        # build a partial ISO: return no-cache for this pass (guests direct-
        # download) and let a later pass -- with the store fully populated --
        # build the single canonical full-set ISO. This self-heals within one
        # deploy: the up-front pre-build downloads the whole set synchronously,
        # and each per-VM call re-attempts any missing download, so the first
        # call that sees a complete store builds the one canonical ISO.
        $haveKeys = @($entries | ForEach-Object { $_.Key })
        $missingKeys = @($resolvableKeys | Where-Object { $haveKeys -notcontains $_ })
        if ($missingKeys.Count -gt 0) {
            Write-Log "DownloadCache: tool set incomplete ($($haveKeys.Count)/$($resolvableKeys.Count) present; missing: $($missingKeys -join ', ')). Deferring ISO build until the full set is in the store (avoids minting a partial-set ISO)." -LogOnly
            return $null
        }

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
                    $tmpIso = "$isoPath.$PID.tmp"
                    try {
                        if (Test-Path $stage) { Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue }
                        New-Item -Path $stage -ItemType Directory -Force | Out-Null

                        $manifest = [ordered]@{
                            version = 1
                            created = (Get-Date).ToUniversalTime().ToString('o')
                            files   = [ordered]@{}
                        }
                        foreach ($e in $entries) {
                            $dst = Join-Path $stage $e.File
                            if (Test-Path $dst) { Remove-Item $dst -Force -ErrorAction SilentlyContinue }
                            # HARDLINK the tool into the stage instead of copying it. A hardlink is a
                            # second NTFS directory entry to the SAME file data (zero extra bytes, and
                            # instant -- no 700MB copy), and IMAPI's AddTree reads the content through
                            # it exactly like a normal file (a hardlink is NOT a reparse point). The
                            # store and the stage are both under azureFiles (same volume), which
                            # hardlinks require, and no admin is needed (unlike symlinks). Deleting the
                            # stage in the finally only drops this extra entry; the store's own entry
                            # keeps the bytes alive. Falls back to a real copy if the link can't be made
                            # (different volume / non-NTFS / unsupported) so the ISO always gets built.
                            $linked = $false
                            try {
                                New-Item -ItemType HardLink -Path $dst -Target $e.Path -ErrorAction Stop | Out-Null
                                $linked = (Test-Path $dst)
                            }
                            catch { $linked = $false }
                            if (-not $linked) { Copy-Item -Path $e.Path -Destination $dst -Force }
                            $manifest.files[$e.Url] = [ordered]@{ file = $e.File; size = $e.Size; sha1 = $e.Sha1 }
                        }
                        ($manifest | ConvertTo-Json -Depth 6) | Out-File (Join-Path $stage 'manifest.json') -Encoding utf8 -Force

                        if (Test-Path $tmpIso) { Remove-Item $tmpIso -Force -ErrorAction SilentlyContinue }
                        New-NoCloudSeedIsoWithImapi -SourceDir $stage -OutputIsoPath $tmpIso -VolumeLabel $script:MemlabsCacheVolumeLabel
                        if (-not (Test-Path $tmpIso)) { throw "ISO build produced no output for $isoPath" }

                        if (-not (Test-Path $isoPath)) {
                            Move-Item -Path $tmpIso -Destination $isoPath -Force
                        }
                        Write-Log "DownloadCache: built $([System.IO.Path]::GetFileName($isoPath)) with $($entries.Count) file(s) [$([string]::Join(', ', $keys))]." -LogOnly
                    }
                    finally {
                        # Always clean the per-PID staging dir + temp ISO, even if the
                        # IMAPI build threw, so failed/contended attempts never leak
                        # cache-build-* folders (or *.tmp) next to the store.
                        if (Test-Path $stage) { Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue }
                        if (Test-Path $tmpIso) { Remove-Item $tmpIso -Force -ErrorAction SilentlyContinue }
                    }
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

function Mount-IsoOnVm {
    # Idempotent, per-drive, multi-drive-safe ISO mount. Manages ONLY the DVD drive
    # that holds (or will hold) THIS exact ISO and never touches another disc:
    #   1. This ISO already attached to some drive  -> verified, no-op (return $true).
    #   2. An EMPTY DVD drive exists                 -> mount there (controller-specific).
    #   3. No empty drive (all busy with other ISOs) -> Add a NEW DVD drive for it.
    # Because every mount targets a specific controller/location and every eject is
    # keyed by ISO path (Dismount-IsoFromVm), multiple ISOs can be mounted on the
    # same VM at once (e.g. cache + SQL + CM). Returns $true only after verifying the
    # ISO is actually attached; never throws.
    #
    # Gen2 (SCSI) supports hot-add of a new DVD drive while running. Gen1 (IDE)
    # cannot hot-add while running -- Add-VMDvdDrive then throws, is caught, and the
    # function returns $false (opportunistic callers like the cache simply yield).
    #
    # -RepresentIfAttached: when the ISO is ALREADY attached, eject+remount it so the
    # guest raises a fresh media-arrival event. A disc left inserted across a guest
    # reboot (e.g. a -startPhase retry) is not re-announced by Hyper-V on boot, so the
    # guest never surfaces the optical volume; re-presenting fixes that. Off by default
    # (case 1 stays a cheap no-op) so opportunistic callers pay nothing.
    param(
        [Parameter(Mandatory)][string]$VmName,
        [Parameter(Mandatory)][string]$IsoPath,
        [string]$Context = "ISO",
        [int]$Phase = 0,
        [switch]$RepresentIfAttached
    )
    if (-not $IsoPath -or -not (Test-Path $IsoPath)) {
        Write-Log "$($VmName): $Context ISO mount skipped -- path missing: $IsoPath" -LogOnly
        return $false
    }
    $tag = ""
    if ($Phase -gt 0) { $tag = "[Phase $Phase]: " }
    # Re-present an already-attached disc so the guest gets a fresh media-arrival
    # event (see -RepresentIfAttached). Eject here; the loop below re-adds it.
    if ($RepresentIfAttached) {
        try {
            $existing = @(Get-VMDvdDrive -VMName $VmName -ErrorAction SilentlyContinue) | Where-Object { $_.Path -eq $IsoPath }
            if ($existing) {
                foreach ($d in $existing) {
                    Set-VMDvdDrive -VMName $VmName -ControllerNumber $d.ControllerNumber -ControllerLocation $d.ControllerLocation -Path $null -ErrorAction SilentlyContinue
                }
                Write-Log "$tag$($VmName): re-presenting $Context ISO (eject+remount) for a fresh guest media-arrival event" -LogOnly
                Start-Sleep -Seconds 3
            }
        }
        catch { }
    }
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            $dvds = @(Get-VMDvdDrive -VMName $VmName -ErrorAction Stop)
            # 1. Already mounted with this exact ISO (idempotent).
            if ($dvds | Where-Object { $_.Path -eq $IsoPath }) { return $true }
            # 2. Reuse an empty drive.
            $empty = $dvds | Where-Object { -not $_.Path } | Select-Object -First 1
            if ($empty) {
                Set-VMDvdDrive -VMName $VmName -ControllerNumber $empty.ControllerNumber -ControllerLocation $empty.ControllerLocation -Path $IsoPath -ErrorAction Stop
            }
            else {
                # 3. All existing drives are busy with OTHER ISOs -> add a new one.
                Add-VMDvdDrive -VMName $VmName -Path $IsoPath -ErrorAction Stop
            }
            # Verify the mount landed.
            $dvds = @(Get-VMDvdDrive -VMName $VmName -ErrorAction Stop)
            if ($dvds | Where-Object { $_.Path -eq $IsoPath }) {
                Write-Log "$tag$($VmName): Mounted $Context ISO $IsoPath" -LogOnly
                # A disc was just (re)attached at the hypervisor. Any host-side
                # PSDirect session for this VM that was created BEFORE this change
                # holds a STALE optical / DOS-device view: a process can't refresh
                # its own device map, so the cached session keeps enumerating the
                # pre-mount disc set and never sees the disc we just added -- the
                # exact cached-vs-fresh split behind the CM media "cmMedia=False" and
                # SQL ISO letterless misses. Evict the cached session so the NEXT
                # Invoke-VmCommand builds a fresh, validated session that enumerates
                # the current media. Cheap (~1-2s rebuild), never throws.
                Invoke-VmSessionRefreshAfterMediaChange -VmName $VmName
                return $true
            }
        }
        catch {
            Write-Log "$tag$($VmName): $Context ISO mount attempt $attempt failed: $($_.Exception.Message)" -LogOnly
        }
        if ($attempt -lt 3) { Start-Sleep -Seconds ([Math]::Min(20, 5 * $attempt)) }
    }
    Write-Log "$tag$($VmName): Failed to mount $Context ISO $IsoPath after 3 attempts" -LogOnly
    return $false
}

# Evict a VM's cached host-side PSDirect session(s) after the host has changed
# the VM's optical/DVD layout (mount / eject / reset). Centralizes the fix for
# the whole "an existing session can't see the new drive/letter" class: rather
# than each call site remembering to refresh, every ISO primitive that mutates
# the DVD set calls this, so no host code path ever reads a stale optical view.
# The next Get-VmSession then rebuilds a fresh session that enumerates the
# current media. No-op + never throws if the eviction helper isn't loaded (e.g.
# a primitive used from a standalone script/unit test).
function Invoke-VmSessionRefreshAfterMediaChange {
    param([Parameter(Mandatory)][string]$VmName)
    try {
        if (Get-Command -Name Remove-VmSessionFromCache -ErrorAction SilentlyContinue) {
            Remove-VmSessionFromCache -VmName $VmName
        }
    }
    catch { }
}

function Confirm-IsoVisibleInGuest {
    # Host-side POSTCONDITION for a mount: confirm the GUEST actually enumerates the
    # disc we just attached, probing on a FRESH PSDirect session each attempt so a
    # stale optical view never sticks (Mount-IsoOnVm already evicted the cached
    # session; we re-evict per attempt for safety). The disc is identified by a
    # content marker at its root ($MarkerRelativePath, e.g. 'setup.exe' for SQL,
    # 'SMSSETUP\BIN\X64\Setup.exe' for CM) rather than by drive-type classification,
    # which is unreliable while a disc is busy / letterless. Any letterless optical
    # is given a temporary letter so the content probe can see it. Returns $true as
    # soon as the guest sees it, $false after the timeout. Never throws.
    #
    # This front-loads visibility to the host -- where we hold the fresh-session
    # lever -- instead of relying solely on the in-guest DSC resource to re-find the
    # media, generalizing the CM media probe as a reusable postcondition.
    param(
        [Parameter(Mandatory)][string]$VmName,
        [Parameter(Mandatory)][string]$VmDomainName,
        [Parameter(Mandatory)][string]$MarkerRelativePath,
        [string]$Context = 'ISO',
        [int]$TimeoutSeconds = 120,
        [int]$Phase = 0
    )
    $tag = ""
    if ($Phase -gt 0) { $tag = "[Phase $Phase]: " }

    $probe = {
        param($marker)
        # Give any letterless optical volume a letter so the content probe sees it.
        try {
            $letterless = @(Get-CimInstance -ClassName Win32_Volume -Filter 'DriveType = 5' -ErrorAction SilentlyContinue | Where-Object { -not $_.DriveLetter })
            if ($letterless.Count -gt 0) {
                $free = @()
                foreach ($n in 70..90) { $l = [char]$n; if (-not (Test-Path "${l}:\")) { $free += $l } }
                $i = 0
                foreach ($vol in $letterless) {
                    if ($i -ge $free.Count) { break }
                    Set-CimInstance -InputObject $vol -Property @{ DriveLetter = "$($free[$i]):" } -ErrorAction SilentlyContinue
                    $i++
                }
            }
        }
        catch { }
        foreach ($n in 67..90) { $dl = [char]$n; if (Test-Path ("${dl}:\$marker")) { return "${dl}:" } }
        # Nudge a device rescan and re-scan once more before giving up this attempt.
        try { & pnputil.exe /scan-devices *>$null } catch { }
        try { "rescan" | & diskpart.exe *>$null } catch { }
        foreach ($n in 67..90) { $dl = [char]$n; if (Test-Path ("${dl}:\$marker")) { return "${dl}:" } }
        return $null
    }

    $deadline = (Get-Date).AddSeconds([int]$TimeoutSeconds)
    $attempt = 0
    while ((Get-Date) -lt $deadline) {
        $attempt++
        # Fresh session each attempt: a runspace created before the disc arrived
        # holds a stale optical view and would never see it (the whole bug class).
        Invoke-VmSessionRefreshAfterMediaChange -VmName $VmName
        $r = Invoke-VmCommand -VmName $VmName -VmDomainName $VmDomainName -ScriptBlock $probe -ArgumentList @($MarkerRelativePath) -SuppressLog -DisplayName "$Context media visible? ($attempt)"
        $root = $r.ScriptBlockOutput
        if ($root -is [string] -and $root) {
            Write-Log "$tag$($VmName): $Context media visible in guest at $root [attempt $attempt]." -LogOnly
            return $true
        }
        Start-Sleep -Seconds 8
    }
    Write-Log "$tag$($VmName): $Context media NOT visible in guest after ~$([int]$TimeoutSeconds)s (marker '$MarkerRelativePath'); leaving it to the in-guest re-enumeration." -Warning
    return $false
}

function Dismount-IsoFromVm {
    # Idempotent, per-drive eject. Ejects ONLY the drive(s) whose media is this exact
    # ISO path -- leaves every other mounted ISO and every empty drive untouched.
    # No-op when the ISO isn't mounted. Never throws.
    param(
        [Parameter(Mandatory)][string]$VmName,
        [Parameter(Mandatory)][string]$IsoPath,
        [string]$Context = "ISO",
        [int]$Phase = 0
    )
    $tag = ""
    if ($Phase -gt 0) { $tag = "[Phase $Phase]: " }
    try {
        foreach ($d in @(Get-VMDvdDrive -VMName $VmName -ErrorAction SilentlyContinue)) {
            if ($d.Path -and $d.Path -eq $IsoPath) {
                Set-VMDvdDrive -VMName $VmName -ControllerNumber $d.ControllerNumber -ControllerLocation $d.ControllerLocation -Path $null -ErrorAction SilentlyContinue
                Write-Log "$tag$($VmName): Ejected $Context ISO $IsoPath" -LogOnly
            }
        }
    }
    catch {
        Write-Log "$tag$($VmName): $Context ISO eject failed: $($_.Exception.Message)" -LogOnly
    }
}

function Reset-IsoDriveOnVm {
    # Strongest guest re-enumeration short of a reboot: REMOVE the DVD drive that
    # holds this exact ISO and ADD a brand-new one back. The guest then sees a
    # device-arrival (a whole new optical device), not merely a media-arrival, so
    # it reliably surfaces a disc that a plain media toggle (eject+remount on the
    # same drive) failed to -- e.g. an ISO left inserted across a guest reboot,
    # where Hyper-V never re-raises any arrival event. Touches ONLY the drive(s)
    # whose media is this exact ISO path; every other DVD drive / ISO is left
    # alone. Requires a Gen2 (SCSI) VM to hot-add while running (Gen1/IDE can't --
    # Mount-IsoOnVm catches that and returns $false). Returns $true only after
    # verifying the ISO is attached again; never throws.
    param(
        [Parameter(Mandatory)][string]$VmName,
        [Parameter(Mandatory)][string]$IsoPath,
        [string]$Context = "ISO",
        [int]$Phase = 0
    )
    $tag = ""
    if ($Phase -gt 0) { $tag = "[Phase $Phase]: " }
    try {
        foreach ($d in @(Get-VMDvdDrive -VMName $VmName -ErrorAction SilentlyContinue)) {
            if ($d.Path -and $d.Path -eq $IsoPath) {
                Remove-VMDvdDrive -VMName $VmName -ControllerNumber $d.ControllerNumber -ControllerLocation $d.ControllerLocation -ErrorAction SilentlyContinue
                Write-Log "$tag$($VmName): Removed $Context DVD drive (held $IsoPath) for a fresh device re-add" -LogOnly
            }
        }
    }
    catch {
        Write-Log "$tag$($VmName): $Context DVD drive remove failed: $($_.Exception.Message)" -LogOnly
    }
    Start-Sleep -Seconds 3
    # Add a fresh DVD drive back with the ISO (Mount-IsoOnVm case 3: all drives
    # busy / none present -> Add-VMDvdDrive), which fires the device-arrival event.
    return (Mount-IsoOnVm -VmName $VmName -IsoPath $IsoPath -Context $Context -Phase $Phase)
}

function Reset-AllDvdDrivesOnVm {
    # De-churn a VM's optical layout by rebuilding it from scratch, preserving
    # every disc that should be mounted. Repeated per-disc add/eject/remove churn
    # (e.g. an escalating "make the guest see it" loop) leaves a Gen2 guest with
    # orphan empty drives and discs pushed to high, climbing SCSI controller
    # locations, which WEDGES the guest's storvsc/optical enumeration -- it then
    # shows a stale/phantom disc and can't see the real media (observed: host had
    # the CM ISO at SCSI 0:5 + an empty drive at 0:1, guest saw only a phantom
    # 700MB disc). The clean fix, verified by hand, is to remove EVERY DVD drive
    # (clearing orphans + the climbing locations) and re-add each wanted ISO fresh
    # at a low location. This preserves co-mounts (cache + SQL + CM can all be
    # present at once -- multiple DVDs are fine; the churn, not the count, is what
    # wedges the guest). Returns $true only after verifying $RequiredIsoPath is
    # attached again. Gen2/SCSI only (hot remove/add while running). Never throws.
    param(
        [Parameter(Mandatory)][string]$VmName,
        [Parameter(Mandatory)][string]$RequiredIsoPath,
        [string]$Context = "ISO",
        [int]$Phase = 0
    )
    $tag = ""
    if ($Phase -gt 0) { $tag = "[Phase $Phase]: " }
    try {
        # Capture the ISOs currently mounted (drop empty/orphan drives), and make
        # sure the required ISO is in the set to re-add.
        $wanted = @(Get-VMDvdDrive -VMName $VmName -ErrorAction SilentlyContinue | Where-Object { $_.Path } | Select-Object -ExpandProperty Path)
        $wanted = @($wanted + $RequiredIsoPath | Where-Object { $_ } | Select-Object -Unique)

        # Remove EVERY DVD drive (orphan empties included) for a clean slate.
        foreach ($d in @(Get-VMDvdDrive -VMName $VmName -ErrorAction SilentlyContinue)) {
            Remove-VMDvdDrive -VMName $VmName -ControllerNumber $d.ControllerNumber -ControllerLocation $d.ControllerLocation -ErrorAction SilentlyContinue
        }
        Write-Log "$tag$($VmName): $Context DVD reset -- removed all DVD drives; re-adding $($wanted.Count) disc(s) cleanly." -LogOnly
        Start-Sleep -Seconds 3

        # Re-add each wanted ISO fresh, one at a time with a short settle so the
        # guest gets a clean device-arrival per disc at a low controller location.
        foreach ($iso in $wanted) {
            if (Test-Path $iso) {
                try { Add-VMDvdDrive -VMName $VmName -Path $iso -ErrorAction Stop } catch { Write-Log "$tag$($VmName): re-add of '$iso' failed: $($_.Exception.Message)" -LogOnly }
                Start-Sleep -Seconds 2
            }
        }
    }
    catch {
        Write-Log "$tag$($VmName): $Context DVD reset failed: $($_.Exception.Message)" -LogOnly
    }
    # The optical topology was just rebuilt (all drives removed + discs re-added).
    # Evict the cached host session so the next probe sees the fresh device set,
    # not the pre-reset view (this is the reset path's equivalent of the mount
    # eviction -- without it the very DVD reset done to un-wedge enumeration would
    # be re-read through the same stale session that couldn't see the disc).
    Invoke-VmSessionRefreshAfterMediaChange -VmName $VmName
    return ([bool](@(Get-VMDvdDrive -VMName $VmName -ErrorAction SilentlyContinue) | Where-Object { $_.Path -eq $RequiredIsoPath }))
}

function Dismount-IsoFromAllVMs {
    # Host-wide safety gate: eject a specific ISO (by full path) from EVERY VM's DVD
    # drive BEFORE the host deletes / re-downloads that ISO on disk. A VM that still
    # has the ISO mounted locks the file (the delete/redownload then fails and leaves a
    # stale copy) and, if the file were swapped underneath it, would read torn content.
    # So any re-download of an ISO we manage must first confirm no VM has it mounted --
    # this makes that true by ejecting it. Ejects ONLY the drive(s) whose media is this
    # exact path; leaves every other mounted ISO and every empty drive untouched. Never
    # throws (Hyper-V unavailable / access denied -> logs and returns). Returns the list
    # of VM names it ejected the ISO from (empty when nothing was mounted).
    param(
        [Parameter(Mandatory)][string]$IsoPath
    )
    $ejected = New-Object System.Collections.Generic.List[string]
    $target = $IsoPath
    try { $target = [System.IO.Path]::GetFullPath($IsoPath) } catch { }
    try {
        $vms = @(Get-VM -ErrorAction SilentlyContinue)
    }
    catch {
        Write-Log -LogOnly "Dismount-IsoFromAllVMs: Get-VM failed ($($_.Exception.Message)); skipping mount check for $IsoPath"
        return $ejected
    }
    foreach ($vm in $vms) {
        try {
            foreach ($d in @(Get-VMDvdDrive -VMName $vm.Name -ErrorAction SilentlyContinue)) {
                if (-not $d.Path) { continue }
                $mounted = $d.Path
                try { $mounted = [System.IO.Path]::GetFullPath($d.Path) } catch { }
                if ($mounted -ieq $target) {
                    Set-VMDvdDrive -VMName $vm.Name -ControllerNumber $d.ControllerNumber -ControllerLocation $d.ControllerLocation -Path $null -ErrorAction SilentlyContinue
                    $ejected.Add($vm.Name)
                    Write-Log "Ejected ISO '$IsoPath' from VM '$($vm.Name)' (state: $($vm.State)) before re-download." -Warning
                }
            }
        }
        catch {
            Write-Log -LogOnly "Dismount-IsoFromAllVMs: eject from $($vm.Name) failed: $($_.Exception.Message)"
        }
    }
    return $ejected
}

function Dismount-AllManagedIsosFromVm {
    # Guaranteed, idempotent end-of-build teardown of EVERY memlabs-managed ISO
    # from one VM's DVD drives. "Managed" = any mounted ISO whose file lives under
    # our azureFiles tree (OS install / SQL / CM media) PLUS the transient
    # cache-<hash>.iso and dsc-<hash>.iso. Ejects media only (leaves the empty DVD
    # drive); touches nothing that isn't ours; never throws.
    #
    # This is the safety net that makes the whole ISO lifecycle reliable regardless
    # of which per-phase eject ran. The per-phase ejects (Dismount-SqlIsoForPhase,
    # Dismount-CmIsoForPhase) are gated on WHOLE-PHASE success, so a single VM
    # failing a phase leaves install media mounted on every sibling that succeeded,
    # and a killed / -StartPhase-partial run can leave media mounted indefinitely --
    # which then bakes a host ISO path into checkpoints / .memlabs exports and trips
    # the Phase 11 leftover-ISO validator. Called once per VM from New-Lab's finally
    # on a SUCCESSFUL build, this sweeps the lab clean no matter what the per-phase
    # ejects skipped. On a FAILED build it is deliberately NOT called, so the media
    # stays mounted on the failed VM for inspection and an idempotent -StartPhase
    # retry (the retry's eventual success then triggers the sweep).
    param([Parameter(Mandatory)][string]$VmName)

    $azureRoot = $null
    try {
        if ($Common -and $Common.AzureFilesPath) { $azureRoot = [System.IO.Path]::GetFullPath($Common.AzureFilesPath) }
    }
    catch { $azureRoot = $null }

    try {
        foreach ($d in @(Get-VMDvdDrive -VMName $VmName -ErrorAction SilentlyContinue)) {
            if (-not $d.Path) { continue }
            $name = [System.IO.Path]::GetFileName($d.Path)
            $isManaged = $false
            if ($name -like 'cache-*.iso' -or $name -like 'dsc-*.iso') {
                $isManaged = $true
            }
            elseif ($azureRoot) {
                # Any ISO staged from our azureFiles tree (OS/SQL/CM). Full-path
                # compare so a same-named ISO from another root is never touched.
                $full = $d.Path
                try { $full = [System.IO.Path]::GetFullPath($d.Path) } catch { $full = $d.Path }
                if ($full.StartsWith($azureRoot, [System.StringComparison]::OrdinalIgnoreCase)) { $isManaged = $true }
            }
            if ($isManaged) {
                Set-VMDvdDrive -VMName $VmName -ControllerNumber $d.ControllerNumber -ControllerLocation $d.ControllerLocation -Path $null -ErrorAction SilentlyContinue
                Write-Log "$($VmName): end-of-build ISO teardown -- ejected $($d.Path)" -LogOnly
            }
        }
    }
    catch {
        Write-Log "$($VmName): end-of-build ISO teardown failed (non-fatal): $($_.Exception.Message)" -LogOnly
    }
}

function Mount-MemlabsCacheIsoToVm {
    # Mount the cache ISO read-only on a VM's DVD drive. Idempotent + per-drive +
    # multi-drive via Mount-IsoOnVm: reuses an empty drive, or adds its own drive
    # when the existing drives are busy with other ISOs (cache no longer has to
    # yield). Dismount-MemlabsCacheIsoFromVm ejects only cache-*.iso by name, so
    # the cache never disturbs a co-mounted CM/SQL/OS disc.
    param([string]$VmName, [string]$IsoPath)
    return (Mount-IsoOnVm -VmName $VmName -IsoPath $IsoPath -Context "cache")
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

function Get-MemlabsDscIsoForPayload {
    # Build (once per content) a read-only, content-addressed ISO that carries the
    # ENTIRE host DSC payload -- DSC.zip (the compiled modules) PLUS the loose phase
    # scripts -- i.e. exactly what Copy-ItemSafe ships to C:\staging\DSC today. The
    # ISO is just a faster TRANSPORT for that same payload: mounting it + copying off
    # the local DVD in-guest beats a host->guest PSDirect transfer of the zip and the
    # many small loose scripts (PSDirect's worst case). Named dsc-<sig12>.iso where
    # sig = the caller's whole-folder signature (DSC.zip MD5 + newest loose-file
    # mtime + loose count), so the ISO is immutable and rebuilt ONLY when the DSC
    # payload actually changes. Old ones are evicted by Remove-StaleMemlabsDscIso.
    #
    # Returns the ISO path, or $null on any failure (caller then direct-copies).
    param([string]$RootPath, [string]$Signature)
    try {
        $srcDir = Join-Path $RootPath 'DSC'
        if (-not (Test-Path $srcDir)) { return $null }
        if ([string]::IsNullOrWhiteSpace($Signature)) { return $null }

        $isoDir = Get-MemlabsCacheIsoDir
        $hash = (Get-MemlabsCacheStringHash -Text $Signature).Substring(0, 12)
        $isoPath = Join-Path $isoDir "dsc-$hash.iso"
        if (Test-Path $isoPath) { return $isoPath }

        # Serialize the complete check/build/publish sequence per content hash.
        # The IMAPI mutex inside New-NoCloudSeedIsoWithImapi protects COM, but it
        # does not stop each waiting VM_Config process from building the same ISO
        # after the previous process publishes it. Recheck under this lock so one
        # process builds and every waiter immediately reuses the finished artifact.
        $mutex = [System.Threading.Mutex]::new($false, "Global\MemlabsDscIsoBuild-$hash")
        $null = $mutex.WaitOne()
        try {
            if (Test-Path $isoPath) { return $isoPath }

            # AddTree reads the live DSC folder directly ($false puts its contents
            # at the ISO root, matching the C:\staging\DSC layout).
            $tmpIso = "$isoPath.$PID.tmp"
            try {
                if (Test-Path $tmpIso) { Remove-Item $tmpIso -Force -ErrorAction SilentlyContinue }
                New-NoCloudSeedIsoWithImapi -SourceDir $srcDir -OutputIsoPath $tmpIso -VolumeLabel $script:MemlabsDscVolumeLabel
                if (-not (Test-Path $tmpIso)) { throw "DSC ISO build produced no output for $isoPath" }
                Move-Item -Path $tmpIso -Destination $isoPath -Force
                Write-Log "DownloadCache: built $([System.IO.Path]::GetFileName($isoPath)) (DSC payload)." -LogOnly
            }
            finally {
                if (Test-Path $tmpIso) { Remove-Item $tmpIso -Force -ErrorAction SilentlyContinue }
            }
        }
        finally {
            $mutex.ReleaseMutex()
            $mutex.Dispose()
        }
        return $isoPath
    }
    catch {
        Write-Log "DownloadCache: Get-MemlabsDscIsoForPayload failed: $($_.Exception.Message). Caller will direct-copy DSC." -Warning
        return $null
    }
}

function Mount-MemlabsDscIsoToVm {
    # Mount the DSC payload ISO read-only on the VM. Idempotent + per-drive +
    # multi-drive via Mount-IsoOnVm (reuses an empty drive or adds its own). The
    # caller ejects it right after the in-guest copy (Dismount-MemlabsDscIsoFromVm,
    # by dsc-*.iso name), so it never disturbs a co-mounted CM/SQL/OS/cache disc.
    param([string]$VmName, [string]$IsoPath)
    return (Mount-IsoOnVm -VmName $VmName -IsoPath $IsoPath -Context "DSC")
}


function Dismount-MemlabsDscIsoFromVm {
    # Eject only OUR dsc-*.iso from this VM (leaves any OS/cache/other DVD alone).
    param([string]$VmName)
    try {
        foreach ($d in @(Get-VMDvdDrive -VMName $VmName -ErrorAction SilentlyContinue)) {
            if ($d.Path -and ([System.IO.Path]::GetFileName($d.Path)) -like 'dsc-*.iso') {
                Set-VMDvdDrive -VMName $VmName -ControllerNumber $d.ControllerNumber -ControllerLocation $d.ControllerLocation -Path $null -ErrorAction SilentlyContinue
            }
        }
    }
    catch {}
}

function Remove-StaleMemlabsDscIso {
    # Evict old dsc-*.iso (dev rebuilds mint a new one each time the DSC payload
    # changes). Same host-wide-safe rules as Remove-StaleMemlabsCacheIso: never the
    # newest, never one younger than a day, never one any VM still has mounted.
    param([string]$KeepIsoPath)
    try {
        $all = @(Get-ChildItem -Path (Get-MemlabsCacheIsoDir) -Filter 'dsc-*.iso' -File -ErrorAction SilentlyContinue)
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
            Write-Log "DownloadCache: evicted stale DSC ISO $($iso.Name)." -LogOnly
        }
    }
    catch {}
}
