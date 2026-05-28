enum Ensure {
    Absent
    Present
}

function Get-InstalledProducts {
    $Installer = New-Object -ComObject WindowsInstaller.Installer
    $InstallerProducts = $Installer.ProductsEx("", "", 7)
    $InstalledProducts = ForEach ($Product in $InstallerProducts) {
        [PSCustomObject]@{
            ProductCode   = $Product.ProductCode()
            LocalPackage  = $Product.InstallProperty("LocalPackage")
            VersionString = $Product.InstallProperty("VersionString")
            ProductName   = $Product.InstallProperty("ProductName")
        }
    } 
    return $InstalledProducts
}


function Invoke-DownloadFile {
    param(
        [string] $url,
        [string] $dest
    )

    if ((Test-Path $dest)) {
        Remove-Item $dest -Force -ErrorAction SilentlyContinue | Out-Null
    }

    if (!(Test-Path $dest)) {
        Write-Status "Downloading $url to $dest"
        $dirname = Split-Path $dest -Parent
        New-Item -ItemType Directory -Force -Path $dirname
        try {
            $wc = New-Object System.Net.WebClient
            $wc.DownloadFile($url, $dest)
            #Start-BitsTransfer -Source $url -Destination $dest -Priority Foreground -ErrorAction Stop
        }
        catch {
            Write-Verbose $_
            Write-Status "Failed Downloading $url to $dest Using WebClient. Retrying using Start-BitsTransfer"
            Clear-DnsClientCache -ErrorAction SilentlyContinue
            try {
                Start-BitsTransfer -Source $url -Destination $dest -Priority Foreground -ErrorAction Stop
            }
            catch {
                try {
                    Write-Status "Failed Downloading $url to $dest. Retrying with Invoke-WebRequest"
                    Write-Verbose $_
                    Invoke-WebRequest -Uri $url -OutFile $dest -ErrorAction Stop
                    #Start-BitsTransfer -Source $odbcurl -Destination $_odbcpath -Priority Foreground -ErrorAction Stop
                }
                catch {
                    Write-Verbose $_
                    $ErrorMessage = $_.Exception.Message
                    # Force reboot
                    #[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUserDeclaredVarsMoreThanAssignments', '', Scope = 'Function')]
                    #$global:DSCMachineStatus = 1
                    write-status "Failed to Download $url with error: $ErrorMessage"
                    throw "Failed to Download $url with error: $ErrorMessage"
                    return
                }
            }
        }        
    }

    if ((Test-Path $dest)) {
        $pattern = "https://.*/sqlserver.*-.*-x64_(.*).exe"
        if ($url -match $pattern) {
            $hash = get-filehash -Algorithm SHA1 $dest
            if ($hash.Hash.ToLowerInvariant() -eq $matches[1]) {
                Write-Verbose "Hash check passed for $dest ($($hash.Hash))"
            }
            else {
                $badfile = $dest + ".bad"
                if (Test-Path $badfile) {
                    remove-item $badfile -force
                }
                rename-item $dest $badfile
                write-status "Hash check failed for $dest ($($hash.Hash))"
                throw "Hash check failed for $dest ($($hash.Hash))"
            }
        }
        If ((Get-Item $dest).length -gt 0kb) {
            write-status "Download of $url Succeeded"
        }
        else {
            write-status "Failed to Download $url Destination file $dest is 0kb."
            $badfile = $dest + ".bad"
            if (Test-Path $badfile) {
                remove-item $badfile -force
            }
            rename-item $dest $badfile
            throw "Failed to Download $url Destination file $dest is 0kb."
        }
    }
    else {
        write-status "Failed to Download $url Destination file $dest missing."
        throw "Failed to Download $url Destination file $dest missing."
    }

}

# Hardened MSI installer. Several DSC resources previously called `& msiexec /i ...`
# directly -- but msiexec.exe is a launcher stub that returns immediately while the
# real install runs async under the msiexec /V service. That made callers print
# "Installed Successfully!" before the MSI had done anything, and never inspect
# $LASTEXITCODE. Use Start-Process -Wait -PassThru so we actually block on
# completion and can inspect ExitCode, capture a verbose log, and optionally
# verify a registry marker proving the install registered.
function Install-MSIPackage {
    param(
        [Parameter(Mandatory)][string] $MsiPath,
        [Parameter(Mandatory)][string] $DisplayName,
        [string[]] $AdditionalArguments = @(),
        [string] $LogPath,
        [string] $VerifyRegistryPath,
        [string] $VerifyRegistryValueName,
        [int[]]  $SuccessExitCodes = @(0, 3010)  # 3010 = success, reboot required
    )

    if (-not (Test-Path -Path $MsiPath)) {
        throw "$DisplayName install failed: MSI not found at $MsiPath"
    }

    if (-not $LogPath) {
        $base = [IO.Path]::GetFileNameWithoutExtension($MsiPath)
        $LogPath = "C:\temp\$base.install.log"
    }
    $logDir = Split-Path -Path $LogPath -Parent
    if ($logDir -and -not (Test-Path -Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }

    $msiArgs = @("/i", "`"$MsiPath`"", "/qn", "/norestart") + $AdditionalArguments + @("/l*v", "`"$LogPath`"")

    Write-Status "Installing $DisplayName from $MsiPath ..."
    Write-Verbose ("Commandline: msiexec.exe $($msiArgs -join ' ')")

    $proc = Start-Process -FilePath "msiexec.exe" -ArgumentList $msiArgs -Wait -PassThru -NoNewWindow
    $exit = $proc.ExitCode

    if ($SuccessExitCodes -notcontains $exit) {
        # MSI 1603 ("fatal error during installation") never tells you the
        # cause in the tail of the log -- the tail is always MSI cleanup
        # noise (MainEngineThread returning, RESTART MANAGER closing, etc).
        # The real failure trigger lives upstream and is signalled by one
        # of a small set of markers. Grep for those, take 5 lines of
        # context before/after each match, dedupe, cap, and surface that
        # instead of (or in addition to) the dumb tail.
        $diag = ""
        if (Test-Path -Path $LogPath) {
            try {
                $all = Get-Content -Path $LogPath -ErrorAction SilentlyContinue
                if ($all) {
                    # Patterns that bracket the real 1603 root cause:
                    #   Return value 3.                  -> last custom action that failed
                    #   CustomAction .* returned actual error code
                    #   Error 1[0-9]{3}                  -> MSI numeric errors (1402 ACL, 1603 fatal, 1719 service, 1935 assembly)
                    #   Note: 1: 27[0-9]{2}              -> internal MSI errors
                    #   Product .* Installation failed
                    #   Action ended .* Return value 3   -> redundant with above but catches some logs
                    #   Failed to .*                     -> generic CA failure text
                    $rx = '(Return value 3\.|returned actual error code|Error 1[0-9]{3}\b|Note: 1: 27[0-9]{2}|Installation failed\.|Action ended .* Return value 3|Failed to (?!find resource))'
                    $hits = New-Object 'System.Collections.Generic.HashSet[int]'
                    for ($i = 0; $i -lt $all.Count; $i++) {
                        if ($all[$i] -match $rx) {
                            for ($k = [math]::Max(0, $i - 5); $k -le [math]::Min($all.Count - 1, $i + 5); $k++) {
                                [void]$hits.Add($k)
                            }
                        }
                    }
                    if ($hits.Count -gt 0) {
                        $ordered = $hits | Sort-Object
                        $sb = New-Object System.Text.StringBuilder
                        $prev = -2
                        foreach ($idx in $ordered) {
                            if ($sb.Length -ge 4000) { break }
                            if ($prev -ge 0 -and $idx -ne ($prev + 1)) { [void]$sb.AppendLine("  ...") }
                            [void]$sb.AppendLine(("  L{0}: {1}" -f ($idx + 1), $all[$idx]))
                            $prev = $idx
                        }
                        $diag = $sb.ToString().TrimEnd()
                    }
                }
            } catch {}
        }
        # Also keep the tail as fallback context (helps if our patterns
        # missed the actual trigger -- the tail at least shows the
        # final state).
        $tail = ""
        if (Test-Path -Path $LogPath) {
            try { $tail = (Get-Content -Path $LogPath -Tail 10 -ErrorAction SilentlyContinue) -join "`n" } catch {}
        }
        $msg = "msiexec for $DisplayName exited with $exit. Log: $LogPath"
        if ($diag) { $msg += "`nFailure context (matched lines + 5 before/after, deduped):`n$diag" }
        if ($tail) { $msg += "`nLog tail (last 10):`n$tail" }
        Write-Status $msg
        throw "$DisplayName install failed (msiexec exit $exit). Log: $LogPath"
    }

    if ($VerifyRegistryPath) {
        if (-not (Test-Path -Path $VerifyRegistryPath)) {
            throw "$DisplayName msiexec exit was $exit but registry path $VerifyRegistryPath is missing -- install did not register"
        }
        if ($VerifyRegistryValueName) {
            $val = (Get-ItemProperty -Path $VerifyRegistryPath -Name $VerifyRegistryValueName -ErrorAction SilentlyContinue).$VerifyRegistryValueName
            if (-not $val) {
                throw "$DisplayName msiexec exit was $exit but $VerifyRegistryPath\$VerifyRegistryValueName is empty -- install did not register"
            }
            Write-Status "$DisplayName installed successfully ($VerifyRegistryValueName=$val, exit $exit)"
            return
        }
    }

    Write-Status "$DisplayName installed successfully (exit $exit)"
}

[DscResource()]
class InstallADK {
    [DscProperty(Key)]
    [string] $ADKPath

    [DscProperty(Mandatory)]
    [string] $ADKWinPEPath

    [DscProperty(Mandatory)]
    [string] $ADKDownloadPath #  "https://go.microsoft.com/fwlink/?linkid=2196127"

    [DscProperty(Mandatory)]
    [string] $ADKWinPEDownloadPath #  "https://go.microsoft.com/fwlink/?linkid=2243391"

    [DscProperty(Mandatory)]
    [Ensure] $Ensure

    [DscProperty(NotConfigurable)]
    [Nullable[datetime]] $CreationTime

    [void] Set() {
        $_adkpath = $this.ADKPath
        $_adkWinPEpath = $this.ADKWinPEPath

        $_ADKDownloadPath = $this.ADKDownloadPath
        $_ADKWinPEDownloadPath = $this.ADKWinPEDownloadPath


        # Use this block to download the FULL ADK, Filename: adksetup.exe
        Invoke-DownloadFile $_ADKDownloadPath $_adkpath
        
        # Use this block to download the WinPE ADK, Filename: adkwinpesetup.exe
        Invoke-DownloadFile $_ADKWinPEDownloadPath $_adkWinPEpath        

        # Local helper: invoke adksetup with a dedicated log file, check
        # exit code, and surface the real failure on error.
        #
        # adksetup is a WiX Burn bundle; on failure it dumps ~hundreds of
        # WixBundle* variables at the end of the log, so a plain "last 40
        # lines" tail just captures variable dumps and tells us nothing
        # useful. Burn prefixes meaningful lines with single-letter codes:
        #   i### informational, w### warning, e### error, f### fatal
        # We extract the error/warning/fatal lines (plus a few lines of
        # surrounding context) so the DSC status surfaces the actual root
        # cause -- which package failed, MSI return, missing prereq, etc.
        $invokeAdk = {
            param($exe, [string[]]$argv, $label)
            $logFile = Join-Path $env:TEMP ("adksetup-" + ($label -replace '\W','_') + ".log")
            if (Test-Path $logFile) { Remove-Item $logFile -Force -ErrorAction SilentlyContinue }

            $full = @($argv) + @('/log', $logFile)
            Write-Status ("ADK {0}: running adksetup (downloading + installing, may take several minutes): {1} {2}" -f $label, $exe, ($full -join ' '))
            $proc = Start-Process -FilePath $exe -ArgumentList $full -Wait -PassThru -NoNewWindow
            $code = $proc.ExitCode
            Write-Status ("ADK {0}: adksetup exit code: {1} (0x{2:x})" -f $label, $code, $code)
            # 3010 = ERROR_SUCCESS_REBOOT_REQUIRED — install succeeded, reboot needed.
            # Don't enter the diagnostics/dead-link-probe path for 3010.
            if ($code -ne 0 -and $code -ne 3010) {
                $errLines = @()
                if (Test-Path $logFile) {
                    try {
                        $all = Get-Content -LiteralPath $logFile -ErrorAction SilentlyContinue
                        $pattern = '^\s*\[[^\]]+\]\s*[efw]\d{3}:|Error\s+\d|failed|returned\s+(error|exit code)|cancel|Applying execute package'
                        $errLines = $all | Where-Object { $_ -match $pattern } | Select-Object -Last 40
                    } catch { }
                }
                if (-not $errLines -or $errLines.Count -eq 0) {
                    try { $errLines = Get-Content -LiteralPath $logFile -Tail 25 -ErrorAction SilentlyContinue } catch { }
                }
                $diag = ($errLines -join "`n")
                Write-Status ("adksetup ({0}) failed. Log {1}. Diagnostic lines:`n{2}" -f $label, $logFile, $diag)

                # Extract any download URLs Burn complained about (fwlinks,
                # direct CDN urls, etc.) and probe each one. A dead/retired
                # fwlink is the #1 cause of mystery 0x80070642 acquisition
                # failures and the bundle's own log doesn't say "404 from
                # microsoft" -- it just says HttpSendRequest failed. Probing
                # here surfaces the actual HTTP status in the DSC log so
                # the next reader knows immediately whether to blame the
                # network, the proxy, or a retired link.
                try {
                    if (Test-Path $logFile) {
                        $logText = Get-Content -LiteralPath $logFile -Raw -ErrorAction SilentlyContinue
                        $urlMatches = [regex]::Matches($logText, 'https?://[^\s''"<>)]+')
                        $urls = $urlMatches | ForEach-Object { $_.Value.TrimEnd('.',',',';',':') } |
                                Where-Object { $_ -match 'go\.microsoft\.com/fwlink|download\.microsoft\.com|\.cab(\?|$)|\.msi(\?|$)|\.exe(\?|$)' } |
                                Sort-Object -Unique
                        if ($urls) {
                            Write-Status ("adksetup ({0}) referenced {1} download URL(s); probing each for dead-link detection." -f $label, $urls.Count)
                            $deadHits = @()
                            foreach ($u in $urls) {
                                $probeMsg = $null
                                $resolved = $null
                                $status   = $null
                                $isDead   = $false
                                try {
                                    $req = [System.Net.HttpWebRequest]::Create($u)
                                    $req.Method = 'HEAD'
                                    $req.Timeout = 15000
                                    $req.AllowAutoRedirect = $true
                                    $req.MaximumAutomaticRedirections = 10
                                    $req.UserAgent = 'MemLabs-AdkProbe/1.0'
                                    $resp = $req.GetResponse()
                                    $status = [int]$resp.StatusCode
                                    $resolved = $resp.ResponseUri.AbsoluteUri
                                    $resp.Close()
                                    if ($status -ge 400) {
                                        $probeMsg = "DEAD (HTTP $status) -> $resolved"
                                        $isDead = $true
                                    } else {
                                        $probeMsg = "ok  (HTTP $status) -> $resolved"
                                    }
                                } catch [System.Net.WebException] {
                                    $we = $_.Exception
                                    if ($we.Response) {
                                        try { $status = [int]$we.Response.StatusCode } catch {}
                                        try { $resolved = $we.Response.ResponseUri.AbsoluteUri } catch {}
                                    }
                                    if ($status -in 404,410) {
                                        $probeMsg = "DEAD (HTTP $status, link retired by publisher)"
                                        if ($resolved) { $probeMsg += " -> $resolved" }
                                        $isDead = $true
                                    } elseif ($status) {
                                        $probeMsg = "DEAD (HTTP $status) -> $resolved"
                                        $isDead = $true
                                    } else {
                                        $probeMsg = "probe failed: $($we.Message)"
                                    }
                                } catch {
                                    $probeMsg = "probe error: $($_.Exception.Message)"
                                }
                                # Pull linkid out of fwlink URLs for at-a-glance correlation.
                                $linkid = $null
                                if ($u -match 'linkid=(\d+)') { $linkid = $Matches[1] }
                                $tag = if ($linkid) { "fwlink linkid=$linkid" } else { 'url' }
                                Write-Status ("  adksetup-link {0,-22} {1} : {2}" -f $tag, $u, $probeMsg)
                                if ($isDead) {
                                    $deadHits += [pscustomobject]@{ Url=$u; LinkId=$linkid; Status=$status; Resolved=$resolved }
                                }
                            }
                            # Bubble a punchy summary status line so the host
                            # monitor (which shows the most recent Write-Status)
                            # surfaces the headline finding instead of just
                            # "adksetup exit code 1603".
                            if ($deadHits.Count -gt 0) {
                                $summary = $deadHits | ForEach-Object {
                                    if ($_.LinkId) { "fwlink $($_.LinkId) (HTTP $($_.Status))" }
                                    else { "$($_.Url) (HTTP $($_.Status))" }
                                }
                                Write-Status ("ADK $label : DEAD LINK DETECTED -- {0} retired/unreachable download(s): {1}. See log {2} for full URL list." -f $deadHits.Count, ($summary -join '; '), $logFile)

                                # Recovery: try to pre-stage the missing payload(s)
                                # from the resolved CDN folder of each dead fwlink.
                                # WiX Burn checks the local source path first; if
                                # we drop the file there, the next attempt will
                                # find it and skip the dead download entirely.
                                #
                                # This salvages the common Microsoft pattern where
                                # the fwlink itself redirects to a download.microsoft.com
                                # folder URL that returns 404 (directory listing
                                # forbidden / folder removed) but specific files
                                # UNDER that folder are still hosted. ADK bundles
                                # have repeatedly shipped with baked-in child
                                # fwlinks pointing at such retired folder roots
                                # (e.g. linkid=2290227 in the Dec-2024 26100.2454
                                # bundle, linkid=2337876 in the Nov-2025 28000.1
                                # bundle) -- both fixable this way without waiting
                                # for MS to republish the bootstrapper.
                                try {
                                    $expected = New-Object System.Collections.Generic.List[string]
                                    foreach ($line in $all) {
                                        if ($line -match 'Failed to resolve source for file:\s*(.+?),\s*error:') {
                                            $p = $Matches[1].Trim()
                                            if ($p -and -not $expected.Contains($p)) { $expected.Add($p) }
                                        }
                                    }
                                    if ($expected.Count -gt 0) {
                                        # Build candidate base URLs from the dead-link
                                        # resolved URIs. Strip trailing filename if the
                                        # resolved URL already points at a file (rare
                                        # for the fwlink-folder case but defensive).
                                        $candidateBases = New-Object System.Collections.Generic.List[string]
                                        foreach ($hit in $deadHits) {
                                            $b = $hit.Resolved
                                            if (-not $b) { continue }
                                            if ($b -notmatch '/$') { $b = ($b -replace '/[^/]*$','/') }
                                            if ($b -and -not $candidateBases.Contains($b)) { $candidateBases.Add($b) }
                                        }
                                        if ($candidateBases.Count -gt 0) {
                                            Write-Status ("ADK $label : attempting to pre-stage {0} missing payload(s) from {1} dead-link CDN base(s)." -f $expected.Count, $candidateBases.Count)
                                            foreach ($localPath in $expected) {
                                                if (Test-Path -LiteralPath $localPath) {
                                                    Write-Status ("  pre-stage: $localPath already present, skipping")
                                                    continue
                                                }
                                                $fname = Split-Path -Path $localPath -Leaf
                                                $encoded = [uri]::EscapeDataString($fname)
                                                $localDir = Split-Path -Path $localPath -Parent
                                                if ($localDir -and -not (Test-Path -LiteralPath $localDir)) {
                                                    New-Item -ItemType Directory -Path $localDir -Force | Out-Null
                                                }
                                                # ADK bundle layout puts every payload
                                                # under an Installers/ subfolder on the
                                                # CDN mirror. Try that first; fall back
                                                # to base + filename for other layouts.
                                                $relCandidates = @("Installers/$encoded", $encoded)
                                                $staged = $false
                                                :baseLoop foreach ($base in $candidateBases) {
                                                    foreach ($rel in $relCandidates) {
                                                        $url = $base + $rel
                                                        try {
                                                            $wc = New-Object System.Net.WebClient
                                                            Write-Status ("  pre-stage: downloading $fname from $url")
                                                            $wc.DownloadFile($url, $localPath)
                                                            if ((Test-Path -LiteralPath $localPath) -and (Get-Item -LiteralPath $localPath).Length -gt 0) {
                                                                $sz = (Get-Item -LiteralPath $localPath).Length
                                                                Write-Status ("  pre-stage: OK ({0:N0} bytes) -> $localPath" -f $sz)
                                                                $staged = $true
                                                                break baseLoop
                                                            }
                                                        } catch {
                                                            Write-Status ("  pre-stage: $url -> $($_.Exception.Message)")
                                                            if (Test-Path -LiteralPath $localPath) {
                                                                Remove-Item -LiteralPath $localPath -Force -ErrorAction SilentlyContinue
                                                            }
                                                        }
                                                    }
                                                }
                                                if (-not $staged) {
                                                    Write-Status ("  pre-stage: could not locate $fname under any dead-link base")
                                                }
                                            }
                                        }
                                    }
                                } catch {
                                    Write-Status ("ADK $label : pre-stage attempt threw: $($_.Exception.Message)")
                                }
                            }
                        }
                    }
                } catch {
                    Write-Status ("adksetup ({0}) link probe threw: {1}" -f $label, $_.Exception.Message)
                }
            }
            return $code
        }

        # Install routine: prefer direct /quiet /features (only fetches
        # the packages the selected features need -- skips optional/dead
        # children entirely). Falls back to /layout + offline install as
        # a last resort if every direct attempt fails: layout caches the
        # whole bundle locally and installs from there, which can rescue
        # cases where Burn's child-package fetch is racing a flaky CDN.
        #
        # Note: /layout downloads EVERY package in the bundle regardless
        # of /features, so it's vulnerable to baked-in dead child fwlinks
        # (the 24H2 Dec-2024 bundle's linkid=2290227 / Toolkit
        # Documentation MSI was a known casualty -- retired by MS without
        # a corresponding bundle refresh). That's why direct goes first.
        $runAdkInstall = {
            param($exe, [string[]]$features, $label, $layoutDir, $maxAttempts, [string[]]$verifyPaths)

            # Helper: adksetup sometimes exits 0 in a few seconds without
            # actually installing anything (e.g. another bundle instance
            # already handled by Burn, bootstrapper detected an in-progress
            # install, etc.). Caller passes the install paths it expects to
            # exist after success; we verify them and treat missing-paths
            # as a non-zero outcome so the retry/layout fallback path fires.
            $verifyInstall = {
                if (-not $verifyPaths -or $verifyPaths.Count -eq 0) { return $true }
                $missing = @($verifyPaths | Where-Object { -not (Test-Path $_) })
                if ($missing.Count -eq 0) { return $true }
                Write-Status ("ADK {0} : adksetup reported success but expected install path(s) missing: {1}" -f $label, ($missing -join '; '))
                $logFile = Join-Path $env:TEMP ("adksetup-" + ($label -replace '\W','_') + ".log")
                if (Test-Path $logFile) {
                    try {
                        $tail = Get-Content -LiteralPath $logFile -Tail 15 -ErrorAction SilentlyContinue
                        if ($tail) { Write-Status ("ADK {0} : adksetup log tail ({1}):`n{2}" -f $label, $logFile, ($tail -join "`n")) }
                    } catch { }
                }
                return $false
            }

            $attempt = 0
            $lastExit = -1
            while ($attempt -lt $maxAttempts) {
                $attempt++
                Write-Status "ADK $label install... (attempt $attempt/$maxAttempts, mode=direct)"
                try {
                    $directArgs = @('/quiet','/features') + $features
                    $lastExit = & $invokeAdk $exe $directArgs $label
                }
                catch {
                    $ErrorMessage = $_.Exception.Message
                    Write-Status "Failed to launch ADK $label setup: $ErrorMessage"
                    throw "Failed to launch ADK $label setup: $ErrorMessage"
                }
                if ($lastExit -eq 0 -or $lastExit -eq 3010) {
                    if (& $verifyInstall) { return $lastExit }
                    # 0-exit but install didn't happen -- almost always means
                    # Burn's dependency-provider registry has a stale entry
                    # ("WixBundleInstalled = 1" in the log) from a prior run
                    # whose MSIs got rolled back / cleaned. The bootstrapper
                    # then no-op's every subsequent install attempt. Force an
                    # uninstall to clear the stale provider key, then retry.
                    Write-Status "ADK $label : running /uninstall /quiet to clear stale Burn registration before retry."
                    try {
                        $uninstallExit = & $invokeAdk $exe @('/uninstall','/quiet') ("$label-uninstall")
                        Write-Status "ADK $label : /uninstall returned $uninstallExit."
                    } catch {
                        Write-Status "ADK $label : /uninstall threw: $($_.Exception.Message) (continuing to retry install)"
                    }
                    $lastExit = -2
                }
                Write-Status "ADK $label : adksetup exited $lastExit; will retry after backoff."
                Start-Sleep -Seconds 5
            }

            # Direct path exhausted. Last-resort: try /layout + offline install.
            Write-Status "ADK $label : all $maxAttempts direct attempts failed (last exit $lastExit). Falling back to /layout + offline install."
            try {
                if (!(Test-Path $layoutDir)) {
                    New-Item -ItemType Directory -Force -Path $layoutDir | Out-Null
                }
                $layoutArgs = @('/quiet','/layout',$layoutDir)
                $layoutExit = & $invokeAdk $exe $layoutArgs ("$label-layout")
                if ($layoutExit -ne 0 -and $layoutExit -ne 3010) {
                    Write-Status "ADK $label : /layout fallback failed with exit $layoutExit. Giving up."
                    return $layoutExit
                }
                $localExe = Join-Path $layoutDir 'adksetup.exe'
                if (!(Test-Path $localExe)) {
                    $localExe = Join-Path $layoutDir (Split-Path $exe -Leaf)
                }
                if (!(Test-Path $localExe)) {
                    Write-Status "ADK $label : /layout succeeded but no installer found in $layoutDir. Giving up."
                    return 1
                }
                $offlineArgs = @('/quiet','/features') + $features
                $offlineExit = & $invokeAdk $localExe $offlineArgs ("$label-offline")
                if (($offlineExit -eq 0 -or $offlineExit -eq 3010) -and -not (& $verifyInstall)) {
                    Write-Status "ADK $label : offline install reported success but expected paths still missing. Giving up."
                    return -2
                }
                return $offlineExit
            }
            catch {
                Write-Status "ADK $label : /layout fallback threw: $($_.Exception.Message)"
                return $lastExit
            }
        }

        $maxAttempts = 4

        #Install DeploymentTools and UserStateMigrationTool in a single call
        $adkinstallpath = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools"
        $adkinstallpath2 = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\User State Migration Tool"
        Write-Status "ADK [1/2]: installing DeploymentTools + UserStateMigrationTool (first of two adksetup runs)"
        $deptoolsFeatures = @('OptionId.DeploymentTools','OptionId.UserStateMigrationTool')
        $deptoolsLayout = 'C:\temp\adk-layout-deptools'
        $lastExit = & $runAdkInstall $_adkpath $deptoolsFeatures "deptools" $deptoolsLayout $maxAttempts @($adkinstallpath, $adkinstallpath2)
        if (!(Test-Path $adkinstallpath) -or !(Test-Path $adkinstallpath2)) {
            throw ("ADK DeploymentTools/UserStateMigrationTool install failed (last exit code $lastExit, $maxAttempts direct attempts + layout fallback exhausted). Paths missing: " +
                   (@($adkinstallpath, $adkinstallpath2) | Where-Object { -not (Test-Path $_) }) -join '; ')
        }
        Write-Status "ADK [1/2] DeploymentTools + UserStateMigrationTool installed successfully. Starting [2/2] WinPE addon..."

        #Install WindowsPreinstallationEnvironment
        $adkinstallpath = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment"
        Write-Status "ADK [2/2]: installing WinPE addon to $adkinstallpath (separate ~1.5GB download, typically 3-5 min on a healthy link)"
        $winpeFeatures = @('OptionId.WindowsPreinstallationEnvironment')
        $winpeLayout = 'C:\temp\adk-layout-winpe'
        $lastExit = & $runAdkInstall $_adkWinPEpath $winpeFeatures "winpe" $winpeLayout $maxAttempts @($adkinstallpath)
        if (!(Test-Path $adkinstallpath)) {
            throw "ADK WinPE addon install failed (last exit code $lastExit, $maxAttempts direct attempts + layout fallback exhausted). Path missing: $adkinstallpath"
        }
        Write-Status "ADK [2/2] WinPE addon installed successfully. ADK install complete."
    }

    [bool] Test() {
        Write-Status "Checking ADK installation status"
        $key = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry32)
        $subKey = $key.OpenSubKey("SOFTWARE\Microsoft\Windows Kits\Installed Roots")
        if ($subKey) {
            $tool1 = $tool2 = $tool3 = $false
            if ($null -ne $subKey.GetValue('KitsRoot10')) {
                if ($subKey.GetValueNames() | Where-Object { $subkey.GetValue($_) -like "*Deployment Tools*" }) {
                    $tool1 = $true
                }
                if ($subKey.GetValueNames() | Where-Object { $subkey.GetValue($_) -like "*Windows PE*" }) {
                    $tool2 = $true
                }
                if ($subKey.GetValueNames() | Where-Object { $subkey.GetValue($_) -like "*User State Migration*" }) {
                    $tool3 = $true
                }

                if ($tool1 -and $tool2 -and $tool3) {
                    return $true
                }
            }
        }
        return $false
    }

    [InstallADK] Get() {
        return $this
    }
}

[DscResource()]
class InstallSSMS {
    [DscProperty(Key)]
    [string] $DownloadUrl

    [DscProperty(Mandatory)]
    [Ensure] $Ensure

    [void] Set() {
        # Download SSMS

        $ssmsSetup = "C:\temp\SSMS-Setup-ENU.exe"

        Invoke-DownloadFile $this.DownloadUrl $ssmsSetup
                
        # Install SSMS
        $smssinstallpath = "C:\Program Files (x86)\Microsoft SQL Server Management Studio 18\Common7\IDE"
        $smssinstallpath2 = "C:\Program Files (x86)\Microsoft SQL Server Management Studio 19\Common7\IDE"
        $smssinstallpath3 = "C:\Program Files (x86)\Microsoft SQL Server Management Studio 20\Common7\IDE"

        if ((Test-Path $smssinstallpath) -or (Test-Path $smssinstallpath2) -or (Test-Path $smssinstallpath3)) {
            Write-Status "SSMS Installed Successfully! (Tested Out)"
            return
        }
        else {

            $cmd = $ssmsSetup
            $arg1 = "/install"
            $arg2 = "/quiet"
            $arg3 = "/norestart"

            try {
                Write-Status "Installing SSMS..."
                & $cmd $arg1 $arg2 $arg3 | out-null
                Write-Status "SSMS Installed Successfully!"

                # Reboot
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUserDeclaredVarsMoreThanAssignments', '', Scope = 'Function')]
                $global:DSCMachineStatus = 1
            }
            catch {
                $ErrorMessage = $_.Exception.Message
                Write-Status "Failed to install SSMS with below error: $ErrorMessage"
                throw "Failed to install SSMS with below error: $ErrorMessage"
            }
        }
    }

    [bool] Test() {
        Write-Status "Checking SSMS installation status"
        $smssinstallpath = "C:\Program Files (x86)\Microsoft SQL Server Management Studio 18\Common7\IDE\ssms.exe"
        $smssinstallpath2 = "C:\Program Files (x86)\Microsoft SQL Server Management Studio 19\Common7\IDE\ssms.exe"
        $smssinstallpath3 = "C:\Program Files (x86)\Microsoft SQL Server Management Studio 20\Common7\IDE\ssms.exe"

        if (Test-Path $smssinstallpath) {
            If ((Get-Item $smssinstallpath).length -gt 0kb) {
                Write-Verbose "Test - Installing SSMS... $smssinstallpath exists"
                return $true
            }
        }

        if (Test-Path $smssinstallpath2) {
            If ((Get-Item $smssinstallpath2).length -gt 0kb) {
                Write-Verbose "Test - Installing SSMS... $smssinstallpath2 exists"
                return $true
            }
        }
        if (Test-Path $smssinstallpath3) {
            If ((Get-Item $smssinstallpath3).length -gt 0kb) {
                Write-Verbose "Test - Installing SSMS... $smssinstallpath3 exists"
                return $true
            }
        }

        Write-Verbose "Test - Installing SSMS... $smssinstallpath3 does not exist"
        return $false
    }

    [InstallSSMS] Get() {
        return $this
    }
}

[DscResource()]
class InstallDotNet4 {
    [DscProperty(Key)]
    [string] $DownloadUrl

    [DscProperty(Mandatory)]
    [string] $FileName

    [DscProperty(Mandatory)]
    [string] $NetVersion

    [DscProperty(Mandatory)]
    [Ensure] $Ensure

    [void] Set() {

        # Download
        $setup = "C:\temp\$($this.FileName)"
        
        Invoke-DownloadFile $this.DownloadUrl $setup
        
        # Install
        $cmd = $setup
        $arg1 = "/q"
        $arg2 = "/norestart"

        try {
            Write-Status "Installing .NET $($this.FileName)..."
            & $cmd $arg1 $arg2 | out-null

            $processName = ($this.FileName -split ".exe")[0]
            while ($true) {
                Start-Sleep -Seconds 10
                $process = Get-Process $processName -ErrorAction SilentlyContinue
                if ($null -eq $process) {
                    break
                }
            }
            Start-Sleep -Seconds 10 ## Buffer Wait
            Write-Status ".NET $($this.FileName) Installed Successfully!"

            # Reboot
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUserDeclaredVarsMoreThanAssignments', '', Scope = 'Function')]
            $global:DSCMachineStatus = 1
        }
        catch {
            $ErrorMessage = $_.Exception.Message
            Write-Status "Failed to install .NET with below error: $ErrorMessage"
            throw "Failed to install .NET with below error: $ErrorMessage"
        }
    }

    [bool] Test() {
        Write-Status "Checking .NET Framework installation status"
        $NETval = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full" -Name "Release"

        If ($NETval.Release -ge $this.NetVersion) {
            Write-Host ".NET $($this.FileName) or greater $($NETval.Release) is installed"
            return $true
        }

        return $false
    }

    [InstallDotNet4] Get() {
        return $this
    }
}


[DscResource()]
class InstallReportBuilder {
    [DscProperty(Key)]
    [string] $Path

    [DscProperty(Mandatory)]
    [Ensure] $Ensure

    [DscProperty(Mandatory)]
    [string] $URL

    [DscProperty(NotConfigurable)]
    [Nullable[datetime]] $CreationTime

    [void] Set() {
        $_Path = $this.Path
        $_URL = $this.URL

        Invoke-DownloadFile $_URL $_Path

        Install-MSIPackage `
            -MsiPath $_Path `
            -DisplayName "Report Builder" `
            -LogPath "C:\temp\reportbuilder.log"
    }

    [bool] Test() {

        Write-Status "Checking Report Builder installation status"
        $_path = $this.Path

        if (-not (Test-Path -Path $_path)) {
            return $false
        }

        try {

            $product = Get-InstalledProducts | Where-Object { $_.ProductName -like "*Report Builder*" }

            if (-not $product) {
                return $false
            }

            return $true
       
        }
        catch {
            return $false
        }
    }

    [InstallReportBuilder] Get() {
        return $this
    }
}
[DscResource()]
class InstallODBCDriver {
    [DscProperty(Key)]
    [string] $ODBCPath

    [DscProperty(Mandatory)]
    [Ensure] $Ensure

    [DscProperty(Mandatory)]
    [string] $URL

    [DscProperty(NotConfigurable)]
    [Nullable[datetime]] $CreationTime

    [void] Set() {
        $_odbcpath = $this.ODBCPath
        $_URL = $this.URL

        Invoke-DownloadFile $_URL $_odbcpath

        Install-MSIPackage `
            -MsiPath $_odbcpath `
            -DisplayName "Microsoft ODBC Driver 18 for SQL Server" `
            -AdditionalArguments @("IACCEPTMSODBCSQLLICENSETERMS=YES") `
            -LogPath "C:\temp\odbcinstallation.log" `
            -VerifyRegistryPath "HKLM:\Software\Microsoft\MSODBCSQL18" `
            -VerifyRegistryValueName "InstalledVersion"
    }

    [bool] Test() {
        Write-Status "Checking ODBC Driver 18 installation status"

        try {
            $ODBCRegistryPath = "HKLM:\Software\Microsoft\MSODBCSQL18"

            if (Test-Path -Path $ODBCRegistryPath) {
                try {
                    # Get the InstalledVersion only if the path exists
                    $ODBCVersion = Get-ItemProperty -Path $ODBCRegistryPath -Name "InstalledVersion" -ErrorAction SilentlyContinue
                }
                catch {
                    $ErrorMessage = $_.Exception.Message
                    Write-Verbose "Microsoft ODBC Driver 18 for SQL Server Error $($ErrorMessage)!"

                    return $false
                }
            }
            else {
                return $false
            }

            If ($ODBCVersion.InstalledVersion -ge "18.1.2.1") {
                Write-Host "Microsoft ODBC Driver for SQL Server 18.1.2.1 or greater $($ODBCVersion.InstalledVersion) is installed"
                return $true
            }

            return $false
        }
        catch {
            return $false
        }
    }

    [InstallODBCDriver] Get() {
        return $this
    }
}

[DscResource()]
class InstallOleDbDriver {
    [DscProperty(Key)]
    [string] $Path

    [DscProperty(Mandatory)]
    [Ensure] $Ensure

    [DscProperty(Mandatory)]
    [string] $URL

    [DscProperty(NotConfigurable)]
    [Nullable[datetime]] $CreationTime

    [void] Set() {
        $_msipath = $this.Path
        $_URL = $this.URL

        Invoke-DownloadFile $_URL $_msipath

        Install-MSIPackage `
            -MsiPath $_msipath `
            -DisplayName "Microsoft OLEDB Driver 19" `
            -AdditionalArguments @("IACCEPTMSOLEDBSQLLICENSETERMS=YES") `
            -LogPath "C:\temp\msoledbsql.install.log" `
            -VerifyRegistryPath "HKLM:\SOFTWARE\Microsoft\MSOLEDBSQL19" `
            -VerifyRegistryValueName "InstalledVersion"
    }

    [bool] Test() {
        $packageName = "Microsoft OLEDB Driver 19"
        Write-Status "Checking $packageName installation status"
        try {
            $InstallRegistryPath = "HKLM:\SOFTWARE\Microsoft\MSOLEDBSQL19"

            if (Test-Path -Path $InstallRegistryPath) {
                try {
                    # Get the InstalledVersion only if the path exists
                    $InstallVersion = Get-ItemProperty -Path $InstallRegistryPath -Name "InstalledVersion" -ErrorAction SilentlyContinue
                }
                catch {
                    $ErrorMessage = $_.Exception.Message
                    Write-Verbose "$packageName Error $($ErrorMessage)!"

                    return $false
                }
            }
            else {
                return $false
            }

            If ($InstallVersion.InstalledVersion -ge "19.2.0.0") {
                Write-Host "$packageName 19.2.0.0 or greater $($InstallVersion.InstalledVersion) is installed"
                return $true
            }

            return $false
        }
        catch {
            return $false
        }
    }

    [InstallOleDbDriver] Get() {
        return $this
    }
}
[DscResource()]
class InstallSqlClient {
    [DscProperty(Key)]
    [string] $Path

    [DscProperty(Mandatory)]
    [Ensure] $Ensure

    [DscProperty(Mandatory)]
    [string] $URL

    [DscProperty(NotConfigurable)]
    [Nullable[datetime]] $CreationTime

    [void] Set() {
        $_path = $this.Path
        $_URL = $this.URL
        Invoke-DownloadFile $_URL $_path

        Install-MSIPackage `
            -MsiPath $_path `
            -DisplayName "SQL Server Native Client 11" `
            -AdditionalArguments @("IACCEPTSQLNCLILICENSETERMS=YES") `
            -LogPath "C:\temp\sqlncli.install.log" `
            -VerifyRegistryPath "HKLM:\SOFTWARE\Microsoft\SQLNCLI11" `
            -VerifyRegistryValueName "InstalledVersion"
    }

    [bool] Test() {
        Write-Status "Checking SQL Native Client 11 installation status"
        try {
            $RegistryPath = "HKLM:\SOFTWARE\Microsoft\SQLNCLI11"

            if (Test-Path -Path $RegistryPath) {
                try {
                    # Get the InstalledVersion only if the path exists
                    $Version = Get-ItemProperty -Path $RegistryPath -ErrorAction SilentlyContinue
                }
                catch {
                    $ErrorMessage = $_.Exception.Message
                    Write-Verbose "Sql Client Error $($ErrorMessage)!"

                    return $false
                }
            }
            else {
                return $false
            }

            If ([System.Version]$($Version.InstalledVersion) -ge [System.Version]"11.4.7001.0") {
                Write-Host "Sql Client 11.4.7001.0 or greater $($Version.InstalledVersion) is installed"
                return $true
            }

            return $false
        }
        catch {
            return $false
        }
    }

    [InstallSqlClient] Get() {
        return $this
    }
}

[DscResource()]
class InstallVCRedist {
    [DscProperty(Key)]
    [string] $Path

    [DscProperty(Mandatory)]
    [Ensure] $Ensure

    [DscProperty(Mandatory)]
    [string] $URL

    [DscProperty(NotConfigurable)]
    [Nullable[datetime]] $CreationTime

    [void] Set() {
        $_path = $this.Path
        $_URL = $this.URL

        Invoke-DownloadFile $_URL $_path

        # Sanity-check the downloaded bootstrapper -- vc_redist.{x64,x86}.exe
        # is ~25MB / ~14MB respectively. If WebClient/BITS handed us a tiny
        # redirect body, an HTML error page from a misbehaving proxy, etc.,
        # the "install" will exit in milliseconds and we'll happily move on
        # to OLE DB which then fails its VCRedistCheck CA. Catch that here.
        $minBytes = if ($_path -like "*x64*") { 20MB } else { 10MB }
        $fi = Get-Item -LiteralPath $_path -ErrorAction SilentlyContinue
        if (-not $fi -or $fi.Length -lt $minBytes) {
            $sz = if ($fi) { $fi.Length } else { 0 }
            throw "VC Redist download is suspect: $_path is $sz bytes (need >= $minBytes). URL=$_URL"
        }

        # Install
        #VC_redist.x64.exe /install /passive /quiet
        $cmd = $_path
        $logFile = if ($_path -like "*x64*") { "c:\temp\vc_redistx64.log" } else { "c:\temp\vc_redistx86.log" }
        $argList = @('/install', '/quiet', '/norestart', '/log', $logFile)

        try {
            Write-Status "Installing VC Redist $_path..."
            Write-Verbose ("Commandline: $cmd $($argList -join ' ')")
            # Use Start-Process so we actually capture the exit code.
            # VC Redist bootstrapper exit codes:
            #   0     success
            #   1638  newer version already installed (treat as success)
            #   3010  success, reboot required (treat as success)
            #   1602  user canceled
            #   1603  fatal install error
            #   5100  prereq check failed
            $proc = Start-Process -FilePath $cmd -ArgumentList $argList -Wait -PassThru -NoNewWindow
            $exit = $proc.ExitCode
            $ok = @(0, 1638, 3010)
            if ($ok -notcontains $exit) {
                $logTail = ""
                if (Test-Path $logFile) {
                    try { $logTail = (Get-Content -LiteralPath $logFile -Tail 30 -ErrorAction SilentlyContinue) -join "`n" } catch {}
                }
                throw "VC Redist $_path failed (exit $exit). Log: $logFile`nTail:`n$logTail"
            }
            Write-Status "VC Redist $_path bootstrapper exited (exit $exit). Waiting for install to settle..."

            # The WiX Burn bootstrapper for vc_redist detaches an elevated
            # worker and returns from the parent process almost immediately
            # (observed: parent exits in ~1.3s while child MSIs run for
            # another 8-10s -- vcRuntimeMinimum then vcRuntimeAdditional).
            # Start-Process -Wait only waits for the launched process, not
            # its detached children. If we move on now, the next DSC
            # resource (e.g. InstallOleDbDriver) starts and its
            # VCRedistCheck CA reads a stale/in-flight registry state and
            # fails with "requires VS2022 redist 14.34+".
            #
            # Wait for both the bundle's Package Cache uninstall key to
            # appear AND for one of the child MSI logs (whichever the
            # bundle writes) to contain a "Shutting down, exit code"
            # line. Poll up to 120s; that covers slow disks and AV
            # scanning the cached MSIs.
            $bundleKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
            $childLogPattern = if ($_path -like "*x64*") {
                "c:\temp\vc_redistx64_*_vcRuntime*_x64.log"
            } else {
                "c:\temp\vc_redistx86_*_vcRuntime*_x86.log"
            }
            $deadline = (Get-Date).AddSeconds(120)
            $settled = $false
            while ((Get-Date) -lt $deadline) {
                # Look for any vcRuntime child MSI log whose tail shows
                # MainEngineThread returning (msiexec completed).
                $childLogs = @(Get-ChildItem -Path $childLogPattern -ErrorAction SilentlyContinue)
                if ($childLogs.Count -ge 1) {
                    $allDone = $true
                    foreach ($cl in $childLogs) {
                        $tail = $null
                        try { $tail = (Get-Content -LiteralPath $cl.FullName -Tail 5 -ErrorAction SilentlyContinue) -join "`n" } catch {}
                        if (-not $tail -or $tail -notmatch 'MainEngineThread is returning|=== Verbose logging stopped') {
                            $allDone = $false
                            break
                        }
                    }
                    if ($allDone) { $settled = $true; break }
                }
                Start-Sleep -Milliseconds 500
            }
            if (-not $settled) {
                Write-Status ("VC Redist {0}: child MSI logs did not settle within 120s; proceeding anyway (registry will be re-checked next)." -f $_path)
            } else {
                Write-Status ("VC Redist {0}: child MSI install completed." -f $_path)
            }
        }
        catch {
            $ErrorMessage = $_.Exception.Message
            Write-Status "Failed to install VC Redist with error: $ErrorMessage"
            throw "Failed to install VC Redist with error: $ErrorMessage"
        }

        # Verify post-install -- not just that the key exists, but that the
        # Bld DWORD is high enough. OLE DB Driver 19's VCRedistCheck custom
        # action reads Bld and compares to 14.34 (build 33135). If our Set
        # ran but registry still shows older Bld, fail loudly here rather
        # than letting OLE DB blow up downstream.
        $regPath = if ($_path -like "*x64*") {
            "HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\X64"
        } else {
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\14.0\VC\Runtimes\X86"
        }
        if (-not (Test-Path $regPath)) {
            throw "VC Redist install reported success but registry $regPath is missing."
        }
        # Bld DWORD updates after the child MSI commits; if we read it
        # right when the bundle exits, it can still show the old value.
        # Poll up to 30s.
        $deadline2 = (Get-Date).AddSeconds(30)
        $major = 0; $minor = 0; $bld = 0; $v = $null
        while ((Get-Date) -lt $deadline2) {
            $v = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue
            $major = [int]($v.Major); $minor = [int]($v.Minor); $bld = [int]($v.Bld)
            if ($major -ge 14 -and (($minor -gt 34) -or ($minor -eq 34 -and $bld -ge 33135))) { break }
            Start-Sleep -Milliseconds 500
        }
        Write-Status ("VC Redist registered: Major={0} Minor={1} Bld={2} Installed={3} InstalledVersion={4} ({5})" -f $major, $minor, $bld, $v.Installed, $v.Version, $regPath)
        if ($major -lt 14 -or ($major -eq 14 -and $minor -lt 34) -or ($major -eq 14 -and $minor -eq 34 -and $bld -lt 33135)) {
            throw "VC Redist install reported success but $regPath shows Major=$major Minor=$minor Bld=$bld (need >= 14.34, Bld >= 33135 for OLE DB Driver 19)."
        }
    }

    [bool] Test() {
        Write-Status "Checking VC++ Redistributable installation status"
        try {
            # OLE DB Driver 19's VCRedistCheck CA reads Bld DWORD; require
            # at least 14.34 (Bld 33135). Major.Minor alone isn't enough --
            # an old runtime can register Major=14, Minor=34, Bld=0.
            if ($this.Path -like "*x64*") {
                $RegistryPath = "HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\X64"
            }
            else {
                $RegistryPath = "HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\14.0\VC\Runtimes\X86"
            }

            if (-not (Test-Path -Path $RegistryPath)) { return $false }

            $v = Get-ItemProperty -Path $RegistryPath -ErrorAction SilentlyContinue
            if (-not $v) { return $false }
            $major = [int]($v.Major); $minor = [int]($v.Minor); $bld = [int]($v.Bld)
            Write-Verbose "VC Redist registry: Major=$major Minor=$minor Bld=$bld at $RegistryPath"

            # Require Major.Minor >= 14.42 OR (>= 14.34 with Bld set). We
            # bump our floor to 14.42 (current aka.ms/vs/17 release) so a
            # baseimage with an ancient stub doesn't satisfy Test() and
            # silently leave OLE DB to discover the gap later.
            if ($major -lt 14) { return $false }
            if ($major -eq 14 -and $minor -lt 42) { return $false }
            # Defense in depth: even at 14.42, require Bld DWORD present
            # and non-trivial. Real installs always set Bld; absent means
            # half-installed or hand-poked.
            if ($bld -lt 33135) { return $false }
            Write-Host "VC Redist 14.42+ (Bld $bld) is installed at $RegistryPath"
            return $true
        }
        catch {
            return $false
        }
    }

    [InstallVCRedist] Get() {
        return $this
    }
}

[DscResource()]
class InstallPMPC {
    [DscProperty(Key)]
    [string] $Path

    [DscProperty(Mandatory)]
    [Ensure] $Ensure

    [DscProperty(Mandatory)]
    [string] $URL

    [DscProperty(Mandatory)]
    [string] $SiteCode

    [DscProperty(Mandatory)]
    [string] $SqlServer

    [DscProperty(Mandatory)]
    [string] $SiteServer

    [DscProperty(Mandatory)]
    [string] $FileServer
   
    [void] Set() {
        $_path = $this.Path
        $_URL = $this.URL

        $Name = "Patch my PC"
        Invoke-DownloadFile $_URL $_path

        Install-MSIPackage `
            -MsiPath $_Path `
            -DisplayName $Name `
            -LogPath "C:\temp\pmpc.log"

        $SettingsXML = Get-Content "C:\Staging\DSC\Phases\PMPC.Settings.Template" -Raw
        $SettingsXML = $SettingsXML.Replace("TEMPLATESITECODE", $this.SiteCode)
        $SettingsXML = $SettingsXML.Replace("TEMPLATESQLSERVER", $this.SqlServer)
        $SettingsXML = $SettingsXML.Replace("TEMPLATESITESERVER", $this.SiteServer)
        $SettingsXML = $SettingsXML.Replace("TEMPLATEFILESERVER", $this.FileServer)
        stop-service -name PatchMyPCService
 
        $SettingsXML | out-file "C:\Program Files\Patch My PC\Patch My PC Publishing Service\Settings.xml" -Force -Encoding utf8
        $SupportedProduct = Get-Content "C:\Staging\DSC\Phases\PMPC.SupportedProducts.Template" -Raw
        $SupportedProduct | out-file "C:\Program Files\Patch My PC\Patch My PC Publishing Service\SupportedProducts.xml" -Force -Encoding utf8
        start-service -name PatchMyPCService 
        start-sleep -seconds 120
        & "C:\Program Files\Patch My PC\Patch My PC Publishing Service\PatchMyPC-Settings.exe" /SyncNow
    }

    [bool] Test() {
        Write-Status "Checking Patch My PC installation status"
        if ((Test-Path -Path "C:\Program Files\Patch My PC\Patch My PC Publishing Service\Settings.xml")) {
            return $true
        }        
        return $false
    }

    [InstallPMPC] Get() {
        
        return $this
    }

}


[DscResource()]
class InstallConsole {
    [DscProperty(Key)]
    [string] $SiteServerFQDN
    [DscProperty(Mandatory)]
    [string] $CMInstallDir
   
    [void] Set() {
        $_SiteServer = $this.SiteServerFQDN
        $_CMInstallDir = $this.CMInstallDir

        if ($null -eq $_SiteServer) {
            Write-Status "SiteServerFQDN is null, cannot install SCCM Console"
            throw "SiteServerFQDN is null, cannot install SCCM Console"
        }
        if ($null -eq $_CMInstallDir) {
            Write-Status "CMInstallDir is null, cannot install SCCM Console"
            throw "CMInstallDir is null, cannot install SCCM Console"
        }

        Write-Status "Installing SCCM Console..."
        & C:\staging\DSC\phases\Install-Console.ps1 -SiteServer $_SiteServer -CMInstallDir $_CMInstallDir
        Write-Status "Finished installing SCCM Console... Rebooting"  
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUserDeclaredVarsMoreThanAssignments', '', Scope = 'Function')]
        $global:DSCMachineStatus = 1      
    }

    [bool] Test() {
        Write-Status "Checking ConfigMgr Console installation status"
        try {
            $key = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry32)
        }
        catch {
            return $false
        }
        if (-not $key) {
            return $false
        }
        $subKey = $key.OpenSubKey("SOFTWARE\Microsoft\ConfigMgr10\Setup")
        if ($subKey) {
            $uiInstallPath = $subKey.GetValue("UI Installation Directory")
        }
        else {
            return $false
        }
        if ($uiInstallPath) {
            return $true
        }
        return $false
    }

    [InstallConsole] Get() {
        
        return $this
    }

}

[DscResource()]
class WriteEvent {

    [DscProperty(Mandatory)]
    [string] $LogPath

    [DscProperty(Mandatory = $false)]
    [string] $FileName

    [DscProperty(Key)]
    [string] $WriteNode

    [DscProperty(Mandatory)]
    [string] $Status

    [DscProperty(Mandatory)]
    [Ensure] $Ensure

    [DscProperty(NotConfigurable)]
    [Nullable[datetime]] $CreationTime

    [void] Set() {
        $_FileName = "DSC_Events"
        if ($this.FileName) {
            $_FileName = $this.FileName
        }
        $_Node = $this.WriteNode
        $_Status = $this.Status
        $_LogPath = $this.LogPath
        $ConfigurationFile = Join-Path -Path $_LogPath -ChildPath "$_FileName.json"
        $Configuration = Get-Content -Path $ConfigurationFile | ConvertFrom-Json
        Write-Status "Setting event $_Node to $_Status in $_LogPath"
        $Configuration.$_Node.Status = $_Status
        $Configuration.$_Node.EndTime = Get-Date -format "yyyy-MM-dd HH:mm:ss"

        $Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force
    }

    [bool] Test() {
        $_FileName = "DSC_Events"
        if ($this.FileName) {
            $_FileName = $this.FileName
        }
        $_LogPath = $this.LogPath
        $Configuration = ""
        $ConfigurationFile = Join-Path -Path $_LogPath -ChildPath "$_FileName.json"
        if (Test-Path -Path $ConfigurationFile) {
            $Configuration = Get-Content -Path $ConfigurationFile | ConvertFrom-Json
        }
        else {
            if (-not $this.FileName) {
                # For named-file, caller must ensure file exists with required nodes.
                [hashtable]$Actions = @{
                    ConfigurationFinished = @{
                        Status    = 'NotStart'
                        StartTime = ''
                        EndTime   = ''
                    }
                }
                $Configuration = New-Object -TypeName psobject -Property $Actions
                $Configuration | ConvertTo-Json | Out-File -FilePath $ConfigurationFile -Force
            }
        }

        return $false
    }

    [WriteEvent] Get() {
        return $this
    }
}

[DscResource()]
class WaitForEvent {

    [DscProperty(Key)]
    [string] $MachineName

    [DscProperty(Mandatory)]
    [string] $LogFolder

    [DscProperty(Mandatory = $false)]
    [string] $FileName

    [DscProperty(Key)]
    [string] $ReadNode

    [DscProperty(Mandatory)]
    [string] $ReadNodeValue

    [DscProperty(Mandatory)]
    [Ensure] $Ensure

    [DscProperty(NotConfigurable)]
    [Nullable[datetime]] $CreationTime

    [void] Set() {
        $_FileName = "DSC_Events"
        if ($this.FileName) {
            $_FileName = $this.FileName
        }

        $_FilePath = "\\$($this.MachineName)\$($this.LogFolder)"
        $ConfigurationFile = Join-Path -Path $_FilePath -ChildPath "$_FileName.json"

        while (!(Test-Path $ConfigurationFile)) {
            Write-Verbose "Wait for configuration file to exist on $($this.MachineName), will try again in 30 seconds..."
            Start-Sleep -Seconds 30
            $ConfigurationFile = Join-Path -Path $_FilePath -ChildPath "$_FileName.json"
        }

        $mtx = New-Object System.Threading.Mutex($false, "$_FileName")
        Write-Verbose "Attempting to acquire '$_FileName' Mutex"
        [void]$mtx.WaitOne()
        Write-Verbose "Acquired '$_FileName' Mutex"
        $Configuration = $null
        try {
            $Configuration = Get-Content -Path $ConfigurationFile -ErrorAction Ignore | ConvertFrom-Json
        }
        finally {
            [void]$mtx.ReleaseMutex()
            [void]$mtx.Dispose()
        }
        while ($Configuration.$($this.ReadNode).Status -ne $this.ReadNodeValue) {
            Write-Verbose "Wait for step: [$($this.ReadNode)] to finish on $($this.MachineName), will try again in 30 seconds..."
            Start-Sleep -Seconds 30
            $mtx = New-Object System.Threading.Mutex($false, "$_FileName")
            Write-Verbose "Attempting to acquire '$_FileName' Mutex"
            [void]$mtx.WaitOne()
            Write-Verbose "Acquired '$_FileName' Mutex"
            try {
                $Configuration = Get-Content -Path $ConfigurationFile | ConvertFrom-Json
            }
            finally {
                [void]$mtx.ReleaseMutex()
                [void]$mtx.Dispose()
            }
        }
        Write-Status "Step: [$($this.ReadNode)] Finished on $($this.MachineName)"
    }

    [bool] Test() {
        $_FileName = "DSC_Events"
        if ($this.FileName) {
            $_FileName = $this.FileName
        }
        $_FilePath = "\\$($this.MachineName)\$($this.LogFolder)"
        $ConfigurationFile = Join-Path -Path $_FilePath -ChildPath "$_FileName.json"

        if (!(Test-Path $ConfigurationFile)) { return $false }
        $mtx = New-Object System.Threading.Mutex($false, "$_FileName")
        Write-Verbose "Attempting to acquire '$_FileName' Mutex"
        [void]$mtx.WaitOne()
        Write-Verbose "acquired '$_FileName' Mutex"
        try {
            $Configuration = Get-Content -Path $ConfigurationFile -ErrorAction Ignore | ConvertFrom-Json
            if ($Configuration.$($this.ReadNode).Status -eq $this.ReadNodeValue) {
                return $true
            }
            return $false
        }
        catch {
            return $false
        }
        finally {
            [void]$mtx.ReleaseMutex()
            [void]$mtx.Dispose()
        }

        return $false

    }

    [WaitForEvent] Get() {
        return $this
    }
}

[DscResource()]
class WaitForExtendSchemaFile {
    [DscProperty(Key)]
    [string] $MachineName

    [DscProperty(Mandatory)]
    [string] $ExtFolder

    [DscProperty(Mandatory)]
    [Ensure] $Ensure

    [DscProperty()]
    [System.Management.Automation.PSCredential] $AdminCreds

    [DscProperty(NotConfigurable)]
    [Nullable[datetime]] $CreationTime

    [void] Set() {

        Write-Status "Extend Schema. Testing network connection"
        $success = $false
        while ($success -eq $false) {
            if ($this.AdminCreds) {
                $user = $this.AdminCreds.UserName
                $pass = $this.AdminCreds.GetNetworkCredential().Password
                $machine = "\\$($this.MachineName)"
                Write-Verbose "Running New-SmbMapping -RemotePath \\$machine -UserName $user -Password $pass"
                Write-Status "Testing connection to \\$machine for user $user"
                $smb = New-SmbMapping -RemotePath $machine -UserName $user -Password $pass
                if ($smb) {
                    Write-Verbose "Mapping success: $smb"
                    $success = $true
                }
                else {
                    Write-Status "Could not get a connection to \\$machine for user $user. Retrying."
                    Write-Verbose "Mapping Failure.."
                    start-sleep -Seconds 30
                }
            }
            else {
                Write-Verbose "No AdminCreds passed.. Moving on"
                $success = $true
            }
        }

        $_FilePath = "\\$($this.MachineName)\$($this.ExtFolder)"
        $extadschpath = Join-Path -Path $_FilePath -ChildPath "SMSSETUP\BIN\X64\extadsch.exe"
        $extadschpath2 = Join-Path -Path $_FilePath -ChildPath "cd.retail\SMSSETUP\BIN\X64\extadsch.exe"
        $extadschpath3 = Join-Path -Path $_FilePath -ChildPath "cd.retail.LN\SMSSETUP\BIN\X64\extadsch.exe"
        $extadschpath4 = Join-Path -Path $_FilePath -ChildPath "cd.preview\SMSSETUP\BIN\X64\extadsch.exe"
        while (!(Test-Path $extadschpath) -and !(Test-Path $extadschpath2) -and !(Test-Path $extadschpath3) -and !(Test-Path $extadschpath4)) {
            Write-Verbose "Testing $extadschpath and $extadschpath2 and $extadschpath3"
            Write-Status "Wait for extadsch.exe exist on $($this.MachineName), will try 10 seconds later..."
            Start-Sleep -Seconds 10
            $extadschpath = Join-Path -Path $_FilePath -ChildPath "SMSSETUP\BIN\X64\extadsch.exe"
            $extadschpath2 = Join-Path -Path $_FilePath -ChildPath "cd.retail\SMSSETUP\BIN\X64\extadsch.exe"
            $extadschpath3 = Join-Path -Path $_FilePath -ChildPath "cd.retail.LN\SMSSETUP\BIN\X64\extadsch.exe"
            $extadschpath4 = Join-Path -Path $_FilePath -ChildPath "cd.preview\SMSSETUP\BIN\X64\extadsch.exe"
        }

        Write-Status "Extending the Active Directory schema..."

        # Force AD Replication (job-based with timeout; repadmin can hang if a
        # DC's NTDS is still initializing, e.g. BDC just promoted)
        $domainControllers = Get-ADDomainController -Filter * -ErrorAction SilentlyContinue
        if ($domainControllers.Count -gt 1) {
            Write-Status "Forcing AD Replication on $($domainControllers.Name -join ',')"
            $dcNames = @($domainControllers.Name)
            $dn = (Get-ADDomain).DistinguishedName
            $replJob = Start-Job -ScriptBlock {
                param($dcNames, $dn)
                $dcNames | ForEach-Object { repadmin /syncall $_ $dn /AdeP 2>&1 | Out-Null }
            } -ArgumentList $dcNames, $dn
            $null = Wait-Job $replJob -Timeout 60
            if ($replJob.State -eq 'Running') {
                Stop-Job $replJob -ErrorAction SilentlyContinue
            }
            Remove-Job $replJob -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 3
        }

        if (Test-Path $extadschpath) {
            Write-Status "Running $extadschpath"
            & $extadschpath | out-null
        }
        if (Test-Path $extadschpath2) {
            Write-Status "Running $extadschpath2"
            & $extadschpath2 | out-null
        }

        if (Test-Path $extadschpath3) {
            Write-Status "Running $extadschpath3"
            & $extadschpath3 | out-null
        }

        if (Test-Path $extadschpath4) {
            Write-Status "Running $extadschpath4"
            & $extadschpath4 | out-null
        }
        Write-Status "Done Extending Schema"
    }

    [bool] Test() {
        return $false
    }

    [WaitForExtendSchemaFile] Get() {
        return $this
    }
}

[DscResource()]
class DelegateControl {
    [DscProperty(Key)]
    [string] $Machine

    [DscProperty(Mandatory)]
    [string] $DomainFullName

    [DscProperty(Mandatory)]
    [Ensure] $Ensure

    [DscProperty()]
    [bool] $IsGroup

    [DscProperty(NotConfigurable)]
    [Nullable[datetime]] $CreationTime

    # Helper method to join multi-line dsacls output
    hidden [string[]] JoinDsaclsOutput([string[]] $rawOutput) {
        $joinedLines = @()
        $currentLine = ""

        foreach ($line in $rawOutput) {
            if ($line -match '^\s{2,}' -and $currentLine) {
                # This is a continuation line - append to current
                $currentLine += " " + $line.Trim()
            }
            else {
                # This is a new entry - save previous and start new
                if ($currentLine) { $joinedLines += $currentLine }
                $currentLine = $line
            }
        }
        if ($currentLine) { $joinedLines += $currentLine }
        
        return $joinedLines
    }

    # Helper method to check if permissions exist
    hidden [bool] CheckPermissions([string[]] $permissionInfo, [string] $machineName, [string] $domainName) {
        # Join multi-line output
        $joinedLines = $this.JoinDsaclsOutput($permissionInfo)
        
        if ($this.IsGroup) {
            $searchPattern = "*$domainName\$machineName*FULL CONTROL*"
            Write-Verbose "Searching for pattern: $searchPattern"
            $match = $joinedLines | Where-Object { $_ -like $searchPattern }
        }
        else {
            $searchPattern = "*$machineName`$*FULL CONTROL*"
            Write-Verbose "Searching for pattern: $searchPattern"
            $match = $joinedLines | Where-Object { $_ -like $searchPattern }
        }
        
        if ($match) {
            Write-Verbose "Found matching permission: $match"
            return $true
        }
        
        return $false
    }

    [void] Set() {
        $_machinename = $this.Machine
        $root = (Get-ADRootDSE).defaultNamingContext
        $ou = $null

        
        try {
            Write-Status "Getting AD Object: CN=System Management,CN=System,$root"
            $ou = Get-ADObject "CN=System Management,CN=System,$root"
        }
        catch {
            Write-Verbose "System Management container does not currently exist."
        }
        if ($null -eq $ou) {
            Write-Status "Creating new AD Object: CN=System Management,CN=System,$root"
            $ou = New-ADObject -Type Container -name "System Management" -Path "CN=System,$root" -Passthru
        }
        $DomainName = $this.DomainFullName.split('.')[0]
        #Delegate Control
        $cmd = "dsacls.exe"
        $arg1 = "CN=System Management,CN=System,$root"
        $arg2 = "/G"
        if ($this.IsGroup) {
            $arg3 = "" + $this.DomainFullName + "\" + $this.Machine + "`:GA;;"
        }
        else {
            $arg3 = "" + $DomainName + "\" + $this.Machine + "`$:GA;;"

        }
        $arg4 = "/I:T"


        $retries = 0
        $maxretries = 15
        while ($retries -le $maxretries) {

            Clear-DnsClientCache -ErrorAction SilentlyContinue

            if ($retries -eq 5) {
                $_FileName = "C:\temp\SysMgmt.txt"

                if (-not (Test-Path $_FileName)) {
                    Write-Status "dsacls.exe failed to add permissions 5 time.. Attempting reboot."
                    Write-Verbose "Rebooting"
                    New-Item $_FileName
                    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUserDeclaredVarsMoreThanAssignments', '', Scope = 'Function')]
                    $global:DSCMachineStatus = 1
                    return
                }
            }

            $retries++
            Write-Status "Running dsacls.exe to add FULL Control ($arg3) to $arg1. Try $retries/$maxretries"
            Write-Verbose "Running $cmd $arg1 $arg2 $arg3 $arg4"
            $result = & $cmd $arg1 $arg2 $arg3 $arg4 *>&1
            $dsaclsExitCode = $LASTEXITCODE

            Write-Verbose "Result $result"
            Write-Verbose "dsacls.exe exit code: $dsaclsExitCode"

            # If dsacls.exe reported success (exit code 0), trust it and
            # do a quick verify. The old 60s-per-retry logic turned a
            # simple pattern-match problem into a 90-minute wait.
            if ($dsaclsExitCode -eq 0) {
                Start-Sleep -Seconds 2
            }

            $tcmd = "dsacls.exe"
            $targ1 = "CN=System Management,CN=System,$root"
            $permissioninfo = & $tcmd $targ1

            # Use helper method to check permissions
            if ($this.CheckPermissions($permissioninfo, $_machinename, $DomainName)) {
                Write-Verbose "Permissions verified successfully"
                break
            }

            # If dsacls.exe said it succeeded but our pattern match failed,
            # log diagnostic info and try a case-insensitive fallback check
            # before sleeping.
            if ($dsaclsExitCode -eq 0) {
                Write-Status "dsacls.exe returned success but verification pattern did not match - checking with relaxed match"
                $joinedLines = $this.JoinDsaclsOutput($permissioninfo)
                # Relaxed check: look for the machine name anywhere with
                # any form of "FULL CONTROL" or "GA" (Generic All)
                $relaxedMatch = $joinedLines | Where-Object {
                    $_ -match [regex]::Escape($_machinename) -and ($_ -match 'FULL CONTROL' -or $_ -match 'Generic All')
                }
                if ($relaxedMatch) {
                    Write-Status "Relaxed verification passed for $_machinename"
                    Write-Verbose "Matched line: $relaxedMatch"
                    break
                }
                Write-Verbose "Relaxed match also failed. dsacls output sample:"
                $joinedLines | Select-Object -First 20 | ForEach-Object { Write-Verbose "  $_" }
            }

            Write-Verbose "$tcmd $targ1 did not contain the new permissions. Sleeping 10 seconds and trying again"
            Write-Verbose "$permissioninfo"
            Start-Sleep -Seconds 10

        }


    }

    [bool] Test() {
        Write-Status "Checking AD System Management container delegation"
        $_machinename = $this.Machine
        $DomainName = $this.DomainFullName.split('.')[0]
        $root = (Get-ADRootDSE).defaultNamingContext
        try {
            Get-ADObject "CN=System Management,CN=System,$root"
        }
        catch {
            Write-Verbose "System Management container does not currently exist."
            return $false
        }

        Write-Verbose "Testing for permissions. IsGroup: $($this.IsGroup)"
        $cmd = "dsacls.exe"
        $arg1 = "CN=System Management,CN=System,$root"
        $permissioninfo = & $cmd $arg1

        # Use helper method to check permissions (strict pattern)
        if ($this.CheckPermissions($permissioninfo, $_machinename, $DomainName)) {
            return $true
        }

        # Relaxed fallback: the strict wildcard pattern can fail on some
        # Windows versions where dsacls.exe output format differs slightly.
        # Use regex to match machine name + full control indicator.
        $joinedLines = $this.JoinDsaclsOutput($permissioninfo)
        $relaxedMatch = $joinedLines | Where-Object {
            $_ -match [regex]::Escape($_machinename) -and ($_ -match 'FULL CONTROL' -or $_ -match 'Generic All')
        }
        if ($relaxedMatch) {
            Write-Verbose "Strict pattern missed but relaxed match found: $relaxedMatch"
            return $true
        }

        Write-Verbose "No permission match found for $_machinename"
        return $false
    }

    [DelegateControl] Get() {
        return $this
    }
}

[DscResource()]
class AddNtfsPermissions {
    [DscProperty(key)]
    [Ensure] $Ensure

    [DscProperty(NotConfigurable)]
    [Nullable[datetime]] $CreationTime

    [void] Set() {
        Write-Status "Adding NTFS permissions to C:\tools"
        $testPath = "C:\staging\DSC\AddNtfsPermissions.txt"
        & icacls C:\tools /grant "Users:(M,RX)" /t | Out-File $testPath -Force -ErrorAction SilentlyContinue
        & icacls C:\temp /grant "Users:F" /t | Out-File $testPath -Append -Force
        & takeown /F C:\windows\system32\Configuration /A /R | Out-File $testPath -Append -Force
        & icacls C:\windows\system32\Configuration /grant "Administrators:F" /t | Out-File $testPath -Append -Force
    }

    [bool] Test() {
        Write-Status "Checking NTFS permissions on C:\tools"
        $testPath = "C:\staging\DSC\AddNtfsPermissions.txt"
        if (Test-Path $testPath) {
            return $true
        }

        return $false
    }

    [AddNtfsPermissions] Get() {
        return $this
    }
}

[DscResource()]
class DownloadSCCM {
    [DscProperty(Key)]
    [string] $CM

    [DscProperty(Key)]
    [string] $CMDownloadUrl

    [DscProperty(Mandatory)]
    [Ensure] $Ensure

    [DscProperty(NotConfigurable)]
    [Nullable[datetime]] $CreationTime

    [void] Set() {
        $_CM = $this.CM
        $_CMURL = $this.CMDownloadUrl
        $cmpath = "c:\temp\$_CM.exe"
        $cmsourcepath = "c:\$_CM"
        Write-Status "Downloading [$_CMURL] $_CM installation source... to $cmpath"

        if (Test-Path $cmpath) {
            stop-process -name $_CM -Force -ErrorAction SilentlyContinue
            Remove-Item -Path $cmpath -Recurse -Force | Out-Null
        }
        Invoke-DownloadFile $_CMURL $cmpath
        
        if (Test-Path $cmsourcepath) {
            Remove-Item -Path $cmsourcepath -Recurse -Force | Out-Null
        }

        if (!(Test-Path $cmsourcepath)) {

            Write-Status "Extracting $cmpath to $cmsourcepath"
            if (($_CMURL -like "*MCM_*") -or ($_CMURL -like "*go.microsoft.com*")) {
                $size = (Get-Item $cmpath).length / 1GB
                
                if ($size -gt 1 -or $_CM -eq "CMTP") {
                    Write-Status "Extracting $cmpath to $cmsourcepath using: Start-Process -Filepath ($cmpath) -ArgumentList ('-d' + $cmsourcepath + ' -s2') -Wait"
                    $process = Start-Process -Filepath ($cmpath) -ArgumentList ('-d' + $cmsourcepath + ' -s2') -Wait -PassThru
                    Write-Status "$cmPath return code: $($process.ExitCode)"
                }
                else {
                    Write-Status "Extracting $cmpath to $cmsourcepath using: Start-Process -Filepath ($cmpath) -ArgumentList ('/extract:"' + $cmsourcepath + '" /quiet') -Wait"
                    $process = Start-Process -Filepath ($cmpath) -ArgumentList ('/extract:"' + $cmsourcepath + '" /quiet') -Wait -PassThru
                    Write-Status "$cmPath return code: $($process.ExitCode)"
                }
            }
            else {
                Write-Status "Extracting $cmpath to $cmsourcepath using: Start-Process -Filepath ($cmpath) -ArgumentList ('/Auto "' + $cmsourcepath + '"') -Wait"
                $process = Start-Process -Filepath ($cmpath) -ArgumentList ('/Auto "' + $cmsourcepath + '"') -Wait -PassThru
                Write-Status "$cmPath return code: $($process.ExitCode)"
            }
        }
    }

    [bool] Test() {
        
        $_CM = $this.CM
        $cmpath = "c:\temp\$_CM.exe"
        if (!(Test-Path $cmpath)) {
            return $false
        }

        # if C:\CMCB does not exist, fail
        $cmsourcepath = "c:\$_CM"
        if (!(Test-Path $cmsourcepath)) {
            return $false
        }
        # if C:\CMCB is empty, fail
        if (!(Test-Path ($cmsourcepath + "\*"))) {
            return $false
        }

        return $true
    }

    [DownloadSCCM] Get() {
        return $this
    }
}

[DscResource()]
class DownloadFile {
    [DscProperty(Key)]
    [string] $DownloadUrl

    [DscProperty(Mandatory)]
    [Ensure] $Ensure

    [DscProperty(Mandatory)]
    [string] $FilePath

    [void] Set() {
        Write-Verbose "Downloading file from $($this.DownloadUrl) to $($this.FilePath)..."
        Invoke-DownloadFile $this.DownloadUrl $this.FilePath
    }

    [bool] Test() {
        #if (!(Test-Path $this.FilePath)) {
        #    return $false
        #}

        #If (!(Get-Item $this.FilePath).length -gt 0kb) {
        #    return $false
        #}

        #Let logic in Invoke-DownloadFile handle this
        return $false
    }

    [DownloadFile] Get() {
        return $this
    }
}

[DscResource()]
class WaitForDomainReady {
    [DscProperty(key)]
    [string] $DCName

    [DscProperty(Key)]
    [string] $DomainName

    [DscProperty(Mandatory = $false)]
    [int] $WaitSeconds = 10

    [DscProperty(Mandatory)]
    [Ensure] $Ensure

    [DscProperty(NotConfigurable)]
    [Nullable[datetime]] $CreationTime

    [void] Set() {
        $_DCName = $this.DCName
        $_DomainName = $this.DomainName
        $_WaitSeconds = $this.WaitSeconds
        $_DCFullName = "$_DCName.$_DomainName"
        Write-Verbose "Domain Controller is: $_DCName"
        $testconnection = test-connection -ComputerName $_DCFullName -ErrorAction Ignore
        while (!$testconnection) {
            Write-Status "Waiting for Domain ready. Trying to ping $_DCName, will try again in $_WaitSeconds seconds..."
            Clear-DnsClientCache -ErrorAction SilentlyContinue
            ipconfig /renew
            Register-DnsClient -ErrorAction SilentlyContinue
            Start-Sleep -Seconds $_WaitSeconds
            $testconnection = test-connection -ComputerName $_DCFullName -ErrorAction Ignore
        }
        Write-Status "Domain is ready now."
    }

    [bool] Test() {
        $_DCName = $this.DCName
        $_DomainName = $this.DomainName
        $_DCFullName = "$_DCName.$_DomainName"
        Write-Verbose "Domain computer is: $_DCFullName"
        $testconnection = test-connection -ComputerName $_DCFullName -ErrorAction Ignore

        if (!$testconnection) {
            ipconfig /renew
            return $false
        }

        Register-DnsClient -ErrorAction SilentlyContinue
        return $true
    }

    [WaitForDomainReady] Get() {
        return $this
    }
}

[DscResource()]
class VerifyComputerJoinDomain {
    [DscProperty(key)]
    [string] $ComputerName

    [DscProperty(Mandatory)]
    [Ensure] $Ensure

    [DscProperty(NotConfigurable)]
    [Nullable[datetime]] $CreationTime

    [void] Set() {
        $_Computername = $this.ComputerName
        $_ComputernameList = $_Computername.Split(',')
        foreach ($CL in $_ComputernameList) {
            $searcher = [adsisearcher] "(cn=$CL)"
            while ($searcher.FindAll().count -ne 1) {
                Write-Status "[adsisearcher] Waiting for $CL to join domain. Retrying in 30 Seconds."
                Start-Sleep -Seconds 30
                $searcher = [adsisearcher] "(cn=$CL)"
            }
            Write-Status "$CL has joined the domain."
        }
    }

    [bool] Test() {
        return $false
    }

    [VerifyComputerJoinDomain] Get() {
        return $this
    }
}

[DscResource()]
class MoveComputerToOU {
    [DscProperty(Key)]
    [string] $ComputerName

    [DscProperty(Mandatory)]
    [string] $TargetOU

    [DscProperty(Mandatory)]
    [Ensure] $Ensure

    [void] Set() {
        $_ComputerName = $this.ComputerName
        $_TargetOU = $this.TargetOU

        try {
            $computer = Get-ADComputer -Identity $_ComputerName -ErrorAction Stop
            $targetPath = $_TargetOU
            $currentOU = ($computer.DistinguishedName -split ',', 2)[1]

            if ($currentOU -ne $targetPath) {
                Write-Status "Moving $_ComputerName from $currentOU to $targetPath"
                Move-ADObject -Identity $computer.DistinguishedName -TargetPath $targetPath -ErrorAction Stop
                Write-Status "Successfully moved $_ComputerName to $targetPath"
            }
            else {
                Write-Status "$_ComputerName is already in $targetPath"
            }
        }
        catch {
            Write-Status "Failed to move $_ComputerName to $_TargetOU. Error: $_"
        }
    }

    [bool] Test() {
        $_ComputerName = $this.ComputerName
        $_TargetOU = $this.TargetOU

        try {
            $computer = Get-ADComputer -Identity $_ComputerName -ErrorAction Stop
            $currentOU = ($computer.DistinguishedName -split ',', 2)[1]
            return ($currentOU -eq $_TargetOU)
        }
        catch {
            return $false
        }
    }

    [MoveComputerToOU] Get() {
        return $this
    }
}

function Write-Status {
    param(
        [String] $Status
    )
    $_Status = $Status

    $StatusFile = "C:\staging\DSC\DSC_Status.txt"
    $StatusLog = "C:\staging\DSC\DSC_Log.log"
    try {
        Write-Verbose "Writing Status: $_Status"    

        try {
            try {
                [void](Get-Variable this -ErrorAction Stop)
                $Static = $false
            }
            catch {
                $Static = $true
            }
            if ($Static) {
                $prefix = (Get-PSCallStack)[1].FunctionName
            }
            else {
                $prefix = $this.gettype().Name
            }      
            if ($prefix -ne "WriteStatus") {
                $_Status = "$($prefix)`: $($_Status)"      
            }
        }
        catch {}
        $AlreadyComplete = $false
        $InCMSetup = $false
        if (Test-Path $StatusFile) {
            try {
                $AlreadyComplete = (Get-Content -Path $StatusFile -Force -ErrorAction SilentlyContinue) -eq "Complete!"
                $InCMSetup = (Get-Content -Path $StatusFile -Force -ErrorAction SilentlyContinue) -eq "Setting up ConfigMgr. See ConfigMgrSetup.log"
            }
            catch {}
        }

        if (-not $AlreadyComplete -and -not $InCMSetup) {
            "$_Status" | Out-File -FilePath $StatusFile -Force
        }
    
        try {
            try {
                $caller = (Get-PSCallStack | Select-Object Command, Location, Arguments)[1].Command
                if (-not $caller) {
                    $caller = $this.gettype().Name
                }
            }
            catch {}
            $Text = $_Status.ToString().Trim()
            $CallingFunction = Get-PSCallStack | Select-Object -first 2 | select-object -last 1
            $context = $CallingFunction.Command
            if (-not $context) {
                $context = $CallingFunction.FunctionName
            }
            $file = $CallingFunction.Location
            $tid = [System.Threading.Thread]::CurrentThread.ManagedThreadId
            $date = Get-Date -Format 'MM-dd-yyyy'
            $time = Get-Date -Format 'HH:mm:ss.fff'

            $logText = "<![LOG[$Text]LOG]!><time=""$time"" date=""$date"" component=""$caller"" context=""$context"" type=""Status"" thread=""$tid"" file=""$file"">"
            $logText | Out-File $StatusLog -Append -Encoding utf8
            Write-Progress -Activity $caller -Status $Text -PercentComplete 50
        }
        catch {
            try {
                # Retry once and ignore if failed
                $logText | Out-File $StatusLog -Append -ErrorAction SilentlyContinue -Encoding utf8
            }
            catch {
                $_Status | Out-File $StatusLog -Append -ErrorAction SilentlyContinue -Encoding utf8
            }
        }
    }
    catch {
        Write-Verbose $_
    }

}

[DscResource()]
class WriteStatus {
    [DscProperty(key)]
    [string] $Status

    [void] Set() {

        $_Status = $this.Status
        Write-Status $_Status 
    }

    [bool] Test() {
        # Always return false so Set() writes the current status.
        # Previously checked DSC_Log.log for the text, but that caused
        # skips on re-runs when the message was already in the log from
        # a prior attempt, leaving DSC_Status.txt stale.
        return $false
    }

    [WriteStatus] Get() {
        return $this
    }
}

[DscResource()]
class WriteFileOnce {
    [DscProperty(key)]
    [string] $FilePath

    [DscProperty(key)]
    [string] $Content

    [void] Set() {
        $_FilePath = $this.FilePath
        $_Content = $this.Content
        $flag = "$_FilePath.done"

        Write-Status "Writing specified content to $_FilePath"

        $_Content | Out-File -FilePath $_FilePath -Force
        "WriteFileOnce" | Out-File -FilePath $flag -Force

    }

    [bool] Test() {
        $_FilePath = $this.FilePath
        $_Content = $this.Content
        $flag = "$_FilePath.done"

        # Wrote once, don't do it again
        if (Test-Path $flag) {
            return $true
        }

        if (Test-Path $_FilePath) {
            Write-Verbose "Testing if $_FilePath contains specified content"
            $contains = (Get-Content -Path $_FilePath -Force) -eq $_Content
            if ($contains) {
                Write-Verbose "FilePath contains content."
                return $true
            }
        }

        Write-Verbose "FilePath does not contain content."
        return $false
    }

    [WriteFileOnce] Get() {
        return $this
    }
}

[DscResource()]
class ChangeSQLServicesAccount {
    [DscProperty(key)]
    [string] $SQLInstanceName

    [DscProperty(Mandatory)]
    [Ensure] $Ensure

    [DscProperty(NotConfigurable)]
    [Nullable[datetime]] $CreationTime

    [void] Set() {
        $_SQLInstanceName = $this.SQLInstanceName
        $serviceName = if ($_SQLInstanceName -eq "MSSQLSERVER") { $_SQLInstanceName } else { "MSSQL`$$_SQLInstanceName" }
        $query = "Name = '$serviceName'"
        $services = Get-WmiObject win32_service -Filter $query

        if ($services.State -eq 'Running') {
            #Check if SQLSERVERAGENT is running
            $sqlserveragentflag = 0
            $sqlAgentService = if ($_SQLInstanceName -eq "MSSQLSERVER") { "SQLSERVERAGENT" } else { "SQLAgent`$$_SQLInstanceName" }
            $sqlserveragentservices = Get-WmiObject win32_service -Filter "Name = '$sqlAgentService'"
            if ($null -ne $sqlserveragentservices) {
                if ($sqlserveragentservices.State -eq 'Running') {
                    Write-Status "$sqlAgentService need to be stopped first"
                    $Result = $sqlserveragentservices.StopService()
                    Write-Status "Stopping $sqlAgentService.."
                    if ($Result.ReturnValue -eq '0') {
                        $sqlserveragentflag = 1
                        Write-Verbose "[$(Get-Date -format HH:mm:ss)] Stopped"
                    }
                }
            }
            $Result = $services.StopService()
            Write-Status "Stopping SQL Server services.."
            if ($Result.ReturnValue -eq '0') {
                Write-Verbose "[$(Get-Date -format HH:mm:ss)] Stopped"
            }

            Write-Status "Changing the services account to LocalSystem..."

            $Result = $services.change($null, $null, $null, $null, $null, $null, "LocalSystem", $null, $null, $null, $null)
            if ($Result.ReturnValue -eq '0') {
                Write-Status "Successfully Changed the service account"
                if ($sqlserveragentflag -eq 1) {
                    Write-Status "Starting $sqlAgentService.."
                    $Result = $sqlserveragentservices.StartService()
                    if ($Result.ReturnValue -eq '0') {
                        Write-Verbose "[$(Get-Date -format HH:mm:ss)] Started"
                    }
                }
                $Result = $services.StartService()
                Write-Status "Starting SQL Server services.."
                while ($Result.ReturnValue -ne '0') {
                    $returncode = $Result.ReturnValue
                    Write-Status "Start Service Returned $returncode, Retry in 10 seconds"
                    Start-Sleep -Seconds 10
                    $Result = $services.StartService()
                }
                Write-Verbose "[$(Get-Date -format HH:mm:ss)] Started"
            }
        }
    }

    [bool] Test() {
        $_SQLInstanceName = $this.SQLInstanceName
        $serviceName = if ($_SQLInstanceName -eq "MSSQLSERVER") { $_SQLInstanceName } else { "MSSQL`$$_SQLInstanceName" }
        $query = "Name = '$serviceName'"
        $services = Get-WmiObject win32_service -Filter $query

        if ($null -ne $services) {
            if ($services.StartName -ne "LocalSystem") {
                return $false
            }
            else {
                return $true
            }
        }

        return $true
    }

    [ChangeSQLServicesAccount] Get() {
        return $this
    }
}


[DscResource()]
class ChangeSqlInstancePort {
    [DscProperty(key)]
    [string] $SQLInstanceName

    [DscProperty(Mandatory)]
    [int] $SQLInstancePort

    [DscProperty(Mandatory)]
    [Ensure] $Ensure

    [DscProperty(NotConfigurable)]
    [Nullable[datetime]] $CreationTime

    [void] Set() {
        $_SQLInstanceName = $this.SQLInstanceName
        $_SQLInstancePort = $this.SQLInstancePort

        #if ($_SQLInstanceName -eq "MSSQLSERVER") {
        #    return
        #}

        Try {
            # Load the assemblies
            Write-Status "[ChangeSqlInstancePort]: Setting port for $_SQLInstanceName to $_SQLInstancePort"

            [system.reflection.assembly]::LoadWithPartialName("Microsoft.SqlServer.Smo") | Out-Null
            [system.reflection.assembly]::LoadWithPartialName("Microsoft.SqlServer.SqlWmiManagement") | Out-Null
            $mc = new-object Microsoft.SqlServer.Management.Smo.Wmi.ManagedComputer $env:COMPUTERNAME
            $i = $mc.ServerInstances[$_SQLInstanceName]
            $p = $i.ServerProtocols['Tcp']
            foreach ($ip in $p.IPAddresses) {
                #$ip = $p.IPAddresses['IPAll']
                $ip.IPAddressProperties['TcpDynamicPorts'].Value = ''
                $ipa = $ip.IPAddressProperties['TcpPort']
                $ipa.Value = [string]$_SQLInstancePort
            }
            $p.Alter()


            New-NetFirewallRule -DisplayName 'SQL over TCP Inbound (Named Instance)' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort $_SQLInstancePort -Group "For SQL Server"

        }
        Catch {
            Write-Status "ERROR[ChangeSqlInstancePort]: SET Failed: $($_.Exception.Message)"
        }
    }

    [bool] Test() {

        $_SQLInstanceName = $this.SQLInstanceName
        $_SQLInstancePort = $this.SQLInstancePort

        #if ($_SQLInstanceName -eq "MSSQLSERVER") {
        #    return $true
        #}

        try {
            # Load the assemblies
            Write-Verbose "[ChangeSqlInstancePort]: Testing port for $_SQLInstanceName"

            [system.reflection.assembly]::LoadWithPartialName("Microsoft.SqlServer.Smo") | Out-Null
            [system.reflection.assembly]::LoadWithPartialName("Microsoft.SqlServer.SqlWmiManagement") | Out-Null
            $mc = new-object Microsoft.SqlServer.Management.Smo.Wmi.ManagedComputer $env:COMPUTERNAME
            $i = $mc.ServerInstances[$_SQLInstanceName]
            $p = $i.ServerProtocols['Tcp']
            $ip = $p.IPAddresses['IPAll']
            $ipa = $ip.IPAddressProperties['TcpPort']
            if ($ipa.Value -eq $_SQLInstancePort) {
                return $true
            }
            return $false
        }
        catch {
            Write-Verbose "ERROR[ChangeSqlInstancePort]: TEST Failed: $($_.Exception.Message)"
            return $false
        }
    }

    [ChangeSqlInstancePort] Get() {
        return $this
    }
}

[DscResource()]
class RegisterTaskScheduler {
    [DscProperty(key)]
    [string] $TaskName

    [DscProperty(Mandatory)]
    [string] $ScriptName

    [DscProperty(Mandatory)]
    [string] $ScriptPath

    [DscProperty(Mandatory)]
    [string] $ScriptArgument

    [DscProperty(Mandatory)]
    [System.Management.Automation.PSCredential] $AdminCreds

    [DscProperty(Mandatory)]
    [Ensure] $Ensure

    [DscProperty(NotConfigurable)]
    [Nullable[datetime]] $CreationTime

    [void] Set() {
        $_TaskName = $this.TaskName
        $_ScriptName = $this.ScriptName
        $_ScriptPath = $this.ScriptPath
        $_ScriptArgument = $this.ScriptArgument
        $_AdminCreds = $this.AdminCreds



        $RegisterTime = [datetime]::Now
        $waitTime = 30

        $success = $this.RegisterTask()
        $lastRunTime = $this.GetLastRunTime()
        $failCount = 0
        Write-Status "Starting task $_Taskname from $_ScriptPath $_ScriptName $_ScriptArgument"
        Write-Verbose "lastRunTime: $lastRunTime   RegisterTime: $RegisterTime"
        while ($lastRunTime -lt $RegisterTime) {
            Write-Verbose "Checking to see if task has started Attempt $failCount"
            Write-Verbose "lastRunTime: $lastRunTime   RegisterTime: $RegisterTime"

            if ($failCount -gt 2) {
                Write-Verbose "Manually starting the task"
                Start-ScheduledTask -TaskName $_TaskName
                start-sleep $waitTime
                $lastRunTime = $this.GetLastRunTime()
            }

            if ($failCount -eq 5) {
                Write-Status "$_TaskName has not ran yet after 5 Cycles. Re-Registering Task"
                #Unregister existing task
                $success = $this.RegisterTask()

            }

            if ($failCount -eq 8) {
                Write-Status "$_TaskName failed to run after 8 retries, and reregistration. Exiting. Please check Task Scheduler for Task: $_TaskName"
                throw "Task failed to run after 8 retries, and reregistration. Exiting. Please check Task Scheduler for Task: $_TaskName"
            }

            if ($lastRunTime -gt $RegisterTime) {
                Write-Status "$_Taskname was successfully started at $lastRunTime"
                break
            }
            else {
                Write-Status "$_Taskname has not started. Last run time was: $lastRunTime"
                $failCount++
            }
            start-sleep -Seconds $waitTime
            $lastRunTime = $this.GetLastRunTime()
        }
        Write-Status "$_TaskName was successfully started at $lastRunTime"



        # $TaskStartTime = [datetime]::Now.AddMinutes(2)
        # $service = new-object -ComObject("Schedule.Service")
        # $service.Connect()
        # $rootFolder = $service.GetFolder("\")
        # $TaskDefinition = $service.NewTask(0)
        # $TaskDefinition.RegistrationInfo.Description = "$TaskDescription"
        # $TaskDefinition.Settings.Enabled = $true
        # $TaskDefinition.Settings.AllowDemandStart = $true
        # $triggers = $TaskDefinition.Triggers
        # #http://msdn.microsoft.com/en-us/library/windows/desktop/aa383915(v=vs.85).aspx
        # $trigger = $triggers.Create(1)
        # $trigger.StartBoundary = $TaskStartTime.ToString("yyyy-MM-dd'T'HH:mm:ss")
        # $trigger.Enabled = $true
        # #http://msdn.microsoft.com/en-us/library/windows/desktop/aa381841(v=vs.85).aspx
        # $Action = $TaskDefinition.Actions.Create(0)
        # $action.Path = "$TaskCommand"
        # $action.Arguments = "$TaskArg"
        # #http://msdn.microsoft.com/en-us/library/windows/desktop/aa381365(v=vs.85).aspx
        # $rootFolder.RegisterTaskDefinition("$_TaskName", $TaskDefinition, 6, "System", $null, 5)
    }

    [bool] Test() {

        $exists = Get-ScheduledTask -TaskName $($this.TaskName) -ErrorAction SilentlyContinue
        if ($exists) {
            if ($exists.state -eq "Running") {
                Stop-ScheduledTask -TaskName $($this.TaskName) -ErrorAction SilentlyContinue                                
            }
            Unregister-ScheduledTask -TaskName $($this.TaskName) -ErrorAction SilentlyContinue
            return $false
        }
        return $false
    }

    [RegisterTaskScheduler] Get() {
        return $this
    }


    [bool] RegisterTask() {
        $ProvisionToolPath = "$env:windir\temp\ProvisionScript"
        if (!(Test-Path $ProvisionToolPath)) {
            New-Item $ProvisionToolPath -ItemType directory | Out-Null
        }
        Write-Status "Checking for existing task: $($this.TaskName)"
        $exists = Get-ScheduledTask -TaskName $($this.TaskName) -ErrorAction SilentlyContinue
        if ($exists) {
            Write-Status "Task $($this.TaskName) already exists. Removing"
            if ($exists.state -eq "Running") {
                stop-Process -Name setup -Force -ErrorAction SilentlyContinue
                stop-Process -Name setupwpf -Force -ErrorAction SilentlyContinue
                $exists | Stop-ScheduledTask -ErrorAction SilentlyContinue
            }
            Unregister-ScheduledTask -TaskName $($this.TaskName) -Confirm:$false
            Write-Status "Task $($this.TaskName) Removed"
        }

        $sourceDirectory = "$($this.ScriptPath)\*"
        $destDirectory = "$ProvisionToolPath\"

        Write-Status "Copying $sourceDirectory to $destDirectory"
        Copy-item -Force -Recurse $sourceDirectory -Destination $destDirectory

        $TaskDescription = "vmbuild task"
        $TaskCommand = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
        $TaskScript = "$ProvisionToolPath\$($this.ScriptName)"

        Write-Status "Task script full path is : $TaskScript "

        $TaskArg = "-WindowStyle Hidden -NonInteractive -ExecutionPolicy unrestricted -file $TaskScript $($this.ScriptArgument)"

        $Action = New-ScheduledTaskAction -Execute $TaskCommand -Argument $TaskArg
        Write-Verbose "New-ScheduledTaskAction : $TaskCommand $TaskArg"

        # Seconds to wait to start task
        $waitTime = 15
        $TaskStartTime = [datetime]::Now.AddSeconds($waitTime)
        $RegisterTime = [datetime]::Now
        #$Trigger = New-ScheduledTaskTrigger -Once -At $TaskStartTime
        #Write-Verbose "Time is now: $RegisterTime Task Scheduled to run at $TaskStartTime"

        $Principal = New-ScheduledTaskPrincipal -UserId $($this.AdminCreds.UserName) -RunLevel Highest
        $Password = $($this.AdminCreds).GetNetworkCredential().Password
        $certauthFile = $destDirectory + "\" + "certauth.txt"
        $Password | Out-file -FilePath $certauthFile -Force

        $Task = New-ScheduledTask -Action $Action -Description $TaskDescription -Principal $Principal

        $Task | Register-ScheduledTask -TaskName $($this.TaskName) -User $($this.AdminCreds.UserName) -Password $Password -Force | out-Null

        start-sleep -Seconds $waitTime

        Write-Status "Time is now: $([datetime]::Now) Task Scheduled $($this.TaskName) is starting"
        Start-ScheduledTask -TaskName $($this.TaskName)
        Write-Status "Time is now: $([datetime]::Now) Task Scheduled $($this.TaskName) has Started."

        return $true

    }

    [datetime] GetLastRunTime() {

        $filterXML = @'
        <QueryList>
         <Query Id="0" Path="Microsoft-Windows-TaskScheduler/Operational">
          <Select Path="Microsoft-Windows-TaskScheduler/Operational">
           *[EventData/Data[@Name='TaskName']='\TEMPLATE']
          </Select>
         </Query>
        </QueryList>
'@

        $filterXML = $filterXML -replace ("TEMPLATE", $this.TaskName)
        $Lastevent = (Get-WinEvent  -FilterXml $filterXML -ErrorAction Stop) | Where-Object { $_.ID -eq 100 } | Select-Object -First 1

        if ($Lastevent) {
            Write-Verbose "Last Run Time is $($Lastevent.TimeCreated)"
            return $Lastevent.TimeCreated
        }
        Write-Verbose "No Last Run Time found returning $([datetime]::MinValue)"
        return [datetime]::MinValue

    }
}

[DscResource()]
class InitializeDisks {
    [DscProperty(key)]
    [string] $DummyKey

    [DscProperty(Mandatory)]
    [string] $VM

    [void] Set() {

        Write-Status "Initializing disks"

        # Move CD-ROM drive to Z: before assigning disk letters
        if (-not (Get-Volume -DriveLetter "Z" -ErrorAction SilentlyContinue)) {
            Write-Status "Moving CD-ROM drive to Z:.."
            Get-WmiObject -Class Win32_volume -Filter 'DriveType=5' | Select-Object -First 1 | Set-WmiInstance -Arguments @{DriveLetter = 'Z:' }
        }

        $_VM = $this.VM | ConvertFrom-Json
        $_Disks = $_VM.additionalDisks

        # For debugging
        Write-Status  "VM Additional Disks: $_Disks"
        Get-Disk | Write-Verbose

        if ($null -eq $_Disks) {
            Write-Verbose "No disks to initialize."
            return
        }

        # Loop through disks
        $count = 0
        $label = "DATA"
        foreach ($disk in $_Disks.psobject.properties) {
            Write-Status "Assigning $($disk.Name) Drive Letter to disk with size $($disk.Value)"
            $rawdisk = Get-Disk | Where-Object { $_.PartitionStyle -eq "RAW" -and $_.Size -eq $disk.Value } | Select-Object -First 1
            $rawdisk | Initialize-Disk -PartitionStyle GPT -PassThru | New-Partition -UseMaximumSize -DriveLetter $disk.Name | Format-Volume -FileSystem NTFS -NewFileSystemLabel "$label`_$count" -Confirm:$false -Force
            $count++
        }

        # Create NO_SMS_ON_DRIVE.SMS
        New-Item "$env:systemdrive\NO_SMS_ON_DRIVE.SMS" -ItemType File -Force -ErrorAction SilentlyContinue
    }

    [bool] Test() {

        # Check if there are any RAW disks
        Write-Verbose "Testing if any Raw disks are left"
        $Validate = Get-Disk | Where-Object partitionstyle -eq 'RAW'

        If (!($null -eq $Validate)) {
            Write-Verbose "Disks are not initialized"
            return $false
        }
        Else {
            Write-Verbose "Disks are initialized"
            return $true
        }
    }

    [InitializeDisks] Get() {
        return $this
    }
}

[DscResource()]
class AddUserToLocalAdminGroup {
    [DscProperty(Key)]
    [string] $Name

    [DscProperty(Key)]
    [string] $NetbiosDomainName

    [void] Set() {
        $_DomainName = $($this.NetbiosDomainName)
        $_Name = $this.Name
        try {
            $AdminGroupName = (Get-WmiObject -Class Win32_Group -Filter 'LocalAccount = True AND SID = "S-1-5-32-544"').Name
            $GroupObj = [ADSI]"WinNT://$env:COMPUTERNAME/$AdminGroupName"
            Write-Status "Adding $_DomainName\$_Name to administrators group"
            if (-not $GroupObj.IsMember("WinNT://$_DomainName/$_Name")) {
                $GroupObj.Add("WinNT://$_DomainName/$_Name")
            }
        }
        catch {
            Write-Status "AddUserToLocalAdminGroup: Failed to add $_DomainName\$_Name to administrators group $_"
            if ($(Test-ComputerSecureChannel) -eq $False) { 
                Write-Status "AddUserToLocalAdminGroup: Secure Channel is broken. Attempting to reboot to fix it."
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUserDeclaredVarsMoreThanAssignments', '', Scope = 'Function')]
                $global:DSCMachineStatus = 1
            }
        }
    
    }

    [bool] Test() {
        $_DomainName = $($this.NetbiosDomainName)
        $_Name = $this.Name
        try {
            $AdminGroupName = (Get-WmiObject -Class Win32_Group -Filter 'LocalAccount = True AND SID = "S-1-5-32-544"').Name
            $GroupObj = [ADSI]"WinNT://$env:COMPUTERNAME/$AdminGroupName"
            Write-Verbose "[$(Get-Date -format HH:mm:ss)] Testing $_DomainName\$_Name is in administrators group"
            if ($GroupObj.IsMember("WinNT://$_DomainName/$_Name") -eq $true) {
                return $true
            }
            return $false
        }
        catch {
            Write-Verbose "AddUserToLocalAdminGroup: Failed to test $_DomainName\$_Name in administrators group $_"
            return $false
        }
    }

    [AddUserToLocalAdminGroup] Get() {
        return $this
    }

}

[DscResource()]
class JoinDomain {
    [DscProperty(Key)]
    [string] $DomainName

    [DscProperty(Mandatory)]
    [System.Management.Automation.PSCredential] $Credential

    [void] Set() {
        $_credential = $this.Credential
        $_DomainName = $this.DomainName
        $_retryCount = 80
        try {
            Write-Status "Joining computer to Domain $_DomainName"
            Add-Computer -DomainName $_DomainName -Credential $_credential -ErrorAction Stop
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUserDeclaredVarsMoreThanAssignments', '', Scope = 'Function')]
            $global:DSCMachineStatus = 1
        }
        catch {
            $CurrentDomain = (Get-WmiObject -Class Win32_ComputerSystem).Domain
            $count = 0
            Write-Status "Failed to join into the domain $_DomainName, retry $count/$_retryCount"
            $flag = $false
            while ($CurrentDomain -ne $_DomainName) {
                if ($count -lt $_retryCount) {
                    $count++
                    Write-Status "Current Domain of $CurrentDomain does not match $_DomainName. Retry count: $count/$_retryCount"
                    Start-Sleep -Seconds 15
                    Add-Computer -DomainName $_DomainName -Credential $_credential -ErrorAction Ignore

                    $CurrentDomain = (Get-WmiObject -Class Win32_ComputerSystem).Domain
                }
                else {
                    $flag = $true
                    break
                }
            }
            if ($flag) {
                Write-Status "Failed too many times.  Rebooting, then Rejoining domain."
                Add-Computer -DomainName $_DomainName -Credential $_credential
            }
            else {
                Write-Status "Domain Join Successful. Rebooting."
            }
            $global:DSCMachineStatus = 1
        }
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUserDeclaredVarsMoreThanAssignments', '', Scope = 'Function')]
        $global:DSCMachineStatus = 1
    }

    [bool] Test() {

        $_DomainName = $this.DomainName
        $CurrentDomain = (Get-WmiObject -Class Win32_ComputerSystem).Domain

        if ($CurrentDomain -eq $_DomainName) {
            return $true
        }

        return $false
    }

    [JoinDomain] Get() {
        return $this
    }

}

[DscResource()]
class TestDomainJoin {
    # Runs after JoinDomain (which always ends with a reboot). On the post-reboot
    # DSC pass JoinDomain.Test() returns true (we're joined), so this resource is
    # the first thing to actually exercise the machine-account secret against the
    # DC. If the secret is out of sync (e.g. JoinDomain's retry loop fired
    # Add-Computer twice against a half-promoted DC and rolled the password), we
    # detect it here and self-heal before any downstream resource tries to talk
    # to AD with a broken secure channel.
    #
    # Self-heal strategy:
    #   1. Reset-ComputerMachinePassword against the named DC (no reboot needed).
    #   2. If still broken, full Remove-Computer + Add-Computer + reboot.
    [DscProperty(Key)]
    [string] $DomainName

    [DscProperty(Mandatory)]
    [string] $DCName

    [DscProperty(Mandatory)]
    [System.Management.Automation.PSCredential] $Credential

    [bool] Test() {
        $_DomainName = $this.DomainName
        $cs = Get-WmiObject -Class Win32_ComputerSystem -ErrorAction SilentlyContinue
        if (-not $cs -or $cs.Domain -ne $_DomainName) {
            # Not joined yet -- nothing for us to test. JoinDomain should have run
            # first; if it hasn't, returning true here just defers to its ordering.
            return $true
        }

        # Retry a few times to ride out transient netlogon hiccups right after
        # the reboot from JoinDomain. Only declare broken if all attempts fail.
        for ($i = 1; $i -le 3; $i++) {
            try {
                if (Test-ComputerSecureChannel -ErrorAction Stop) {
                    return $true
                }
            }
            catch {
                Write-Verbose "TestDomainJoin: Test-ComputerSecureChannel threw on attempt $i : $_"
            }
            if ($i -lt 3) { Start-Sleep -Seconds 10 }
        }
        return $false
    }

    [void] Set() {
        $_DomainName = $this.DomainName
        $_DCName = $this.DCName
        $_credential = $this.Credential

        # Step 1: try Reset-ComputerMachinePassword. Cheap, no reboot.
        Write-Status "Secure channel to $_DomainName is broken. Resetting machine password against $_DCName."
        for ($i = 1; $i -le 3; $i++) {
            try {
                Reset-ComputerMachinePassword -Server $_DCName -Credential $_credential -ErrorAction Stop
                Start-Sleep -Seconds 5
                if (Test-ComputerSecureChannel -ErrorAction SilentlyContinue) {
                    Write-Status "Reset-ComputerMachinePassword restored secure channel (attempt $i)."
                    return
                }
            }
            catch {
                $msg = ($_.Exception.Message -replace '\s+', ' ').Trim()
                Write-Status "Reset-ComputerMachinePassword attempt $i failed: $msg"
            }
            if ($i -lt 3) { Start-Sleep -Seconds 15 }
        }

        # Step 2: full unjoin + rejoin. Requires reboot, but avoids leaving the
        # node wedged with a broken secret that every later phase will trip on.
        Write-Status "Reset failed. Performing full Remove-Computer + Add-Computer cycle."
        try {
            Remove-Computer -UnjoinDomainCredential $_credential -PassThru -Force -ErrorAction Stop | Out-Null
        }
        catch {
            $msg = ($_.Exception.Message -replace '\s+', ' ').Trim()
            Write-Status "Remove-Computer failed (continuing to Add-Computer anyway): $msg"
        }
        try {
            Add-Computer -DomainName $_DomainName -Credential $_credential -Force -ErrorAction Stop
            Write-Status "Add-Computer succeeded. Rebooting to complete rejoin."
        }
        catch {
            $msg = ($_.Exception.Message -replace '\s+', ' ').Trim()
            Write-Status "Add-Computer failed during self-heal: $msg"
            throw
        }
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUserDeclaredVarsMoreThanAssignments', '', Scope = 'Function')]
        $global:DSCMachineStatus = 1
    }

    [TestDomainJoin] Get() {
        return $this
    }
}

[DscResource()]
class OpenFirewallPortForSCCM {
    [DscProperty(Key)]
    [string] $Name

    [DscProperty(Mandatory)]
    [string[]] $Role

    [void] Set() {
        $_Role = $this.Role

        Write-Status "Opening firewall ports for Role:$_Role"

        New-NetFirewallRule -DisplayName "Cluster Network Outbound" -Profile Any -Direction Outbound -Action Allow -RemoteAddress "10.250.250.0/24"
        New-NetFirewallRule -DisplayName "Cluster Network Inbound" -Profile Any -Direction Inbound -Action Allow -RemoteAddress "10.250.250.0/24"

        New-NetFirewallRule -DisplayName 'WinRM Outbound' -Profile Any -Direction Outbound -Action Allow -Protocol TCP -LocalPort @(5985, 5986) -Group "For WinRM"
        New-NetFirewallRule -DisplayName 'WinRM Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort @(5985, 5986) -Group "For WinRM"
        New-NetFirewallRule -DisplayName 'RDP Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort 3389 -Group "For RdcMan"

        if ($_Role -contains "DC") {
            #HTTP(S) Requests
            New-NetFirewallRule -DisplayName 'HTTP(S) Outbound' -Profile Any -Direction Outbound -Action Allow -Protocol TCP -LocalPort @(80, 443) -Group "For DC"
            New-NetFirewallRule -DisplayName 'HTTP(S) Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort @(80, 443) -Group "For DC"

            #PS-->DC(in)
            New-NetFirewallRule -DisplayName 'LDAP Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort 389 -Group "For DC"
            New-NetFirewallRule -DisplayName 'Kerberos Password Change TCP' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort 464 -Group "For DC"
            New-NetFirewallRule -DisplayName 'Kerberos Password Change UDP' -Profile Any -Direction Inbound -Action Allow -Protocol UDP -LocalPort 464 -Group "For DC"
            New-NetFirewallRule -DisplayName 'LDAP(SSL) Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort 636 -Group "For DC"
            New-NetFirewallRule -DisplayName 'LDAP(SSL) UDP Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol UDP -LocalPort 636 -Group "For DC"
            New-NetFirewallRule -DisplayName 'Global Catalog LDAP Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort 3268 -Group "For DC"
            New-NetFirewallRule -DisplayName 'Global Catalog LDAP SSL Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort 3269 -Group "For DC"
            New-NetFirewallRule -DisplayName 'RPC Endpoint Mapper Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort 135 -Group "For DC"
            New-NetFirewallRule -DisplayName 'RPC Endpoint Mapper UDP Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol UDP -LocalPort 135 -Group "For DC"
            #Dynamic Port
            New-NetFirewallRule -DisplayName 'RPC Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort 1024-65535 -Group "For DC"

            #THAgent
            Enable-NetFirewallRule -DisplayGroup "Windows Management Instrumentation (WMI)" -Direction Inbound
            Enable-NetFirewallRule -Group "@FirewallAPI.dll,-28502"
        }

        if ($_Role -contains "Site Server") {
            New-NetFirewallRule -DisplayName 'HTTP(S) Outbound' -Profile Any -Direction Outbound -Action Allow -Protocol TCP -LocalPort @(80, 443) -Group "For SCCM"
            New-NetFirewallRule -DisplayName 'HTTP(S) Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort @(80, 443) -Group "For SCCM"

            #site server<->site server
            New-NetFirewallRule -DisplayName 'SMB Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort 445 -Group "For SCCM"
            New-NetFirewallRule -DisplayName 'SMB Outbound' -Profile Any -Direction Outbound -Action Allow -Protocol TCP -LocalPort 445 -Group "For SCCM"
            New-NetFirewallRule -DisplayName 'PPTP Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort 1723 -Group "For SCCM"
            New-NetFirewallRule -DisplayName 'PPTP Outbound' -Profile Any -Direction Outbound -Action Allow -Protocol TCP -LocalPort 1723 -Group "For SCCM"

            #primary site server(out) ->DC
            New-NetFirewallRule -DisplayName 'LDAP Outbound' -Profile Any -Direction Outbound -Action Allow -Protocol TCP -LocalPort 389 -Group "For SCCM"
            New-NetFirewallRule -DisplayName 'LDAP(SSL) Outbound' -Profile Any -Direction Outbound -Action Allow -Protocol TCP -LocalPort 636 -Group "For SCCM"
            New-NetFirewallRule -DisplayName 'LDAP(SSL) UDP Outbound' -Profile Any -Direction Outbound -Action Allow -Protocol UDP -LocalPort 636 -Group "For SCCM"
            New-NetFirewallRule -DisplayName 'Global Catalog LDAP Outbound' -Profile Any -Direction Outbound -Action Allow -Protocol TCP -LocalPort 3268 -Group "For SCCM"
            New-NetFirewallRule -DisplayName 'Global Catalog LDAP SSL Outbound' -Profile Any -Direction Outbound -Action Allow -Protocol TCP -LocalPort 3269 -Group "For SCCM"


            #Dynamic Port?
            New-NetFirewallRule -DisplayName 'RPC Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort 1024-65535 -Group "For SCCM"
            New-NetFirewallRule -DisplayName 'RPC Outbound' -Profile Any -Direction Outbound -Action Allow -Protocol TCP -LocalPort 1024-65535 -Group "For SCCM"
            New-NetFirewallRule -DisplayName 'RPC Endpoint Mapper Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort 135 -Group "For SCCM"
            New-NetFirewallRule -DisplayName 'RPC Endpoint Mapper Outbound' -Profile Any -Direction Outbound -Action Allow -Protocol TCP -LocalPort 135 -Group "For SCCM"
            New-NetFirewallRule -DisplayName 'RPC Endpoint Mapper UDP Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol UDP -LocalPort 135 -Group "For SCCM"
            New-NetFirewallRule -DisplayName 'RPC Endpoint Mapper UDP Outbound' -Profile Any -Direction Outbound -Action Allow -Protocol UDP -LocalPort 135 -Group "For SCCM"

            New-NetFirewallRule -DisplayName 'SQL over TCP  Inbound 1433' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort 1433 -Group "For SCCM"
            New-NetFirewallRule -DisplayName 'SQL over TCP  Outbound 1433' -Profile Any -Direction Outbound -Action Allow -Protocol TCP -LocalPort 1433 -Group "For SCCM"

            New-NetFirewallRule -DisplayName 'SQL over TCP  Inbound 2433' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort 2433 -Group "For SCCM"
            New-NetFirewallRule -DisplayName 'SQL over TCP  Outbound 2433' -Profile Any -Direction Outbound -Action Allow -Protocol TCP -LocalPort 2433 -Group "For SCCM"

            New-NetFirewallRule -DisplayName 'SQL over TCP  Inbound 1500' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort 1500 -Group "For SCCM"
            New-NetFirewallRule -DisplayName 'SQL over TCP  Outbound 1500' -Profile Any -Direction Outbound -Action Allow -Protocol TCP -LocalPort 1500 -Group "For SCCM"

            New-NetFirewallRule -DisplayName 'RPC Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort 135 -Group "For SCCM"
            New-NetFirewallRule -DisplayName 'Wake on LAN Outbound' -Profile Any -Direction Outbound -Action Allow -Protocol UDP -LocalPort 9 -Group "For SCCM"
        }

        if ($_Role -contains "Software Update Point") {
            New-NetFirewallRule -DisplayName 'SMB SUPInbound' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort 445 -Group "For SCCM SUP"
            New-NetFirewallRule -DisplayName 'SMB SUP Outbound' -Profile Any -Direction Outbound -Action Allow -Protocol TCP -LocalPort 445 -Group "For SCCM SUP"
            New-NetFirewallRule -DisplayName 'HTTP(S) SUP Outbound' -Profile Any -Direction Outbound -Action Allow -Protocol TCP -LocalPort @(8530, 8531) -Group "For SCCM SUP"
            New-NetFirewallRule -DisplayName 'HTTP(S) SUP Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort @(8530, 8531) -Group "For SCCM SUP"
            #SUP->Internet
            New-NetFirewallRule -DisplayName 'HTTP Outbound' -Profile Any -Direction Outbound -Action Allow -Protocol TCP -LocalPort 80 -Group "For SCCM SUP"

            New-NetFirewallRule -DisplayName 'HTTP(S) Outbound' -Profile Any -Direction Outbound -Action Allow -Protocol TCP -LocalPort @(80, 443) -Group "For SCCM SUP"
            New-NetFirewallRule -DisplayName 'HTTP(S) Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort @(80, 443) -Group "For SCCM SUP"
        }
        if ($_Role -contains "State Migration Point") {
            #SMB,RPC Endpoint Mapper
            New-NetFirewallRule -DisplayName 'SMB SMP Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort 445 -Group "For SCCM SMP"
            New-NetFirewallRule -DisplayName 'SMB SMP Outbound' -Profile Any -Direction Outbound -Action Allow -Protocol TCP -LocalPort 445 -Group "For SCCM SMP"
            New-NetFirewallRule -DisplayName 'RPC Endpoint Mapper Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort 135 -Group "For SCCM SMP"
            New-NetFirewallRule -DisplayName 'RPC Endpoint Mapper Outbound' -Profile Any -Direction Outbound -Action Allow -Protocol TCP -LocalPort 135 -Group "For SCCM SMP"
            New-NetFirewallRule -DisplayName 'RPC Endpoint Mapper UDP Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol UDP -LocalPort 135 -Group "For SCCM SMP"
            New-NetFirewallRule -DisplayName 'RPC Endpoint Mapper UDP Outbound' -Profile Any -Direction Outbound -Action Allow -Protocol UDP -LocalPort 135 -Group "For SCCM SMP"
            New-NetFirewallRule -DisplayName 'HTTP(S) Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort @(80, 443) -Group "For SCCM SUP"
        }
        if ($_Role -contains "PXE Service Point") {
            #SMB,RPC Endpoint Mapper,RPC
            New-NetFirewallRule -DisplayName 'SMB Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort 445 -Group "For SCCM PXE SP"
            New-NetFirewallRule -DisplayName 'SMB Outbound' -Profile Any -Direction Outbound -Action Allow -Protocol TCP -LocalPort 445 -Group "For SCCM PXE SP"
            New-NetFirewallRule -DisplayName 'RPC Endpoint Mapper Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort 135 -Group "For SCCM PXE SP"
            New-NetFirewallRule -DisplayName 'RPC Endpoint Mapper Outbound' -Profile Any -Direction Outbound -Action Allow -Protocol TCP -LocalPort 135 -Group "For SCCM PXE SP"
            New-NetFirewallRule -DisplayName 'RPC Endpoint Mapper UDP Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol UDP -LocalPort 135 -Group "For SCCM PXE SP"
            New-NetFirewallRule -DisplayName 'RPC Endpoint Mapper UDP Outbound' -Profile Any -Direction Outbound -Action Allow -Protocol UDP -LocalPort 135 -Group "For SCCM PXE SP"
            #Dynamic Port
            New-NetFirewallRule -DisplayName 'RPC Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort 1024-65535 -Group "For SCCM PXE SP"
            New-NetFirewallRule -DisplayName 'RPC Outbound' -Profile Any -Direction Outbound -Action Allow -Protocol TCP -LocalPort 1024-65535 -Group "For SCCM PXE SP"
            New-NetFirewallRule -DisplayName 'SQL over TCP  Outbound 1433' -Profile Any -Direction Outbound -Action Allow -Protocol TCP -LocalPort 1433 -Group "For SCCM PXE SP"
            New-NetFirewallRule -DisplayName 'SQL over TCP  Outbound 2433' -Profile Any -Direction Outbound -Action Allow -Protocol TCP -LocalPort 2433 -Group "For SCCM PXE SP"
            New-NetFirewallRule -DisplayName 'SQL over TCP  Outbound 1500' -Profile Any -Direction Outbound -Action Allow -Protocol TCP -LocalPort 1500 -Group "For SCCM PXE SP"

            New-NetFirewallRule -DisplayName 'DHCP Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort @(67.68) -Group "For SCCM PXE SP"
            New-NetFirewallRule -DisplayName 'TFTP Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort 69  -Group "For SCCM PXE SP"
            New-NetFirewallRule -DisplayName 'BINL Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort 4011 -Group "For SCCM PXE SP"
        }
        if ($_Role -contains "System Health Validator") {
            #SMB,RPC Endpoint Mapper,RPC
            New-NetFirewallRule -DisplayName 'SMB Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort 445 -Group "For SCCM System Health Validator"
            New-NetFirewallRule -DisplayName 'SMB Outbound' -Profile Any -Direction Outbound -Action Allow -Protocol TCP -LocalPort 445 -Group "For SCCM System Health Validator"
            New-NetFirewallRule -DisplayName 'RPC Endpoint Mapper Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort 135 -Group "For SCCM System Health Validator"
            New-NetFirewallRule -DisplayName 'RPC Endpoint Mapper Outbound' -Profile Any -Direction Outbound -Action Allow -Protocol TCP -LocalPort 135 -Group "For SCCM System Health Validator"
            New-NetFirewallRule -DisplayName 'RPC Endpoint Mapper UDP Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol UDP -LocalPort 135 -Group "For SCCM System Health Validator"
            New-NetFirewallRule -DisplayName 'RPC Endpoint Mapper UDP Outbound' -Profile Any -Direction Outbound -Action Allow -Protocol UDP -LocalPort 135 -Group "For SCCM System Health Validator"
            #dynamic port
            New-NetFirewallRule -DisplayName 'RPC Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort 1024-65535 -Group "For SCCM System Health Validator"
            New-NetFirewallRule -DisplayName 'RPC Outbound' -Profile Any -Direction Outbound -Action Allow -Protocol TCP -LocalPort 1024-65535 -Group "For SCCM System Health Validator"
        }
        if ($_Role -contains "Fallback Status Point") {
            #SMB,RPC Endpoint Mapper,RPC
            New-NetFirewallRule -DisplayName 'SMB Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort 445 -Group "For SCCM FSP"
            New-NetFirewallRule -DisplayName 'SMB Outbound' -Profile Any -Direction Outbound -Action Allow -Protocol TCP -LocalPort 445 -Group "For SCCM FSP "
            New-NetFirewallRule -DisplayName 'RPC Endpoint Mapper Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort 135 -Group "For SCCM FSP"
            New-NetFirewallRule -DisplayName 'RPC Endpoint Mapper Outbound' -Profile Any -Direction Outbound -Action Allow -Protocol TCP -LocalPort 135 -Group "For SCCM FSP"
            New-NetFirewallRule -DisplayName 'RPC Endpoint Mapper UDP Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol UDP -LocalPort 135 -Group "For SCCM FSP"
            New-NetFirewallRule -DisplayName 'RPC Endpoint Mapper UDP Outbound' -Profile Any -Direction Outbound -Action Allow -Protocol UDP -LocalPort 135 -Group "For SCCM FSP"
            #dynamic port
            New-NetFirewallRule -DisplayName 'RPC Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort 1024-65535 -Group "For SCCM FSP"
            New-NetFirewallRule -DisplayName 'RPC Outbound' -Profile Any -Direction Outbound -Action Allow -Protocol TCP -LocalPort 1024-65535 -Group "For SCCM FSP"

            New-NetFirewallRule -DisplayName 'HTTP Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort 80 -Group "For SCCM FSP"
        }
        if ($_Role -contains "Reporting Services Point") {
            New-NetFirewallRule -DisplayName 'SQL over TCP  Inbound 1433' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort 1433 -Group "For SCCM RSP"
            New-NetFirewallRule -DisplayName 'SQL over TCP  Outbound 1433' -Profile Any -Direction Outbound -Action Allow -Protocol TCP -LocalPort 1433 -Group "For SCCM RSP"
            New-NetFirewallRule -DisplayName 'SQL over TCP  Inbound 2433' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort 2433 -Group "For SCCM RSP"
            New-NetFirewallRule -DisplayName 'SQL over TCP  Outbound 2433' -Profile Any -Direction Outbound -Action Allow -Protocol TCP -LocalPort 2433 -Group "For SCCM RSP"
            New-NetFirewallRule -DisplayName 'SQL over TCP  Inbound 1500' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort 1500 -Group "For SCCM RSP"
            New-NetFirewallRule -DisplayName 'SQL over TCP  Outbound 1500' -Profile Any -Direction Outbound -Action Allow -Protocol TCP -LocalPort 1500 -Group "For SCCM RSP"
            New-NetFirewallRule -DisplayName 'HTTP(S) Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort @(80, 443) -Group "For SCCM RSP"
            New-NetFirewallRule -DisplayName 'SMB Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort 445 -Group "For SCCM RSP"
            New-NetFirewallRule -DisplayName 'RPC Endpoint Mapper Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort 135 -Group "For SCCM RSP"
            New-NetFirewallRule -DisplayName 'RPC Endpoint Mapper UDP Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol UDP -LocalPort 135 -Group "For SCCM RSP"
            #dynamic port
            New-NetFirewallRule -DisplayName 'RPC Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort 1024-65535 -Group "For SCCM RSP"
        }
        if ($_Role -contains "Distribution Point") {
            New-NetFirewallRule -DisplayName 'HTTP(S) Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort @(80, 443) -Group "For SCCM DP"
            New-NetFirewallRule -DisplayName 'SMB DP Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort 445 -Group "For SCCM DP"
            New-NetFirewallRule -DisplayName 'Multicast Protocol Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort 63000-64000 -Group "For SCCM DP"
        }
        if ($_Role -contains "Management Point") {
            New-NetFirewallRule -DisplayName 'HTTP(S) Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort @(80, 443) -Group "For SCCM MP"
            New-NetFirewallRule -DisplayName 'SQL over TCP  Outbound 1433' -Profile Any -Direction Outbound -Action Allow -Protocol TCP -LocalPort 1433 -Group "For SCCM MP"
            New-NetFirewallRule -DisplayName 'SQL over TCP  Outbound 2433' -Profile Any -Direction Outbound -Action Allow -Protocol TCP -LocalPort 2433 -Group "For SCCM MP"
            New-NetFirewallRule -DisplayName 'SQL over TCP  Outbound 1500' -Profile Any -Direction Outbound -Action Allow -Protocol TCP -LocalPort 1500 -Group "For SCCM MP"
            New-NetFirewallRule -DisplayName 'LDAP Outbound' -Profile Any -Direction Outbound -Action Allow -Protocol TCP -LocalPort 389 -Group "For SCCM MP"
            New-NetFirewallRule -DisplayName 'LDAP(SSL) Outbound' -Profile Any -Direction Outbound -Action Allow -Protocol TCP -LocalPort 636 -Group "For SCCM MP"
            New-NetFirewallRule -DisplayName 'LDAP(SSL) UDP Outbound' -Profile Any -Direction Outbound -Action Allow -Protocol UDP -LocalPort 636 -Group "For SCCM MP"
            New-NetFirewallRule -DisplayName 'Global Catalog LDAP Outbound' -Profile Any -Direction Outbound -Action Allow -Protocol TCP -LocalPort 3268 -Group "For SCCM MP"
            New-NetFirewallRule -DisplayName 'Global Catalog LDAP SSL Outbound' -Profile Any -Direction Outbound -Action Allow -Protocol TCP -LocalPort 3269 -Group "For SCCM MP"

            New-NetFirewallRule -DisplayName 'SMB Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort 445 -Group "For SCCM MP"
            New-NetFirewallRule -DisplayName 'SMB Outbound' -Profile Any -Direction Outbound -Action Allow -Protocol TCP -LocalPort 445 -Group "For SCCM MP"
            New-NetFirewallRule -DisplayName 'RPC Endpoint Mapper Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort 135 -Group "For SCCM MP"
            New-NetFirewallRule -DisplayName 'RPC Endpoint Mapper Outbound' -Profile Any -Direction Outbound -Action Allow -Protocol TCP -LocalPort 135 -Group "For SCCM MP"
            New-NetFirewallRule -DisplayName 'RPC Endpoint Mapper UDP Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol UDP -LocalPort 135 -Group "For SCCM MP"
            New-NetFirewallRule -DisplayName 'RPC Endpoint Mapper UDP Outbound' -Profile Any -Direction Outbound -Action Allow -Protocol UDP -LocalPort 135 -Group "For SCCM MP"
            #dynamic port
            New-NetFirewallRule -DisplayName 'RPC Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort 1024-65535 -Group "For SCCM MP"
            New-NetFirewallRule -DisplayName 'RPC Outbound' -Profile Any -Direction Outbound -Action Allow -Protocol TCP -LocalPort 1024-65535 -Group "For SCCM MP"
        }
        if ($_Role -contains "Branch Distribution Point") {
            New-NetFirewallRule -DisplayName 'SMB BDP Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort 445 -Group "For SCCM BDP"
            New-NetFirewallRule -DisplayName 'HTTP(S) Outbound' -Profile Any -Direction Outbound -Action Allow -Protocol TCP -LocalPort @(80, 443) -Group "For SCCM BDP"
        }
        if ($_Role -contains "Server Locator Point") {
            New-NetFirewallRule -DisplayName 'HTTP Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort 80 -Group "For SCCM SLP"
            New-NetFirewallRule -DisplayName 'SQL over TCP  Outbound 1433' -Profile Any -Direction Outbound -Action Allow -Protocol TCP -LocalPort 1433 -Group "For SQL Server SLP"
            New-NetFirewallRule -DisplayName 'SQL over TCP  Outbound 2433' -Profile Any -Direction Outbound -Action Allow -Protocol TCP -LocalPort 2433 -Group "For SQL Server SLP"
            New-NetFirewallRule -DisplayName 'SQL over TCP  Outbound 1500' -Profile Any -Direction Outbound -Action Allow -Protocol TCP -LocalPort 1500 -Group "For SQL Server SLP"
            New-NetFirewallRule -DisplayName 'SMB Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort 445 -Group "For SCCM SLP"
            New-NetFirewallRule -DisplayName 'RPC Endpoint Mapper Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort 135 -Group "For SCCM SLP"
            New-NetFirewallRule -DisplayName 'RPC Endpoint Mapper UDP Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol UDP -LocalPort 135 -Group "For SCCM SLP"
            #Dynamic port
            New-NetFirewallRule -DisplayName 'RPC Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort 1024-65535 -Group "For SCCM RSP"
        }
        if ($_Role -contains "SQL Server") {
            New-NetFirewallRule -DisplayName 'SQL over TCP  Inbound 1433' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort 1433 -Group "For SQL Server"
            New-NetFirewallRule -DisplayName 'SQL over TCP  Inbound 2433' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort 2433 -Group "For SQL Server"
            New-NetFirewallRule -DisplayName 'SQL over TCP  Inbound 1500' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort 1500 -Group "For SQL Server"
            New-NetFirewallRule -DisplayName 'WMI' -Program "%systemroot%\system32\svchost.exe" -Service "winmgmt" -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort Domain -Group "For SQL Server WMI"
            New-NetFirewallRule -DisplayName 'DCOM' -Program "%systemroot%\system32\svchost.exe" -Service "rpcss" -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort 135 -Group "For SQL Server DCOM"
            New-NetFirewallRule -DisplayName 'SMB Provider Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort 445 -Group "For SQL Server"
        }
        if ($_Role -contains "Provider") {
            New-NetFirewallRule -DisplayName 'SMB Provider Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort 445 -Group "For SCCM Provider"
            New-NetFirewallRule -DisplayName 'RPC Endpoint Mapper Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort 135 -Group "For SCCM Provider"
            New-NetFirewallRule -DisplayName 'RPC Endpoint Mapper UDP Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol UDP -LocalPort 135 -Group "For SCCM Provider"
            #dynamic port
            New-NetFirewallRule -DisplayName 'RPC Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort 1024-65535 -Group "For SCCM"
        }
        if ($_Role -contains "Asset Intelligence Synchronization Point") {
            New-NetFirewallRule -DisplayName 'SMB Provider Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort 445 -Group "For SCCM AISP"
            New-NetFirewallRule -DisplayName 'RPC Endpoint Mapper Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort 135 -Group "For SCCM AISP"
            New-NetFirewallRule -DisplayName 'RPC Endpoint Mapper UDP Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol UDP -LocalPort 135 -Group "For SCCM AISP"
            #rpc dynamic port
            New-NetFirewallRule -DisplayName 'RPC Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort 1024-65535 -Group "For SCCM AISP"
            New-NetFirewallRule -DisplayName 'HTTPS Outbound' -Profile Any -Direction Outbound -Action Allow -Protocol TCP -LocalPort 443 -Group "For SCCM AISP"
        }
        if ($_Role -contains "CM Console") {
            New-NetFirewallRule -DisplayName 'RPC Outbound' -Profile Any -Direction Outbound -Action Allow -Protocol TCP -LocalPort 135 -Group "For SCCM Console"
            #cm console->client
            New-NetFirewallRule -DisplayName 'Remote Control(control) Outbound' -Profile Any -Direction Outbound -Action Allow -Protocol TCP -LocalPort 2701 -Group "For SCCM Console"
            New-NetFirewallRule -DisplayName 'Remote Control(control) Outbound' -Profile Any -Direction Outbound -Action Allow -Protocol UDP -LocalPort 2701 -Group "For SCCM Console"
            New-NetFirewallRule -DisplayName 'Remote Control(data) Outbound' -Profile Any -Direction Outbound -Action Allow -Protocol TCP -LocalPort 2702 -Group "For SCCM Console"
            New-NetFirewallRule -DisplayName 'Remote Control(data) Outbound' -Profile Any -Direction Outbound -Action Allow -Protocol UDP -LocalPort 2702 -Group "For SCCM Console"
            New-NetFirewallRule -DisplayName 'Remote Control(RPC Endpoint Mapper) Outbound' -Profile Any -Direction Outbound -Action Allow -Protocol TCP -LocalPort 135 -Group "For SCCM Console"
            New-NetFirewallRule -DisplayName 'Remote Assistance(RDP AND RTC) Outbound' -Profile Any -Direction Outbound -Action Allow -Protocol TCP -LocalPort 3389 -Group "For SCCM Console"
        }
        if ($_Role -contains "DomainMember" -or $_Role -contains "WorkgroupMember") {
            #Client Push Installation
            Enable-NetFirewallRule -Group "@FirewallAPI.dll,-28502"
            Enable-NetFirewallRule -DisplayGroup "Windows Management Instrumentation (WMI)" -Direction Inbound
            New-NetFirewallRule -DisplayName 'SMB Provider Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort 445 -Group "For SCCM Client"
            New-NetFirewallRule -DisplayName 'SMB Provider Inbound' -Profile Any -Direction Outbound -Action Allow -Protocol TCP -LocalPort 445 -Group "For SCCM Client"


            #Remote Assistance and Remote Desktop
            New-NetFirewallRule -Program "C:\Windows\PCHealth\HelpCtr\Binaries\helpsvc.exe" -DisplayName "Remote Assistance - Helpsvc.exe" -Enabled True -Direction Outbound -Group "For SCCM Client"
            New-NetFirewallRule -Program "C:\Windows\PCHealth\HelpCtr\Binaries\helpsvc.exe" -DisplayName "Remote Assistance - Helpsvc.exe" -Enabled True -Direction Inbound -Group "For SCCM Client"
            New-NetFirewallRule -DisplayName 'CM Remote Assistance' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort 2701 -Group "For SCCM Client"

            #Client Requests
            New-NetFirewallRule -DisplayName 'HTTP(S) Outbound' -Profile Any -Direction Outbound -Action Allow -Protocol TCP -LocalPort @(80, 443) -Group "For SCCM Client"

            #Client Notification
            New-NetFirewallRule -DisplayName 'CM Client Notification' -Profile Any -Direction Outbound -Action Allow -Protocol TCP -LocalPort 10123 -Group "For SCCM Client"

            #Remote Control
            New-NetFirewallRule -DisplayName 'CM Remote Control' -Profile Any -Direction Outbound -Action Allow -Protocol TCP -LocalPort 2701 -Group "For SCCM Client"

            #Wake-Up Proxy
            New-NetFirewallRule -DisplayName 'Wake-Up Proxy' -Profile Any -Direction Outbound -Action Allow -Protocol UDP -LocalPort @(25536, 9) -Group "For SCCM Client"

            #SUP
            New-NetFirewallRule -DisplayName 'CM Connect SUP' -Profile Any -Direction Outbound -Action Allow -Protocol TCP -LocalPort @(8530, 8531) -Group "For SCCM Client"

            #enable firewall public profile
            if ($_Role -notcontains "WorkgroupMember") {
                Set-NetFirewallProfile -Profile Public -Enabled True
            }

            if ($_Role -contains "WorkgroupMember") {
                New-NetFirewallRule -DisplayName 'SMB Provider Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort 445 -Group "For WorkgroupMember"
                New-NetFirewallRule -DisplayName 'SMB Provider Inbound' -Profile Any -Direction Outbound -Action Allow -Protocol TCP -LocalPort 445 -Group "For WorkgroupMember"

                # Force reboot, RDP doesn't seem to work until reboot
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUserDeclaredVarsMoreThanAssignments', '', Scope = 'Function')]
                $global:DSCMachineStatus = 1
            }
        }
        $StatusPath = "$env:windir\temp\OpenFirewallStatus.txt"
        "Finished" >> $StatusPath
    }

    [bool] Test() {
        $StatusPath = "$env:windir\temp\OpenFirewallStatus.txt"
        if (Test-Path $StatusPath) {
            return $true
        }

        return $false
    }

    [OpenFirewallPortForSCCM] Get() {
        return $this
    }

}

[DscResource()]
class InstallFeatureForSCCM {
    [DscProperty(Key)]
    [string] $Name

    [DscProperty(Mandatory)]
    [string[]] $Role

    [DscProperty(NotConfigurable)]
    [string] $Version = "7"

    [void] Set() {
        $_Role = $this.Role

        Write-Status "Installing Windows Features for Role $_Role"

        # Install on all devices
        try {
            Write-Status "Installing Windows Feature TelnetClient"
            dism / online / Enable-Feature / FeatureName:TelnetClient
        }
        catch {}

        # Server OS?
        $os = Get-WmiObject -Class Win32_OperatingSystem -ErrorAction SilentlyContinue
        if ($os) {
            $IsServerOS = $true
            if ($os.ProductType -eq 1) {
                $IsServerOS = $false
            }
        }
        else {
            $IsServerOS = $false
        }

        if ($IsServerOS) {

            #
            #
            #
            #   If you add roles here, please update the Version number so existing Machines will get the new roles
            #
            #
            #

            # Collect all features into a single list, then install once for speed.
            $features = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

            # All servers
            [void]$features.Add("Web-Windows-Auth")
            [void]$features.Add("Web-ISAPI-Ext")
            [void]$features.Add("RSAT-AD-PowerShell")
            [void]$features.Add("AD-Domain-Services")

            if ($_Role -notcontains "DC" -and $_Role -notcontains "BDC") {
                # Non-DC servers get BITS and IIS metabase
                [void]$features.Add("BITS")
                [void]$features.Add("BITS-IIS-Ext")
                [void]$features.Add("Web-WMI")
                [void]$features.Add("Web-Metabase")

                if ($_Role -notcontains "DomainMember") {
                    [void]$features.Add("Rdc")
                }
            }

            if ($_Role -contains "SQLAO") {
                foreach ($f in @("Failover-Clustering", "RSAT-Clustering-PowerShell", "RSAT-Clustering-CmdInterface", "RSAT-Clustering-Mgmt")) {
                    [void]$features.Add($f)
                }
            }

            if ($_Role -contains "Site Server") {
                foreach ($f in @("Net-Framework-Core", "NET-Framework-45-Core",
                    "Web-Basic-Auth", "Web-IP-Security", "Web-Url-Auth", "Web-ASP", "Web-Asp-Net",
                    "Web-Mgmt-Console", "Web-Lgcy-Scripting", "Web-Mgmt-Service", "Web-Mgmt-Tools", "Web-Scripting-Tools",
                    "Web-WMI", "Web-Metabase", "Rdc", "UpdateServices-UI", "BITS", "BITS-IIS-Ext")) {
                    [void]$features.Add($f)
                }
            }

            if ($_Role -contains "Application Catalog website point") {
                foreach ($f in @("Web-Default-Doc", "Web-Static-Content", "Web-Asp-Net", "Web-Asp-Net45", "Web-Net-Ext", "Web-Net-Ext45", "Web-Metabase")) {
                    [void]$features.Add($f)
                }
            }

            if ($_Role -contains "Application Catalog web service point") {
                foreach ($f in @("Web-Default-Doc", "Web-Asp-Net", "Web-Asp-Net45", "Web-Net-Ext", "Web-Net-Ext45", "Web-Metabase")) {
                    [void]$features.Add($f)
                }
            }

            if ($_Role -contains "Certificate registration point") {
                foreach ($f in @("Web-Asp-Net", "Web-Asp-Net45", "Web-Metabase", "Web-WMI")) {
                    [void]$features.Add($f)
                }
            }

            if ($_Role -contains "Distribution point") {
                foreach ($f in @("Web-WMI", "Web-Metabase")) {
                    [void]$features.Add($f)
                }
            }

            if ($_Role -contains "Enrollment point") {
                foreach ($f in @("Web-Default-Doc", "Web-Asp-Net", "Web-Asp-Net45", "Web-Net-Ext", "Web-Net-Ext45", "Web-Metabase")) {
                    [void]$features.Add($f)
                }
            }

            if ($_Role -contains "Enrollment proxy point") {
                foreach ($f in @("Web-Default-Doc", "Web-Static-Content", "Web-Asp-Net", "Web-Asp-Net45", "Web-Net-Ext", "Web-Net-Ext45", "Web-Metabase")) {
                    [void]$features.Add($f)
                }
            }

            if ($_Role -contains "Fallback status point") {
                [void]$features.Add("Web-Metabase")
            }

            if ($_Role -contains "Management point") {
                foreach ($f in @("BITS", "BITS-IIS-Ext", "Web-WMI", "Web-Metabase")) {
                    [void]$features.Add($f)
                }
            }

            if ($_Role -contains "State migration point") {
                foreach ($f in @("Web-Default-Doc", "Web-Asp-Net", "Web-Asp-Net45", "Web-Net-Ext", "Web-Net-Ext45", "Web-Metabase")) {
                    [void]$features.Add($f)
                }
            }

            # Install all collected features in a single call
            $featureList = @($features)
            Write-Status "Installing $($featureList.Count) Windows Features: $($featureList -join ', ')"
            $result = Install-WindowsFeature -Name $featureList -IncludeManagementTools
            if ($result.RestartNeeded -eq "Yes") {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUserDeclaredVarsMoreThanAssignments', '', Scope = 'Function')]
                $global:DSCMachineStatus = 1
            }
        }

        $StatusPath = "$env:windir\temp\InstallFeatureStatus$($this.Role)$($this.Version).txt"
        "Finished" >> $StatusPath
    }

    [bool] Test() {
        $StatusPath = "$env:windir\temp\InstallFeatureStatus$($this.Role)$($this.Version).txt"
        if (Test-Path $StatusPath) {
            $os = Get-WmiObject -Class Win32_OperatingSystem -ErrorAction SilentlyContinue
            if ($os) {
                $IsServerOS = $true
                if ($os.ProductType -eq 1) {
                    $IsServerOS = $false
                }
            }
            else {
                $IsServerOS = $false
            }

            if ($IsServerOS) {
                if ((Get-WindowsFeature -name AD-Domain-Services).InstallState -ne "Installed") {
                    return $false
                }
            }

            return $true
        }
        return $false
       
    }

    [InstallFeatureForSCCM] Get() {
        return $this
    }
}

[DscResource()]
class SetCustomPagingFile {
    [DscProperty(Key)]
    [string] $Drive

    [DscProperty(Mandatory)]
    [string] $InitialSize

    [DscProperty(Mandatory)]
    [string] $MaximumSize

    [void] Set() {
        $_Drive = $this.Drive
        $_InitialSize = $this.InitialSize
        $_MaximumSize = $this.MaximumSize
        Write-Status "Creating Page file $_Drive\pagefile.sys Size: $_MaximumSize MB "
        $currentstatus = Get-CimInstance -ClassName 'Win32_ComputerSystem'
        if ($currentstatus.AutomaticManagedPagefile) {
            set-ciminstance $currentstatus -Property @{AutomaticManagedPagefile = $false }
        }

        $currentpagingfile = Get-CimInstance -ClassName 'Win32_PageFileSetting' -Filter "SettingID='pagefile.sys @ $_Drive'"

        if (!($currentpagingfile)) {
            Set-WmiInstance -Class Win32_PageFileSetting -Arguments @{name = "$_Drive\pagefile.sys"; InitialSize = $_InitialSize; MaximumSize = $_MaximumSize }
        }
        else {
            Set-CimInstance $currentpagingfile -Property @{InitialSize = $_InitialSize ; MaximumSize = $_MaximumSize }
        }
        Write-Status "Page file configured. $_Drive\pagefile.sys Size: $_MaximumSize MB. Rebooting."
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUserDeclaredVarsMoreThanAssignments', '', Scope = 'Function')]
        $global:DSCMachineStatus = 1
    }

    [bool] Test() {
        $_Drive = $this.Drive
        $_InitialSize = $this.InitialSize
        $_MaximumSize = $this.MaximumSize

        $isSystemManaged = (Get-CimInstance -ClassName 'Win32_ComputerSystem').AutomaticManagedPagefile
        if ($isSystemManaged) {
            return $false
        }

        $_Drive = $this.Drive
        $currentpagingfile = Get-CimInstance -ClassName 'Win32_PageFileSetting' -Filter "SettingID='pagefile.sys @ $_Drive'"
        if (!($currentpagingfile) -or !($currentpagingfile.InitialSize -eq $_InitialSize -and $currentpagingfile.MaximumSize -eq $_MaximumSize)) {
            return $false
        }

        return $true
    }

    [SetCustomPagingFile] Get() {
        return $this
    }

}

[DscResource()]
class FileReadAccessShare {
    [DscProperty(Key)]
    [string] $Name

    [DscProperty(Mandatory)]
    [string] $Path

    [void] Set() {
        $_Name = $this.Name
        $_Path = $this.Path

        Write-Status  "Creating SMB Share $_Name -> $_Path"
        New-Item -ItemType Directory -Force -Path $_Path
        New-SMBShare -Name $_Name -Path $_Path
    }

    [bool] Test() {
        $_Name = $this.Name

        $testfileshare = Get-SMBShare | Where-Object { $_.name -eq $_Name }
        if (!($testfileshare)) {
            return $false
        }

        return $true
    }

    [FileReadAccessShare] Get() {
        return $this
    }

}

[DscResource()]
class UpdateCAPrefs {
    [DscProperty(Key)]
    [string] $RootCA

    [void] Set() {
        try {
            certutil -setreg Policy\EditFlags +EDITF_ENABLELDAPREFERRALS
            Restart-Service -Name certsvc
            $StatusPath = "$env:windir\temp\UpdateCAStatus.txt"
            "Finished" >> $StatusPath

            Write-Status "Finished installing CA."
        }
        catch {
            Write-Status "Failed to install CA. $_"
        }
    }

    [bool] Test() {
        $StatusPath = "$env:windir\temp\UpdateCAStatus.txt"
        if (Test-Path $StatusPath) {
            return $true
        }

        return $false
    }

    [UpdateCAPrefs] Get() {
        return $this
    }

}

[DscResource()]
class ClusterSetOwnerNodes {
    [DscProperty(Key)]
    [string] $ClusterName

    [DscProperty()]
    [string[]]$Nodes

    [void] Set() {
        $_ClusterName = $this.ClusterName
        $_Nodes = $this.Nodes
        try {
            foreach ($c in Get-ClusterResource -Cluster $_ClusterName) {
                $NeedsFixing = $c | Get-ClusterOwnerNode | Where-Object { $_.OwnerNodes.Count -ne 2 }
                if ($NeedsFixing) {
                    Write-Status "Cluster $_ClusterName`: Setting Cluster Node owners $($_Nodes -Join ',') on $($c.Name)"
                    $c | Set-ClusterOwnerNode -owners $_Nodes
                }
            }
        }
        catch {
            Write-Status "$_ClusterName Failed to Set Owner Nodes"
            Write-Verbose "$_"
        }
    }

    [bool] Test() {

        try {
            $_ClusterName = $this.ClusterName
            $badNodes = foreach ($c in Get-ClusterResource -Cluster $_ClusterName) {
                $c | Get-ClusterOwnerNode | Where-Object { $_.OwnerNodes.Count -ne 2 }
            }

            if ($badNodes.Count -gt 0) {
                return $false
            }

            return $true
        }
        catch {
            Write-Status "Failed to Find Cluster Resources."
            Write-Verbose "$_"
            return $true
        }
    }

    [ClusterSetOwnerNodes] Get() {
        return $this
    }

}

[DscResource()]
class ClusterRemoveUnwantedIPs {
    [DscProperty(Key)]
    [string] $ClusterName

    [void] Set() {
        try {
            $_ClusterName = $this.ClusterName
            $valid = $false
            [int]$failCount = 0
            Write-Status "Getting Cluster $_ClusterName"
            $Cluster = Get-ClusterResource -Cluster $_ClusterName -ErrorAction Stop
            if ($Cluster) {
                $valid = $true
            }
            while (-not $valid -and $failCount -lt 15) {
                Write-Status "Failed to get Cluster $_ClusterName. Retrying $failCount/15"
                try {
                    $Cluster = Get-ClusterResource -Cluster $_ClusterName -ErrorAction Stop
                    if ($Cluster) {
                        $valid = $true
                    }
                    else {
                        $failCount++
                        start-sleep 60
                    }
                }
                catch {
                    Write-Verbose "$_ Failed Get-ClusterResource for $_ClusterName"
                    $failCount++
                    start-sleep 60
                }
            }
            $ResourcesToRemove = ($Cluster | Where-Object { $_.ResourceType -eq "IP Address" } | Get-ClusterParameter -Name "Address" | Select-Object ClusterObject, Value | Where-Object { $_.Value -notlike "10.250.250.*" }).ClusterObject
            if ($ResourcesToRemove) {
                foreach ($Resource in $ResourcesToRemove) {
                    Write-Status "Cluster Removing $($resource.Name)"
                    Remove-ClusterResource -Name $resource.Name -Force
                }
            }
            Write-Status "Cluster Registering new DNS records"
            Get-ClusterResource -Name "Cluster Name" | Update-ClusterNetworkNameResource
            Write-Status "Finished Removing Unwanted Cluster IPs"
        }
        catch {
            Write-Status "Failed to Remove Cluster IPs."
            Write-Verbose "$_"
        }
    }

    [bool] Test() {

        try {
            $_ClusterName = $this.ClusterName
            $valid = $false
            [int]$failCount = 0
            $Cluster = Get-ClusterResource -Cluster $_ClusterName -ErrorAction Stop
            if ($Cluster) {
                $valid = $true
            }
            while (-not $valid -and $failCount -lt 15) {
                try {
                    $Cluster = Get-ClusterResource -Cluster $_ClusterName -ErrorAction Stop
                    if ($Cluster) {
                        $valid = $true
                    }
                    else {
                        Write-Verbose "$_ Get-ClusterResource for $_ClusterName did not return an entry"
                        $failCount++
                        start-sleep 60
                    }
                }
                catch {
                    Write-Verbose "$_ Failed Get-ClusterResource for $_ClusterName"
                    $failCount++
                    start-sleep 60
                }
            }
            $ResourcesToRemove = ($Cluster | Where-Object { $_.ResourceType -eq "IP Address" } | Get-ClusterParameter -Name "Address" | Select-Object ClusterObject, Value | Where-Object { $_.Value -notlike "10.250.250.*" }).ClusterObject

            if ($ResourcesToRemove) {
                return $false
            }

            return $true
        }
        catch {
            Write-Verbose "Failed to Find Cluster IPs."
            Write-Verbose "$_"
            return $true
        }
    }

    [ClusterRemoveUnwantedIPs] Get() {
        return $this
    }

}


[DscResource()]
class ModuleAdd {
    [DscProperty(Key)]
    [string]$key = 'Always'

    [DscProperty(Mandatory)]
    [string]$CheckModuleName

    [DscProperty()]
    [string]$Clobber = 'Yes'

    [DscProperty()]
    [string]$UserScope = 'AllUsers'

    [void] Set() {

        $_moduleName = $this.CheckModuleName
        $_userScope = $this.UserScope

        write-Status "Installing powershell module $_moduleName for scope $_userScope"

        # Force TLS 1.2 for PSGallery/NuGet access - without this, older
        # Windows Server defaults to TLS 1.0/1.1 which PSGallery rejects,
        # causing Install-Module to hang or time out for up to 30 minutes.
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

        $Nuget = $null
        try {
            $NuGet = Get-PackageProvider -Name Nuget -ErrorAction SilentlyContinue -WarningAction SilentlyContinue -ListAvailable
        }
        catch { }
        
        IF ($null -eq $NuGet) {
            #Install-PackageProvider Nuget -force -Confirm:$false
            Find-PackageProvider -Name NuGet -Force | Install-PackageProvider -Force -Scope AllUsers -Confirm:$false
            Register-PackageSource -Name nuget.org -Location https://www.nuget.org/api/v2 -ProviderName NuGet -Force -Trusted
        }

        $module = Get-InstalledModule -Name PowerShellGet -ErrorAction SilentlyContinue -WarningAction SilentlyContinue 

        if ($null -eq $module) {
            try { 
                Install-Module -Name PowerShellGet -Force -Confirm:$false -Scope $_userScope -ErrorAction Stop
            }
            catch {
                Write-Verbose "$_"
                write-Status "Retry. Installing powershell module PowerShellGet for scope $_userScope"
                Clear-DnsClientCache -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 20
                Install-Module -Name PowerShellGet -Force -Confirm:$false -Scope $_userScope -SkipPublisherCheck -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
            }
        }

        # Ensure PSGallery is trusted and PowerShellGet is current in this session.
        # Without this, the first Install-Module call for the target module fails
        # because the session still has stale provider state from bootstrapping.
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
        Import-Module PowerShellGet -Force -ErrorAction SilentlyContinue

        $module = Get-InstalledModule -Name $_moduleName -ErrorAction SilentlyContinue -WarningAction SilentlyContinue

        if ($null -eq $module) {
            if ($this.Clobber -eq 'Yes') {
                try {
                    write-Status "Retry. Installing powershell module $_moduleName for scope $_userScope."
                    Install-Module -Name $_moduleName -Force -Confirm:$false -Scope $_userScope -AllowClobber -ErrorAction Stop
                }
                catch {
                    Write-Verbose "$_"
                    write-Status "Retry. Installing powershell module $_moduleName for scope $_userScope.."
                    Clear-DnsClientCache -ErrorAction SilentlyContinue
                    Start-Sleep -Seconds 20
                    Install-Module -Name $_moduleName -Force -Confirm:$false -Scope $_userScope -AllowClobber -SkipPublisherCheck -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
                }
            }
            else {
                try {
                    write-Status "Retry. Installing powershell module $_moduleName for scope $_userScope..."
                    Install-Module -Name $_moduleName -Force -Confirm:$false -Scope $_userScope -ErrorAction Stop
                }
                catch {
                    Write-Verbose "$_"
                    write-Status "Retry. Installing powershell module $_moduleName for scope $_userScope...."
                    Clear-DnsClientCache -ErrorAction SilentlyContinue
                    Start-Sleep -Seconds 20
                    Install-Module -Name $_moduleName -Force -Confirm:$false -Scope $_userScope -SkipPublisherCheck -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
                }
            }
        }
    }

    [bool] Test() {

        $_ModuleName = $this.CheckModuleName
        write-verbose ('Searching for module:' + $_ModuleName)
        $GetModuleStatus = Get-InstalledModule -Name $_ModuleName -ErrorAction SilentlyContinue -WarningAction SilentlyContinue

        if ($GetModuleStatus) {
            write-verbose ('Found module:' + $_ModuleName + 'ModuleStatus:' + $GetModuleStatus.Version)
            return $true
        }

        return $false

    }

    [ModuleAdd] Get() {
        return $this
    }

}


[DscResource()]
class ConfigureWSUS {
    [DscProperty(Key)]
    [string] $ContentPath

    [DscProperty()]
    [string]$SqlServer

    [DscProperty()]
    [string]$HTTPSUrl
    # Should usually be 'ConfigMgr WebServer Certificate'
    [DscProperty()]
    [string]$TemplateName

    hidden [void] CleanupWSUS() {
        Write-Status "Cleaning up WSUS IIS configuration..."
        
        Import-Module WebAdministration -ErrorAction SilentlyContinue
        
        # Stop WSUS Service
        $ServiceName = 'WSUSService'
        $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq 'Running') {
            Write-Status "Stopping WSUS Service..."
            Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
        }
        
        # Remove WSUS Administration website
        Write-Status "Removing WSUS Administration website..."
        $wsusWebsite = Get-Website -Name "WSUS Administration" -ErrorAction SilentlyContinue
        if ($wsusWebsite) {
            Remove-Website -Name "WSUS Administration" -ErrorAction SilentlyContinue
            Write-Verbose "WSUS Administration website removed"
        }
        
        # Remove Application Pools
        Write-Status "Removing WSUS Application Pools..."
        $appPools = @('WsusPool', 'WSUSPool')
        foreach ($poolName in $appPools) {
            $pool = Get-IISAppPool -Name $poolName -ErrorAction SilentlyContinue
            if ($pool) {
                Remove-WebAppPool -Name $poolName -ErrorAction SilentlyContinue
                Write-Verbose "Removed app pool: $poolName"
            }
        }
        
        # Remove IIS application directories
        Write-Status "Removing WSUS IIS directories..."
        $iisApps = @(
            'IIS:\Sites\WSUS Administration\ApiRemoting30',
            'IIS:\Sites\WSUS Administration\ClientWebService',
            'IIS:\Sites\WSUS Administration\DSSAuthWebService',
            'IIS:\Sites\WSUS Administration\Inventory',
            'IIS:\Sites\WSUS Administration\ReportingWebService',
            'IIS:\Sites\WSUS Administration\ServerSyncWebService',
            'IIS:\Sites\WSUS Administration\SimpleAuthWebService'
        )
        
        foreach ($app in $iisApps) {
            if (Test-Path $app) {
                Remove-Item -Path $app -Recurse -Force -ErrorAction SilentlyContinue
                Write-Verbose "Removed: $app"
            }
        }
        
        # Remove physical directories
        Write-Status "Removing WSUS physical directories..."
        $wsusPath = "$env:ProgramFiles\Update Services\WebServices"
        if (Test-Path $wsusPath) {
            Remove-Item -Path $wsusPath -Recurse -Force -ErrorAction SilentlyContinue
            Write-Verbose "Removed: $wsusPath"
        }
        
        # Remove SSL bindings for port 8531
        Write-Status "Removing SSL bindings..."
        $sslBinding = Get-WebBinding -Name "WSUS Administration" -Port 8531 -Protocol "https" -ErrorAction SilentlyContinue
        if ($sslBinding) {
            Remove-WebBinding -Name "WSUS Administration" -Port 8531 -Protocol "https" -ErrorAction SilentlyContinue
            Write-Verbose "Removed HTTPS binding on port 8531"
        }
        
        # Remove HTTP bindings for ports 8530
        $httpBinding = Get-WebBinding -Name "WSUS Administration" -Port 8530 -Protocol "http" -ErrorAction SilentlyContinue
        if ($httpBinding) {
            Remove-WebBinding -Name "WSUS Administration" -Port 8530 -Protocol "http" -ErrorAction SilentlyContinue
            Write-Verbose "Removed HTTP binding on port 8530"
        }
        
        # Clean up any remaining IIS configuration
        Write-Status "Cleaning up IIS configuration..."
        $iisConfigPaths = @(
            "IIS:\AppPools\WsusPool",
            "IIS:\AppPools\WSUSPool",
            "IIS:\Sites\WSUS Administration"
        )
        
        foreach ($path in $iisConfigPaths) {
            if (Test-Path $path) {
                Remove-Item -Path $path -Recurse -Force -ErrorAction SilentlyContinue
                Write-Verbose "Removed IIS config: $path"
            }
        }
        
        Write-Status "WSUS cleanup completed"
    }

    [void] Set() {

        $_HTTPSurl = $this.HTTPSUrl
        $_FriendlyName = $this.TemplateName
        $postinstallOutput = ""

        $ServiceName = 'WSUSService'

        $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        if (-not $svc) {
            write-verbose "Service $ServiceName not found."
            throw
        }

        # If disabled, set to Automatic
        if ($svc.StartType -eq 'Disabled') {
            Set-Service -Name $ServiceName -StartupType Automatic
            $svc = Get-Service -Name $ServiceName
        }

        # Start if not running
        if ($svc.Status -ne 'Running') {
            Start-Service -Name $ServiceName
        }

        try {
            try {
                New-Item -Path $this.ContentPath -ItemType Directory -Force
            }
            catch {
                write-verbose ("$_")
            }

            if ($this.SqlServer) {
                write-Status ("Configuring WSUS for $($this.SqlServer) in $($this.ContentPath)")
                write-verbose ("running:  'C:\Program Files\Update Services\Tools\WsusUtil.exe' postinstall SQL_INSTANCE_NAME=$($this.SqlServer) CONTENT_DIR=$($this.ContentPath)")
                $postinstallOutput = & 'C:\Program Files\Update Services\Tools\WsusUtil.exe' postinstall SQL_INSTANCE_NAME=$($this.SqlServer) CONTENT_DIR=$($this.ContentPath) 2>&1
                
                # Check for "object identifier does not represent a valid object" error
                if ($postinstallOutput -match "object identifier does not represent a valid object") {
                    Write-Status "Detected invalid object error. Performing full WSUS cleanup..."
                    Write-Verbose "Error output: $postinstallOutput"
                    
                    $this.CleanupWSUS()
                    
                    Write-Status "Re-running WSUS postinstall after cleanup..."
                    Start-Sleep -Seconds 5
                    $postinstallOutput = & 'C:\Program Files\Update Services\Tools\WsusUtil.exe' postinstall SQL_INSTANCE_NAME=$($this.SqlServer) CONTENT_DIR=$($this.ContentPath) 2>&1
                }
                
                # Check for Server 2022 and schema version error
                $osVersion = [System.Environment]::OSVersion.Version
                $isServer2022 = ($osVersion.Major -eq 10 -and $osVersion.Build -ge 20348)
                
                if ($isServer2022 -and $postinstallOutput -match "schema version of the database is from a newer version of WSUS") {
                    Write-Status "Detected schema version error on Server 2022. Running fix-postinstall.ps1..."
                    Write-Verbose "Error output: $postinstallOutput"
                    
                    & c:\tools\fix-postinstall.ps1
                    
                    Write-Status "Re-running WSUS postinstall after fix..."
                    $postinstallOutput = & 'C:\Program Files\Update Services\Tools\WsusUtil.exe' postinstall SQL_INSTANCE_NAME=$($this.SqlServer) CONTENT_DIR=$($this.ContentPath) 2>&1
                }
            }
            else {
                write-Status ("Configuring WSUS for WID in $($this.ContentPath)")
                write-verbose ("running:  'C:\Program Files\Update Services\Tools\WsusUtil.exe' postinstall CONTENT_DIR=$($this.ContentPath)")
                $postinstallOutput = & 'C:\Program Files\Update Services\Tools\WsusUtil.exe' postinstall CONTENT_DIR=$($this.ContentPath) 2>&1
                
                # Check for "object identifier does not represent a valid object" error
                if ($postinstallOutput -match "object identifier does not represent a valid object") {
                    Write-Status "Detected invalid object error. Performing full WSUS cleanup..."
                    Write-Verbose "Error output: $postinstallOutput"
                    
                    $this.CleanupWSUS()
                    
                    Write-Status "Re-running WSUS postinstall after cleanup..."
                    Start-Sleep -Seconds 5
                    $postinstallOutput = & 'C:\Program Files\Update Services\Tools\WsusUtil.exe' postinstall CONTENT_DIR=$($this.ContentPath) 2>&1
                }
                
                # Check for Server 2022 and schema version error
                $osVersion = [System.Environment]::OSVersion.Version
                $isServer2022 = ($osVersion.Major -eq 10 -and $osVersion.Build -ge 20348)
                
                if ($isServer2022 -and $postinstallOutput -match "schema version of the database is from a newer version of WSUS") {
                    Write-Status "Detected schema version error on Server 2022. Running fix-postinstall.ps1..."
                    Write-Verbose "Error output: $postinstallOutput"
                    
                    & c:\tools\fix-postinstall.ps1
                    
                    Write-Status "Re-running WSUS postinstall after fix..."
                    $postinstallOutput = & 'C:\Program Files\Update Services\Tools\WsusUtil.exe' postinstall CONTENT_DIR=$($this.ContentPath) 2>&1
                }
            }
            Write-Verbose "WSUS postinstall output: $postinstallOutput"
        }
        catch {
            Write-Status "Failed to Configure WSUS"
            Write-Verbose "$_ $postinstallOutput"
        }
        
        try {
            $wsus = get-WsusServer
        }
        catch {
            Write-Status "Failed to Configure WSUS. Could not locate WSUS Server after postinstall"
            Write-Verbose "$_"
            throw
        }

        if ($this.HTTPSUrl) {
            Write-Status "Configuring HTTPS for WSUS"
            $cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.FriendlyName -eq $_FriendlyName } | Select-Object -Last 1
            if (-not $cert) {
                Write-Status "Could not find cert with friendly Name $_FriendlyName"
                throw "Could not find cert with friendly Name $_FriendlyName"
            }

            Write-Status "Removing web binding for port 8531"
            (Get-WebBinding -Name "WSUS Administration" -Port 8531 -Protocol "https") | Remove-WebBinding

            $webBinding = (Get-WebBinding -Name "WSUS Administration" -Port 8531 -Protocol "https")
            if (-not $webBinding) {
                #New-WebBinding -Name "WSUS Administration" -Protocol https -Port 8531 -IPAddress *
                Write-Status "Creating new web binding for port 8531"
                $webBinding = New-WebBinding -Name "WSUS Administration" -IPAddress "*" -Port 8531  -Protocol "https"

            }
            $webBinding = (Get-WebBinding -Name "WSUS Administration" -Port 8531 -Protocol "https")
            if (-not $webBinding) {
                Write-Status "Could not create webbinding for 8531"
                throw "Could not create webbinding for 8531"
            }

            Write-Status "Adding SSL cert $($cert.Thumbprint) to MY store"
            $webBinding.AddSslCertificate($($cert.Thumbprint), "my")

            #$cert | New-Item -Path IIS:\SslBindings\0.0.0.0!8531

            $wsussslparams = @('ApiRemoting30', 'ClientWebService', 'DSSAuthWebService', 'ServerSyncWebService', 'SimpleAuthWebService')
            foreach ($item in $wsussslparams) {
                Write-Status "Configuring IIS for WSUS SSL"
                $cfgSection = Get-IISConfigSection -Location "WSUS Administration/$item" -SectionPath "system.webServer/security/access";
                Set-IISConfigAttributeValue -ConfigElement $cfgSection -AttributeName "sslFlags" -AttributeValue "Ssl";
            }
            Write-Status "Running WsusUtil.exe ConfigureSSL $_HTTPSurl"
            write-verbose ("running:  'C:\Program Files\Update Services\Tools\WsusUtil.exe' configuressl $_HTTPSurl")
            & 'C:\Program Files\Update Services\Tools\WsusUtil.exe' configuressl $_HTTPSurl

        }
    }

    [bool] Test() {

        try {
            $wsus = get-WsusServer
            if ($wsus) {
                return $true
            }

            return $false
        }
        catch {
            Write-Verbose "Failed to Find WSUS Server"
            Write-Verbose "$_"
            return $false
        }
    }

    [ConfigureWSUS] Get() {
        return $this
    }
}

[DscResource()]
class WSUSSync {
    [DscProperty(Key)]
    [string] $ServerName

    [void] Set() {
       
        Write-Status "Starting initial WSUSSync for $($this.ServerName) using Product: SQL Server 2005 Category: Tools"
        try {
            $WSUS = Get-WsusServer -Name $this.ServerName -PortNumber 8530 #-UseSsl
 
            Get-WsusProduct | Set-WsusProduct -disable
            Get-WsusProduct | Where-Object { $_.Product.Title -eq "SQL Server 2005" } | Set-WsusProduct
         
            Get-WsusClassification | Set-WsusClassification -disable
            Get-WsusClassification | Where-Object { $_.Classification.Title -eq "Tools" } | Set-WsusClassification
         
            $sub = $WSUS.GetSubscription()
            $sub.StartSynchronization()
        }
        catch {
            Write-Status "Initial WSUSSync failed.  Skipping."
        }
       
    }

    [bool] Test() {

        try {
            $wsus = get-WsusServer
            $sub = $WSUS.GetSubscription()
            if ($wsus) {
                if (($sub.GetUpdateCategories() | where-object { $_.Title -eq "SQL Server 2005" }).Count -ge 1) {
                    return $true
                }
            }

            return $false
        }
        catch {
            Write-Status "Failed to Find WSUS Server"
            Write-Verbose "$_"
            return $false
        }
    }

    [WSUSSync] Get() {
        return $this
    }

}


#InstallPBIRS
[DscResource()]
class InstallPBIRS {
    [DscProperty(Key)]
    [string] $InstallPath

    [DscProperty()]
    [string]$SqlServer

    [DscProperty()]
    [string]$DownloadUrl

    [DscProperty()]
    #Must be PBIRS
    [string]$RSInstance

    [DscProperty()]
    [PSCredential]$DBcredentials

    [DscProperty()]
    [bool]$IsRemoteDatabaseServer

    [DscProperty()]
    [string]$TemplateName

    [DscProperty()]
    [string]$DNSName

    [void] Set() {
        try {
            $_Creds = $this.DBcredentials
            write-Status ("Configuring PBIRS for $($this.SqlServer) in $($this.InstallPath) downloading from $($this.DownloadUrl)")

            # Verify install by checking for RSReportServer.config, not just
            # the instance folder. The config file is the last artifact the
            # installer creates; its presence proves a complete install.
            $verifyPbirs = Join-Path $this.InstallPath "$($this.RSInstance)\ReportServer\RSReportServer.config"
            $pbirsAttempt = 0
            $pbirsMaxAttempts = 3
            $pbirsExit = -1
            $needsReboot = $false

            # Skip download + install entirely if already installed
            if (Test-Path -LiteralPath $verifyPbirs) {
                Write-Status "PBIRS already installed ($verifyPbirs exists). Skipping install."
            } else {

            $pbirsSetup = "C:\temp\PowerBIReportServer.exe"
            Invoke-DownloadFile $this.DownloadUrl $pbirsSetup
            
            try {
                New-Item -Path $this.InstallPath -ItemType Directory -Force
            }
            catch {
                write-verbose ("InstallPBIRS $_")
            }


            write-Status ("Starting $pbirsSetup")
            $PBIRSargs = "/quiet /InstallFolder=$($this.InstallPath) /IAcceptLicenseTerms /Edition=Dev /Log C:\staging\PBI.log"

            # PowerBIReportServer.exe is a WiX/Burn bootstrapper bundle, so it
            # has the same silent-success failure mode as adksetup: a stale
            # dependency-provider registration ("WixBundleInstalled = 1") from
            # a prior failed install makes the bundle exit 0 in a few seconds
            # without doing real work. If config file is missing after install,
            # force /uninstall to clear the provider key and retry.
            while ($pbirsAttempt -lt $pbirsMaxAttempts) {
                $pbirsAttempt++
                Write-Status ("PBIRS install attempt $pbirsAttempt/$pbirsMaxAttempts (Start-Process -Wait, may take several minutes)...")
                $pbirsProc = Start-Process -FilePath $pbirsSetup -ArgumentList $PBIRSargs -Wait -PassThru
                $pbirsExit = $pbirsProc.ExitCode
                Write-Status ("PBIRS bootstrapper exit code: $pbirsExit (0x{0:x})" -f $pbirsExit)
                # 3010 = ERROR_SUCCESS_REBOOT_REQUIRED — install succeeded, reboot needed.
                # Treat it the same as exit 0 for the path-verification check.
                $pbirsOk = ($pbirsExit -eq 0 -or $pbirsExit -eq 3010)
                if ($pbirsOk -and (Test-Path -LiteralPath $verifyPbirs)) {
                    if ($pbirsExit -eq 3010) {
                        Write-Status "PBIRS installed successfully (SSRS subfolder present, exit 3010 = reboot required)."
                        $needsReboot = $true
                    } else {
                        Write-Status "PBIRS installed successfully (SSRS subfolder present)."
                    }
                    break
                }
                if ($pbirsOk) {
                    # 3010 without SSRS folder: bootstrapper saw a pending reboot (likely from
                    # a prior uninstall or VC++ redist) and returned immediately without
                    # installing anything. Retrying won't help — need to reboot first.
                    if ($pbirsExit -eq 3010) {
                        Write-Status "PBIRS returned 3010 but SSRS folder missing — pending reboot blocking install. Requesting reboot."
                        $needsReboot = $true
                        break
                    }
                    Write-Status "PBIRS bootstrapper reported success but expected install path missing: $verifyPbirs"
                    if (Test-Path -LiteralPath 'C:\staging\PBI.log') {
                        try {
                            $pbirsTail = Get-Content -LiteralPath 'C:\staging\PBI.log' -Tail 15 -ErrorAction SilentlyContinue
                            if ($pbirsTail) { Write-Status ("PBIRS log tail:`n{0}" -f ($pbirsTail -join "`n")) }
                        } catch { }
                    }
                }
                if ($pbirsAttempt -lt $pbirsMaxAttempts) {
                    # Exit 87 (ERROR_INVALID_PARAMETER) is often transient — file lock,
                    # bootstrapper collision, etc. Sleep and retry before resorting to
                    # uninstall which can leave a pending 3010 that poisons the next attempt.
                    if ($pbirsExit -eq 87) {
                        Write-Status "Exit 87 is often transient. Sleeping 15s before retry (no uninstall)."
                        Start-Sleep -Seconds 15
                        continue
                    }
                    Write-Status "Running PBIRS /uninstall /quiet to clear stale Burn registration before retry."
                    try {
                        $unArgs = "/uninstall /quiet /Log C:\staging\PBI-uninstall.log"
                        $unProc = Start-Process -FilePath $pbirsSetup -ArgumentList $unArgs -Wait -PassThru
                        $unExit = $unProc.ExitCode
                        Write-Status ("PBIRS /uninstall returned $unExit.")
                        # If the uninstall itself needs a reboot, retrying the install is
                        # futile — the bootstrapper will return 3010 without doing real work.
                        if ($unExit -eq 3010) {
                            Write-Status "Uninstall requires reboot (3010). Requesting reboot; install will resume after."
                            $needsReboot = $true
                            break
                        }
                    } catch {
                        Write-Status ("PBIRS /uninstall threw: $($_.Exception.Message) (continuing to retry install)")
                    }
                    Start-Sleep -Seconds 5
                }
            }
            if (-not (Test-Path -LiteralPath $verifyPbirs)) {
                if ($needsReboot) {
                    # Don't throw — let Set() exit normally so DSC processes the reboot
                    # signal. After reboot, Test() will return false (config file still
                    # missing) and LCM will call Set() again for a clean install.
                    Write-Status "PBIRS not yet installed; reboot pending. LCM will re-run Set() after reboot."
                    $global:DSCMachineStatus = 1
                    return
                } else {
                    throw "PBIRS install failed after $pbirsMaxAttempts attempts (last exit $pbirsExit). Expected path missing: $verifyPbirs. See C:\staging\PBI.log."
                }
            }

            } # end else (skip install when already present)

            try {
                write-Status ("Installing Module ReportingServicesTools")
                Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
                Install-Module -Name ReportingServicesTools -Force -AllowClobber -Confirm:$false
            }
            catch {
                Write-Verbose ("InstallPBIRS $_")
            }


            try {
                Write-Status "Calling Set-RsDatabase"
                if ($this.IsRemoteDatabaseServer) {
                    try {
                        Write-Status ("Calling Set-RsDatabase -ReportServerInstance $($this.RSInstance) -ReportServerVersion PowerBIReportServer -DatabaseServerName $($this.SqlServer) -DatabaseName ReportServer -DatabaseCredentialType Windows -Confirm:$false -IsRemoteDatabaseServer -DatabaseCredential xxxx -TrustServerCertificate")
                        Set-RsDatabase -ReportServerInstance $($this.RSInstance) -ReportServerVersion PowerBIReportServer -DatabaseServerName $($this.SqlServer) -DatabaseName ReportServer -DatabaseCredentialType Windows -Confirm:$false -IsRemoteDatabaseServer -DatabaseCredential $_Creds -TrustServerCertificate
                    }
                    catch {
                        Write-Status ("Calling2 Set-RsDatabase -ReportServerInstance $($this.RSInstance) -ReportServerVersion PowerBIReportServer -DatabaseServerName $($this.SqlServer) -DatabaseName ReportServer -DatabaseCredentialType Windows -Confirm:$false -IsRemoteDatabaseServer -DatabaseCredential xxxx -TrustServerCertificate")
                        Set-RsDatabase -ReportServerInstance $($this.RSInstance) -ReportServerVersion PowerBIReportServer -DatabaseServerName $($this.SqlServer) -DatabaseName ReportServer -DatabaseCredentialType Windows -Confirm:$false -IsRemoteDatabaseServer -DatabaseCredential $_Creds -TrustServerCertificate
                    }
                }
                else {
                    try {
                        Write-Status ("Calling Set-RsDatabase -ReportServerInstance $($this.RSInstance) -ReportServerVersion PowerBIReportServer -DatabaseServerName $($this.SqlServer) -DatabaseName ReportServer -DatabaseCredentialType Windows -Confirm:$false -DatabaseCredential xxxx -TrustServerCertificate")
                        Set-RsDatabase -ReportServerInstance $($this.RSInstance) -ReportServerVersion PowerBIReportServer -DatabaseServerName $($this.SqlServer) -DatabaseName ReportServer -DatabaseCredentialType Windows -Confirm:$false -DatabaseCredential $_Creds -TrustServerCertificate
                    }
                    catch {
                        Write-Status ("Calling2 Set-RsDatabase -ReportServerInstance $($this.RSInstance) -ReportServerVersion PowerBIReportServer -DatabaseServerName $($this.SqlServer) -DatabaseName ReportServer -DatabaseCredentialType Windows -Confirm:$false -DatabaseCredential xxxx -TrustServerCertificate")
                        Set-RsDatabase -ReportServerInstance $($this.RSInstance) -ReportServerVersion PowerBIReportServer -DatabaseServerName $($this.SqlServer) -DatabaseName ReportServer -DatabaseCredentialType Windows -Confirm:$false -DatabaseCredential $_Creds -TrustServerCertificate
                    }
                }
            }
            catch {
                Write-Verbose ("InstallPBIRS $_")
                if ($this.IsRemoteDatabaseServer) {
                    Write-Status ("Calling3 Set-RsDatabase -ReportServerInstance $($this.RSInstance) -ReportServerVersion PowerBIReportServer -DatabaseServerName $($this.SqlServer) -DatabaseName ReportServer -DatabaseCredentialType Windows -Confirm:$false -IsRemoteDatabaseServer -DatabaseCredential xxxx -IsExistingDatabase -TrustServerCertificate")
                    Set-RsDatabase -ReportServerInstance $($this.RSInstance) -ReportServerVersion PowerBIReportServer -DatabaseServerName $($this.SqlServer) -DatabaseName ReportServer -DatabaseCredentialType Windows -Confirm:$false -IsRemoteDatabaseServer -DatabaseCredential $_Creds -IsExistingDatabase -TrustServerCertificate
                }
                else {
                    Write-Status ("Calling3 Set-RsDatabase -ReportServerInstance $($this.RSInstance) -ReportServerVersion PowerBIReportServer -DatabaseServerName $($this.SqlServer) -DatabaseName ReportServer -DatabaseCredentialType Windows -Confirm:$false -DatabaseCredential xxxx -IsExistingDatabase -TrustServerCertificate")
                    Set-RsDatabase -ReportServerInstance $($this.RSInstance) -ReportServerVersion PowerBIReportServer -DatabaseServerName $($this.SqlServer) -DatabaseName ReportServer -DatabaseCredentialType Windows -Confirm:$false -DatabaseCredential $_Creds -IsExistingDatabase -TrustServerCertificate
                }
            }


            Write-Status ("Calling Set-PbiRsUrlReservation -ReportServerInstance $($this.RSInstance) -ReportServerVersion PowerBIReportServer")
            Set-PbiRsUrlReservation -ReportServerInstance $($this.RSInstance) -ReportServerVersion PowerBIReportServer -Confirm:$false


            if ($this.TemplateName) {
                Write-Status ("Enabling HTTPS")
                start-sleep -seconds 20
                $_FriendlyName = $this.TemplateName
                $_dnsName = $this.DNSName

                $httpsPort = 443
                $ipAddress = "0.0.0.0"
                $lcid = (Get-Culture).Lcid

                $wmiName = (Get-WmiObject -namespace root\Microsoft\SqlServer\ReportServer  -class __Namespace -ComputerName $env:COMPUTERNAME).Name
                $version = (Get-WmiObject -namespace root\Microsoft\SqlServer\ReportServer\$wmiName -class __Namespace).Name
                $rsConfig = Get-WmiObject -namespace "root\Microsoft\SqlServer\ReportServer\$wmiName\$version\Admin" -class MSReportServer_ConfigurationSetting

                Write-Status ("Removing HTTP ReportServerWebApp ReportServerWebService URLS")
                $rsConfig.RemoveURL("ReportServerWebApp", "https://+:$httpsPort", $lcid)
                $rsConfig.RemoveURL("ReportServerWebApp", "https://$($_dnsName):$httpsPort", $lcid)
                $rsConfig.ReserveURL("ReportServerWebApp", "https://$($_dnsName):$httpsPort", $lcid)

                $rsConfig.RemoveURL("ReportServerWebService", "https://+:$httpsPort", $lcid)
                $rsConfig.RemoveURL("ReportServerWebService", "https://$($_dnsName):$httpsPort", $lcid)
                $rsConfig.ReserveURL("ReportServerWebService", "https://$($_dnsName):$httpsPort", $lcid)
                $cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.FriendlyName -eq $_FriendlyName } | Select-Object -Last 1
                if (-not $cert) {
                    throw "Could not find cert with friendly Name $_FriendlyName"
                }

                Write-Status ("Adding HTTPS ReportServerWebApp ReportServerWebService URLS")
                $thumbprint = $cert.ThumbPrint.ToLower()
                $rsConfig.CreateSSLCertificateBinding('ReportServerWebApp', $Thumbprint, $ipAddress, $httpsport, $lcid)
                $rsConfig.CreateSSLCertificateBinding('ReportServerWebService', $Thumbprint, $ipAddress, $httpsport, $lcid)
                $rsConfig.SetSecureConnectionLevel("1")
                $rsConfig.DeleteEncryptedInformation()
                $rsConfig.ReencryptSecureInformation()
                $rsconfig.SetServiceState($false, $false, $false)
                $rsconfig.SetServiceState($true, $true, $true)
            }
            Write-Status ("Restart PowerBIReportServer Service")
            Start-Sleep -Seconds 3
            Restart-Service -Name "PowerBIReportServer" -Force
            Start-Sleep -Seconds 5
            Write-Status ("Calling Initialize-Rs -ReportServerInstance $($this.RSInstance) -ReportServerVersion PowerBIReportServer")
            try { Initialize-Rs -ReportServerInstance $($this.RSInstance) -ReportServerVersion PowerBIReportServer } catch {}
            Write-Status ("Restart PowerBIReportServer Service")
            Restart-Service -Name "PowerBIReportServer" -Force
            try {
                Get-Service | Where-Object { $_.Name -eq "SQLSERVERAGENT" -or $_.Name -like "SqlAgent*" } | Start-Service
            }
            catch {}

            if ($needsReboot) {
                Write-Status "Requesting reboot for pending PBIRS prerequisite updates (exit 3010)."
                $global:DSCMachineStatus = 1
            }
        }
        catch {
            Write-Status "Failed to Configure PBIRS"
            Write
            Write-Verbose "$_"
        }
    }

    [bool] Test() {
        try {
            # Service must be installed and running
            if ($this.RSInstance -eq "PBIRS") {
                $service = Get-Service PowerBIReportServer -ErrorAction SilentlyContinue
                if (-not $service -or $service.Status -ne "Running") {
                    Write-Verbose "InstallPBIRS Test: PowerBIReportServer service not running."
                    return $false
                }
            }

            # Instance subfolder must exist (proves install completed)
            $ssrsPath = Join-Path $this.InstallPath $this.RSInstance

            # RSReportServer.config must exist (proves install completed fully)
            $configPath = Join-Path $ssrsPath 'ReportServer\RSReportServer.config'
            if (-not (Test-Path -LiteralPath $configPath)) {
                Write-Verbose "InstallPBIRS Test: RSReportServer.config not found at $configPath"
                return $false
            }

            # Check database configuration via WMI (the definitive source).
            # RSReportServer.config's <DSN> element is often empty/encrypted;
            # WMI always has the real DatabaseName after Set-RsDatabase.
            $wmiNs = $null
            try {
                $wmiRS = Get-WmiObject -Namespace root\Microsoft\SqlServer\ReportServer -Class __Namespace -ErrorAction Stop
                $rsName = $wmiRS.Name
                $wmiVer = Get-WmiObject -Namespace "root\Microsoft\SqlServer\ReportServer\$rsName" -Class __Namespace -ErrorAction Stop
                $verName = $wmiVer.Name
                $wmiNs = "root\Microsoft\SqlServer\ReportServer\$rsName\$verName\Admin"
            } catch {
                Write-Verbose "InstallPBIRS Test: cannot enumerate PBIRS WMI namespace: $_"
                return $false
            }

            $rsConfig = Get-WmiObject -Namespace $wmiNs -Class MSReportServer_ConfigurationSetting -ErrorAction SilentlyContinue
            if (-not $rsConfig) {
                Write-Verbose "InstallPBIRS Test: MSReportServer_ConfigurationSetting not found in $wmiNs"
                return $false
            }

            # DatabaseName must be populated (proves Set-RsDatabase ran)
            if ([string]::IsNullOrWhiteSpace($rsConfig.DatabaseName)) {
                Write-Verbose "InstallPBIRS Test: database not configured (empty DatabaseName in WMI)"
                return $false
            }

            # At least one URL must be reserved
            $urls = $rsConfig.ListReservedUrls()
            if (-not $urls -or -not $urls.UrlString -or $urls.UrlString.Count -eq 0) {
                Write-Verbose "InstallPBIRS Test: no URL reservations in WMI"
                return $false
            }

            return $true
        }
        catch {
            Write-Verbose "InstallPBIRS Test: $_"
            return $false
        }
    }

    [InstallPBIRS] Get() {
        return $this
    }

}

[DscResource()]
class RebootNow {
    [DscProperty(Key)]
    [string]$FileName

    [void] Set() {

        $_FileName = $this.FileName

        if (-not (Test-Path $_FileName)) {
            Write-Status "Rebooting machine."
            Start-sleep -seconds 4
            New-Item $_FileName
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUserDeclaredVarsMoreThanAssignments', '', Scope = 'Function')]
            $global:DSCMachineStatus = 1
            return
        }

        Write-Verbose "Not Rebooting"
    }

    [bool] Test() {

        $_FileName = $this.FileName
        if (-not (Test-Path $_FileName)) {
            return $false
        }

        # Even if marker file exists, force reboot if there's a pending computer rename
        # (handles retry scenarios where prior run was interrupted after rename but before reboot completed)
        try {
            $activeName = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' -ErrorAction Stop).ComputerName
            $pendingName = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' -ErrorAction Stop).ComputerName
            if ($activeName -ne $pendingName) {
                Write-Verbose "Pending computer rename detected ($activeName -> $pendingName). Forcing reboot."
                return $false
            }
        }
        catch {
            Write-Verbose "Could not check pending rename: $_"
        }

        return $true
    }

    [RebootNow] Get() {
        return $this
    }

}

[DscResource()]
class InstallRootCertificate {
    [DscProperty(Key)]
    [string]$CAName


    [void] Set() {

        $_FileName = "C:\Temp\rootCA.cer"


        if (-not (Test-Path $_FileName)) {
            Write-Status "Install Root Cert"

            # Get the full certificate chain from the CA (works for both single-tier and two-tier PKI)
            $chainFile = "C:\Temp\ca_chain.p7b"
            certutil.exe -config $this.CAName -ca.chain $chainFile

            # Import the PKCS#7 chain and find root (self-signed) vs subordinate certs
            $chainCerts = [System.Security.Cryptography.X509Certificates.X509Certificate2Collection]::new()
            $chainCerts.Import($chainFile)

            $rootCert = $chainCerts | Where-Object { $_.Subject -eq $_.Issuer } | Select-Object -First 1
            $subCACert = $chainCerts | Where-Object { $_.Subject -ne $_.Issuer } | Select-Object -First 1

            if (-not $rootCert) {
                Write-Status "WARNING: Could not find root CA in chain, falling back to -ca.cert"
                certutil.exe -config $this.CAName -ca.cert $_FileName
            }
            else {
                [System.IO.File]::WriteAllBytes($_FileName, $rootCert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert))
                Write-Status "Exported root CA '$($rootCert.Subject)' to $_FileName"
            }

            # Publish root CA cert as RootCA and NtauthCA
            Write-Status "Running certutil.exe -dspublish -f $_FileName RootCA"
            certutil.exe -dspublish -f $_FileName RootCA
            Write-Status "Running certutil.exe -dspublish -f $_FileName NtauthCA"
            certutil.exe -dspublish -f $_FileName NtauthCA

            # If two-tier PKI, publish the subordinate CA cert as SubCA
            if ($subCACert) {
                $subCACertFile = "C:\Temp\subCA.cer"
                [System.IO.File]::WriteAllBytes($subCACertFile, $subCACert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert))
                Write-Status "Two-tier PKI: publishing subordinate CA '$($subCACert.Subject)' as SubCA"
                certutil.exe -dspublish -f $subCACertFile SubCA
            }
            else {
                # Single-tier: the CA is the root, publish as SubCA too
                Write-Status "Running certutil.exe -dspublish -f $_FileName SubCA"
                certutil.exe -dspublish -f $_FileName SubCA
            }
        }


    }

    [bool] Test() {

        $_FileName = "C:\Temp\rootCA.cer"
        if (-not (Test-Path $_FileName)) {
            return $false
        }

        return $true
    }

    [InstallRootCertificate] Get() {
        return $this
    }

}



[DscResource()]
class AddCertificateTemplate {
    [DscProperty(Key)]
    [string]$TemplateName

    [DscProperty()]
    [string]$GroupName

    [DscProperty()]
    [string]$Permissions

    [DscProperty()]
    [bool]$PermissionsOnly

    [DscProperty()]
    [bool]$SkipIfNotExist

    [void] Set() {

        $_TemplateName = $this.TemplateName
        $_Group = $this.GroupName
        $_Permissions = $this.Permissions
        $_Skip = $this.SkipIfNotExist

        Write-Status "Adding Certificate Template $_TemplateName"           

        if (-not $this.PermissionsOnly) {
            $_Path = "C:\staging\DSC\CertificateTemplates\$_TemplateName.ldf"
            if (!(Test-Path -Path $_Path -PathType Leaf)) {
                Write-Status "Could not find $_Path"
                throw "Could not find $_Path"
            }
        }

        $registryKey = "HKLM:\SOFTWARE\Microsoft\Cryptography\CertificateTemplateCache"
        Write-Status "Removing $registryKey TimeStamp"  
        Remove-ItemProperty -Path $registryKey -Name "Timestamp" -Force -ErrorAction SilentlyContinue
        Write-Status "Restarting CertSvc"
        restart-Service -Name CertSvc -ErrorAction SilentlyContinue
        Write-Status "Adding Certificate Template $_TemplateName ."   
        if ($_Group) {

            # Force TLS 1.2 before any PSGallery access - prevents 30-min
            # hangs on Server 2016/2019 where .NET defaults to TLS 1.0/1.1.
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

            $module = Get-InstalledModule -Name PSPKI -ErrorAction SilentlyContinue -WarningAction SilentlyContinue

            IF ($null -eq $module) {
                Write-Status "Installing PSPKI Module"  
                Write-Verbose "Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force"
                Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
                Write-Verbose "Install-Module -Name PSPKI -Force:$true -Confirm:$false -MaximumVersion 4.2.0"
                Install-Module -Name PSPKI -Force:$true -Confirm:$false -MaximumVersion 4.2.0 -SkipPublisherCheck
            }
            Write-Status "Adding Certificate Template $_TemplateName .." 
            Write-Verbose "Get-Command -Module PSPKI"
            Get-Command -Module PSPKI  | Out-null
            #Write-Verbose "PSPKI\Get-CertificateTemplate -Name $_TemplateName ..."
            $retries = 0
            $success = $false
            while ($retries -lt 10 -and $success -eq $false) {
                Write-Status "Adding Certificate Template $_TemplateName ..."                 
                try {
                    if ($retries -eq 0) {
                        Get-CertificationAuthority | Get-CRLValidityPeriod | Set-CRLValidityPeriod -BaseCRL "22 weeks" -BaseCRLOverlap "12 weeks" -DeltaCRL "0 days" -ErrorAction SilentlyContinue
                        #Get-CertificationAuthority | Get-CRLValidityPeriod | Set-CRLValidityPeriod -BaseCRL "22 weeks" -BaseCRLOverlap "2 weeks" -DeltaCRL "1 hours" -DeltaCRLOverlap "1 weeks" -ErrorAction SilentlyContinue
                    }
                }
                catch {}
                $retries++
                try {
                    Write-Status "PSPKI\Get-CertificateTemplate -Name $_TemplateName -ErrorAction stop"
                    $template = PSPKI\Get-CertificateTemplate -Name $_TemplateName -ErrorAction stop

                    if (-not $template -and $_Skip) {
                        return
                    }
                    Write-Status "PSPKI\Get-CertificateTemplateAcl -ErrorAction stop"
                    $templateacl = $template | PSPKI\Get-CertificateTemplateAcl -ErrorAction stop

                    Write-Status "PSPKI\Add-CertificateTemplateAcl -Identity $_Group -AccessType Allow -AccessMask $_Permissions -ErrorAction stop"
                    $templateacl2 = $templateacl |  PSPKI\Add-CertificateTemplateAcl -Identity $_Group -AccessType Allow -AccessMask $_Permissions -ErrorAction stop

                    Write-Status "PSPKI\Set-CertificateTemplateAcl -ErrorAction stop"
                    $templateacl2 | PSPKI\Set-CertificateTemplateAcl -ErrorAction stop
                    $success = $true
                }
                catch {
                    if ($_Skip) {
                        return
                    }
                    try {
                        $registryKey = "HKLM:\SOFTWARE\Microsoft\Cryptography\CertificateTemplateCache"
                        Remove-ItemProperty -Path $registryKey -Name "Timestamp" -Force -ErrorAction SilentlyContinue
                        Write-Status "Restarting CertSvc"
                        restart-Service -Name CertSvc -ErrorAction SilentlyContinue
                        start-sleep -Seconds 15
                    }
                    catch {
                        Write-Verbose "Starting CertSvc: $_"
                    }

                    try {
                        Write-Status "PSPKI\Get-CertificateTemplate -Name $_TemplateName |  PSPKI\Get-CertificateTemplateAcl |  PSPKI\Add-CertificateTemplateAcl -Identity $_Group -AccessType Allow -AccessMask $_Permissions |  PSPKI\Set-CertificateTemplateAcl"
                        PSPKI\Get-CertificateTemplate -Name $_TemplateName |  PSPKI\Get-CertificateTemplateAcl |  PSPKI\Add-CertificateTemplateAcl -Identity $_Group -AccessType Allow -AccessMask $_Permissions |  PSPKI\Set-CertificateTemplateAcl
                        $success = $true
                    }
                    catch {
                        Write-Verbose "$_"
                        if (-not (Test-Path "C:\temp\certreboot2.txt")) {
                            Write-Status "Rebooting $_"
                            New-Item "C:\temp\certreboot2.txt"
                            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUserDeclaredVarsMoreThanAssignments', '', Scope = 'Function')]
                            $global:DSCMachineStatus = 1
                            return
                        }
                    }
                }
            }
        }

        try {
            Write-Status "Adding Certificate Template $_TemplateName ...." 
            $registryKey = "HKLM:\SOFTWARE\Microsoft\Cryptography\CertificateTemplateCache"
            Remove-ItemProperty -Path $registryKey -Name "Timestamp" -Force -ErrorAction SilentlyContinue
            $registryKey = "HKCU:\SOFTWARE\Microsoft\Cryptography\CertificateTemplateCache"
            Remove-ItemProperty -Path $registryKey -Name "Timestamp" -Force -ErrorAction SilentlyContinue
            Restart-Service -Name CertSvc -ErrorAction SilentlyContinue
            start-sleep -seconds 15
        }
        catch {}
        if (-not $this.PermissionsOnly) {
            $count = (ADCSAdministration\get-CaTemplate | Where-Object { $_.Name -eq $_TemplateName }).Count
            while ($count -eq 0) {
                try {
                    Write-Status "ADCSAdministration\Add-CATemplate $_TemplateName -Force -ErrorAction Stop"
                    ADCSAdministration\Add-CATemplate $_TemplateName -Force -ErrorAction Stop
                }
                catch {
                    try {
                        Write-Status "Adding Certificate Template $_TemplateName ....." 
                        Start-Service -Name CertSvc
                        Start-Sleep -Seconds 10
                        Write-Verbose "$_"
                        Write-Status "PSPKI\Get-CertificationAuthority | PSPKI\Add-CATemplate -Name $_TemplateName"
                        $output = PSPKI\Get-CertificationAuthority | PSPKI\Add-CATemplate -Name $_TemplateName
                        Write-Verbose "$output"
                        $output = PSPKI\Get-CA | PSPKI\Add-CATemplate -Name $_TemplateName
                        Write-Verbose "$output"
                    }
                    catch {
                        # Reboot
                        Write-Verbose "$_"
                        if (-not (Test-Path "C:\temp\certreboot.txt")) {
                            Write-Status "Rebooting $_"
                            New-Item "C:\temp\certreboot.txt"
                            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUserDeclaredVarsMoreThanAssignments', '', Scope = 'Function')]
                            $global:DSCMachineStatus = 1
                            return
                        }
                        throw
                    }
                }
                $count = (ADCSAdministration\get-CaTemplate | Where-Object { $_.Name -eq $_TemplateName }).Count
                if ($count -ne 0) {
                    Write-Status "$_TemplateName added successfully"
                }
                else {
                    try {
                        Write-Status "Deleting CertificateTemplateCache and restarting the CA" 
                        $registryKey = "HKLM:\SOFTWARE\Microsoft\Cryptography\CertificateTemplateCache"
                        Remove-ItemProperty -Path $registryKey -Name "Timestamp" -Force -ErrorAction SilentlyContinue
                        $registryKey = "HKCU:\SOFTWARE\Microsoft\Cryptography\CertificateTemplateCache"
                        Remove-ItemProperty -Path $registryKey -Name "Timestamp" -Force -ErrorAction SilentlyContinue
                        Restart-Service -Name CertSvc -ErrorAction SilentlyContinue
                        start-sleep -seconds 15
                    }
                    catch {}
                }
            }
        }
    }

    [bool] Test() {

        $_Skip = $this.SkipIfNotExist
        $_TemplateName = $this.TemplateName

        if ($this.PermissionsOnly) {
            if ($_Skip) {
                try {
                    $count = (ADCSAdministration\get-Catemplate | Where-Object { $_.Name -eq $_TemplateName }).Count
                }
                catch {
                    return $true
                }
                if ($count -eq 0) {
                    return $true
                }
            }
            return $false
        }
        
        try {
            Write-Verbose " -- ADCSAdministration\get-Catemplate"
            $count = (ADCSAdministration\get-Catemplate | Where-Object { $_.Name -eq $_TemplateName }).Count
        }
        catch {
            if ($_Skip) {
                return $true
            }
            Write-Verbose "$_"
            Write-Verbose " -- Restart-Service -Name CertSvc"
            $registryKey = "HKLM:\SOFTWARE\Microsoft\Cryptography\CertificateTemplateCache"
            Remove-ItemProperty -Path $registryKey -Name "Timestamp" -Force -ErrorAction SilentlyContinue
            Restart-Service -Name CertSvc -ErrorAction SilentlyContinue
            start-sleep -seconds 15
            Write-Verbose " -- ADCSAdministration\get-Catemplate"
            $count = (ADCSAdministration\get-Catemplate | Where-Object { $_.Name -eq $_TemplateName }).Count
        }
        if ($count -gt 0) {
            return $true
        }
        else {
            if ($_Skip) {
                return $true
            }
        }

        return $false
    }

    [AddCertificateTemplate] Get() {
        return $this
    }

}

[DscResource()]
class AddCertificateToIIS {
    [DscProperty(Key)]
    [string]$FriendlyName

    [void] Set() {

        $_FriendlyName = $this.FriendlyName

        Write-Status "Installing cert $_FriendlyName to IIS"
        $cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.FriendlyName -eq $_FriendlyName } | Select-Object -Last 1
        if (-not $cert) {
            Write-Status "Could not find cert with friendly Name $_FriendlyName"
            throw "Could not find cert with friendly Name $_FriendlyName"
        }
        try {
            netsh http delete sslcert ipport=0.0.0.0:443
        }
        catch {}


        #netsh http add sslcert ipport=0.0.0.0:443 certhash=$($cert.Thumbprint) appid='{4dc3e181-e14b-4a21-b022-59fc669b0914}' certstorename=My verifyclientcertrevocation=enable
        #New-WebBinding -Name "Default Web Site" -Protocol https -Port 443 -IPAddress *


        $webBinding = (Get-WebBinding -Name "Default Web Site" -Port 443 -Protocol "https")
        if (-not $webBinding) {
            New-WebBinding -Name "Default Web Site" -IPAddress "*" -Port 443  -Protocol "https"
        }
        $webBinding = (Get-WebBinding -Name "Default Web Site" -Port 443 -Protocol "https")
        if (-not $webBinding) {
            throw "Could not create webbinding for 443"
        }
        $webBinding.AddSslCertificate($($cert.Thumbprint), "my")

    }

    [bool] Test() {

        try {
            $_FriendlyName = $this.FriendlyName
            $cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.FriendlyName -eq $_FriendlyName } | Select-Object -Last 1
            $certdata = netsh http show sslcert ipport=0.0.0.0:443
            $thumbPrint = $($cert.Thumbprint).ToLower()
            if ($certdata.ToLower() -match $thumbPrint ) {
                return $true
            }
        }
        catch {
            Write-Verbose "$_"
            return $false
        }

        return $false
    }

    [AddCertificateToIIS] Get() {
        return $this
    }

}

[DscResource()]
class AddToAdminGroup {
    [DscProperty(Key)]
    [string]$DomainName

    [DscProperty()]
    [System.Management.Automation.PSCredential] $RemoteCreds

    [DscProperty(Mandatory)]
    [string[]] $AccountNames

    [DscProperty(Key)]
    [string] $TargetGroup
    [void] Set() {


        Write-Status "Adding accounts to $($this.TargetGroup)"
        $retries = 120
        $tryno = 0
        $DisplayAccountName = "$($this.AccountNames -join ',')"
        while ($tryno -le $retries) {
            $tryno++
            try {
                if ($this.DomainName -ne "NONE") {
                    foreach ($AccountName in $this.AccountNames) {
                        $DisplayAccountName = "$($this.DomainName)\$AccountName"

                        if ($AccountName.EndsWith("$")) {                           
                            Write-Status "Adding Computer $DisplayAccountName to $($this.TargetGroup)"
                            $user1 = Get-ADComputer -Identity $AccountName -server $this.DomainName -AuthType Negotiate -Credential $this.RemoteCreds
                        }
                        else {
                            Write-Status "Adding User  $DisplayAccountName to $($this.TargetGroup)"
                            $user1 = Get-ADuser -Identity $AccountName -server $this.DomainName -AuthType Negotiate -Credential $this.RemoteCreds
                        }
                        Write-Verbose "Add-ADGroupMember -Identity $($this.TargetGroup) -Members $user1 ($DisplayAccountName)"
                        Add-ADGroupMember -Identity $this.TargetGroup -Members $user1
                    }
                }
                else {
                    foreach ($AccountName in $this.AccountNames) {

                        $DisplayAccountName = "$AccountName"
                        if ($AccountName.EndsWith("$")) {
                            Write-Status "Adding Computer $DisplayAccountName"
                            $user2 = Get-ADComputer -Identity $AccountName
                        }
                        else {
                            Write-Status "Adding User $DisplayAccountName"
                            $user2 = Get-ADuser -Identity $AccountName
                        }
                        Write-Verbose "Add-ADGroupMember -Identity $($this.TargetGroup) -Members $user2 ($DisplayAccountName)"
                        Add-ADGroupMember -Identity $this.TargetGroup -Members $user2
                    }
                }
            }
            catch {
                Write-Status "Failed to add $DisplayAccountName To $($this.TargetGroup).  Retrying. $tryno/$retries"
                Write-Verbose $_
                start-sleep -seconds 5
                continue
            }
            Write-Status "Done $DisplayAccountName."
            return
        }

    }

    [bool] Test() {

        return $false
    }

    [AddToAdminGroup] Get() {
        return $this
    }

}

[DscResource()]
class RunPkiSync {
    [DscProperty(Key)]
    [string]$SourceForest

    [DscProperty(Key)]
    [string]$TargetForest
    [void] Set() {


        write-Status "Running PKISync from $($this.SourceForest) to $($this.TargetForest)"
        $MaxRetries = 20
        $retry = 0
        while ($true) {

            if ($retry -ge $MaxRetries) {
                Write-Verbose "Failed to connect to target forests after $MaxRetries attempts"
                return
            }
            $retry++

            
            try {
                Write-Status "Attempting to connect to $($this.TargetForest)"
                $TargetForestContext = New-Object System.DirectoryServices.ActiveDirectory.DirectoryContext Forest, $this.TargetForest
                $TargetForObj = [System.DirectoryServices.ActiveDirectory.Forest]::GetForest($TargetForestContext)
                if (-not $TargetForObj) {
                    throw "Could not connect to $($this.TargetForest)"
                }

            }
            catch {
                Clear-DnsClientCache -ErrorAction SilentlyContinue
                gpupdate.exe /force
                Write-Verbose $_
                Start-Sleep -Seconds 20
                continue
            }
            try {
                Write-Status "Attempting to connect to $($this.SourceForest)"
                $SourceForestContext = New-Object System.DirectoryServices.ActiveDirectory.DirectoryContext Forest, $this.SourceForest
                $SourceForObj = [System.DirectoryServices.ActiveDirectory.Forest]::GetForest($SourceForestContext)
                if (-not $SourceForObj) {
                    throw "Could not connect to $($this.SourceForest)"
                }
            }
            catch {
                Clear-DnsClientCache -ErrorAction SilentlyContinue
                gpupdate.exe /force
                Write-Verbose $_
                Start-Sleep -Seconds 20
                continue
            }

            break
        }

        Write-Status "Running C:\staging\DSC\phases\PKISync.Ps1"
        C:\staging\DSC\phases\PKISync.Ps1 -sourceforest $this.SourceForest -targetforest $this.TargetForest -f
    }

    [bool] Test() {

        return $false
    }

    [RunPkiSync] Get() {
        return $this
    }

}

[DscResource()]
class GpUpdate {
    [DscProperty(Key)]
    [string]$Run

    [void] Set() {
        Write-Status "Forcing a gpupdate"
        gpupdate.exe /force
    }

    [bool] Test() {

        return $false
    }

    [GpUpdate] Get() {
        return $this
    }

}

[DscResource()]
class SetDNSAddress {
    [DscProperty(Key)]
    [string] $Name

    [DscProperty(Mandatory)]
    [string[]] $Address

    [void] Set() {
        $alias = (Get-NetAdapter | Select-Object -First 1).Name
        Write-Status "Setting DNS to $($this.Address -join ', ') on $alias"
        Set-DnsClientServerAddress -InterfaceAlias $alias -ServerAddresses $this.Address
    }

    [bool] Test() {
        $alias = (Get-NetAdapter | Select-Object -First 1).Name
        $current = (Get-DnsClientServerAddress -InterfaceAlias $alias -AddressFamily IPv4).ServerAddresses
        $desired = $this.Address
        return ($null -ne $current -and ($current -join ',') -eq ($desired -join ','))
    }

    [SetDNSAddress] Get() {
        return $this
    }
}
