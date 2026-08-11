# Progress records from a pushed DSC run marshal back to the pushing client over
# WmiPrvSE -> Winmgmt -> WinRM, and block the engine if that client never drains them.
$ProgressPreference = 'SilentlyContinue'

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


function Copy-MemlabsCachedFile {
    # Cache-first delivery: if the MemLabs download-cache DVD (volume label
    # MEMLABSCACHE) is mounted and contains the file for $Url, verify it against
    # the on-disc manifest (size + SHA1) and copy it to $Dest. Returns $true on a
    # verified hit; $false (never throws) on any miss so the caller downloads
    # normally. The manifest is keyed by URL -- the same URL the DSC resource
    # already passes in -- so no per-resource filename knowledge is required.
    param([string] $Url, [string] $Dest)
    if ([string]::IsNullOrWhiteSpace($Url) -or [string]::IsNullOrWhiteSpace($Dest)) { return $false }
    try {
        $drive = $null
        foreach ($cd in (Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=5" -ErrorAction SilentlyContinue)) {
            if ($cd.VolumeName -eq 'MEMLABSCACHE' -and $cd.DeviceID) { $drive = $cd.DeviceID; break }
        }
        if (-not $drive) { return $false }

        $manifestPath = Join-Path "$drive\" 'manifest.json'
        if (-not (Test-Path $manifestPath)) { return $false }
        $manifest = Get-Content -Path $manifestPath -Raw -ErrorAction Stop | ConvertFrom-Json
        if (-not $manifest -or -not $manifest.files) { return $false }

        $entry = $null
        $urlTrim = $Url.Trim()
        foreach ($prop in $manifest.files.psobject.properties) {
            if ($prop.Name -eq $Url -or [string]::Equals($prop.Name.Trim(), $urlTrim, [System.StringComparison]::OrdinalIgnoreCase)) {
                $entry = $prop.Value
                break
            }
        }
        if (-not $entry -or -not $entry.file) { return $false }

        $src = Join-Path "$drive\" $entry.file
        if (-not (Test-Path $src)) { return $false }

        $srcItem = Get-Item $src -ErrorAction Stop
        if ($entry.size -and ([int64]$srcItem.Length -ne [int64]$entry.size)) { return $false }
        if ($entry.sha1) {
            $h = (Get-FileHash -Algorithm SHA1 -Path $src -ErrorAction Stop).Hash.ToLowerInvariant()
            if ($h -ne ([string]$entry.sha1).ToLowerInvariant()) { return $false }
        }

        $destDir = Split-Path $Dest -Parent
        if ($destDir -and -not (Test-Path $destDir)) { New-Item -ItemType Directory -Force -Path $destDir | Out-Null }
        $hashCachePath = "$Dest.SHA1"
        if (Test-Path $Dest) { Remove-Item $Dest -Force -ErrorAction SilentlyContinue | Out-Null }
        if (Test-Path $hashCachePath) { Remove-Item $hashCachePath -Force -ErrorAction SilentlyContinue | Out-Null }
        Copy-Item -Path $src -Destination $Dest -Force -ErrorAction Stop
        if (-not (Test-Path $Dest)) { return $false }
        if ($entry.sha1) {
            $destItem = Get-Item $Dest -ErrorAction Stop
            @(
                ([string]$entry.sha1).ToLowerInvariant()
                $destItem.Length.ToString()
                $destItem.LastWriteTimeUtc.ToString('o')
            ) | Out-File -FilePath $hashCachePath -Force
        }
        return $true
    }
    catch {
        return $false
    }
}


function Initialize-MemlabsCachedHashSidecar {
    param([string] $Url, [string] $Dest, [string] $ExpectedHash)
    if (-not (Test-Path $Dest) -or [string]::IsNullOrWhiteSpace($ExpectedHash)) { return $false }
    try {
        $drive = $null
        foreach ($cd in (Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=5" -ErrorAction SilentlyContinue)) {
            if ($cd.VolumeName -eq 'MEMLABSCACHE' -and $cd.DeviceID) { $drive = $cd.DeviceID; break }
        }
        if (-not $drive) { return $false }

        $manifestPath = Join-Path "$drive\" 'manifest.json'
        if (-not (Test-Path $manifestPath)) { return $false }
        $manifest = Get-Content -Path $manifestPath -Raw -ErrorAction Stop | ConvertFrom-Json
        $entry = $null
        $urlTrim = $Url.Trim()
        foreach ($prop in $manifest.files.psobject.properties) {
            if ($prop.Name -eq $Url -or [string]::Equals($prop.Name.Trim(), $urlTrim, [System.StringComparison]::OrdinalIgnoreCase)) {
                $entry = $prop.Value
                break
            }
        }
        if (-not $entry -or -not $entry.file -or -not $entry.sha1) { return $false }
        if (-not [string]::Equals([string]$entry.sha1, $ExpectedHash, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }

        $src = Join-Path "$drive\" $entry.file
        if (-not (Test-Path $src)) { return $false }
        $srcItem = Get-Item $src -ErrorAction Stop
        $destItem = Get-Item $Dest -ErrorAction Stop
        if ($srcItem.Length -ne $destItem.Length -or $srcItem.LastWriteTimeUtc -ne $destItem.LastWriteTimeUtc) { return $false }
        if ($entry.size -and ([int64]$destItem.Length -ne [int64]$entry.size)) { return $false }

        @(
            $ExpectedHash.ToLowerInvariant()
            $destItem.Length.ToString()
            $destItem.LastWriteTimeUtc.ToString('o')
        ) | Out-File -FilePath "$Dest.SHA1" -Force
        return $true
    }
    catch {
        return $false
    }
}


function Invoke-DownloadFile {
    param(
        [string] $url,
        [string] $dest
    )

    # Cache-first: serve from the mounted MemLabs cache DVD when available. On any
    # miss this is a no-op and we fall through to the normal download chain.
    try {
        if (Copy-MemlabsCachedFile -Url $url -Dest $dest) {
            Write-Status "Using cached $([System.IO.Path]::GetFileName($dest)) from MemLabs cache DVD"
            return
        }
    }
    catch { Write-Verbose "Cache-first lookup failed: $($_.Exception.Message)" }

    if ((Test-Path $dest)) {
        Remove-Item $dest -Force -ErrorAction SilentlyContinue | Out-Null
    }

    if (!(Test-Path $dest)) {
        Write-Status "Downloading $url to $dest"
        $dirname = Split-Path $dest -Parent
        New-Item -ItemType Directory -Force -Path $dirname
        try {
            # Best-effort expected size (for a percentage display); aka.ms redirects are followed.
            $expectedBytes = 0
            try {
                $head = [System.Net.HttpWebRequest]::Create($url)
                $head.Method = "HEAD"
                $head.AllowAutoRedirect = $true
                $head.UserAgent = "memlabs-dsc"
                $headResp = $head.GetResponse()
                $expectedBytes = [int64]$headResp.ContentLength
                $headResp.Close()
            }
            catch { $expectedBytes = 0 }

            # Async download so we can report progress while it runs (the synchronous
            # DownloadFile blocks with no feedback, which makes long downloads look hung).
            $wc = New-Object System.Net.WebClient
            $dlState = [hashtable]::Synchronized(@{ Done = $false; Error = $null })
            $completedSub = Register-ObjectEvent -InputObject $wc -EventName DownloadFileCompleted -MessageData $dlState -Action {
                $s = $Event.MessageData
                if ($EventArgs.Error) { $s.Error = $EventArgs.Error.Message }
                elseif ($EventArgs.Cancelled) { $s.Error = "Cancelled" }
                $s.Done = $true
            }
            # Stall / overall-budget guards: a wedged TCP transfer keeps IsBusy true
            # forever (WebClient has no overall timeout), so abort and fall through to
            # the BITS / Invoke-WebRequest fallback instead of hanging the LCM.
            $stallTimeoutSec = 120   # no byte growth for this long => stalled
            $maxDownloadSec = 1800   # 30 min hard cap for the whole transfer
            $stallReason = $null
            try {
                $wc.DownloadFileAsync([uri]$url, $dest)
                $startTime = Get-Date
                $lastStatusTime = [DateTime]::MinValue
                $lastSize = -1
                $lastGrowthTime = Get-Date
                while ($wc.IsBusy -and -not $dlState.Done) {
                    Start-Sleep -Milliseconds 500
                    $now = Get-Date
                    $sizeNow = 0
                    try { if (Test-Path $dest) { $sizeNow = (Get-Item $dest -ErrorAction SilentlyContinue).Length } } catch { $sizeNow = 0 }
                    if ($sizeNow -gt $lastSize) {
                        $lastSize = $sizeNow
                        $lastGrowthTime = $now
                    }
                    elseif (($now - $lastGrowthTime).TotalSeconds -ge $stallTimeoutSec) {
                        $stallReason = "no data received for $stallTimeoutSec s (stalled at $([math]::Round($sizeNow / 1MB, 1)) MB)"
                        break
                    }
                    if (($now - $startTime).TotalSeconds -ge $maxDownloadSec) {
                        $stallReason = "exceeded $maxDownloadSec s overall budget (at $([math]::Round($sizeNow / 1MB, 1)) MB)"
                        break
                    }
                    if (($now - $lastStatusTime).TotalSeconds -ge 5) {
                        $lastStatusTime = $now
                        $mbNow = [math]::Round($sizeNow / 1MB, 1)
                        $elapsed = [int]($now - $startTime).TotalSeconds
                        if ($expectedBytes -gt 0) {
                            $pct = [math]::Min(100, [math]::Round(($sizeNow / $expectedBytes) * 100, 0))
                            $mbTotal = [math]::Round($expectedBytes / 1MB, 1)
                            Write-Status "Downloading $dest : $mbNow / $mbTotal MB ($pct%) [$elapsed s]"
                        }
                        else {
                            Write-Status "Downloading $dest : $mbNow MB downloaded [$elapsed s]"
                        }
                    }
                }
                if ($stallReason) {
                    Write-Status "Download stalled: $stallReason. Cancelling and switching to fallback."
                    try { $wc.CancelAsync() } catch {}
                    Start-Sleep -Milliseconds 500
                }
            }
            finally {
                if ($completedSub) {
                    Unregister-Event -SourceIdentifier $completedSub.Name -ErrorAction SilentlyContinue
                    Remove-Job -Name $completedSub.Name -Force -ErrorAction SilentlyContinue
                }
                $wc.Dispose()
            }
            if ($stallReason) {
                # Remove the partial file so the fallback path starts clean.
                if (Test-Path $dest) { Remove-Item $dest -Force -ErrorAction SilentlyContinue | Out-Null }
                throw "WebClient async download stalled: $stallReason"
            }
            if ($dlState.Error) {
                throw "WebClient async download failed: $($dlState.Error)"
            }
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
                    #[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Scope = 'Function')]
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
            # 3010 = ERROR_SUCCESS_REBOOT_REQUIRED -- install succeeded, reboot needed.
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

        # Version-agnostic detection paths. v18/19/20 install 32-bit under
        # "...(x86)\Microsoft SQL Server Management Studio NN\Common7\IDE"; v21/22+ install 64-bit under
        # "...\Microsoft SQL Server Management Studio NN\Release\Common7\IDE". Match any of them so a future
        # version bump never re-triggers a needless reinstall + reboot on every pass.
        $ssmsExePaths = @(
            "C:\Program Files\Microsoft SQL Server Management Studio *\Release\Common7\IDE\Ssms.exe",
            "C:\Program Files\Microsoft SQL Server Management Studio *\Common7\IDE\Ssms.exe",
            "C:\Program Files (x86)\Microsoft SQL Server Management Studio *\Common7\IDE\ssms.exe"
        )

        $ssmsExe = Get-ChildItem -Path $ssmsExePaths -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1
        if ($ssmsExe) {
            Write-Status "SSMS Installed Successfully! (Tested Out) - $($ssmsExe.FullName)"
            return
        }

        # Pick the correct SILENT arguments for whichever installer the URL actually served, so the install
        # is bullet-proof no matter which SSMS the link resolves to now or later:
        #   - WiX Burn standalone (SSMS <= 20, SSMS-Setup-ENU.exe):       /install /quiet /norestart
        #   - Visual Studio bootstrapper (SSMS 21/22+, vs_SSMS.exe):      --quiet --norestart --wait
        # The file was saved under a fixed name, so classify by CONTENT: the VS stub is tiny (~5 MB) and its
        # version info references Visual Studio; the Burn package is hundreds of MB.
        $burnArgs = @('/install', '/quiet', '/norestart')
        $vsArgs = @('--quiet', '--norestart', '--wait')

        $looksVs = $false
        try {
            $fi = Get-Item -LiteralPath $ssmsSetup -ErrorAction Stop
            $sizeMB = [math]::Round($fi.Length / 1MB, 1)
            $vi = $fi.VersionInfo
            $viText = ("{0}|{1}|{2}" -f $vi.FileDescription, $vi.ProductName, $vi.OriginalFilename)
            if ($sizeMB -lt 60) { $looksVs = $true }
            if ($viText -match 'Visual Studio|vs_setup|bootstrap') { $looksVs = $true }
            if ($looksVs) { $kindText = 'VS bootstrapper' } else { $kindText = 'Burn standalone' }
            Write-Status ("SSMS installer classified as {0} ({1} MB; '{2}')" -f $kindText, $sizeMB, $viText)
        }
        catch {
            Write-Status "Could not read SSMS installer metadata ($($_.Exception.Message)); defaulting to Burn-style args."
        }

        # Try the most-likely arg style first; fall back to the other only if the first EXITED without
        # installing (a misclassification). Each attempt runs under a hard timeout + kill so a wedged
        # installer or a UI dialog in session 0 can never hang the phase for hours.
        if ($looksVs) {
            $attempts = @(
                @{ Name = 'VS bootstrapper'; Args = $vsArgs },
                @{ Name = 'Burn standalone'; Args = $burnArgs }
            )
        }
        else {
            $attempts = @(
                @{ Name = 'Burn standalone'; Args = $burnArgs },
                @{ Name = 'VS bootstrapper'; Args = $vsArgs }
            )
        }

        $timeoutSeconds = 2700   # 45-min hard cap per attempt; never hang the phase for hours.
        $installed = $false
        $timedOut = $false
        $lastDetail = 'no attempt ran'

        foreach ($attempt in $attempts) {
            Write-Status ("Installing SSMS [{0}]: `"{1}`" {2}" -f $attempt.Name, $ssmsSetup, ($attempt.Args -join ' '))
            $proc = $null
            try {
                $proc = Start-Process -FilePath $ssmsSetup -ArgumentList $attempt.Args -PassThru -WindowStyle Hidden -ErrorAction Stop
            }
            catch {
                $lastDetail = "Start-Process failed: $($_.Exception.Message)"
                Write-Status "SSMS install [$($attempt.Name)] could not start: $($_.Exception.Message)"
                continue
            }

            if ($proc.WaitForExit($timeoutSeconds * 1000)) {
                $lastDetail = "exit code $($proc.ExitCode)"
                Write-Status ("SSMS install [{0}] exited with code {1}" -f $attempt.Name, $proc.ExitCode)
            }
            else {
                $timedOut = $true
                $lastDetail = "timed out after ${timeoutSeconds}s"
                Write-Status ("SSMS install [{0}] did not finish within {1}s -- killing it and any child installers" -f $attempt.Name, $timeoutSeconds)
                try { $proc.Kill() } catch { }
                foreach ($pn in @('vs_installer', 'vs_installershell', 'vs_bootstrapper', 'vs_setup_bootstrapper', 'setup', 'SSMS-Setup-ENU')) {
                    Get-Process -Name $pn -ErrorAction SilentlyContinue | ForEach-Object { try { $_.Kill() } catch { } }
                }
            }

            # Verify by ground truth (the file on disk), NOT the exit code: installers use different codes and
            # 3010/1641 mean success-with-reboot. So just re-scan for ssms.exe.
            Start-Sleep -Seconds 5
            $ssmsExe = Get-ChildItem -Path $ssmsExePaths -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1
            if ($ssmsExe) {
                Write-Status "SSMS Installed Successfully! - $($ssmsExe.FullName)"
                $installed = $true
                break
            }

            if ($timedOut) {
                # A hang on this binary will almost certainly hang again with the other arg style on the SAME
                # file, so stop here and fail rather than burn another 45 minutes.
                Write-Status "SSMS installer hung; not retrying the alternate argument style on the same hung binary."
                break
            }

            Write-Status ("SSMS not present after the [{0}] attempt; retrying with the alternate installer arguments." -f $attempt.Name)
        }

        if (-not $installed) {
            $msg = "Failed to install SSMS (tried Burn '/install /quiet /norestart' and VS '--quiet --norestart --wait'). Last detail: $lastDetail"
            Write-Status $msg
            throw $msg
        }

        # Reboot ONLY if one is genuinely pending. SSMS is an application install and does
        # not require a reboot to function. The old code rebooted unconditionally, but on
        # the boxes SSMS lands on (installSSMS => CAS/Primary site servers) the IIS-group
        # RebootNow later in this same Phase 3 pass already provides a reboot, making this
        # one redundant -- and an extra reboot here just lengthens Phase 3 and (when files
        # were in use) can re-trigger the whole post-reboot MOF re-apply. So probe the
        # standard pending-reboot signals and only set DSCMachineStatus when the install
        # actually staged in-use files; otherwise let the downstream reboot (or Phase 4
        # SQL, on a SQL-only SSMS box) finalize.
        $rebootPending = $false
        try {
            if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $rebootPending = $true }
            if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $rebootPending = $true }
            $sm = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue
            if ($sm -and $sm.PendingFileRenameOperations) { $rebootPending = $true }
        }
        catch { }

        if ($rebootPending) {
            Write-Status "SSMS install left a pending reboot; rebooting to finalize."
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Scope = 'Function')]
            $global:DSCMachineStatus = 1
        }
        else {
            Write-Status "SSMS installed; no reboot pending (a later step will reboot if needed)."
        }
    }

    [bool] Test() {
        Write-Status "Checking SSMS installation status"

        # Version-agnostic detection. Match any installed SSMS across every layout:
        #   - v18/19/20: 32-bit, "C:\Program Files (x86)\Microsoft SQL Server Management Studio NN\Common7\IDE\ssms.exe"
        #   - v21/22+  : 64-bit (VS-based), "C:\Program Files\Microsoft SQL Server Management Studio NN\Release\Common7\IDE\Ssms.exe"
        # Assigning Get-ChildItem to a variable consumes its pipeline output so nothing leaks onto the
        # success stream (a DSC class Test() must return ONLY a boolean, or the LCM hard-fails).
        $ssmsExe = Get-ChildItem -Path @(
            "C:\Program Files\Microsoft SQL Server Management Studio *\Release\Common7\IDE\Ssms.exe",
            "C:\Program Files\Microsoft SQL Server Management Studio *\Common7\IDE\Ssms.exe",
            "C:\Program Files (x86)\Microsoft SQL Server Management Studio *\Common7\IDE\ssms.exe"
        ) -ErrorAction SilentlyContinue | Where-Object { $_.Length -gt 0 } | Sort-Object FullName -Descending | Select-Object -First 1

        if ($ssmsExe) {
            Write-Verbose "Test - Installing SSMS... $($ssmsExe.FullName) exists"
            return $true
        }

        Write-Verbose "Test - Installing SSMS... no ssms.exe found under any 'Microsoft SQL Server Management Studio *' path"
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

        $processName = ($this.FileName -split ".exe")[0]

        # Bounded install. The .NET bootstrapper (ndp48...exe /q /norestart) extracts and runs a child
        # installer named after the file; the OLD code polled for that child in a `while ($true)` loop with
        # NO upper bound, so a wedged installer span forever. Cap every wait and verify by registry.
        $launchTimeoutSeconds = 1800   # 30-min cap for the launcher stub to exit
        $childTimeoutSeconds = 1800    # 30-min cap waiting for the extracted child installer to finish

        try {
            Write-Status "Installing .NET $($this.FileName)..."

            $exitCode = $null
            $proc = Start-Process -FilePath $setup -ArgumentList @('/q', '/norestart') -PassThru -WindowStyle Hidden -ErrorAction Stop
            if (-not $proc.WaitForExit($launchTimeoutSeconds * 1000)) {
                Write-Status ".NET installer launcher did not exit within ${launchTimeoutSeconds}s -- killing it"
                try { $proc.Kill() } catch { }
            }
            else {
                try { $exitCode = $proc.ExitCode } catch { }
            }

            # Bounded wait for the extracted child installer to clear (replaces the unbounded while ($true) loop).
            $waited = 0
            while ($true) {
                $child = Get-Process $processName -ErrorAction SilentlyContinue
                if ($null -eq $child) { break }
                if ($waited -ge $childTimeoutSeconds) {
                    Write-Status ".NET child installer '$processName' still running after ${childTimeoutSeconds}s -- killing it"
                    foreach ($c in $child) { try { $c.Kill() } catch { } }
                    break
                }
                Start-Sleep -Seconds 10
                $waited += 10
            }
            Start-Sleep -Seconds 10 ## Buffer Wait

            # Read ground truth (the same NDP\v4\Full Release the Test() method checks).
            $installed = $false
            try {
                $netVal = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full" -Name "Release" -ErrorAction Stop
                if ($netVal.Release -ge $this.NetVersion) { $installed = $true }
            }
            catch { }

            # The .NET 4.8 offline installer (ndp48-x86-x64-allos-enu.exe) almost always returns 3010
            # (ERROR_SUCCESS_REBOOT_REQUIRED) -- or 1641 -- on Server 2016/2019/2022 because in-use .NET
            # assemblies force PendingFileRenameOperations, and the NDP\v4\Full Release value is NOT raised
            # to the new build until AFTER that reboot. So a pre-reboot registry read legitimately still
            # shows the OLD (< NetVersion) value on a perfectly successful install. Treat 0/3010/1641 as
            # success-needs-reboot: set DSCMachineStatus and let Test() verify the Release value AFTER the
            # reboot (this is the original, tried-and-true behavior). Only HARD-FAIL on a genuinely bad
            # installer exit code, so a wedged/failed installer still surfaces cleanly instead of looping.
            $okExitCodes = @(0, 3010, 1641)
            if (-not $installed -and $null -ne $exitCode -and ($okExitCodes -notcontains $exitCode)) {
                throw ".NET $($this.FileName) failed to install (installer exit code $exitCode; NDP\v4\Full Release still < $($this.NetVersion))."
            }

            if ($installed) {
                Write-Status ".NET $($this.FileName) Installed Successfully!"
            }
            else {
                Write-Status ".NET $($this.FileName) staged (installer exit code $(if ($null -eq $exitCode) { 'unknown' } else { $exitCode })); rebooting to finalize registration."
            }

            # Reboot. Registration of the new Release value completes on this reboot when files were in use;
            # Test() re-verifies NDP\v4\Full Release >= NetVersion after the machine comes back up.
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Scope = 'Function')]
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

        # Skip install if already registered (Set may be called just to
        # restore the MSI file for Windows Installer source resolution).
        $regPath = "HKLM:\SOFTWARE\Microsoft\SQLNCLI11"
        if (Test-Path $regPath) {
            $ver = (Get-ItemProperty $regPath -ErrorAction SilentlyContinue).InstalledVersion
            if ($ver -and [System.Version]$ver -ge [System.Version]"11.4.7001.0") {
                Write-Status "SQL Native Client $ver already installed, MSI restored to $_path"
                return
            }
        }

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
                # Installed, but ensure the MSI file still exists at the download
                # path so Windows Installer can find it when a CU patches it.
                if (-not (Test-Path $this.Path)) {
                    Write-Status "SQL Native Client is installed but MSI missing at $($this.Path) - re-downloading"
                    return $false
                }
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
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Scope = 'Function')]
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

        # Liveness watchdog. Nothing but the scheduled task advances this json, so if
        # the task stops before reaching $ReadNodeValue (process killed, crashed, or
        # Task Scheduler ended it) the wait below can never finish and the LCM spins
        # forever on a frozen status. This must cover the "json does not exist yet"
        # window too: a workflow that dies before its first write leaves no file at
        # all, and an unwatched Test-Path loop there waits forever. Only armed when we
        # are waiting on OUR OWN machine's task -- the remote WaitPrimary usage must
        # not touch a local task of the same name. A restart resumes: ScriptWorkflow.json
        # step states make completed work a no-op, which is what a phase re-run relies on.
        $watchTask = $null
        if ($this.MachineName -eq $env:COMPUTERNAME -and (Get-ScheduledTask -TaskName $_FileName -ErrorAction SilentlyContinue)) {
            $watchTask = $_FileName
        }
        $taskRestarts = 0
        $maxTaskRestarts = 3
        $deadPolls = 0

        $Configuration = $null
        while ($true) {
            $stuckOn = "$_FileName.json does not exist yet"
            if (Test-Path $ConfigurationFile) {
                $mtx = New-Object System.Threading.Mutex($false, "$_FileName")
                Write-Verbose "Attempting to acquire '$_FileName' Mutex"
                [void]$mtx.WaitOne()
                Write-Verbose "Acquired '$_FileName' Mutex"
                try {
                    $Configuration = Get-Content -Path $ConfigurationFile -ErrorAction Ignore | ConvertFrom-Json
                }
                finally {
                    [void]$mtx.ReleaseMutex()
                    [void]$mtx.Dispose()
                }
                if ($Configuration.$($this.ReadNode).Status -eq $this.ReadNodeValue) {
                    break
                }
                $stuckOn = "[$($this.ReadNode)] is '$($Configuration.$($this.ReadNode).Status)'"
                Write-Verbose "Wait for step: [$($this.ReadNode)] to finish on $($this.MachineName), will try again in 30 seconds..."
            }
            else {
                Write-Verbose "Wait for configuration file to exist on $($this.MachineName), will try again in 30 seconds..."
            }

            if ($watchTask) {
                $taskState = $null
                try { $taskState = (Get-ScheduledTask -TaskName $watchTask -ErrorAction Stop).State } catch { }
                if ($taskState -and $taskState -ne 'Running') {
                    # Require two consecutive dead polls so we never race a task that is mid-start.
                    $deadPolls++
                    if ($deadPolls -ge 2) {
                        $deadPolls = 0
                        $lastResult = 'unknown'
                        try { $lastResult = "0x{0:X8}" -f (Get-ScheduledTaskInfo -TaskName $watchTask -ErrorAction Stop).LastTaskResult } catch { }
                        # The workflow's own trap records what killed it; without this the
                        # failure reads only as "it kept exiting".
                        $lastErr = ''
                        try {
                            $crumb = (Get-Content 'C:\staging\DSC\ScriptWorkflow.lasterror.txt' -Raw -ErrorAction Stop).Trim()
                            if ($crumb) { $lastErr = " It died at: $crumb" }
                        }
                        catch { }
                        if ($taskRestarts -lt $maxTaskRestarts) {
                            $taskRestarts++
                            Write-Status "$watchTask is '$taskState' (last result $lastResult) but $stuckOn -- it exited without finishing.$lastErr Restarting it (attempt $taskRestarts/$maxTaskRestarts)."
                            try { Start-ScheduledTask -TaskName $watchTask -ErrorAction Stop }
                            catch { Write-Status "Could not restart ${watchTask}: $($_.Exception.Message)" }
                            Start-Sleep -Seconds 30
                        }
                        else {
                            $msg = "JOBFAILURE: $watchTask kept exiting without setting [$($this.ReadNode)] to '$($this.ReadNodeValue)' ($stuckOn, last result $lastResult); gave up after $maxTaskRestarts restarts.$lastErr See C:\staging\DSC\InstallCMLog.log."
                            # Written directly: Write-Status suppresses writes while the status
                            # file holds the CM-setup sentinel, and the host keys on JOBFAILURE.
                            try { $msg | Out-File -FilePath "C:\staging\DSC\DSC_Status.txt" -Force } catch { }
                            throw $msg
                        }
                    }
                }
                else {
                    $deadPolls = 0
                }
            }

            Start-Sleep -Seconds 30
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
        # Bound the wait: without a deadline a missing external CMCB share (e.g. a
        # cross-forest joiner deployed after the external CAS ejected its ISO-based
        # CM media) hangs Phase 2 indefinitely. Fail with an actionable message so
        # the phase surfaces the real problem instead of spinning forever.
        $waitDeadline = (Get-Date).AddMinutes(30)
        while (!(Test-Path $extadschpath) -and !(Test-Path $extadschpath2) -and !(Test-Path $extadschpath3) -and !(Test-Path $extadschpath4)) {
            if ((Get-Date) -gt $waitDeadline) {
                throw "extadsch.exe never appeared under \\$($this.MachineName)\$($this.ExtFolder) within 30 minutes. The external top-level site server's CM media / CMCB share is not available -- an ISO-based CM ejects its media after its own Phase 8, leaving the CMCB share pointing at an empty ejected DVD. Ensure the external CAS is running with its CM ISO mounted and the CMCB share pointing at it (the host re-mounts it before Phase 2 for cross-forest joiners)."
            }
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
        # DC's NTDS is still initializing, e.g. BDC just promoted).
        # Omit the DN argument so /AdeP walks ALL partitions (Domain,
        # Configuration, AND Schema) -- schema extension targets
        # CN=Schema,CN=Configuration,... which is a separate NC from
        # the domain DN.
        $domainControllers = Get-ADDomainController -Filter * -ErrorAction SilentlyContinue
        if ($domainControllers.Count -gt 1) {
            Write-Status "Forcing AD Replication on $($domainControllers.Name -join ',')"
            $dcNames = @($domainControllers.Name)
            $replJob = Start-Job -ScriptBlock {
                param($dcNames)
                $dcNames | ForEach-Object { repadmin /syncall $_ /AdeP 2>&1 | Out-Null }
            } -ArgumentList (,$dcNames)
            $null = Wait-Job $replJob -Timeout 60
            if ($replJob.State -eq 'Running') {
                Stop-Job $replJob -ErrorAction SilentlyContinue
            }
            Remove-Job $replJob -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 3
        }

        # Find the first valid extadsch.exe path
        $extExe = @($extadschpath, $extadschpath2, $extadschpath3, $extadschpath4) |
            Where-Object { Test-Path $_ } | Select-Object -First 1

        if (-not $extExe) {
            Write-Status "WARNING: extadsch.exe not found in any expected path"
        }
        else {
            # --- Pre-flight checks ---
            $schemaNC = $null
            $schemaOk = $false
            try {
                Import-Module ActiveDirectory -ErrorAction Stop
                $schemaNC = (Get-ADRootDSE).schemaNamingContext
            }
            catch {
                Write-Status "WARNING: Could not query AD schema naming context: $($_.Exception.Message)"
            }

            # Verify Schema Admin membership (extadsch.exe requires it)
            try {
                $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent()
                $schemaAdminsSID = (Get-ADGroup "Schema Admins" -ErrorAction Stop).SID
                if ($currentUser.Groups -notcontains $schemaAdminsSID) {
                    Write-Status "WARNING: Current identity '$($currentUser.Name)' is not in Schema Admins -- extadsch.exe will likely fail. Ensure PsDscRunAsCredential is set to a domain admin account."
                }
                else {
                    Write-Status "Schema Admin membership confirmed for '$($currentUser.Name)'"
                }
            }
            catch {
                Write-Status "WARNING: Could not verify Schema Admins membership: $($_.Exception.Message)"
            }

            # Verify Schema Master FSMO is reachable
            try {
                $schemaMaster = (Get-ADForest -ErrorAction Stop).SchemaMaster
                $localFQDN = [System.Net.Dns]::GetHostEntry("").HostName
                Write-Status "Schema Master: $schemaMaster (local: $localFQDN)"
                if ($localFQDN -ine $schemaMaster) {
                    if (-not (Test-Connection -ComputerName $schemaMaster -Count 1 -Quiet -ErrorAction SilentlyContinue)) {
                        Write-Status "WARNING: Schema Master $schemaMaster is not reachable"
                    }
                }
            }
            catch {
                Write-Status "WARNING: Could not identify Schema Master: $($_.Exception.Message)"
            }

            # Check if schema is already fully extended (skip extadsch if so)
            if ($schemaNC) {
                try {
                    $existingObjs = @(Get-ADObject -SearchBase $schemaNC `
                        -Filter "name -like 'MS-SMS-*' -or name -like 'mS-SMS-*'" -ErrorAction SilentlyContinue)
                    if ($existingObjs.Count -ge 18) {
                        Write-Status "CM schema already extended ($($existingObjs.Count) SMS objects found) - skipping extadsch.exe"
                        $schemaOk = $true
                    }
                    elseif ($existingObjs.Count -gt 0) {
                        Write-Status "Partial CM schema detected ($($existingObjs.Count)/18 objects) - will attempt to complete"
                    }
                }
                catch {}
            }

            # Wait for replication convergence before schema extension (multi-DC only)
            if (-not $schemaOk) {
                $dcList = @(Get-ADDomainController -Filter * -ErrorAction SilentlyContinue)
                if ($dcList.Count -gt 1) {
                    Write-Status "Waiting for replication convergence across $($dcList.Count) DCs..."
                    $sw = [System.Diagnostics.Stopwatch]::StartNew()
                    while ($sw.Elapsed.TotalSeconds -lt 60) {
                        Start-Sleep -Seconds 10
                        $chk = & repadmin /replsummary 2>&1
                        # Look for error/fail indicators -- more reliable than
                        # parsing error codes, since replsummary format varies by OS.
                        # Exclude header lines ("Source DSA ... largest delta  fails/total %  error"
                        # and the matching Destination DSA header) which contain the
                        # words "fails" and "error" as column labels, not real errors.
                        $errors = $chk | Where-Object { $_ -match 'error|fail|\*' -and $_ -notmatch '^(Source|Destination) DSA' -and $_ -notmatch 'largest delta' }
                        if (-not $errors) { break }
                        Write-Status "Replication settling ($([int]$sw.Elapsed.TotalSeconds)s)..."
                    }
                    $sw.Stop()
                }
            }

            $logFile = "C:\ExtADSch.log"
            $maxAttempts = 3

            for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
                if ($schemaOk) { break }
                # Rename previous log so we can detect whether extadsch.exe
                # actually wrote a new one (vs failing silently due to
                # permissions or path issues).
                $logExisted = Test-Path $logFile
                if ($logExisted) {
                    $bak = "$logFile.attempt$($attempt - 1)"
                    Rename-Item $logFile $bak -Force -ErrorAction SilentlyContinue
                }

                Write-Status "Running extadsch.exe (attempt $attempt/$maxAttempts): $extExe"
                $extOutput = & $extExe 2>&1
                Start-Sleep -Seconds 2

                # Parse ExtADSch.log for success/failure
                if (Test-Path $logFile) {
                    $logContent = Get-Content $logFile -Raw
                    if ($logContent -match 'Successfully extended the Active Directory schema') {
                        Write-Status "Schema extension succeeded (attempt $attempt)"
                        $schemaOk = $true
                        break
                    }
                    $failLines = ($logContent -split "`r?`n") | Where-Object { $_ -match 'Failed|Error code' } | Select-Object -First 5
                    Write-Status "Schema extension failed (attempt $attempt): $($failLines -join ' | ')"
                }
                else {
                    # extadsch.exe ran but didn't produce a log -- likely a
                    # permissions or working-directory issue, not a schema
                    # problem.  Note: extadsch.exe writes diagnostics to
                    # C:\ExtADSch.log, not stdout, so console capture is
                    # usually empty.  A missing log typically means a
                    # filesystem ACL or working-directory problem on C:\.
                    $consoleOut = if ($extOutput) { ($extOutput | Select-Object -First 5) -join ' | ' } else { '(no output)' }
                    Write-Status "Schema extension (attempt $attempt): extadsch.exe produced no log at $logFile -- check C:\ filesystem permissions. Console: $consoleOut"
                }

                if ($attempt -lt $maxAttempts) {
                    $delay = 30 * $attempt
                    Write-Status "Retrying schema extension in ${delay}s..."
                    Start-Sleep -Seconds $delay

                    # Force replication before retry -- omit DN so all partitions
                    # (including Schema NC) are synced
                    $dcList = Get-ADDomainController -Filter * -ErrorAction SilentlyContinue
                    if ($dcList.Count -gt 1) {
                        repadmin /syncall $env:COMPUTERNAME /AdeP 2>&1 | Out-Null
                    }
                }
            }

            # Verify all required SMS schema attributes and classes exist.
            # Catches both fresh extensions and re-runs where extadsch.exe
            # reports "Failed" but the objects were created by a prior deployment.
            if (-not $schemaOk -and $schemaNC) {
                try {
                    $reqAttrs = @('MS-SMS-Site-Code','mS-SMS-Assignment-Site-Code','MS-SMS-Site-Boundaries',
                        'MS-SMS-Roaming-Boundaries','MS-SMS-Default-MP','mS-SMS-Device-Management-Point',
                        'MS-SMS-MP-Name','MS-SMS-MP-Address','mS-SMS-Health-State','mS-SMS-Source-Forest',
                        'MS-SMS-Ranged-IP-Low','MS-SMS-Ranged-IP-High','mS-SMS-Version','mS-SMS-Capabilities')
                    $reqClasses = @('MS-SMS-Management-Point','MS-SMS-Server-Locator-Point',
                        'MS-SMS-Site','MS-SMS-Roaming-Boundary-Range')

                    $found = @(Get-ADObject -SearchBase $schemaNC `
                        -Filter "name -like 'MS-SMS-*' -or name -like 'mS-SMS-*'" -ErrorAction SilentlyContinue |
                        Select-Object -ExpandProperty Name)

                    $missingA = @($reqAttrs | Where-Object { $found -notcontains $_ })
                    $missingC = @($reqClasses | Where-Object { $found -notcontains $_ })

                    if ($missingA.Count -eq 0 -and $missingC.Count -eq 0) {
                        Write-Status "All $($reqAttrs.Count) attributes and $($reqClasses.Count) classes present in schema"
                        $schemaOk = $true
                    }
                    else {
                        if ($missingA.Count -gt 0) { Write-Status "Missing schema attributes ($($missingA.Count)): $($missingA -join ', ')" }
                        if ($missingC.Count -gt 0) { Write-Status "Missing schema classes ($($missingC.Count)): $($missingC -join ', ')" }
                    }
                }
                catch {
                    Write-Status "WARNING: Could not verify schema objects: $($_.Exception.Message)"
                }
            }

            if (-not $schemaOk) {
                Write-Status "WARNING: Schema extension incomplete. AD publishing for ConfigMgr will not work. Check C:\ExtADSch.log on the DC."
            }
        }
        Write-Status "Done Extending Schema"
    }

    [bool] Test() {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        Write-Status "WaitForExtendSchemaFile: running as '$($identity.Name)' (AuthType=$($identity.AuthenticationType), IsSystem=$($identity.IsSystem))"
        # Already-extended short-circuit: if the CM AD schema is present, do NOT enter
        # Set() -- it would block up to 30 min waiting for the site server's CMCB media
        # share just to run a no-op extadsch.exe. On a -StartPhase re-run that share is
        # ejected after the prior successful CM phase and may not be re-mounted yet.
        # extadsch is cumulative/idempotent and the schema is a one-time forest-wide
        # extension, so its presence means there is nothing to do.
        try {
            Import-Module ActiveDirectory -ErrorAction Stop
            $schemaNC = (Get-ADRootDSE -ErrorAction Stop).schemaNamingContext
            if ($schemaNC) {
                $smsObjs = @(Get-ADObject -SearchBase $schemaNC -Filter "name -like 'MS-SMS-*' -or name -like 'mS-SMS-*'" -ErrorAction Stop)
                if ($smsObjs.Count -ge 18) {
                    Write-Status "CM AD schema already extended ($($smsObjs.Count) MS-SMS-* objects present) -- skipping the extadsch.exe media wait/re-run."
                    return $true
                }
                Write-Status "CM AD schema not yet extended ($($smsObjs.Count)/18 MS-SMS-* objects) -- will wait for media and run extadsch."
            }
        }
        catch {
            Write-Status "Schema pre-check failed ($($_.Exception.Message)); will run the normal wait + extadsch."
        }
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
        # Use actual NetBIOS name for SID resolution, not the first DNS
        # label. In disjoint namespaces (e.g. DNS "wacky.sandwich.lab" with
        # NetBIOS "TACO"), .split('.')[0] gives "wacky" which dsacls can't
        # resolve to a SID. Get-ADDomain.NetBIOSName is authoritative.
        $DomainName = (Get-ADDomain -ErrorAction SilentlyContinue).NetBIOSName
        if (-not $DomainName) {
            $DomainName = $this.DomainFullName.split('.')[0]
        }
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
        $forcedReplication = $false
        while ($retries -le $maxretries) {

            Clear-DnsClientCache -ErrorAction SilentlyContinue

            if ($retries -eq 5) {
                $_FileName = "C:\temp\SysMgmt.txt"

                if (-not (Test-Path $_FileName)) {
                    Write-Status "dsacls.exe failed to add permissions 5 time.. Attempting reboot."
                    Write-Verbose "Rebooting"
                    New-Item $_FileName
                    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Scope = 'Function')]
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

            # Error 1332 = "No Sid Found" -- the computer account hasn't
            # replicated to this DC yet. Force AD replication once, then
            # try targeting the PDC emulator directly.
            if ($dsaclsExitCode -eq 1332 -and -not $forcedReplication) {
                $forcedReplication = $true
                try {
                    $domainControllers = @(Get-ADDomainController -Filter * -ErrorAction SilentlyContinue)
                    if ($domainControllers.Count -gt 1) {
                        $dn = (Get-ADDomain -ErrorAction SilentlyContinue).DistinguishedName
                        Write-Status "SID not found locally. Forcing AD replication across $($domainControllers.Count) DCs..."
                        $dcNames = @($domainControllers.Name)
                        $replJob = Start-Job -ScriptBlock {
                            param($dcNames, $dn)
                            $dcNames | ForEach-Object { repadmin /syncall $_ $dn /AdeP 2>&1 | Out-Null }
                        } -ArgumentList $dcNames, $dn
                        $null = Wait-Job $replJob -Timeout 60
                        if ($replJob.State -eq 'Running') {
                            Stop-Job $replJob -ErrorAction SilentlyContinue
                        }
                        Remove-Job $replJob -Force -ErrorAction SilentlyContinue
                        Start-Sleep -Seconds 5
                        Write-Status "Replication sync completed. Retrying dsacls..."
                    }
                }
                catch {
                    Write-Verbose "Forced replication failed: $_"
                }
            }

            # If dsacls failed with 1332 (SID not found on this DC), try
            # targeting each DC directly. The PDC or the DC where the
            # computer account was created may already have the SID.
            $successDcArg1 = $null
            if ($dsaclsExitCode -eq 1332) {
                try {
                    $allDCs = @(Get-ADDomainController -Filter * -ErrorAction SilentlyContinue)
                    foreach ($dc in $allDCs) {
                        if ($dc.HostName -eq (hostname)) { continue }
                        $serverArg1 = "\\$($dc.HostName)\$arg1"
                        Write-Status "Trying dsacls via $($dc.Name)... (Try $retries/$maxretries)"
                        Write-Verbose "Running $cmd $serverArg1 $arg2 $arg3 $arg4"
                        $null = & $cmd $serverArg1 $arg2 $arg3 $arg4 *>&1
                        $dcExitCode = $LASTEXITCODE
                        Write-Verbose "dsacls via $($dc.Name) exit code: $dcExitCode"
                        if ($dcExitCode -eq 0) {
                            Write-Status "dsacls succeeded via $($dc.Name)"
                            $dsaclsExitCode = 0
                            $successDcArg1 = $serverArg1
                            break
                        }
                    }
                }
                catch {
                    Write-Verbose "Multi-DC dsacls attempt failed: $_"
                }
            }

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

            # If dsacls succeeded on a remote DC, verify against that DC
            # (the ACL may not have replicated locally yet).
            if ($successDcArg1) {
                $remotePerm = & $tcmd $successDcArg1
                if ($this.CheckPermissions($remotePerm, $_machinename, $DomainName)) {
                    Write-Status "Permissions verified on remote DC"
                    break
                }
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
        $DomainName = (Get-ADDomain -ErrorAction SilentlyContinue).NetBIOSName
        if (-not $DomainName) {
            $DomainName = $this.DomainFullName.split('.')[0]
        }
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
        if (!(Test-Path $this.FilePath)) {
            return $false
        }

        if (!((Get-Item $this.FilePath).Length -gt 0)) {
            return $false
        }

        # Verify SHA1 hash for files with an embedded hash in the filename
        # (e.g. sqlserver2016-kb5014351-x64_{sha1hash}.exe)
        if ($this.DownloadUrl -match '-x64_([\da-fA-F]{40})\.exe$') {
            $expectedHash = $Matches[1].ToLowerInvariant()
            $fileItem = Get-Item $this.FilePath
            $hashCachePath = "$($this.FilePath).SHA1"

            # Check for a cached hash sidecar file with size and last-modified metadata
            $actualHash = $null
            $useCachedHash = $false
            if (Test-Path $hashCachePath) {
                try {
                    $cacheLines = Get-Content $hashCachePath
                    if ($cacheLines.Count -ge 3) {
                        $cachedHash = $cacheLines[0].Trim().ToLowerInvariant()
                        $cachedSize = [long]$cacheLines[1].Trim()
                        # RoundtripKind: a bare [datetime] cast on the 'o' string returns Kind=Local
                        # shifted by the UTC offset, so this never equalled LastWriteTimeUtc on a
                        # non-UTC guest and the sidecar re-hashed the whole CU every run.
                        $cachedLastWrite = [datetime]::Parse($cacheLines[2].Trim(), [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
                        if ($fileItem.Length -eq $cachedSize -and $fileItem.LastWriteTimeUtc -eq $cachedLastWrite) {
                            $useCachedHash = $true
                            $actualHash = $cachedHash
                        }
                    }
                }
                catch {
                    # Sidecar corrupt or unreadable; fall through to full hash
                }
            }

            if (-not $useCachedHash) {
                if (Initialize-MemlabsCachedHashSidecar -Url $this.DownloadUrl -Dest $this.FilePath -ExpectedHash $expectedHash) {
                    $actualHash = $expectedHash
                    $useCachedHash = $true
                    Write-Verbose "Restored SHA1 cache for $(Split-Path $this.FilePath -Leaf) from matching MemLabs cache metadata"
                }
                else {
                    $actualHash = (Get-FileHash $this.FilePath -Algorithm SHA1).Hash.ToLowerInvariant()
                }
            }

            if ($actualHash -ne $expectedHash) {
                Write-Status "Hash mismatch for $(Split-Path $this.FilePath -Leaf): expected $expectedHash, got $actualHash. Deleting corrupt download."
                $parentDir = Split-Path $this.FilePath -Parent
                Remove-Item $parentDir -Recurse -Force -ErrorAction SilentlyContinue
                return $false
            }

            # Write/update the sidecar cache so subsequent runs skip hashing
            if (-not $useCachedHash) {
                try {
                    @($actualHash, $fileItem.Length.ToString(), $fileItem.LastWriteTimeUtc.ToString('o')) | Out-File -FilePath $hashCachePath -Force
                }
                catch {
                    Write-Verbose "Could not write hash cache file: $_"
                }
            }

            Write-Verbose "SHA1 hash verified for $(Split-Path $this.FilePath -Leaf)"
        }

        return $true
    }

    [DownloadFile] Get() {
        return $this
    }
}

function Test-DomainControllerReady {
    param(
        [Parameter(Mandatory)]
        [string] $DCName,
        [Parameter(Mandatory)]
        [string] $DomainName
    )

    try {
        $nltest = Join-Path $env:SystemRoot 'System32\nltest.exe'
        if (-not (Test-Path $nltest)) { return $false }

        # /PDC makes this stronger than ping or an open LDAP socket: Netlogon
        # must be ready and DC Locator must be able to discover the domain PDC.
        $null = & $nltest "/dsgetdc:$DomainName" /force /pdc 2>&1
        if ($LASTEXITCODE -eq 0) { return $true }
        Write-Verbose "DC Locator cannot find PDC '$DCName' for '$DomainName'."
    }
    catch {
        Write-Verbose "DC Locator readiness check failed for '$DCName': $($_.Exception.Message)"
    }
    return $false
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
        Write-Verbose "Domain Controller is: $_DCName"
        $domainReady = Test-DomainControllerReady -DCName $_DCName -DomainName $_DomainName
        while (-not $domainReady) {
            Write-Status "Waiting for domain services. DC Locator cannot find PDC $_DCName yet; retrying in $_WaitSeconds seconds..."
            Clear-DnsClientCache -ErrorAction SilentlyContinue
            ipconfig /renew 2>&1 | Out-Null
            Register-DnsClient -ErrorAction SilentlyContinue
            Start-Sleep -Seconds $_WaitSeconds
            $domainReady = Test-DomainControllerReady -DCName $_DCName -DomainName $_DomainName
        }
        Write-Status "Domain services are ready now."
    }

    [bool] Test() {
        $_DCName = $this.DCName
        $_DomainName = $this.DomainName
        Write-Verbose "Testing domain services on PDC: $_DCName"
        return (Test-DomainControllerReady -DCName $_DCName -DomainName $_DomainName)
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
            # No Write-Progress here: it blocked the engine ~194s per call waiting on WinRM.
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

function Invoke-WithTimeoutJob {
    # Run a scriptblock under Start-ThreadJob (or Start-Job fallback) with a
    # hard per-attempt timeout + retry, then KILL it if it overruns. Used to
    # bound CDXML/CIM cmdlets such as Get/Remove-DnsServerResourceRecord
    # -ComputerName <DC>, which have no native timeout and can block for
    # minutes when the DC's WinRM/CIM is briefly wedged -- stalling the DSC
    # apply (and the whole phase) with it. Returns the scriptblock output on
    # success, or $null on timeout/error (caller treats that as 'skip').
    param(
        [Parameter(Mandatory)] [scriptblock] $ScriptBlock,
        [object[]] $ArgumentList = @(),
        [int] $TimeoutSec = 30,
        [int] $MaxAttempts = 2
    )
    $useThreadJob = $null -ne (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue)
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $job = $null
        try {
            $job = if ($useThreadJob) {
                Start-ThreadJob -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList -ErrorAction Stop
            }
            else {
                Start-Job -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList -ErrorAction Stop
            }
            if (Wait-Job -Job $job -Timeout $TimeoutSec) {
                $out = Receive-Job -Job $job -ErrorAction SilentlyContinue
                try { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue } catch {}
                return $out
            }
            try { Stop-Job -Job $job -ErrorAction SilentlyContinue } catch {}
            try { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue } catch {}
        }
        catch {
            if ($job) { try { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue } catch {} }
        }
    }
    return $null
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

        # Always ensure the firewall rule exists, even when the port is already correct.
        # Without this, a default MSSQLSERVER on 1433 passes the port check, Set() is
        # skipped, and the firewall rule inside Set() never runs.
        $fwRule = Get-NetFirewallRule -DisplayName 'SQL over TCP Inbound (Named Instance)' -ErrorAction SilentlyContinue
        if (-not $fwRule) {
            Write-Verbose "[ChangeSqlInstancePort]: Firewall rule missing for port $_SQLInstancePort"
            return $false
        }

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

    # Internal: LastRunTime captured just before we start the task, so a fresh start
    # can be detected even when the launched script completes quickly.
    hidden [datetime] $StartBaseline = [datetime]::MinValue

    [void] Set() {
        $_TaskName = $this.TaskName
        $_ScriptName = $this.ScriptName
        $_ScriptPath = $this.ScriptPath
        $_ScriptArgument = $this.ScriptArgument



        $waitTime = 30

        $success = $this.RegisterTask()
        if (-not $success) {
            throw "Failed to register task $_TaskName after multiple attempts. Check domain trust and AD replication."
        }
        Write-Status "Starting task $_Taskname from $_ScriptPath $_ScriptName $_ScriptArgument"

        # RegisterTask() already started the task and confirmed it entered the Running
        # state. Re-verify here using live task state (Get-ScheduledTask /
        # Get-ScheduledTaskInfo) -- which updates immediately, unlike the laggy
        # TaskScheduler/Operational event log -- and, if it somehow isn't running,
        # re-register / re-start it (bounded) before giving up.
        $failCount = 0
        $maxRetries = 8
        while ($true) {
            if ($this.IsTaskRunning()) {
                Write-Status "$_TaskName confirmed running."
                break
            }
            if ($failCount -ge $maxRetries) {
                Write-Status "$_TaskName failed to run after $maxRetries retries. Exiting. Please check Task Scheduler for Task: $_TaskName"
                throw "Task failed to run after $maxRetries retries, and reregistration. Exiting. Please check Task Scheduler for Task: $_TaskName"
            }

            $taskExists = Get-ScheduledTask -TaskName $_TaskName -ErrorAction SilentlyContinue
            if (-not $taskExists) {
                Write-Status "$_TaskName disappeared. Re-registering..."
                if (-not $this.RegisterTask()) {
                    throw "Failed to re-register task $_TaskName."
                }
            }
            else {
                Write-Status "$_TaskName not running yet (attempt $failCount). Starting it."
                Start-ScheduledTask -TaskName $_TaskName -ErrorAction SilentlyContinue
            }
            $failCount++
            Start-Sleep -Seconds $waitTime
        }
        Write-Status "$_TaskName was successfully started."



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

        #$Trigger = New-ScheduledTaskTrigger -Once -At $TaskStartTime
        #Write-Verbose "Time is now: $RegisterTime Task Scheduled to run at $TaskStartTime"

        $Principal = New-ScheduledTaskPrincipal -UserId $($this.AdminCreds.UserName) -RunLevel Highest
        $Password = $($this.AdminCreds).GetNetworkCredential().Password
        $certauthFile = $destDirectory + "\" + "certauth.txt"
        $Password | Out-file -FilePath $certauthFile -Force

        $Task = New-ScheduledTask -Action $Action -Description $TaskDescription -Principal $Principal

        # Register with retry -- domain trust failures are transient (AD replication lag
        # can cause "trust relationship failed" for 10-20 min in large deployments)
        $registered = $false
        $maxRegAttempts = 40  # 40 × 30s = 20 min max wait
        for ($regAttempt = 1; $regAttempt -le $maxRegAttempts; $regAttempt++) {
            try {
                $Task | Register-ScheduledTask -TaskName $($this.TaskName) -User $($this.AdminCreds.UserName) -Password $Password -Force -ErrorAction Stop | Out-Null
            } catch {
                Write-Status "Register-ScheduledTask attempt $regAttempt/$maxRegAttempts failed: $($_.Exception.Message)"
            }
            # Verify the task actually exists
            $verify = Get-ScheduledTask -TaskName $($this.TaskName) -ErrorAction SilentlyContinue
            if ($verify) {
                $registered = $true
                Write-Status "Task $($this.TaskName) registered successfully (attempt $regAttempt)"
                break
            }
            Write-Status "Task $($this.TaskName) not found after attempt $regAttempt/$maxRegAttempts. Retrying in 30s..."
            Start-Sleep -Seconds 30
        }

        if (-not $registered) {
            Write-Status "ERROR: Task $($this.TaskName) could not be registered after 5 attempts."
            return $false
        }

        # Make sure the task isn't already Running before we start it (a leftover run
        # from a prior pass would make "is it running?" ambiguous). Capture the
        # current LastRunTime as a baseline so a fresh start can be detected even if
        # the launched script completes quickly.
        $this.StartBaseline = [datetime]::MinValue
        try {
            $preInfo = Get-ScheduledTaskInfo -TaskName $($this.TaskName) -ErrorAction Stop
            if ($preInfo.LastRunTime) { $this.StartBaseline = $preInfo.LastRunTime }
            $preState = (Get-ScheduledTask -TaskName $($this.TaskName) -ErrorAction Stop).State
            if ($preState -eq 'Running') {
                Write-Status "$($this.TaskName) is already Running before start; stopping it for a clean start."
                Stop-ScheduledTask -TaskName $($this.TaskName) -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 2
            }
        }
        catch {
            Write-Status "Could not read pre-start state for $($this.TaskName): $($_.Exception.Message)"
        }

        Write-Status "Time is now: $([datetime]::Now) Task Scheduled $($this.TaskName) is starting"
        Start-ScheduledTask -TaskName $($this.TaskName)

        # Confirm the task actually entered the Running state (or already ran to
        # completion for a fast no-op script) instead of sleeping a fixed interval and
        # hoping. State / LastRunTime update almost immediately.
        $startConfirmed = $false
        for ($i = 0; $i -lt 15; $i++) {
            # Probe before sleeping: the task is usually Running by the time Start-ScheduledTask
            # returns, and sleeping first charged every registration a flat 2s for nothing.
            if ($this.IsTaskRunning()) {
                $startConfirmed = $true
                break
            }
            Start-Sleep -Seconds 2
        }
        if ($startConfirmed) {
            Write-Status "Time is now: $([datetime]::Now) Task Scheduled $($this.TaskName) has Started."
        }
        else {
            Write-Status "WARNING: $($this.TaskName) did not confirm Running within 30s after start; caller will retry."
        }

        return $true

    }

    [bool] IsTaskRunning() {
        # True when the scheduled task is actively Running, or (for a fast no-op script
        # that already finished) when it has run since we captured StartBaseline.
        try {
            $state = (Get-ScheduledTask -TaskName $($this.TaskName) -ErrorAction Stop).State
            if ($state -eq 'Running') { return $true }
            $info = Get-ScheduledTaskInfo -TaskName $($this.TaskName) -ErrorAction Stop
            # 267009 = SCHED_S_TASK_RUNNING
            if ($info.LastTaskResult -eq 267009) { return $true }
            if ($info.LastRunTime -and $info.LastRunTime -gt $this.StartBaseline) { return $true }
        }
        catch {
            Write-Verbose "IsTaskRunning check failed for $($this.TaskName): $($_.Exception.Message)"
        }
        return $false
    }
}

function Resolve-OpticalMediaDriveLetter {
    # Reliably locate the optical (mounted-ISO) disc that carries $MarkerRelativePath
    # at its root and give it $TargetDriveLetter, returning "<letter>:" on success or
    # $null (never throws). This is the reusable in-guest form of the drive-letter
    # resolution the SQL media (Phase 4 AssignSqlIsoDriveLetter) and any other
    # in-guest media reader needs, so the same hardening lives in ONE place.
    #
    # Why it exists: the guest's own long-lived LCM/DSC session can hold a STALE
    # optical view -- a disc the host attached AFTER the session started can
    # enumerate LETTERLESS or lag entirely, and a naive "find the lettered CD-ROM"
    # then misses it and the dependent resource strands (re-stages pending.mof).
    # This helper (a) POLLS for the disc to settle (device rescan between tries),
    # (b) recognizes a LETTERLESS disc by binding a temporary scratch letter to
    # probe it by content, and (c) assigns the target letter via CIM -> WMI ->
    # mountvol until the marker resolves.
    #
    # USAGE: call only from CLASS-BASED DSC resources in THIS module (the module is
    # already loaded there, so the call is free). Do NOT call it from a DSC Script
    # resource via `Import-Module TemplateHelpDSC` -- importing this large
    # class-based module inside the LCM's own Script-resource runspace re-parses
    # every DSC class and is extremely slow (it froze Phase 4 AssignSqlIsoDrive-
    # Letter for ~8 min and tripped the stranded-PendingConfiguration self-healer).
    # A Script resource must keep its own compact inline copy instead.
    param(
        [string]$MarkerRelativePath = 'setup.exe',
        [string]$TargetDriveLetter = 'S',
        [int]$TimeoutSeconds = 120
    )
    $target = ([string]$TargetDriveLetter).TrimEnd(':')   # 'S'
    $targetColon = "${target}:"                           # 'S:'
    $mountvol = "$env:SystemRoot\System32\mountvol.exe"

    $hasMarker = { param($L) try { [bool](Test-Path (Join-Path "${L}:\" $MarkerRelativePath) -ErrorAction SilentlyContinue) } catch { $false } }

    $findVol = {
        $optical = @(Get-CimInstance -ClassName Win32_Volume -Filter 'DriveType = 5' -ErrorAction SilentlyContinue)
        # (a) Prefer a lettered optical volume carrying the marker at its root.
        foreach ($vol in $optical) {
            if ($vol.DriveLetter -and (& $hasMarker (([string]$vol.DriveLetter).TrimEnd(':')))) { return $vol }
        }
        # (b) Probe LETTERLESS optical volumes via a temporary scratch letter, so a
        #     disc that merely lacks a letter (two-disc optical enumeration churn) is
        #     still recognized instead of being treated as absent.
        $scratchPool = @('R', 'Q', 'P', 'O', 'N', 'M')
        $used = @{}
        foreach ($v in (Get-CimInstance -ClassName Win32_Volume -ErrorAction SilentlyContinue)) {
            if ($v.DriveLetter) { $used[([string]$v.DriveLetter).TrimEnd(':')] = $true }
        }
        foreach ($vol in $optical) {
            if ($vol.DriveLetter) { continue }
            $scratch = $scratchPool | Where-Object { -not $used.ContainsKey($_) } | Select-Object -First 1
            if (-not $scratch) { break }
            $isMatch = $false
            try {
                & $mountvol "${scratch}:" $vol.DeviceID 2>$null | Out-Null
                Start-Sleep -Seconds 1
                $isMatch = [bool](& $hasMarker $scratch)
            }
            catch { }
            try { & $mountvol "${scratch}:" /D 2>$null | Out-Null } catch { }
            if ($isMatch) { return $vol }
        }
        return $null
    }

    # (1) Locate the disc, polling briefly: after a host mount the guest can take a
    #     few seconds to enumerate it, and with two discs attached it can appear
    #     letterless. Rescan devices between tries.
    $disc = $null
    $deadline = (Get-Date).AddSeconds([int]$TimeoutSeconds)
    do {
        $disc = & $findVol
        if ($disc) { break }
        try { & pnputil.exe /scan-devices *>$null } catch { }
        try { "rescan" | & diskpart.exe *>$null } catch { }
        Start-Sleep -Seconds 5
    } while ((Get-Date) -lt $deadline)
    if (-not $disc) { return $null }
    if ($disc.DriveLetter -eq $targetColon) { return $targetColon }

    # (2) Free the target letter so the reassignment can't be rejected: park a live
    #     holder on a high letter, clear any mount-point mapping, and drop a stale
    #     \DosDevices reservation left by a prior mount whose volume is gone.
    $high = @('Z', 'Y', 'X', 'W', 'V', 'U', 'T')
    $used = @{}
    foreach ($v in (Get-CimInstance -ClassName Win32_Volume -ErrorAction SilentlyContinue)) {
        if ($v.DriveLetter) { $used[([string]$v.DriveLetter).TrimEnd(':')] = $true }
    }
    $holder = Get-CimInstance -ClassName Win32_Volume -Filter "DriveLetter = '$targetColon'" -ErrorAction SilentlyContinue
    if ($holder) {
        $free = $high | Where-Object { -not $used.ContainsKey($_) } | Select-Object -First 1
        if ($free) {
            try {
                $wmiHolder = Get-WmiObject -Class Win32_Volume -ErrorAction SilentlyContinue | Where-Object { $_.DeviceID -eq $holder.DeviceID } | Select-Object -First 1
                if ($wmiHolder) { $wmiHolder | Set-WmiInstance -Arguments @{ DriveLetter = "${free}:" } -ErrorAction SilentlyContinue | Out-Null }
            }
            catch { }
        }
    }
    try { & $mountvol $targetColon /D 2>$null | Out-Null } catch { }
    try {
        $stillHeld = Get-CimInstance -ClassName Win32_Volume -Filter "DriveLetter = '$targetColon'" -ErrorAction SilentlyContinue
        if (-not $stillHeld) {
            $md = 'HKLM:\SYSTEM\MountedDevices'
            $name = "\DosDevices\$targetColon"
            if ($null -ne (Get-ItemProperty -Path $md -Name $name -ErrorAction SilentlyContinue)) {
                Remove-ItemProperty -Path $md -Name $name -ErrorAction SilentlyContinue
            }
        }
    }
    catch { }

    # (3) Assign the target letter to the disc, trying each method until the marker
    #     resolves under it.
    $assigned = $false
    try {
        $disc.DriveLetter = $targetColon
        Set-CimInstance -InputObject $disc -ErrorAction Stop
        $assigned = [bool](& $hasMarker $target)
    }
    catch { }
    if (-not $assigned) {
        try {
            $wmiVol = Get-WmiObject -Class Win32_Volume -Filter 'DriveType = 5' -ErrorAction SilentlyContinue | Where-Object { $_.DeviceID -eq $disc.DeviceID } | Select-Object -First 1
            if ($wmiVol) { $wmiVol | Set-WmiInstance -Arguments @{ DriveLetter = $targetColon } -ErrorAction SilentlyContinue | Out-Null }
            $assigned = [bool](& $hasMarker $target)
        }
        catch { }
    }
    if (-not $assigned) {
        try {
            & $mountvol $targetColon $disc.DeviceID 2>$null | Out-Null
            Start-Sleep -Seconds 1
            $assigned = [bool](& $hasMarker $target)
        }
        catch { }
    }
    if ($assigned) { return $targetColon }
    return $null
}

[DscResource()]
class InitializeDisks {
    [DscProperty(key)]
    [string] $DummyKey

    [DscProperty(Mandatory)]
    [string] $VM

    [void] Set() {

        Write-Status "Initializing disks"

        # Park every CD-ROM (mounted ISO) on a HIGH drive letter before assigning
        # data-disk letters, so no disc can squat a data-disk letter. Multiple
        # discs may be mounted at once (SQL / CM / cache), so relabel each one that
        # isn't already high. Idempotent: a disc already on a high letter is left
        # alone. Each consumer later finds ITS disc by content (SQL -> setup.exe at
        # root -> S:; CM -> SMSSETUP; cache -> MEMLABSCACHE label), never by letter.
        try {
            $highLetters = @('Z', 'Y', 'X', 'W', 'V', 'U', 'T')
            $usedLetters = @{}
            foreach ($v in (Get-Volume -ErrorAction SilentlyContinue)) {
                if ($v.DriveLetter) { $usedLetters[([string]$v.DriveLetter).TrimEnd(':')] = $true }
            }
            foreach ($cd in (Get-WmiObject -Class Win32_Volume -Filter 'DriveType = 5' -ErrorAction SilentlyContinue)) {
                if (-not $cd.DriveLetter) { continue }
                $cur = ([string]$cd.DriveLetter).TrimEnd(':')
                if ($highLetters -contains $cur) { continue }
                $free = $highLetters | Where-Object { -not $usedLetters.ContainsKey($_) } | Select-Object -First 1
                if (-not $free) { continue }
                Write-Status "Moving CD-ROM $($cd.DriveLetter) to ${free}:.."
                $cd | Set-WmiInstance -Arguments @{DriveLetter = "${free}:" } -ErrorAction SilentlyContinue | Out-Null
                $usedLetters.Remove($cur) | Out-Null
                $usedLetters["$free"] = $true
            }
        }
        catch {
            Write-Status "CD-ROM drive-letter parking skipped (non-fatal): $($_.Exception.Message)"
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
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Scope = 'Function')]
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

        # Pre-flight: detect network problems that make domain join impossible.
        # Catching these early avoids a 20-minute blind retry loop.
        $this.DiagnoseNetwork($_DomainName)

        try {
            Write-Status "Joining computer to Domain $_DomainName"
            Add-Computer -DomainName $_DomainName -Credential $_credential -ErrorAction Stop
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Scope = 'Function')]
            $global:DSCMachineStatus = 1
        }
        catch {
            $CurrentDomain = (Get-WmiObject -Class Win32_ComputerSystem).Domain
            $count = 0
            Write-Status "Failed to join into the domain $_DomainName, retry $count/$_retryCount"
            $lastDiag = [datetime]::MinValue
            $flag = $false
            while ($CurrentDomain -ne $_DomainName) {
                if ($count -lt $_retryCount) {
                    $count++
                    Write-Status "Current Domain of $CurrentDomain does not match $_DomainName. Retry count: $count/$_retryCount"

                    # Re-run diagnostics every 5 minutes during retry loop
                    if (([datetime]::Now - $lastDiag).TotalMinutes -ge 5) {
                        $this.DiagnoseNetwork($_DomainName)
                        $lastDiag = [datetime]::Now
                    }

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
                # Final diagnostic before last-ditch attempt
                $this.DiagnoseNetwork($_DomainName)
                Write-Status "Failed too many times.  Rebooting, then Rejoining domain."
                Add-Computer -DomainName $_DomainName -Credential $_credential
            }
            else {
                Write-Status "Domain Join Successful. Rebooting."
            }
            $global:DSCMachineStatus = 1
        }
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Scope = 'Function')]
        $global:DSCMachineStatus = 1
    }

    [void] DiagnoseNetwork([string] $domainName) {
        # Check for APIPA or duplicate IP — the two most common causes of
        # domain join failure that waste 20 minutes in a blind retry loop.
        try {
            $adapters = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.InterfaceAlias -notmatch 'Loopback' }
            foreach ($a in $adapters) {
                $ip = $a.IPAddress
                $iface = $a.InterfaceAlias
                if ($ip.StartsWith('169.254')) {
                    Write-Status "WARNING: $iface has APIPA address $ip - no DHCP lease. Domain join will fail until this is resolved."
                }
                # Check for DAD (Duplicate Address Detection) state
                if ($a.AddressState -eq 'Duplicate') {
                    Write-Status "ERROR: $iface has DUPLICATE IP $ip - another device owns this address. This is likely a cluster/AG virtual IP assigned as a DHCP reservation by mistake. Domain join is impossible until the reservation is fixed on the DHCP server."
                }
            }
            # Check DNS resolution
            try {
                $dcAddrs = [System.Net.Dns]::GetHostAddresses($domainName) |
                    Where-Object { $_.AddressFamily -eq 'InterNetwork' }
                if ($dcAddrs) {
                    Write-Status "DNS: $domainName resolves to $($dcAddrs.IPAddressToString -join ', ')"
                }
                else {
                    Write-Status "WARNING: DNS resolution for $domainName returned no IPv4 addresses."
                }
            }
            catch {
                Write-Status "WARNING: DNS resolution for $domainName failed: $($_.Exception.Message)"
            }
            # Check LDAP port on the first resolved DC
            try {
                $dnsServer = (Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                    Where-Object { $_.ServerAddresses.Count -gt 0 } | Select-Object -First 1).ServerAddresses[0]
                if ($dnsServer) {
                    $tcp = New-Object System.Net.Sockets.TcpClient
                    try {
                        $tcp.Connect($dnsServer, 389)
                        if ($tcp.Connected) {
                            Write-Status "LDAP: DC at $dnsServer`:389 is reachable."
                        }
                    }
                    catch {
                        Write-Status "WARNING: LDAP port 389 on DC $dnsServer is not reachable: $($_.Exception.Message)"
                    }
                    finally { $tcp.Dispose() }
                }
            }
            catch {}
        }
        catch {
            Write-Status "Network diagnostic failed: $($_.Exception.Message)"
        }
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
    #   0. Require DC Locator to discover the PDC first. Ping and an open LDAP
    #      socket are insufficient while Netlogon/AD is still starting.
    #   1. Test-ComputerSecureChannel -Repair (resets password, no reboot).
    #   2. Reset-ComputerMachinePassword against the named DC.
    #   3. Reconfirm that the PDC stays ready and the secure channel stays broken.
    #   4. Only then, perform a full unjoin + reboot; JoinDomain re-adds the
    #      computer on the next DSC pass.
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

        # Step 0: Require the PDC's Netlogon/DC Locator path before attempting
        # repair. A DC can answer ping and accept TCP 389 before it is ready to
        # authenticate machine accounts.
        $dcReady = $false
        Write-Status "Verifying PDC readiness before secure channel repair."
        for ($attempt = 1; $attempt -le 40; $attempt++) {
            try {
                ipconfig /flushdns 2>&1 | Out-Null
                ipconfig /registerdns 2>&1 | Out-Null
            } catch {}

            if (Test-DomainControllerReady -DCName $_DCName -DomainName $_DomainName) {
                $dcReady = $true
                Write-Status "DC Locator found PDC '$_DCName' (attempt $attempt)."
                break
            }

            if ($attempt -lt 40) {
                Write-Status "DC Locator cannot find PDC '$_DCName' yet (attempt $attempt/40). Waiting 15s before retry."
                Start-Sleep -Seconds 15
            }
        }

        if (-not $dcReady) {
            $msg = "DC Locator could not find PDC '$_DCName' after 10 minutes. Leaving domain membership unchanged for a later retry."
            Write-Status "ERROR: $msg"
            throw $msg
        }

        # Step 1: Test-ComputerSecureChannel -Repair. This does a password
        # reset in one call and is the simplest fix.
        Write-Status "Secure channel to $_DomainName is broken. Attempting -Repair."
        for ($i = 1; $i -le 2; $i++) {
            try {
                if (Test-ComputerSecureChannel -Repair -Credential $_credential -ErrorAction Stop) {
                    Write-Status "Test-ComputerSecureChannel -Repair succeeded (attempt $i)."
                    return
                }
            }
            catch {
                $msg = ($_.Exception.Message -replace '\s+', ' ').Trim()
                Write-Status "Test-ComputerSecureChannel -Repair attempt $i failed: $msg"
            }
            if ($i -lt 2) { Start-Sleep -Seconds 10 }
        }

        # Step 2: Reset-ComputerMachinePassword against the named DC.
        Write-Status "Repair failed. Trying Reset-ComputerMachinePassword against $_DCName."
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

        # Step 3: Before destructive escalation, require five consecutive
        # observations where DC Locator still finds the PDC but the secure
        # channel remains broken. Any PDC-readiness lapse aborts the escalation.
        Write-Status "Non-destructive repairs failed. Confirming stable PDC readiness before full rejoin."
        for ($attempt = 1; $attempt -le 5; $attempt++) {
            if (-not (Test-DomainControllerReady -DCName $_DCName -DomainName $_DomainName)) {
                $msg = "PDC '$_DCName' lost DC Locator readiness during rejoin confirmation. Leaving domain membership unchanged for a later retry."
                Write-Status "ERROR: $msg"
                throw $msg
            }

            try {
                if (Test-ComputerSecureChannel -ErrorAction Stop) {
                    Write-Status "Secure channel recovered during rejoin confirmation (attempt $attempt)."
                    return
                }
            }
            catch {
                $msg = ($_.Exception.Message -replace '\s+', ' ').Trim()
                Write-Status "Secure channel confirmation attempt $attempt remained broken: $msg"
            }
            if ($attempt -lt 5) { Start-Sleep -Seconds 15 }
        }

        # Step 4: The PDC remained discoverable throughout confirmation and both
        # non-destructive repair methods failed. Preserve the proven recovery:
        # unjoin now, reboot, and let JoinDomain re-add on the next DSC pass.
        Write-Status "WARNING: Secure channel remains broken with a stable PDC. Performing full domain unjoin/rejoin recovery."
        try {
            Remove-Computer -UnjoinDomainCredential $_credential -PassThru -Force -ErrorAction Stop | Out-Null
            Write-Status "Remove-Computer succeeded. Requesting reboot so JoinDomain can re-add."
        }
        catch {
            $msg = ($_.Exception.Message -replace '\s+', ' ').Trim()
            Write-Status "Remove-Computer failed: $msg"
            throw
        }
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Scope = 'Function')]
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

        # Hardening: opening firewall ports is BEST-EFFORT. A single bad / unsupported / duplicate
        # rule must NEVER abort the DSC apply and strand the whole configuration. (Observed: an
        # invalid -LocalPort value made New-NetFirewallRule throw a non-terminating error, which the
        # LCM recorded as a Set failure -> pending.mof retained -> node parked in PendingConfiguration
        # for the rest of Phase 2.) Suppress per-call errors for the whole method, then surface a
        # single summary at the end so a genuine problem is still visible without failing the deploy.
        $ErrorActionPreference = 'SilentlyContinue'
        $Error.Clear()

        Write-Status "Opening firewall ports for Role:$_Role"

        New-NetFirewallRule -DisplayName "Cluster Network Outbound" -Profile Any -Direction Outbound -Action Allow -RemoteAddress @("10.250.250.0/24", "10.250.251.0/24")
        New-NetFirewallRule -DisplayName "Cluster Network Inbound" -Profile Any -Direction Inbound -Action Allow -RemoteAddress @("10.250.250.0/24", "10.250.251.0/24")

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

            New-NetFirewallRule -DisplayName 'DHCP Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort @(67, 68) -Group "For SCCM PXE SP"
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
            New-NetFirewallRule -DisplayName 'SQL HADR Endpoint Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort 5022 -Group "For SQL Server"
            New-NetFirewallRule -DisplayName 'SQL Browser Inbound' -Profile Any -Direction Inbound -Action Allow -Protocol UDP -LocalPort 1434 -Group "For SQL Server"
            New-NetFirewallRule -DisplayName 'WMI' -Program "%systemroot%\system32\svchost.exe" -Service "winmgmt" -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort RPC -Group "For SQL Server WMI"
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
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Scope = 'Function')]
                $global:DSCMachineStatus = 1
            }
        }

        # Best-effort visibility: every entry in $Error here is a suppressed firewall-rule failure
        # ($Error was cleared at the top of Set and only firewall cmdlets run in between). Report a
        # summary so a real misconfiguration still shows up in the DSC log even though it no longer
        # strands the node. $Error[0] is the most recent failure.
        if ($Error.Count -gt 0) {
            Write-Status "WARNING: $($Error.Count) firewall rule(s) reported errors and were skipped (continuing). First: $(($Error[0].Exception.Message).Trim())"
        }

        # Durable marker under C:\staging (survives reboots + %windir%\temp cleanup, which was
        # purging the old marker between runs -- re-running every firewall rule, and a
        # WorkgroupMember reboot, on every Phase 3).
        $StatusPath = "C:\staging\OpenFirewallStatus.txt"
        if (-not (Test-Path 'C:\staging')) { New-Item -ItemType Directory -Path 'C:\staging' -Force | Out-Null }
        "Finished" | Out-File -FilePath $StatusPath -Append -Encoding ascii
    }

    [bool] Test() {
        # Durable marker, falling back to the legacy %windir%\temp marker so a device already
        # provisioned under the old scheme (old marker not yet cleaned) isn't re-run/rebooted.
        return ([bool]((Test-Path "C:\staging\OpenFirewallStatus.txt") -or (Test-Path "$env:windir\temp\OpenFirewallStatus.txt")))
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

    # PKI CA flags. When set, GetRequiredFeatures lays down the CA role BINARIES here
    # -- during Phase 2/3 DSC, which runs in PARALLEL across VMs, under lighter load,
    # and with DSC's native reboot handling -- so the post-Phase2 PKI orchestrator
    # (Install-PKI) only has to CONFIGURE the CA instead of running a ServerManager
    # servicing install inside its serial, fragile, heavily-loaded window (where it
    # wedged on "Collecting data...").
    [DscProperty()]
    [bool] $InstallCA

    [DscProperty()]
    [bool] $IsOfflineRootCA

    [DscProperty(NotConfigurable)]
    [string] $Version = "8"

    [void] Set() {
        $_Role = $this.Role

        Write-Status "Installing Windows Features for Role $_Role"

        # Install on all devices. This read "dism / online / Enable-Feature / FeatureName:..."
        # for years: PowerShell tokenizes each bare "/" as its own argument, so dism got
        # garbage -- and a native exe returns an exit code instead of throwing, so the
        # try/catch could never see it. Report a bad exit code instead of swallowing it.
        Write-Status "Installing Windows Feature TelnetClient"
        try {
            $dismOutput = & dism.exe /online /Enable-Feature /FeatureName:TelnetClient /NoRestart /Quiet 2>&1
            if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 3010) {
                Write-Status "TelnetClient enable returned exit code $LASTEXITCODE (continuing): $($dismOutput | Select-Object -Last 1)"
            }
        }
        catch {
            Write-Status "TelnetClient enable failed (continuing): $($_.Exception.Message)"
        }

        # Required server features for this role (empty on client OS). Re-query here
        # because Test() may have found only one missing feature; submitting the full
        # role list makes ServerManager reprocess every already-installed feature.
        $stamp = "Finished"
        $featureList = @($this.GetRequiredFeatures())
        if ($featureList.Count -gt 0) {
            $featureState = @($this.GetFeatureState($featureList))
            $pendingFeatures = @($featureState | Where-Object { ([string]$_.InstallState) -like "*Pending" } | ForEach-Object { "$($_.Name)=$($_.InstallState)" })
            if ($pendingFeatures.Count -gt 0) {
                # Name the servicing flag that owes the reboot -- without it the log records
                # only that SOMETHING is pending, and the originating operation is unknowable.
                Write-Status "Windows Feature servicing is pending restart: $($pendingFeatures -join ', ') [reboot owed by: $($this.RebootPendingReasons())]"
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Scope = 'Function')]
                $global:DSCMachineStatus = 1
                return
            }

            $missingFeatures = @($featureState | Where-Object { $_.InstallState -ne "Installed" } | ForEach-Object { $_.Name })
            if ($missingFeatures.Count -eq 0) {
                $stamp = $this.FeatureSignature($featureList)
            }
            else {
                Write-Status "Installing $($missingFeatures.Count) missing Windows Features: $($missingFeatures -join ', ')"
                $result = Install-WindowsFeature -Name $missingFeatures -IncludeManagementTools
                if ($result.RestartNeeded -eq "Yes") {
                    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Scope = 'Function')]
                    $global:DSCMachineStatus = 1
                }
                else {
                    $stamp = $this.FeatureSignature($featureList)
                }
            }
        }

        # A globalModule whose DLL is absent kills EVERY w3wp on the box, so the
        # registration has to go. sfc/DISM cannot help: per the Windows manifests
        # (inetsrv/iis/setup/manifests/IIS-NetFxExtensibility*.man) the DLL and its appcmd
        # registration ship in the same component, so when that component is not installed
        # CBS considers the system correct and restores nothing -- measured on PL-PATTYDP,
        # where DISM /RestoreHealth and sfc both reported success and validcfg.dll stayed
        # missing. Dropping the registration is verbatim the uninstall action from
        # IIS-NetFxExtensibilityCommon-GC.man, and re-installing the feature puts it back.
        $missingModules = @($this.MissingGlobalModules())
        if ($missingModules.Count -gt 0) {
            $appcmd = Join-Path $env:windir 'system32\inetsrv\appcmd.exe'
            foreach ($missingModule in $missingModules) {
                $moduleName = ($missingModule -split ' -> ')[0]
                Write-Status "IIS globalModule '$moduleName' has no DLL on disk; unregistering it so w3wp can start"
                try {
                    $out = & $appcmd uninstall module $moduleName 2>&1
                    Write-Status "appcmd uninstall module $moduleName -> $($out -join ' ')"
                }
                catch { Write-Status "appcmd uninstall module $moduleName failed: $($_.Exception.Message)" }
            }
            $stillMissing = @($this.MissingGlobalModules())
            if ($stillMissing.Count -gt 0) {
                Write-Status "IIS globalModule DLL(s) STILL registered without a file: $($stillMissing -join '; '). IIS will keep returning HTTP 503 until this is resolved."
            }
        }

        # Durable completion breadcrumb (diagnostics + client-OS fast-path + the Test()
        # fast path). Lives under C:\staging so it survives reboots and %windir%\temp
        # cleanup -- the old %windir%\temp marker was being purged between runs (Phase 10
        # maintenance / the reboots during Phase 8 CM install), which made the full
        # feature install + reboot re-run on every Phase 3 for the SiteSystem boxes.
        # On server OS the file records the exact feature set it vouches for, so it is
        # only trusted while that set is unchanged; a reboot-pending install leaves the
        # generic stamp so the next Test() re-verifies against ServerManager.
        $this.WriteMarker($stamp)
    }

    [bool] Test() {
        # Idempotency is keyed on the ACTUAL installed feature set (the marker below only
        # caches a result already proven against ServerManager), so a fully-provisioned
        # server never re-runs the install + reboot just because the marker was cleaned
        # up. Adding a feature in GetRequiredFeatures() is auto-detected here (no Version
        # bump needed): a newly-required-but-missing feature makes Test() return $false
        # and Set() installs only what's missing.
        $featureList = @($this.GetRequiredFeatures())
        if ($featureList.Count -eq 0) {
            # Client OS -- no server features to verify; gate on the durable marker so
            # the one-time TelnetClient enable in Set() isn't re-run forever. Fall back to
            # the legacy %windir%\temp marker so devices provisioned under the old scheme
            # (whose old marker hasn't been cleaned yet) aren't re-run on the first pass.
            return ([bool]((Test-Path $this.MarkerPath()) -or (Test-Path "$env:windir\temp\InstallFeatureStatus$($this.Role)$($this.Version).txt")))
        }

        # Fast path. Get-WindowsFeature is NOT a cheap read: on a provisioned DP/MP/site
        # server ServerManager rebuilds its component cache from CBS, which measured
        # 214-251s per Phase 3 re-run on PT2-DPMP1/PT2-PRISITE (vs 1.5s on a SQL box) --
        # all of it spent proving a set that was already complete. The marker names the
        # exact feature set it vouches for and is only written once that set is verified
        # installed, so a set change (or a Version bump, which is in the file name) falls
        # through to the real query instead of being masked.
        $signature = $this.FeatureSignature($featureList)
        # Checked BEFORE the marker fast-path on purpose. The marker records that the
        # feature SET is installed, which stays true after a module DLL is deleted out of
        # band -- so a check behind the fast path would be skipped on exactly the re-runs
        # that need it (PL-PATTYDP lost validcfg.dll on a long-lived VM whose features
        # were already complete, and every later run sailed past on the marker).
        $missingModules = @($this.MissingGlobalModules())
        if ($missingModules.Count -gt 0) {
            Write-Status "IIS globalModule DLL(s) missing, w3wp cannot start: $($missingModules -join '; ')"
            return $false
        }
        try {
            $recorded = Get-Content -Path $this.MarkerPath() -TotalCount 1 -ErrorAction Stop
            if ($recorded -and ([string]$recorded).Trim() -eq $signature) { return $true }
        }
        catch {}

        $featureState = @($this.GetFeatureState($featureList))
        $missing = @($featureState | Where-Object { $_.InstallState -ne "Installed" })
        if ($missing.Count -eq 0) {
            # Compliant, but the marker is missing or predates this feature set (existing
            # lab, or a Set() that ended reboot-pending). Stamp it so the next run is free.
            $this.WriteMarker($signature)
            return $true
        }
        return $false
    }

    [string] FeatureSignature([string[]] $featureList) {
        return (($featureList | Sort-Object -Unique) -join ',')
    }

    # Every DLL applicationHost.config registers as a globalModule must exist or EVERY
    # w3wp dies at startup with ERROR_MOD_NOT_FOUND -> 5x WAS 5139 -> 5002 disables the
    # pool -> HTTP 503. Cheap: one file read + XML parse, versus the 214-251s
    # Get-WindowsFeature call this sits in front of. Returns @() when IIS is absent.
    [string[]] MissingGlobalModules() {
        $missing = @()
        try {
            $ahcPath = Join-Path $env:windir 'system32\inetsrv\config\applicationHost.config'
            if (-not (Test-Path -LiteralPath $ahcPath)) { return @() }
            $ahcXml = [xml](Get-Content -LiteralPath $ahcPath -Raw -ErrorAction Stop)
            foreach ($globalModule in @($ahcXml.configuration.'system.webServer'.globalModules.add)) {
                $moduleImage = [Environment]::ExpandEnvironmentVariables("$($globalModule.image)")
                if ($moduleImage -and -not (Test-Path -LiteralPath $moduleImage)) {
                    $missing += "$($globalModule.name) -> $moduleImage"
                }
            }
        }
        catch { return @() }
        return $missing
    }

    [void] WriteMarker([string] $content) {
        try {
            $markerPath = $this.MarkerPath()
            $markerDir = Split-Path -Parent $markerPath
            if (-not (Test-Path $markerDir)) { New-Item -ItemType Directory -Path $markerDir -Force | Out-Null }
            $content | Out-File -FilePath $markerPath -Force -Encoding ascii
        }
        catch {}
    }

    [object[]] GetFeatureState([string[]] $featureList) {
        $lastError = $null
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            try {
                $featureState = @(Get-WindowsFeature -Name $featureList -ErrorAction Stop)
                if ($featureState.Count -ne $featureList.Count) {
                    throw "ServerManager returned $($featureState.Count) of $($featureList.Count) requested features."
                }
                return $featureState
            }
            catch {
                $lastError = $_
                if ($attempt -lt 3) { Start-Sleep -Seconds 2 }
            }
        }
        throw "Unable to query required Windows features after 3 attempts: $($lastError.Exception.Message)"
    }

    [string] MarkerPath() {
        # Join the role array deterministically so the filename is stable across runs
        # regardless of how the role[] is ordered/stringified.
        $roleTag = ($this.Role -join '-')
        # The CA flags MUST be part of the name. Phase2DC declares two resources that both
        # carry Role='DC' -- InstallFeature (InstallCA=$false) and InstallCAFeature
        # (InstallCA=$true) -- with different required feature sets. Keyed on Role alone they
        # share one file and overwrite each other's signature, so neither can ever take the
        # fast path and every re-run pays two full Get-WindowsFeature calls (40.7s measured on
        # a DC+CA). That is also what exposes a pending servicing state on a DC and nowhere else.
        if ($this.IsOfflineRootCA) { $roleTag += '-RootCA' }
        elseif ($this.InstallCA) { $roleTag += '-CA' }
        return "C:\staging\InstallFeatureStatus$roleTag$($this.Version).txt"
    }

    # Which servicing flag is holding the reboot. Get-WindowsFeature only reports that a
    # feature is *Pending; this says why, so the write can be traced back to its source.
    [string] RebootPendingReasons() {
        $reasons = @()
        try {
            $cbs = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing'
            foreach ($key in @('RebootPending', 'RebootInProgress', 'PackagesPending')) {
                if (Test-Path -Path "$cbs\$key") { $reasons += "CBS\$key" }
            }
            if (Test-Path -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
                $reasons += 'WindowsUpdate\RebootRequired'
            }
            $pfro = @((Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations)
            if ($pfro.Count -gt 0) {
                # Flat [source, dest, source, dest, ...]; an empty dest means delete-on-reboot.
                $renames = 0
                for ($i = 1; $i -lt $pfro.Count; $i += 2) {
                    if ($pfro[$i]) { $renames++ }
                }
                $reasons += "PendingFileRename($renames renames of $([Math]::Ceiling($pfro.Count / 2)) ops)"
            }
            $activeName = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' -Name ComputerName -ErrorAction SilentlyContinue).ComputerName
            $stagedName = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' -Name ComputerName -ErrorAction SilentlyContinue).ComputerName
            if ($activeName -and $stagedName -and $activeName -ne $stagedName) {
                $reasons += "ComputerRename($activeName -> $stagedName)"
            }
        }
        catch {
            return "probe failed: $($_.Exception.Message)"
        }
        if ($reasons.Count -eq 0) { return 'no reboot flag found' }
        return ($reasons -join ' + ')
    }

    [string[]] GetRequiredFeatures() {
        $os = Get-WmiObject -Class Win32_OperatingSystem -ErrorAction SilentlyContinue
        $IsServerOS = $true
        if (-not $os -or $os.ProductType -eq 1) {
            $IsServerOS = $false
        }
        if (-not $IsServerOS) {
            return @()
        }

        $_Role = $this.Role

        # Collect all features into a single set, deduped case-insensitively.
        # NOTE: adding a feature here is picked up automatically on the next run --
        # Test() checks actual install state, so no Version bump is needed.
        $features = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

        # All servers
        [void]$features.Add("RSAT-AD-PowerShell")
        [void]$features.Add("AD-Domain-Services")

        if ($_Role -notcontains "DC" -and $_Role -notcontains "BDC") {
            # Non-DC servers get the IIS auth/ISAPI bits, BITS and IIS metabase.
            # DCs/BDCs don't host IIS for our roles — the CA web-enrollment path
            # (Common.PKI.ps1) installs its own Web-Server on demand — so these
            # IIS features are skipped on DC/BDC to shorten the feature install.
            [void]$features.Add("Web-Windows-Auth")
            [void]$features.Add("Web-ISAPI-Ext")
            [void]$features.Add("BITS")
            [void]$features.Add("BITS-IIS-Ext")
            [void]$features.Add("Web-WMI")
            [void]$features.Add("Web-Metabase")

            if ($_Role -notcontains "DomainMember") {
                [void]$features.Add("Rdc")
            }
        }

        if ($_Role -contains "SQLAO") {
            foreach ($f in @("Failover-Clustering", "RSAT-Clustering-PowerShell", "RSAT-Clustering-CmdInterface", "RSAT-Clustering-Mgmt", "RSAT-DNS-Server")) {
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
            # This list is DistMgr's, not ours. CDistributionManager::ConfigureOSFeatures
            # (distmgr.cpp) shells out to `dism.exe /online /norestart /enable-feature /ignorecheck`
            # with exactly these whenever the SCF InstallIIS bit is set -- and it does NOT first
            # check whether they are already present. Having them on before Phase 8 turns that into
            # a no-op instead of a live CBS transaction rewriting applicationHost.config while CM
            # is creating its own virtual directories in the same file.
            # DISM name -> ServerManager name: IIS-WebServerRole/Web-Server,
            # IIS-WebServer/Web-WebServer, IIS-CommonHttpFeatures/Web-Common-Http,
            # IIS-StaticContent, IIS-DefaultDocument, IIS-DirectoryBrowsing, IIS-HttpErrors,
            # IIS-HttpRedirect, IIS-WebServerManagementTools/Web-Mgmt-Tools,
            # IIS-IIS6ManagementCompatibility/Web-Mgmt-Compat, IIS-Metabase, IIS-WindowsAuthentication,
            # IIS-WMICompatibility/Web-WMI, IIS-ISAPIExtensions/Web-ISAPI-Ext,
            # IIS-ManagementScriptingTools/Web-Scripting-Tools, MSRDC-Infrastructure/Rdc,
            # IIS-ManagementService/Web-Mgmt-Service.
            # Web-Net-Ext/45 are NOT in DistMgr's list -- see the Management point block for those.
            foreach ($f in @("Web-Server", "Web-WebServer", "Web-Common-Http", "Web-Static-Content",
                    "Web-Default-Doc", "Web-Dir-Browsing", "Web-Http-Errors", "Web-Http-Redirect",
                    "Web-Mgmt-Tools", "Web-Mgmt-Compat", "Web-Metabase", "Web-Windows-Auth",
                    "Web-WMI", "Web-ISAPI-Ext", "Web-Scripting-Tools", "Rdc", "Web-Mgmt-Service",
                    "Web-Net-Ext", "Web-Net-Ext45")) {
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
            # Web-Asp-Net45 is the load-bearing one. RoleSetup::AddAspNet45PreReq (rolesetup.cpp)
            # shells `dism /online /norestart /enable-feature /ignorecheck /featurename:IIS-ASPNET45
            # /all` during role setup unless CheckASPNET40Or45() finds HKLM\SOFTWARE\Microsoft\
            # InetStp\Components\ASPNET45 already set. On PL-PATTYDP that DISM ran mid-Phase-8, its
            # advanced installers lost applicationHost.config to a concurrent writer (0x80070020 x10),
            # CBS failed 0x800f0922 and rolled back -- and the rollback deleted validcfg.dll while
            # failing to remove its globalModule entry, which took the whole lab down with 503s.
            # Installing it in Phase 3 sets that registry value so the prereq never runs at all.
            # Web-Net-Ext/45 then keep the shared Microsoft-Windows-IIS-NetFxExtensibility component
            # refcounted above zero, so a rollback elsewhere still cannot delete the DLL.
            foreach ($f in @("BITS", "BITS-IIS-Ext", "Web-WMI", "Web-Metabase",
                    "Web-Asp-Net45", "Web-Net-Ext", "Web-Net-Ext45")) {
                [void]$features.Add($f)
            }
        }

        if ($_Role -contains "State migration point") {
            foreach ($f in @("Web-Default-Doc", "Web-Asp-Net", "Web-Asp-Net45", "Web-Net-Ext", "Web-Net-Ext45", "Web-Metabase")) {
                [void]$features.Add($f)
            }
        }

        # PKI Certification Authority role binaries. Laid down here (parallel Phase 2/3
        # DSC) so the serial post-Phase2 PKI orchestrator only CONFIGURES the CA.
        if ($this.IsOfflineRootCA) {
            # Offline Standalone Root CA: ADCS role only -- no IIS. CRL/AIA for the
            # root are hosted on the online issuing CA, not on the offline root.
            [void]$features.Add("Adcs-Cert-Authority")
        }
        elseif ($this.InstallCA) {
            # Enterprise / issuing / subordinate CA: ADCS role + IIS (CRL virtual
            # directory / web enrollment served from this box).
            [void]$features.Add("Web-Server")
            [void]$features.Add("Adcs-Cert-Authority")
        }

        return @($features)
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

    # When $true, configure the page file but do NOT force a reboot here.
    # The page-file size change still requires a reboot to take effect, but the
    # caller is responsible for ensuring a subsequent reboot happens (e.g. the
    # DC config places this BEFORE the ADDomain promotion, whose reboot applies
    # the change for free — saving one dedicated reboot per DC). Default $false
    # preserves the original always-reboot behavior for every other caller.
    [DscProperty()]
    [bool] $SuppressReboot = $false

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
        if ($this.SuppressReboot) {
            Write-Status "Page file configured. $_Drive\pagefile.sys Size: $_MaximumSize MB. Reboot deferred to a subsequent step."
        }
        else {
            Write-Status "Page file configured. $_Drive\pagefile.sys Size: $_MaximumSize MB. Rebooting."
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Scope = 'Function')]
            $global:DSCMachineStatus = 1
        }
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
            # Durable marker under C:\staging (survives %windir%\temp cleanup; the old temp marker
            # was lost between runs, needlessly re-running certutil + restarting certsvc each pass).
            $StatusPath = "C:\staging\UpdateCAStatus.txt"
            if (-not (Test-Path 'C:\staging')) { New-Item -ItemType Directory -Path 'C:\staging' -Force | Out-Null }
            "Finished" | Out-File -FilePath $StatusPath -Append -Encoding ascii

            Write-Status "Finished installing CA."
        }
        catch {
            Write-Status "Failed to install CA. $_"
        }
    }

    [bool] Test() {
        # Durable marker, falling back to the legacy %windir%\temp marker so an existing CA
        # provisioned under the old scheme isn't needlessly re-run (certutil + certsvc restart).
        return ([bool]((Test-Path "C:\staging\UpdateCAStatus.txt") -or (Test-Path "$env:windir\temp\UpdateCAStatus.txt")))
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
class WaitForClusterAccess {
    [DscProperty(Key)]
    [string] $ClusterName

    [DscProperty()]
    [string] $ClusterIPAddress = ''

    [DscProperty()]
    [int] $RetryIntervalSec = 15

    [DscProperty()]
    [int] $RetryCount = 40

    hidden [string] $LastError = ''
    hidden [string] $DnsSummary = ''
    hidden [string] $NetSummary = ''
    hidden [string] $FwSummary = ''

    hidden [string] TestFirewallRules() {
        $results = [System.Collections.Generic.List[string]]::new()

        # Check Failover Cluster firewall rules (auto-created by the Windows Feature)
        $clusterRules = Get-NetFirewallRule -DisplayGroup "Failover Clusters" -ErrorAction SilentlyContinue
        if ($clusterRules) {
            $enabled = @($clusterRules | Where-Object { $_.Enabled -eq 'True' }).Count
            $total = @($clusterRules).Count
            $results.Add("ClusterRules:$enabled/$total enabled")
        }
        else {
            $results.Add("ClusterRules:MISSING")
        }

        # Check cluster network blanket rules
        $clusterNetIn = Get-NetFirewallRule -DisplayName "Cluster Network Inbound" -ErrorAction SilentlyContinue
        $clusterNetOut = Get-NetFirewallRule -DisplayName "Cluster Network Outbound" -ErrorAction SilentlyContinue
        $inOk = $clusterNetIn -and $clusterNetIn.Enabled -eq 'True'
        $outOk = $clusterNetOut -and $clusterNetOut.Enabled -eq 'True'
        $results.Add("ClusterNet:In=$(if ($inOk) {'OK'} else {'MISS'}),Out=$(if ($outOk) {'OK'} else {'MISS'})")

        # Check RPC 135 inbound
        $rpc135 = Get-NetFirewallRule -Direction Inbound -Action Allow -Enabled True -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -match 'RPC Endpoint Mapper|DCOM' } |
            Select-Object -First 1
        $results.Add("RPC135in:$(if ($rpc135) {'OK'} else {'MISS'})")

        # Check firewall profiles
        $profiles = Get-NetFirewallProfile -ErrorAction SilentlyContinue
        $activeProfiles = @($profiles | Where-Object { $_.Enabled -eq 'True' } | ForEach-Object { "$($_.Name):$($_.DefaultInboundAction)" })
        if ($activeProfiles.Count -gt 0) {
            $results.Add("Profiles:$($activeProfiles -join ',')")
        }

        $summary = $results -join ', '
        Write-Status "Firewall: $summary"
        $this.FwSummary = $summary
        return $summary
    }

    hidden [string] TestNetworkConnectivity([string] $ip) {
        if (-not $ip) { return "No IP to test" }

        $results = [System.Collections.Generic.List[string]]::new()

        # ICMP ping
        try {
            $ping = Test-Connection -ComputerName $ip -Count 1 -Quiet -ErrorAction Stop
            $results.Add("Ping:$(if ($ping) { 'OK' } else { 'FAIL' })")
        }
        catch {
            $results.Add("Ping:ERR($($_.Exception.Message))")
        }

        # TCP 135 (RPC endpoint mapper -- used by Get-Cluster)
        try {
            $tcp135 = Test-NetConnection -ComputerName $ip -Port 135 -WarningAction SilentlyContinue -ErrorAction Stop
            $results.Add("TCP135:$(if ($tcp135.TcpTestSucceeded) { 'OK' } else { 'CLOSED' })")
        }
        catch {
            $results.Add("TCP135:ERR")
        }

        # TCP 445 (SMB -- used for cluster admin shares)
        try {
            $tcp445 = Test-NetConnection -ComputerName $ip -Port 445 -WarningAction SilentlyContinue -ErrorAction Stop
            $results.Add("TCP445:$(if ($tcp445.TcpTestSucceeded) { 'OK' } else { 'CLOSED' })")
        }
        catch {
            $results.Add("TCP445:ERR")
        }

        $summary = $results -join ', '
        Write-Status "Network $ip : $summary"
        $this.NetSummary = $summary
        return $summary
    }

    hidden [bool] TryClusterAccess([string] $name) {
        Clear-DnsClientCache

        # First check if DNS resolves at all
        $domain = (Get-CimInstance -ClassName Win32_ComputerSystem).Domain
        $clusterFqdn = if ($name -like "*.*") { $name } else { "$name.$domain" }
        try {
            $dnsResult = Resolve-DnsName -Name $clusterFqdn -Type A -ErrorAction Stop |
                Where-Object { $_.Type -eq 'A' }
            if (-not $dnsResult) {
                $this.LastError = "DNS resolves but returned no A records"
                return $false
            }
            $resolvedIP = $dnsResult[0].IPAddress
            Write-Verbose "DNS resolved $clusterFqdn -> $resolvedIP"
        }
        catch {
            $this.LastError = "DNS: $($_.Exception.Message)"
            return $false
        }

        # DNS works, now try the actual cluster connection by name
        try {
            $null = Get-Cluster -Name $name -ErrorAction Stop
            return $true
        }
        catch {
            $nameErr = $_.Exception.Message
            # Try via IP -- if this works, it's a name-based access issue
            # (Cluster Name resource offline or CNO not accessible by name)
            $_ClusterIP = $this.StripCidr($this.ClusterIPAddress)
            if ($_ClusterIP) {
                try {
                    $null = Get-Cluster -Name $_ClusterIP -ErrorAction Stop

                    # Cluster is running and reachable by IP. Check if the
                    # Cluster Name resource is actually Online. If it is,
                    # the name-based failure is a client-side resolution issue
                    # (e.g. local ClusSvc not running on this pre-join node)
                    # and the cluster itself is fully functional.
                    $nameResOnline = $false
                    try {
                        $nameRes = Get-ClusterResource -Cluster $_ClusterIP -ErrorAction Stop |
                            Where-Object { $_.OwnerGroup.Name -eq 'Cluster Group' -and $_.ResourceType -eq 'Network Name' }
                        if ($nameRes -and $nameRes.State -eq 'Online') {
                            $nameResOnline = $true
                        }
                    }
                    catch {
                        Write-Verbose "Could not query Cluster Name resource state: $_"
                    }

                    if ($nameResOnline) {
                        # Cluster Name resource is Online but Get-Cluster by name
                        # still failed -- force DNS re-registration and retry once
                        # by name. xCluster and other resources connect by name,
                        # so we can't accept IP-only access.
                        Write-Status "Get-Cluster by name failed but by IP $_ClusterIP succeeded; Cluster Name resource is Online -- forcing DNS update and retrying by name"
                        try {
                            $nameRes2 = Get-ClusterResource -Cluster $_ClusterIP -ErrorAction Stop |
                                Where-Object { $_.OwnerGroup.Name -eq 'Cluster Group' -and $_.ResourceType -eq 'Network Name' }
                            if ($nameRes2) {
                                $nameRes2 | Update-ClusterNetworkNameResource -ErrorAction Stop
                                Write-Verbose "Update-ClusterNetworkNameResource succeeded"
                            }
                        } catch {
                            Write-Verbose "Update-ClusterNetworkNameResource failed: $_"
                        }
                        Clear-DnsClientCache
                        Start-Sleep -Seconds 5

                        try {
                            $null = Get-Cluster -Name $name -ErrorAction Stop
                            Write-Status "Get-Cluster by name succeeded after DNS update"
                            $this.LastError = $null
                            return $true
                        } catch {
                            $this.LastError = "Get-Cluster by name still fails after DNS update ($($_.Exception.Message)); IP $_ClusterIP works, Cluster Name Online -- will retry"
                            return $false
                        }
                    }

                    $this.LastError = "Get-Cluster by name FAILED ($nameErr) but by IP $_ClusterIP SUCCEEDED -- Cluster Name resource not Online"
                    return $false
                }
                catch {
                    $this.LastError = "Get-Cluster by name FAILED ($nameErr), by IP $_ClusterIP also FAILED ($($_.Exception.Message))"
                    return $false
                }
            }
            $this.LastError = "Get-Cluster: $nameErr"
            return $false
        }
    }

    hidden [string] RepairClusterDns([string] $name) {
        $actions = [System.Collections.Generic.List[string]]::new()

        # If we're on a cluster node, check cluster health and force DNS re-registration.
        # Get-Cluster (no -Name) connects to the local cluster service, bypassing DNS.
        try {
            $localCluster = Get-Cluster -ErrorAction Stop
            if ($localCluster.Name -eq $name) {
                $actions.Add("Local cluster found")

                # Check all resources in the Cluster Group -- the "Cluster Name" and
                # "Cluster IP Address" resources must be Online for remote access.
                $clusterGroup = Get-ClusterGroup -Name "Cluster Group" -ErrorAction Stop
                $groupState = $clusterGroup.State
                $actions.Add("ClusterGroup:$groupState")

                $clusterResources = Get-ClusterResource -ErrorAction Stop |
                    Where-Object { $_.OwnerGroup.Name -eq 'Cluster Group' }
                foreach ($res in $clusterResources) {
                    $actions.Add("$($res.Name):$($res.State)")
                    Write-Status "Cluster resource '$($res.Name)' state: $($res.State)"
                }

                # If Cluster Name or its IP is not Online, try to bring the group online
                $nameRes = $clusterResources | Where-Object { $_.ResourceType -eq 'Network Name' }
                $ipRes = $clusterResources | Where-Object { $_.ResourceType -eq 'IP Address' }

                # If the Cluster IP resource is missing entirely (deleted by a
                # previous buggy ClusterRemoveUnwantedIPs run), recreate it.
                $_ClusterIP = $this.StripCidr($this.ClusterIPAddress)
                if (-not $ipRes -and $_ClusterIP) {
                    Write-Status "Cluster IP resource is MISSING. Recreating for $_ClusterIP..."
                    try {
                        $ipBytes = $_ClusterIP.Split('.')
                        $subnetPrefix = "$($ipBytes[0]).$($ipBytes[1]).$($ipBytes[2])."
                        $clusterNetwork = Get-ClusterNetwork -ErrorAction Stop |
                            Where-Object { $_.Address -and "$($_.Address)".StartsWith($subnetPrefix) } |
                            Select-Object -First 1

                        $resName = "Cluster IP Address"
                        $newIP = Add-ClusterResource -Name $resName -Group "Cluster Group" -ResourceType "IP Address" -ErrorAction Stop
                        $setParams = @{ Address = $_ClusterIP; SubnetMask = "255.255.255.0" }
                        if ($clusterNetwork) { $setParams['Network'] = $clusterNetwork.Name }
                        $newIP | Set-ClusterParameter -Multiple $setParams -ErrorAction Stop

                        if ($nameRes) {
                            Add-ClusterResourceDependency -Resource "Cluster Name" -Provider $resName -ErrorAction SilentlyContinue
                        }

                        Start-ClusterResource -Name $resName -ErrorAction SilentlyContinue
                        Start-Sleep -Seconds 5
                        $ipRes = Get-ClusterResource -Name $resName -ErrorAction SilentlyContinue
                        $actions.Add("IPRecreated:$($ipRes.State)")
                        Write-Status "Cluster IP resource recreated: $($ipRes.State)"
                    }
                    catch {
                        $actions.Add("IPRecreate failed: $_")
                        Write-Status "Failed to recreate Cluster IP: $_"
                    }
                }

                if ($nameRes -and $nameRes.State -ne 'Online') {
                    Write-Status "Cluster Name resource is $($nameRes.State). Attempting to bring online..."
                    # IP must be online before name can come online
                    if ($ipRes -and $ipRes.State -ne 'Online') {
                        foreach ($ip in $ipRes) {
                            if ($ip.State -ne 'Online') {
                                Write-Status "Starting Cluster IP resource '$($ip.Name)'..."
                                $ip | Start-ClusterResource -ErrorAction SilentlyContinue
                                Start-Sleep -Seconds 3
                            }
                        }
                    }
                    $nameRes | Start-ClusterResource -ErrorAction SilentlyContinue
                    Start-Sleep -Seconds 5
                    # Re-check state
                    $nameRes = Get-ClusterResource -Name $nameRes.Name -ErrorAction Stop
                    $actions.Add("NameAfterStart:$($nameRes.State)")
                    Write-Status "Cluster Name resource now: $($nameRes.State)"
                }

                if ($nameRes -and $nameRes.State -eq 'Online') {
                    Write-Status "Forcing DNS re-registration via Update-ClusterNetworkNameResource."
                    try {
                        $null = $nameRes | Update-ClusterNetworkNameResource -ErrorAction Stop
                        $actions.Add("DNS re-registered")
                    }
                    catch {
                        $actions.Add("UpdateDNS failed: $_")
                    }
                    Start-Sleep -Seconds 5
                }
            }
        }
        catch {
            Write-Verbose "Not on a cluster node or local cluster not named '$name': $_"
            $actions.Add("LocalCheck: $_")

            # Not on a cluster node -- try connecting remotely via IP to fix Cluster Name resource.
            # This is the typical path for ClusterNode2 which hasn't joined the cluster yet.
            $_ClusterIP = $this.StripCidr($this.ClusterIPAddress)
            if ($_ClusterIP) {
                try {
                    $remoteCluster = Get-Cluster -Name $_ClusterIP -ErrorAction Stop
                    if ($remoteCluster.Name -eq $name) {
                        $actions.Add("RemoteCluster via $($_ClusterIP) OK")

                        $clusterResources = Get-ClusterResource -Cluster $_ClusterIP -ErrorAction Stop |
                            Where-Object { $_.OwnerGroup.Name -eq 'Cluster Group' }
                        foreach ($res in $clusterResources) {
                            $actions.Add("$($res.Name):$($res.State)")
                            Write-Status "Cluster resource '$($res.Name)' state: $($res.State)"
                        }

                        $nameRes = $clusterResources | Where-Object { $_.ResourceType -eq 'Network Name' }
                        $ipRes = $clusterResources | Where-Object { $_.ResourceType -eq 'IP Address' }

                        if ($nameRes -and $nameRes.State -ne 'Online') {
                            Write-Status "Cluster Name resource is $($nameRes.State). Attempting remote fix via IP..."
                            if ($ipRes -and $ipRes.State -ne 'Online') {
                                foreach ($ip in $ipRes) {
                                    if ($ip.State -ne 'Online') {
                                        Write-Status "Starting Cluster IP resource '$($ip.Name)'..."
                                        $ip | Start-ClusterResource -ErrorAction SilentlyContinue
                                        Start-Sleep -Seconds 3
                                    }
                                }
                            }
                            $nameRes | Start-ClusterResource -ErrorAction SilentlyContinue
                            Start-Sleep -Seconds 5
                            $nameRes = Get-ClusterResource -Name $nameRes.Name -Cluster $_ClusterIP -ErrorAction Stop
                            $actions.Add("NameAfterStart:$($nameRes.State)")
                            Write-Status "Cluster Name resource now: $($nameRes.State)"
                        }

                        if ($nameRes -and $nameRes.State -eq 'Online') {
                            Write-Status "Forcing DNS re-registration via Update-ClusterNetworkNameResource."
                            try {
                                $null = $nameRes | Update-ClusterNetworkNameResource -ErrorAction Stop
                                $actions.Add("DNS re-registered")
                            }
                            catch {
                                $actions.Add("UpdateDNS failed: $_")
                            }
                            Start-Sleep -Seconds 5
                        }
                    }
                }
                catch {
                    Write-Verbose "Remote cluster via IP $_ClusterIP also failed: $_"
                    $actions.Add("RemoteCheck: $_")
                }
            }
        }

        # Discover domain and all DCs
        $domain = (Get-CimInstance -ClassName Win32_ComputerSystem).Domain
        $allDCs = @()
        try {
            Import-Module ActiveDirectory -ErrorAction Stop -Verbose:$false
            $allDCs = @(Get-ADDomainController -Filter * -ErrorAction Stop | Select-Object -ExpandProperty HostName)
        }
        catch {
            $actions.Add("AD module failed: $_")
            Write-Verbose "Could not enumerate DCs via AD module: $_"
        }
        if ($allDCs.Count -eq 0) {
            try {
                $ns = Resolve-DnsName -Name $domain -Type NS -ErrorAction Stop | Where-Object { $_.Type -eq 'NS' }
                $allDCs = @($ns | ForEach-Object { $_.NameHost })
            }
            catch {
                $actions.Add("NS lookup failed")
                Write-Verbose "Could not enumerate DCs via NS records: $_"
            }
        }

        if ($allDCs.Count -eq 0) {
            $summary = "No DCs found"
            $this.DnsSummary = $summary
            return $summary
        }

        $clusterFqdn = if ($name -like "*.*") { $name } else { "$name.$domain" }
        Write-Status "Checking DNS for '$clusterFqdn' across $($allDCs.Count) DC(s): $($allDCs -join ', ')"

        # Check which DCs have the A record and which don't
        $dcsWithRecord = @()
        $dcsMissing = @()
        $dcErrors = @{}
        $knownIP = $null
        foreach ($dc in $allDCs) {
            try {
                $rec = Resolve-DnsName -Name $clusterFqdn -Type A -Server $dc -DnsOnly -ErrorAction Stop |
                    Where-Object { $_.Type -eq 'A' }
                if ($rec) {
                    $dcsWithRecord += $dc
                    if (-not $knownIP) { $knownIP = $rec[0].IPAddress }
                    Write-Status "DC $dc : A record $($rec[0].IPAddress)"
                }
                else {
                    $dcsMissing += $dc
                    $dcErrors[$dc] = "empty response"
                    Write-Status "DC $dc : no A record for $clusterFqdn"
                }
            }
            catch {
                $dcsMissing += $dc
                $dcErrors[$dc] = $_.Exception.Message
                Write-Status "DC $dc : FAILED - $($_.Exception.Message)"
            }
        }

        if ($dcsWithRecord.Count -eq $allDCs.Count) {
            $summary = "DNS OK on all $($allDCs.Count) DC(s) -> $knownIP"
        }
        elseif ($dcsWithRecord.Count -gt 0) {
            $haveShort = ($dcsWithRecord | ForEach-Object { ($_ -split '\.')[0] }) -join ','
            $missShort = ($dcsMissing | ForEach-Object { ($_ -split '\.')[0] }) -join ','
            $summary = "DNS: $knownIP on [$haveShort], missing on [$missShort]"

            # Force replication from a DC that has it
            $sourceDC = $dcsWithRecord[0]
            Write-Status "Forcing AD replication from $sourceDC to $($dcsMissing.Count) DC(s)"
            try {
                $domainDN = ($domain.Split('.') | ForEach-Object { "DC=$_" }) -join ','
                foreach ($targetDC in $dcsMissing) {
                    foreach ($nc in @($domainDN, "DC=DomainDnsZones,$domainDN")) {
                        $repOut = repadmin /replicate $targetDC $sourceDC $nc /force 2>&1
                        Write-Verbose "repadmin $targetDC <- $sourceDC ($nc): $repOut"
                    }
                }
                $actions.Add("Replicated to $missShort")
            }
            catch {
                $actions.Add("Replication failed: $_")
                Write-Verbose "Replication attempt failed: $_"
            }
        }
        else {
            $errMsgs = ($dcErrors.GetEnumerator() | ForEach-Object { "$(($_.Key -split '\.')[0]):$($_.Value)" }) -join '; '
            $summary = "DNS missing on ALL $($allDCs.Count) DC(s) [$errMsgs]"
        }

        if ($actions.Count -gt 0) { $summary += " | $($actions -join '; ')" }

        # Flush local DNS cache after any repair
        Clear-DnsClientCache
        $null = ipconfig /registerdns 2>&1

        Write-Status "DNS repair done: $summary"
        $this.DnsSummary = $summary
        return $summary
    }

    hidden [string] StripCidr([string] $ip) {
        if ($ip -match '^([^/]+)/') { return $Matches[1] }
        return $ip
    }

    [void] Set() {
        # Pre-import modules silently to avoid verbose "Exporting function" spam
        Import-Module FailoverClusters -Verbose:$false -ErrorAction SilentlyContinue
        Import-Module DnsClient -Verbose:$false -ErrorAction SilentlyContinue

        $_ClusterName = $this.ClusterName
        $_RetryInterval = $this.RetryIntervalSec
        $_RetryCount = $this.RetryCount
        $_ClusterIP = $this.StripCidr($this.ClusterIPAddress)

        for ($i = 1; $i -le $_RetryCount; $i++) {
            # On first attempt and every 4th attempt, run full diagnostics
            if ($i -eq 1 -or ($i % 4) -eq 0) {
                try { $this.RepairClusterDns($_ClusterName) } catch { Write-Status "RepairClusterDns error: $_" }
                # Network connectivity test against cluster IP and DNS-resolved IP
                $ipsToTest = [System.Collections.Generic.List[string]]::new()
                if ($_ClusterIP) { $ipsToTest.Add($_ClusterIP) }
                $domain = (Get-CimInstance -ClassName Win32_ComputerSystem).Domain
                $fqdn = if ($_ClusterName -like "*.*") { $_ClusterName } else { "$_ClusterName.$domain" }
                try {
                    $r = Resolve-DnsName -Name $fqdn -Type A -ErrorAction Stop | Where-Object { $_.Type -eq 'A' }
                    if ($r) {
                        $dnsIP = $r[0].IPAddress
                        if ($dnsIP -and $dnsIP -ne $_ClusterIP -and -not $ipsToTest.Contains($dnsIP)) {
                            $ipsToTest.Add($dnsIP)
                        }
                    }
                }
                catch {}
                foreach ($testIP in $ipsToTest) {
                    try { $this.TestNetworkConnectivity($testIP) } catch { Write-Status "Network test error for ${testIP}: $_" }
                }
                # Firewall diagnostics on first attempt only
                if ($i -eq 1) {
                    try { $this.TestFirewallRules() } catch { Write-Status "Firewall check error: $_" }
                }
            }
            else {
                Clear-DnsClientCache
            }

            if ($this.TryClusterAccess($_ClusterName)) {
                Write-Status "Cluster '$_ClusterName' is now accessible by name."
                return
            }

            $detail = $this.LastError
            if ($this.DnsSummary) { $detail = "$detail | $($this.DnsSummary)" }
            if ($this.NetSummary) { $detail = "$detail | Net:$($this.NetSummary)" }
            if ($this.FwSummary -and $i -le 2) { $detail = "$detail | FW:$($this.FwSummary)" }
            Write-Status "Cluster '$_ClusterName' attempt $i/$_RetryCount FAILED: $detail"
            Start-Sleep -Seconds $_RetryInterval
        }
        throw "Cluster '$_ClusterName' did not become accessible after $_RetryCount attempts ($(($_RetryCount * $_RetryInterval) / 60) min). Last: $($this.LastError) | DNS: $($this.DnsSummary) | Net: $($this.NetSummary) | FW: $($this.FwSummary)"
    }

    [bool] Test() {
        # Pre-import modules silently to avoid verbose "Exporting function" spam
        Import-Module FailoverClusters -Verbose:$false -ErrorAction SilentlyContinue
        Import-Module DnsClient -Verbose:$false -ErrorAction SilentlyContinue

        $_ClusterName = $this.ClusterName
        if ($this.TryClusterAccess($_ClusterName)) {
            Write-Verbose "Cluster '$_ClusterName' is accessible by name."
            return $true
        }
        Write-Verbose "Cluster '$_ClusterName' is not accessible by name ($($this.LastError)) -- will attempt DNS repair."
        return $false
    }

    [WaitForClusterAccess] Get() {
        return $this
    }
}

# JoinClusterByIP works around a Windows Failover Cluster API limitation:
# OpenCluster("ClusterName") fails on non-member nodes where ClusSvc is not
# running, even when DNS, SPNs, and the Cluster Name resource are all healthy.
# The xCluster DSC resource uses name-based cluster access in Test-TargetResource,
# which triggers a non-terminating error that causes the LCM to abort. This
# resource uses IP-based access (Get-Cluster -Name $IP / Add-ClusterNode -Cluster $IP)
# which bypasses the broken name resolution layer entirely.

# Impersonation helpers (matching FailoverClusterDsc pattern).
# LogonUser with LOGON32_LOGON_NEW_CREDENTIALS (type 9) creates a token that
# uses the supplied credentials for network access while keeping the local
# identity -- this solves the Kerberos double-hop without needing WinRM loopback.
function Get-ImpersonateLib {
    if ($script:ImpersonateLib) {
        return $script:ImpersonateLib
    }

    $sig = @'
[DllImport("advapi32.dll", SetLastError = true)]
public static extern bool LogonUser(string lpszUsername, string lpszDomain, string lpszPassword, int dwLogonType, int dwLogonProvider, ref IntPtr phToken);

[DllImport("kernel32.dll")]
public static extern Boolean CloseHandle(IntPtr hObject);
'@

    $script:ImpersonateLib = Add-Type -PassThru -Namespace 'Lib.Impersonation' -Name ImpersonationLib -MemberDefinition $sig
    return $script:ImpersonateLib
}

function Set-ImpersonateAs {
    param (
        [Parameter(Mandatory)]
        [PSCredential] $Credential
    )

    [IntPtr] $userToken = [Security.Principal.WindowsIdentity]::GetCurrent().Token
    $ImpersonateLib = Get-ImpersonateLib

    $bLogin = $ImpersonateLib::LogonUser(
        $Credential.GetNetworkCredential().UserName,
        $Credential.GetNetworkCredential().Domain,
        $Credential.GetNetworkCredential().Password,
        9,  # LOGON32_LOGON_NEW_CREDENTIALS
        0,  # LOGON32_PROVIDER_DEFAULT
        [ref]$userToken
    )

    if ($bLogin) {
        $Identity = New-Object Security.Principal.WindowsIdentity $userToken
        $context = $Identity.Impersonate()
    }
    else {
        throw "Unable to impersonate user '$($Credential.GetNetworkCredential().UserName)'"
    }

    return $context, $userToken
}

function Close-UserToken {
    param (
        [Parameter(Mandatory)]
        [IntPtr] $Token
    )

    $ImpersonateLib = Get-ImpersonateLib
    $ImpersonateLib::CloseHandle($Token) | Out-Null
}

[DscResource()]
class JoinClusterByIP {
    [DscProperty(Key)]
    [string] $ClusterName

    [DscProperty(Mandatory)]
    [string] $ClusterIPAddress

    [DscProperty()]
    [string] $Role = 'Join'  # 'Create' for Node1, 'Join' for Node2

    [DscProperty()]
    [PSCredential] $DomainAdministratorCredential

    hidden [string] StripCidr([string] $ip) {
        if ($ip -match '^([^/]+)/') { return $Matches[1] }
        return $ip
    }

    [void] Set() {
        $_ClusterIP = $this.StripCidr($this.ClusterIPAddress)
        $_NodeName = $env:COMPUTERNAME
        $_ClusterName = $this.ClusterName
        $_Credential = $this.DomainAdministratorCredential
        $_Role = $this.Role

        $impersonationContext = $null
        $newToken = [IntPtr]::Zero

        try {
            if ($_Credential) {
                Write-Status "Impersonating '$($_Credential.GetNetworkCredential().UserName)' for cluster access"
                ($impersonationContext, $newToken) = Set-ImpersonateAs -Credential $_Credential
            }

            if ($_Role -eq 'Create') {
                # Preflight: the static cluster IP must sit on a local NIC that owns
                # that subnet. WSFC only assigns the ClusterAndClient role to a
                # gateway-bearing network, so a cluster IP that matches no local NIC
                # (e.g. allocated from the wrong subnet on a multi-network lab) fails
                # New-Cluster with the opaque "no appropriate ClusterAndClient network
                # was found to host it" and then retries for 30+ min before the
                # orchestrator force-restarts the VM. Fail FAST here with an actionable
                # message naming the bad IP, the node's actual NICs, and the expected
                # subnet -- but only when the cluster doesn't already exist (rerun).
                $_localCluster = Get-Cluster -ErrorAction SilentlyContinue -Verbose:$false
                if (-not ($_localCluster -and $_localCluster.Name -eq $_ClusterName)) {
                    $_clusterPrefix = ($_ClusterIP.Split('.')[0..2] -join '.') + '.'
                    $_localV4 = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                        Where-Object { $_.IPAddress -notlike '169.254.*' -and $_.IPAddress -ne '127.0.0.1' })
                    $_hostingNic = $_localV4 | Where-Object { $_.IPAddress -like "$_clusterPrefix*" } | Select-Object -First 1
                    if (-not $_hostingNic) {
                        $_have = (($_localV4 | ForEach-Object { $_.IPAddress }) | Sort-Object -Unique) -join ', '
                        throw "JoinClusterByIP preflight FAILED: cluster IP '$_ClusterIP' is not on any local subnet of '$_NodeName' (node IPv4: [$_have]). The cluster/AG IP must live on this node's own domain subnet ($_clusterPrefix*). This is a config/IP-allocation error -- New-Cluster would fail with 'no appropriate ClusterAndClient network was found to host it'. Remove + re-add this SQLAO node (or correct its ClusterIPAddress/AGIPAddress) so the IP is allocated from the node's network."
                    }
                    $_gw = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -InterfaceIndex $_hostingNic.InterfaceIndex -ErrorAction SilentlyContinue
                    if (-not $_gw) {
                        Write-Status "WARNING: NIC hosting $_clusterPrefix* (ifIndex $($_hostingNic.InterfaceIndex), IP $($_hostingNic.IPAddress)) has no default gateway; WSFC may classify it Cluster-only and reject the cluster IP. Proceeding -- New-Cluster will report the authoritative result."
                    }
                }
                Write-Status "Creating cluster '$_ClusterName' on '$_NodeName' with IP $_ClusterIP"
                try {
                    New-Cluster -Name $_ClusterName -Node $_NodeName -StaticAddress $_ClusterIP -NoStorage -Force -ErrorAction Stop -WarningAction SilentlyContinue -Verbose:$false
                }
                catch {
                    # If the node is already in the target cluster (re-run), treat as success
                    $localCluster = Get-Cluster -ErrorAction SilentlyContinue -Verbose:$false
                    if ($localCluster -and $localCluster.Name -eq $_ClusterName) {
                        Write-Status "Node '$_NodeName' is already in cluster '$_ClusterName'"
                    }
                    else {
                        throw
                    }
                }
                Write-Status "Successfully created cluster '$_ClusterName'"
            }
            else {
                # Check for existing node in Down state -- must remove before re-adding
                try {
                    $existingNode = Get-ClusterNode -Cluster $_ClusterIP -Name $_NodeName -ErrorAction SilentlyContinue -Verbose:$false
                    if ($existingNode -and $existingNode.State -eq 'Down') {
                        Write-Status "Node '$_NodeName' is in Down state in cluster '$_ClusterName' -- removing before re-add"
                        Remove-ClusterNode -Name $_NodeName -Cluster $_ClusterIP -Force -ErrorAction Stop -Verbose:$false
                        Write-Status "Removed downed node '$_NodeName' from cluster '$_ClusterName'"
                    }
                }
                catch {
                    Write-Status "Error checking/removing downed node: $_"
                }

                Write-Status "Joining node '$_NodeName' to cluster '$_ClusterName' via IP $_ClusterIP"
                Add-ClusterNode -Name $_NodeName -Cluster $_ClusterIP -NoStorage -ErrorAction Stop -Verbose:$false
                Write-Status "Successfully joined '$_NodeName' to cluster '$_ClusterName'"
            }
        }
        catch {
            $action = if ($_Role -eq 'Create') { 'New-Cluster' } else { 'Add-ClusterNode' }
            Write-Status "$action failed: $_"
            throw
        }
        finally {
            if ($impersonationContext) {
                $impersonationContext.Undo()
                $impersonationContext.Dispose()
                Close-UserToken -Token $newToken
            }
        }
    }

    [bool] Test() {
        $_ClusterIP = $this.StripCidr($this.ClusterIPAddress)
        $_NodeName = $env:COMPUTERNAME
        $_ClusterName = $this.ClusterName
        $_Credential = $this.DomainAdministratorCredential

        $impersonationContext = $null
        $newToken = [IntPtr]::Zero

        try {
            if ($_Credential) {
                ($impersonationContext, $newToken) = Set-ImpersonateAs -Credential $_Credential
            }

            $node = Get-ClusterNode -Cluster $_ClusterIP -Name $_NodeName -ErrorAction SilentlyContinue -Verbose:$false
            if ($node) {
                if ($node.State -eq 'Up' -or $node.State -eq 'Paused') {
                    Write-Verbose "Node '$_NodeName' is a member of cluster '$_ClusterName' (State: $($node.State))"
                    return $true
                }
                # Down state -- return $false so Set can remove and re-add
                Write-Verbose "Node '$_NodeName' is a member of cluster '$_ClusterName' but state is '$($node.State)' -- will remove and re-add"
                return $false
            }
        }
        catch {
            Write-Verbose "Could not query cluster membership via IP $_ClusterIP`: $_"
        }
        finally {
            if ($impersonationContext) {
                $impersonationContext.Undo()
                $impersonationContext.Dispose()
                Close-UserToken -Token $newToken
            }
        }

        # Fallback: if IP-based query failed or timed out, check local cluster membership
        try {
            $localCluster = Get-Cluster -ErrorAction SilentlyContinue -Verbose:$false
            if ($localCluster -and $localCluster.Name -eq $_ClusterName) {
                $localNode = Get-ClusterNode -Name $_NodeName -ErrorAction SilentlyContinue -Verbose:$false
                if ($localNode -and ($localNode.State -eq 'Up' -or $localNode.State -eq 'Paused')) {
                    Write-Verbose "Node '$_NodeName' confirmed in cluster '$_ClusterName' via local query (IP-based query failed)"
                    return $true
                }
            }
        }
        catch { }

        Write-Verbose "Node '$_NodeName' is not a member of cluster '$_ClusterName'"
        return $false
    }

    [JoinClusterByIP] Get() {
        return $this
    }
}

[DscResource()]
class ClusterRemoveUnwantedIPs {
    [DscProperty(Key)]
    [string] $ClusterName

    [DscProperty()]
    [string] $ClusterIPAddress

    hidden [string] StripCidr([string] $ip) {
        if ($ip -match '^([^/]+)/') { return $Matches[1] }
        return $ip
    }

    [void] Set() {
        try {
            $_ClusterName = $this.ClusterName
            $_KeepIP = if ($this.ClusterIPAddress) { $this.StripCidr($this.ClusterIPAddress) } else { $null }
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
            # Only clean IPs from the "Cluster Group" (the cluster's own identity).
            # Do NOT touch IP resources in AG listener groups -- those belong to
            # the availability group and use domain-subnet IPs by design.
            $clusterGroupResources = $Cluster | Where-Object { $_.OwnerGroup.Name -eq 'Cluster Group' }
            $ipParams = $clusterGroupResources | Where-Object { $_.ResourceType -eq "IP Address" } | Get-ClusterParameter -Name "Address" | Select-Object ClusterObject, Value
            if ($_KeepIP) {
                $ResourcesToRemove = ($ipParams | Where-Object { $_.Value -ne $_KeepIP }).ClusterObject
            }
            else {
                # Legacy fallback: keep heartbeat-subnet IPs (both old and new subnets)
                $ResourcesToRemove = ($ipParams | Where-Object { $_.Value -notlike "10.250.250.*" -and $_.Value -notlike "10.250.251.*" }).ClusterObject
            }
            if ($ResourcesToRemove) {
                foreach ($Resource in $ResourcesToRemove) {
                    Write-Status "Cluster Removing $($resource.Name)"
                    Remove-ClusterResource -Name $resource.Name -Force
                }
                # Let the cluster settle after IP removal before re-registering DNS
                Start-Sleep -Seconds 10
            }

            # Verify the intended IP resource still exists.  A previous version
            # of this code removed ALL domain-subnet IPs, including the one the
            # cluster needs.  Recreate it if missing.
            if ($_KeepIP) {
                $currentClusterRes = Get-ClusterResource -Cluster $_ClusterName -ErrorAction SilentlyContinue |
                    Where-Object { $_.OwnerGroup.Name -eq 'Cluster Group' -and $_.ResourceType -eq 'IP Address' }
                $remainingIPs = $currentClusterRes |
                    Get-ClusterParameter -Name 'Address' -ErrorAction SilentlyContinue
                $hasIntendedIP = $remainingIPs | Where-Object { $_.Value -eq $_KeepIP }
                if (-not $hasIntendedIP) {
                    Write-Status "Cluster IP resource for $_KeepIP is missing. Recreating..."
                    try {
                        # Find the cluster network for this IP's subnet
                        $ipBytes = $_KeepIP.Split('.')
                        $subnetPrefix = "$($ipBytes[0]).$($ipBytes[1]).$($ipBytes[2])."
                        $clusterNetwork = Get-ClusterNetwork -ErrorAction Stop |
                            Where-Object { $_.Address -and "$($_.Address)".StartsWith($subnetPrefix) } |
                            Select-Object -First 1

                        $resName = "Cluster IP Address"
                        # Avoid name collision with existing resources
                        $existing = Get-ClusterResource -Name $resName -ErrorAction SilentlyContinue
                        if ($existing) { $resName = "Cluster IP Address ($_KeepIP)" }

                        $newIP = Add-ClusterResource -Name $resName -Group "Cluster Group" -ResourceType "IP Address" -ErrorAction Stop
                        $setParams = @{ Address = $_KeepIP; SubnetMask = "255.255.255.0" }
                        if ($clusterNetwork) {
                            $setParams['Network'] = $clusterNetwork.Name
                        }
                        $newIP | Set-ClusterParameter -Multiple $setParams -ErrorAction Stop

                        # Cluster Name must depend on this IP
                        $nameRes = Get-ClusterResource -Name "Cluster Name" -ErrorAction SilentlyContinue
                        if ($nameRes) {
                            Add-ClusterResourceDependency -Resource "Cluster Name" -Provider $resName -ErrorAction SilentlyContinue
                        }

                        Start-ClusterResource -Name $resName -ErrorAction SilentlyContinue
                        Start-Sleep -Seconds 5
                        # Try to bring the Cluster Name online now that it has an IP
                        if ($nameRes -and $nameRes.State -ne 'Online') {
                            Start-ClusterResource -Name "Cluster Name" -ErrorAction SilentlyContinue
                        }
                        Write-Status "Cluster IP resource $_KeepIP recreated"
                    }
                    catch {
                        Write-Status "Failed to recreate Cluster IP resource: $_"
                    }
                }
            }
            Write-Status "Cluster Registering new DNS records"
            $dnsRegistered = $false
            for ($dnsAttempt = 1; $dnsAttempt -le 3; $dnsAttempt++) {
                try {
                    Get-ClusterResource -Name "Cluster Name" | Update-ClusterNetworkNameResource -ErrorAction Stop
                    $dnsRegistered = $true
                    break
                }
                catch {
                    Write-Verbose "DNS registration attempt $dnsAttempt/3 failed: $_"
                    if ($dnsAttempt -lt 3) { Start-Sleep -Seconds 15 }
                }
            }
            if (-not $dnsRegistered) {
                Write-Verbose "DNS registration failed after 3 attempts. Cluster may re-register on next consistency check."
            }
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
            $_KeepIP = if ($this.ClusterIPAddress) { $this.StripCidr($this.ClusterIPAddress) } else { $null }
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
            $clusterGroupResources = $Cluster | Where-Object { $_.OwnerGroup.Name -eq 'Cluster Group' }
            $ipParams = $clusterGroupResources | Where-Object { $_.ResourceType -eq "IP Address" } | Get-ClusterParameter -Name "Address" | Select-Object ClusterObject, Value
            if ($_KeepIP) {
                $ResourcesToRemove = ($ipParams | Where-Object { $_.Value -ne $_KeepIP }).ClusterObject
            }
            else {
                $ResourcesToRemove = ($ipParams | Where-Object { $_.Value -notlike "10.250.250.*" -and $_.Value -notlike "10.250.251.*" }).ClusterObject
            }

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


function Test-ModuleAvailable {
    # Quick, network-free "is this module installed and usable?" check. Reads the
    # module manifest via Get-Module -ListAvailable (no PowerShellGet dependency,
    # no PSGallery round-trip) and confirms the module payload is actually on
    # disk, so a half-copied/partial module folder doesn't read as a good install.
    # Returns $true/$false, never throws.
    #
    # This must NEVER call Import-Module. -ListAvailable reports ExportedCommands
    # as EMPTY for any manifest that exports via wildcards -- which SqlServer does
    # -- so an Import-Module fallback here is not the rare path, it is the normal
    # one for exactly the biggest module we check. Measured 2026-08-09: importing
    # SqlServer (loads SMO) took 274s, and because ModuleAdd.Test() calls this on
    # BOTH the marker fast path and the on-disk path, every Phase 4/5/7 re-run paid
    # it while reporting InDesiredState=True -- ~4.5 minutes to decide there was
    # nothing to do.
    param([Parameter(Mandatory)][string] $Name)

    $savedVP = $global:VerbosePreference; $global:VerbosePreference = 'SilentlyContinue'
    try {
        $m = Get-Module -ListAvailable -Name $Name -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $m) { return $false }
        if ($m.ExportedCommands -and $m.ExportedCommands.Count -gt 0) { return $true }

        # Lazy/wildcard exports: prove the implementation exists on disk instead.
        $base = $m.ModuleBase
        if (-not $base -or -not (Test-Path -LiteralPath $base)) { return $false }
        if ($m.RootModule) {
            $root = Join-Path $base $m.RootModule
            if (Test-Path -LiteralPath $root) { return $true }
        }
        # Depth-bounded so a large module tree cannot turn this back into a slow call.
        # Filter on Extension, NOT -Include: with -LiteralPath, -Include does not filter
        # and the manifest itself matches, so a manifest-only (half-copied) folder would
        # read as a good install.
        $impl = Get-ChildItem -LiteralPath $base -Recurse -Depth 2 -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -eq '.psm1' -or $_.Extension -eq '.dll' } |
            Select-Object -First 1
        return [bool]$impl
    }
    catch { return $false }
    finally { $global:VerbosePreference = $savedVP }
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

        # Pre-import package modules quietly to prevent DSC verbose log
        # flooding with hundreds of "Importing cmdlet ..." lines.
        $savedVP = $global:VerbosePreference; $global:VerbosePreference = 'SilentlyContinue'
        try { Import-Module PackageManagement, PowerShellGet -ErrorAction SilentlyContinue }
        finally { $global:VerbosePreference = $savedVP }

        $Nuget = $null
        try {
            $NuGet = Get-PackageProvider -Name Nuget -ErrorAction SilentlyContinue -WarningAction SilentlyContinue -ListAvailable
        }
        catch { }

        # Suppress verbose for all Install-Module / Install-PackageProvider
        # calls. These internally import PackageManagement and PowerShellGet
        # which floods the DSC log with hundreds of "Exporting function ..."
        # and "Importing cmdlet ..." lines.
        $savedVP = $global:VerbosePreference; $global:VerbosePreference = 'SilentlyContinue'
        try {
        
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
                $global:VerbosePreference = $savedVP
                Write-Verbose "$_"
                $global:VerbosePreference = 'SilentlyContinue'
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
                    write-Status "Installing powershell module $_moduleName for scope $_userScope."
                    Install-Module -Name $_moduleName -Force -Confirm:$false -Scope $_userScope -AllowClobber -ErrorAction Stop
                }
                catch {
                    $global:VerbosePreference = $savedVP
                    Write-Verbose "$_"
                    $global:VerbosePreference = 'SilentlyContinue'
                    write-Status "Retry. Installing powershell module $_moduleName for scope $_userScope.."
                    Clear-DnsClientCache -ErrorAction SilentlyContinue
                    Start-Sleep -Seconds 20
                    Install-Module -Name $_moduleName -Force -Confirm:$false -Scope $_userScope -AllowClobber -SkipPublisherCheck -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
                }
            }
            else {
                try {
                    write-Status "Installing powershell module $_moduleName for scope $_userScope..."
                    Install-Module -Name $_moduleName -Force -Confirm:$false -Scope $_userScope -ErrorAction Stop
                }
                catch {
                    $global:VerbosePreference = $savedVP
                    Write-Verbose "$_"
                    $global:VerbosePreference = 'SilentlyContinue'
                    write-Status "Retry. Installing powershell module $_moduleName for scope $_userScope...."
                    Clear-DnsClientCache -ErrorAction SilentlyContinue
                    Start-Sleep -Seconds 20
                    Install-Module -Name $_moduleName -Force -Confirm:$false -Scope $_userScope -SkipPublisherCheck -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
                }
            }
        }

        } finally { $global:VerbosePreference = $savedVP }

        # Verify the module is actually usable now and stamp a marker so future
        # Test() calls (a phase re-run, or Phase 4/5/7 which each ModuleAdd
        # SqlServer) short-circuit instead of paying the PSGallery bootstrap
        # again (~230s just for the NuGet+PowerShellGet bootstrap on a cold VM).
        if (Test-ModuleAvailable -Name $_moduleName) {
            New-Item -ItemType File -Path (Join-Path 'C:\staging\DSC' ("ModuleAdd.$_moduleName.ok")) -Force -ErrorAction SilentlyContinue | Out-Null
            Write-Status "$_moduleName module verified available."
        }
        else {
            Write-Status "WARNING: $_moduleName install completed but the module is not detected as available."
        }
    }

    [bool] Test() {

        $_ModuleName = $this.CheckModuleName
        write-verbose ('Searching for module:' + $_ModuleName)

        # Fast path: a previously-verified install drops a marker file. When the
        # marker is present AND the module is still importable on disk, skip the
        # whole Get-InstalledModule / PSGallery bootstrap in Set().
        $marker = Join-Path 'C:\staging\DSC' ("ModuleAdd.$_ModuleName.ok")
        if (Test-Path $marker) {
            if (Test-ModuleAvailable -Name $_ModuleName) {
                write-verbose ("$_ModuleName marker present and module still available; skipping install.")
                return $true
            }
            # Marker is stale (module went missing) -- drop it and reinstall.
            Remove-Item $marker -Force -ErrorAction SilentlyContinue
        }

        # A module already present on disk satisfies us regardless of HOW it got
        # there (base-image pre-stage, Save-Module, or a prior Install-Module).
        # Get-Module -ListAvailable is faster than Get-InstalledModule, needs no
        # PowerShellGet, and -- unlike Get-InstalledModule -- also sees modules
        # that weren't registered through PowerShellGet.
        if (Test-ModuleAvailable -Name $_ModuleName) {
            New-Item -ItemType File -Path $marker -Force -ErrorAction SilentlyContinue | Out-Null
            write-verbose ("Found module on disk: $_ModuleName")
            return $true
        }

        # Legacy fallback: honor a PowerShellGet-registered install even if the
        # quick manifest check above didn't see exposed commands.
        $GetModuleStatus = $null
        $savedVP = $global:VerbosePreference; $global:VerbosePreference = 'SilentlyContinue'
        try { $GetModuleStatus = Get-InstalledModule -Name $_ModuleName -ErrorAction SilentlyContinue -WarningAction SilentlyContinue }
        finally { $global:VerbosePreference = $savedVP }

        if ($GetModuleStatus) {
            write-verbose ('Found module:' + $_ModuleName + 'ModuleStatus:' + $GetModuleStatus.Version)
            New-Item -ItemType File -Path $marker -Force -ErrorAction SilentlyContinue | Out-Null
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
        
        $savedVP = $global:VerbosePreference; $global:VerbosePreference = 'SilentlyContinue'
        try { Import-Module WebAdministration -ErrorAction SilentlyContinue }
        finally { $global:VerbosePreference = $savedVP }
        
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

        # --- Preflight: ensure the IIS 6 metabase (IISADMIN) is usable before postinstall ---
        # WSUS postinstall's ConfigureWebsite step creates the WSUS Administration site by
        # binding the IIS 6 metabase via ADSI (IIS://localhost/...), which is served by the
        # IISADMIN service. On rare VMs the metabase's encrypted session key is orphaned
        # (the base-image metabase was encrypted with machine keys that got regenerated at
        # deploy) and IISADMIN will not start -- service exit 0x80090006 "Invalid Signature".
        # ConfigureWebsite then fails with COM 0x80080005 and the phase used to loop its
        # entire ~5h budget re-probing a dead metabase. Detect that here and repair it
        # (reinstall IIS 6 Metabase Compatibility) BEFORE postinstall. Returns $false when a
        # reboot was requested for the repair -- return and let the phase resume after reboot.
        if (-not $this.EnsureIisMetabaseHealthy()) {
            return
        }

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

                # WID only: grant the lab admin sysadmin so SSMS can connect to
                # WID without elevation (WID trusts only BUILTIN\Administrators,
                # which UAC token filtering strips from a normal logon).
                $this.GrantWidSysadmin()
            }
            Write-Verbose "WSUS postinstall output: $postinstallOutput"
        }
        catch {
            Write-Status "Failed to Configure WSUS"
            Write-Verbose "$_ $postinstallOutput"
        }
        
        try {
            $null = get-WsusServer
        }
        catch {
            Write-Status "Failed to Configure WSUS. Could not locate WSUS Server after postinstall"
            Write-Verbose "$_"
            throw
        }

        if ($this.HTTPSUrl) {
            Write-Status "Configuring HTTPS for WSUS"
            $enrollError = ""
            $cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.FriendlyName -eq $_FriendlyName } | Select-Object -Last 1
            if (-not $cert) {
                # The friendly-named WebServer cert is missing. This happens when
                # Phase 3 CertReq's subject-only Test skipped stamping it (a
                # subject-colliding cert already existed at enrollment time),
                # leaving a CA-issued ServerAuth template cert for this host with
                # no/other FriendlyName. Recover it by re-stamping the name
                # instead of failing the whole phase (mirrors AddCertificateToIIS).
                # Filter to a CA-issued (Issuer != Subject) cert from an AD
                # template (has the V2 template extension) with ServerAuth EKU and
                # this host's FQDN in the subject -- that excludes SQL's
                # self-signed CN=FQDN ServerAuth cert.
                $fqdn = "$env:COMPUTERNAME.$env:USERDNSDOMAIN"
                $srvAuthOid = '1.3.6.1.5.5.7.3.1'
                $candidate = Get-ChildItem Cert:\LocalMachine\My | Where-Object {
                    ($_.EnhancedKeyUsageList.ObjectId -contains $srvAuthOid) -and
                    ($_.Subject -match [regex]::Escape($fqdn)) -and
                    ($_.Issuer -ne $_.Subject) -and
                    ($_.Extensions.Oid.Value -contains '1.3.6.1.4.1.311.21.7')
                } | Sort-Object NotBefore -Descending | Select-Object -First 1
                if ($candidate) {
                    try {
                        $store = New-Object System.Security.Cryptography.X509Certificates.X509Store('My', 'LocalMachine')
                        $store.Open('ReadWrite')
                        $live = $store.Certificates | Where-Object { $_.Thumbprint -eq $candidate.Thumbprint } | Select-Object -First 1
                        if ($live) { $live.FriendlyName = $_FriendlyName }
                        $store.Close()
                        Write-Status "Recovered CA-issued ServerAuth cert (thumbprint $($candidate.Thumbprint.Substring(0,8))...) that had lost FriendlyName '$_FriendlyName'; re-applied name"
                    }
                    catch {
                        Write-Status "Failed to re-apply FriendlyName to recovered cert: $_"
                    }
                    $cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.FriendlyName -eq $_FriendlyName } | Select-Object -Last 1
                }
            }
            if (-not $cert) {
                # Still no cert to re-stamp -- it was never enrolled. The WebServer
                # cert is enrolled by CertReq PkiWebCert in PHASE 8, but ConfigureWSUS
                # runs in PHASE 6, two phases earlier, so on a clean deploy the cert
                # genuinely does not exist yet. The CA is available by Phase 6 and this
                # machine is in the 'ConfigMgr IIS Servers' AD group (Enroll granted),
                # so enroll it here (same template/subject/SAN as CertReq PkiWebCert)
                # instead of looping until the phase times out.
                $fqdn = "$env:COMPUTERNAME.$env:USERDNSDOMAIN"
                Write-Status "WebServer cert '$_FriendlyName' not present; enrolling ConfigMgrWebServerCertificate for $fqdn"
                try {
                    # Enroll rights on ConfigMgrWebServerCertificate come from the 'ConfigMgr IIS
                    # Servers' AD group the DC put this computer in during Phase 2. Unlike Phase 8,
                    # Phase 6 has no guaranteed reboot after that, so the machine's cached TGT can
                    # still lack the group SID and the CA denies the request. Purge the SYSTEM LUID
                    # (0x3e7) ticket cache first (mirrors Phase 8 PkiRefreshGroupToken).
                    try { gpupdate.exe /target:computer /force 2>&1 | Out-Null } catch {}
                    try { klist.exe -li 0x3e7 purge 2>&1 | Out-Null } catch {}
                    # Trigger autoenrollment + drop the template-cache timestamp so the
                    # template resolves (mirrors Phase 8 PkiRefreshTemplateCache).
                    try { certutil.exe -pulse 2>&1 | Out-Null } catch {}
                    foreach ($hive in @('HKLM', 'HKCU')) {
                        Remove-ItemProperty -Path "${hive}:\SOFTWARE\Microsoft\Cryptography\CertificateTemplateCache" -Name 'Timestamp' -Force -ErrorAction SilentlyContinue
                    }
                    $enrolled = Get-Certificate -Template 'ConfigMgrWebServerCertificate' -SubjectName "CN=$fqdn" `
                        -DnsName $fqdn, $env:COMPUTERNAME -CertStoreLocation Cert:\LocalMachine\My -ErrorAction Stop
                    $newCert = if ($enrolled -and $enrolled.Certificate) { $enrolled.Certificate } else { $null }
                    if ($newCert) {
                        $store = New-Object System.Security.Cryptography.X509Certificates.X509Store('My', 'LocalMachine')
                        $store.Open('ReadWrite')
                        $live = $store.Certificates | Where-Object { $_.Thumbprint -eq $newCert.Thumbprint } | Select-Object -First 1
                        if ($live) { $live.FriendlyName = $_FriendlyName }
                        $store.Close()
                        Write-Status "Enrolled ConfigMgr WebServer Certificate (thumbprint $($newCert.Thumbprint.Substring(0,8))...) and stamped FriendlyName '$_FriendlyName'"
                    }
                    $cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.FriendlyName -eq $_FriendlyName } | Select-Object -Last 1
                }
                catch {
                    $enrollError = "$_"
                    Write-Status "Failed to enroll WebServer cert (template ConfigMgrWebServerCertificate): $_"
                }
            }
            if (-not $cert) {
                # Every resume re-runs Set() from the top and dies here again, so the status
                # text is all the operator gets -- carry the enrollment error in it.
                $why = if ($enrollError) { " Enrollment failed: $enrollError" } else { "" }
                Write-Status "Could not find cert with friendly Name $_FriendlyName.$why"
                throw "Could not find cert with friendly Name $_FriendlyName.$why"
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

        # Harden the WsusPool IIS app pool so it survives the first full
        # Microsoft Update sync. Runs regardless of HTTP/HTTPS.
        $this.HardenWsusPool()
    }

    # WID grants sysadmin only to BUILTIN\Administrators, which UAC token
    # filtering strips from a normal (non-elevated) logon -- so connecting to
    # WID in SSMS otherwise needs "Run as administrator". Add the lab domain
    # admin as an explicit sysadmin login here (this runs as SYSTEM, which is
    # sysadmin on WID) so a normal SSMS session connects directly. WID's named
    # pipe is local-only, so this only matters on the WID host itself.
    # Idempotent -- safe to re-run.
    [void] GrantWidSysadmin() {
        try {
            $deployPath = 'C:\staging\DSC\deployConfig.json'
            if (-not (Test-Path $deployPath)) {
                Write-Verbose "GrantWidSysadmin: $deployPath not found, skipping"
                return
            }
            $dc = Get-Content $deployPath -Raw | ConvertFrom-Json
            $netbios = $dc.vmOptions.domainNetBiosName
            $admin = $dc.vmOptions.adminName
            if (-not $netbios -or -not $admin) {
                Write-Verbose "GrantWidSysadmin: admin/domain missing in deployConfig, skipping"
                return
            }
            $login = "$netbios\$admin"
            $tsql = "IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'$login') CREATE LOGIN [$login] FROM WINDOWS; IF IS_SRVROLEMEMBER('sysadmin', N'$login') <> 1 ALTER SERVER ROLE sysadmin ADD MEMBER [$login];"

            $conn = New-Object System.Data.SqlClient.SqlConnection
            $conn.ConnectionString = "Data Source=np:\\.\pipe\MICROSOFT##WID\tsql\query;Initial Catalog=master;Integrated Security=True;Connect Timeout=30"
            $opened = $false
            for ($i = 1; $i -le 5 -and -not $opened; $i++) {
                try { $conn.Open(); $opened = $true }
                catch { Start-Sleep -Seconds 5 }
            }
            if (-not $opened) {
                Write-Status "GrantWidSysadmin: could not connect to WID pipe after retries (non-fatal)"
                return
            }
            try {
                Write-Status "Granting WID sysadmin to $login"
                $cmd = $conn.CreateCommand()
                $cmd.CommandText = $tsql
                [void]$cmd.ExecuteNonQuery()
                Write-Status "WID sysadmin grant for $login completed"
            }
            finally {
                $conn.Close()
            }
        }
        catch {
            Write-Status "GrantWidSysadmin failed (non-fatal): $_"
            Write-Verbose "$_"
        }
    }

    # The first full Microsoft Update sync pulls the entire modern category
    # taxonomy in a single ServerSync call. With the default WsusPool recycle
    # cap (~1.8 GB private memory) and queueLength (1000), IIS recycles the pool
    # mid-sync; the in-flight ServerSync/GetSubscriptionState dies with HTTP 503,
    # the sync never reaches state 6702, and the catalog stays empty
    # (GetStatus().UpdateCount = 0). Sync 1 then re-runs forever. Uncapping
    # memory + raising the queue + disabling periodic/request recycles lets the
    # pool survive the first big sync. Idempotent — safe to re-run.
    [void] HardenWsusPool() {
        Write-Status "Hardening WsusPool app pool to survive first full WSUS sync"
        $savedVP = $global:VerbosePreference
        $global:VerbosePreference = 'SilentlyContinue'
        try {
            Import-Module WebAdministration -ErrorAction Stop
        }
        catch {
            Write-Status "WsusPool hardening skipped — WebAdministration unavailable: $_"
            $global:VerbosePreference = $savedVP
            return
        }
        $global:VerbosePreference = $savedVP

        $poolPath = 'IIS:\AppPools\WsusPool'
        if (-not (Test-Path $poolPath)) {
            Write-Status "WsusPool not found at $poolPath — skipping hardening"
            return
        }

        $settings = @(
            @{ Name = 'recycling.periodicRestart.privateMemory'; Value = 0 }
            @{ Name = 'recycling.periodicRestart.requests'; Value = 0 }
            @{ Name = 'recycling.periodicRestart.time'; Value = [TimeSpan]::Zero }
            @{ Name = 'queueLength'; Value = 25000 }
            @{ Name = 'processModel.idleTimeout'; Value = [TimeSpan]::Zero }
            @{ Name = 'startMode'; Value = 'AlwaysRunning' }
            @{ Name = 'failure.rapidFailProtection'; Value = $false }
        )
        foreach ($s in $settings) {
            try {
                Set-ItemProperty -Path $poolPath -Name $s.Name -Value $s.Value -ErrorAction Stop
                Write-Verbose "WsusPool $($s.Name) = $($s.Value)"
            }
            catch {
                Write-Status "WsusPool: failed to set $($s.Name): $_"
            }
        }

        try {
            Restart-WebAppPool -Name 'WsusPool' -ErrorAction Stop
            Write-Status "WsusPool hardened and restarted (privateMemory uncapped, queueLength=25000)"
        }
        catch {
            Write-Status "WsusPool: restart after hardening failed: $_"
        }
    }

    # Can the IISADMIN service (IIS 6 metabase compatibility) actually run? That is the
    # prerequisite for WSUS postinstall's ConfigureWebsite ADSI (IIS://) bind. Ensures the
    # service is Automatic + started; returns $true only when it reaches Running.
    hidden [bool] TestIisAdminHealthy() {
        $svc = Get-Service -Name 'IISADMIN' -ErrorAction SilentlyContinue
        if (-not $svc) { return $false }
        if ($svc.StartType -eq 'Disabled') { Set-Service -Name 'IISADMIN' -StartupType Automatic -ErrorAction SilentlyContinue }
        if ($svc.Status -ne 'Running') {
            try { Start-Service -Name 'IISADMIN' -ErrorAction Stop } catch { }
        }
        return ((Get-Service -Name 'IISADMIN' -ErrorAction SilentlyContinue).Status -eq 'Running')
    }

    # Ensure the IIS 6 metabase is usable before postinstall. If IISADMIN cannot start
    # (orphaned metabase encryption -> 0x80090006 Invalid Signature) the fix is to reinstall
    # the IIS-Metabase feature so a fresh metabase is generated + re-keyed to this VM's
    # current machine keys. That reinstall needs TWO sequenced reboots (a single-pass
    # disable+enable stages both to the same pending reboot and cancels out), so this is a
    # small marker-driven state machine that requests a reboot ($global:DSCMachineStatus=1)
    # between steps and is resumed by the phase framework. Bounded to a single repair cycle.
    # Returns:
    #   $true  -> metabase healthy (or nothing to repair) -- caller may proceed to postinstall
    #   $false -> a reboot was requested -- caller should return and resume after the reboot
    hidden [bool] EnsureIisMetabaseHealthy() {
        $stateFile = 'C:\staging\DSC\wsus-metabase-repair.state'
        try { $null = New-Item -ItemType Directory -Path (Split-Path $stateFile -Parent) -Force -ErrorAction SilentlyContinue } catch { }
        $step = ''
        if (Test-Path $stateFile) {
            $raw = Get-Content -Path $stateFile -Raw -ErrorAction SilentlyContinue
            if ($raw) { $step = $raw.Trim() }
        }

        if ([string]::IsNullOrEmpty($step)) {
            # Not repairing. If there is no IISADMIN service, this VM has no IIS 6 metabase
            # to gate -- let postinstall proceed (it will surface any real problem itself).
            if (-not (Get-Service -Name 'IISADMIN' -ErrorAction SilentlyContinue)) { return $true }
            if ($this.TestIisAdminHealthy()) { return $true }

            $code = (Get-CimInstance Win32_Service -Filter "Name='IISADMIN'" -ErrorAction SilentlyContinue).ExitCode
            Write-Status "IISADMIN (IIS 6 metabase) will not start (service ExitCode=$code) -- WSUS ConfigureWebsite would fail. Reinstalling IIS 6 Metabase Compatibility to rebuild a decryptable metabase (reboot 1 of 2)"
            foreach ($s in @('W3SVC', 'WAS', 'IISADMIN')) { try { Stop-Service -Name $s -Force -ErrorAction SilentlyContinue } catch { } }
            & dism.exe /online /disable-feature /featurename:IIS-Metabase /norestart 2>&1 | Out-Null
            Set-Content -Path $stateFile -Value 'disable-done' -Force
            $global:DSCMachineStatus = 1
            return $false
        }
        elseif ($step -eq 'disable-done') {
            Write-Status "Re-enabling IIS 6 Metabase Compatibility to generate a fresh, re-keyed metabase (reboot 2 of 2)"
            & dism.exe /online /enable-feature /featurename:IIS-Metabase /norestart 2>&1 | Out-Null
            Set-Content -Path $stateFile -Value 'enable-done' -Force
            $global:DSCMachineStatus = 1
            return $false
        }
        elseif ($step -eq 'enable-done') {
            if ($this.TestIisAdminHealthy()) {
                Write-Status "IIS 6 Metabase Compatibility reinstalled -- IISADMIN is Running; metabase repaired"
                Remove-Item -Path $stateFile -Force -ErrorAction SilentlyContinue
                return $true
            }
            $code = (Get-CimInstance Win32_Service -Filter "Name='IISADMIN'" -ErrorAction SilentlyContinue).ExitCode
            Set-Content -Path $stateFile -Value 'failed' -Force
            Write-Status "IIS 6 Metabase Compatibility reinstall did NOT fix IISADMIN (ExitCode=$code); WSUS cannot be configured on this VM"
            throw "IIS 6 Metabase Compatibility could not be repaired (IISADMIN start error $code -- orphaned IIS metabase encryption key). WSUS cannot be configured on this VM; rebuild the VM."
        }
        else {
            # 'failed' (or unknown): do not re-run the reboot cycle. Proceed only if healthy now.
            if ($this.TestIisAdminHealthy()) {
                Remove-Item -Path $stateFile -Force -ErrorAction SilentlyContinue
                return $true
            }
            throw "IIS 6 Metabase Compatibility repair already failed on this VM (IISADMIN 0x80090006, orphaned metabase encryption key). WSUS cannot be configured; rebuild the VM."
        }
    }

    [bool] Test() {

        try {
            $wsus = get-WsusServer
            if (-not $wsus) {
                return $false
            }

            # If HTTPS was requested, WSUS is NOT in desired state until the
            # friendly-named WebServer cert exists AND it's bound to the WSUS
            # Administration https:8531 binding. get-WsusServer succeeds as soon
            # as postinstall completes -- if Set() then threw at the HTTPS step
            # (e.g. the WebServer cert was missing), a plain get-WsusServer Test
            # would report InDesiredState=True and a resume would SKIP Set(),
            # silently leaving WSUS SSL unconfigured. Re-check the HTTPS bits so
            # a resume actually re-runs Set() (which now self-heals the cert).
            if ($this.HTTPSUrl) {
                $fn = $this.TemplateName
                $cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.FriendlyName -eq $fn } | Select-Object -Last 1
                if (-not $cert -or [string]::IsNullOrEmpty($cert.Thumbprint)) {
                    Write-Verbose "WSUS HTTPS requested but cert '$fn' is not present; Set() needs to run."
                    return $false
                }
                $savedVP = $global:VerbosePreference; $global:VerbosePreference = 'SilentlyContinue'
                try { Import-Module WebAdministration -ErrorAction SilentlyContinue } finally { $global:VerbosePreference = $savedVP }
                $binding = Get-WebBinding -Name "WSUS Administration" -Port 8531 -Protocol "https" -ErrorAction SilentlyContinue
                if (-not $binding -or [string]::IsNullOrEmpty($binding.certificateHash)) {
                    Write-Verbose "WSUS https:8531 binding is missing or has no cert; Set() needs to run."
                    return $false
                }
            }

            return $true
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
        # Pre-Phase-7 cab import has been moved out of this DSC resource
        # into InstallRoles.ps1 (Start-WsusBaselineImportBackground /
        # Wait-WsusBaselineImport in ScriptFunctions.ps1). DSC's "background
        # process + reboot between phases" model could not reliably tell a
        # completed `wsusutil import` from one killed mid-flight by a
        # post-phase reboot, leaving SUSDB with a partial taxonomy that the
        # next CM sync would trip over ("invalid update identity in XML").
        # InstallRoles owns launch + verify (exit code, log tail, post-count)
        # in a single script context so partial imports get retried instead
        # of silently shipped. See ScriptFunctions.ps1.
        #
        # If the cab is present we skip the MU fire-and-forget sync below --
        # InstallRoles will populate the taxonomy via cab import. If the cab
        # is absent (cab disabled, copy failed, no cab in the build) we
        # still kick off the MU sync here so categories are downloading in
        # the background through Phases 7-10 instead of stalling perfloading
        # for hours waiting on the first MU categories sync.
        $cabPath = 'C:\staging\wsus\WsusCategoriesBaseline.cab'
        if (Test-Path $cabPath) {
            Write-Status "WSUS categories baseline cab present at $cabPath. Skipping Phase 7 MU sync; InstallRoles will run wsusutil import."
            return
        }

        # No cab -- fall back to the early fire-and-forget MU sync to
        # pre-download the WSUS category catalog. This runs in Phase 7
        # (after any PBIRS install on the same VM has completed and
        # rebooted), ~3-4 hours before perfloading needs WSUS ready. By
        # syncing now (even with minimal products), the full category
        # taxonomy downloads in background. When perfloading runs its
        # product sync later, categories are already present and only
        # update metadata is needed.
        Write-Status "Starting early WSUS catalog sync for $($this.ServerName) (fire-and-forget, no cab available)"
        try {
            $WSUS = Get-WsusServer -Name $this.ServerName -PortNumber 8530
            if (-not $WSUS) {
                Write-Status "WSUS server not found at $($this.ServerName):8530. Skipping early sync."
                return
            }

            # Verify WsusPool is hardened (ConfigureWSUS should have done this, but verify)
            $savedVP = $global:VerbosePreference; $global:VerbosePreference = 'SilentlyContinue'
            try { Import-Module WebAdministration -ErrorAction SilentlyContinue } finally { $global:VerbosePreference = $savedVP }
            $pool = Get-ItemProperty -Path 'IIS:\AppPools\WsusPool' -Name recycling.periodicRestart.privateMemory -ErrorAction SilentlyContinue
            if ($pool -and $pool.Value -gt 0) {
                Write-Status "WsusPool privateMemory cap is $($pool.Value) - hardening before sync"
                Set-ItemProperty -Path 'IIS:\AppPools\WsusPool' -Name recycling.periodicRestart.privateMemory -Value 0 -ErrorAction SilentlyContinue
                Restart-WebAppPool -Name WsusPool -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 5
            }

            # Select minimal products/classifications to get the category catalog
            # without downloading massive update metadata. SQL Server 2005 + Tools
            # is small but forces the full category tree download.
            Write-Status "Configuring minimal sync scope (SQL Server 2005 + Tools)"
            Get-WsusProduct | Set-WsusProduct -Disable
            Get-WsusProduct | Where-Object { $_.Product.Title -eq "SQL Server 2005" } | Set-WsusProduct
            Get-WsusClassification | Set-WsusClassification -Disable
            Get-WsusClassification | Where-Object { $_.Classification.Title -eq "Tools" } | Set-WsusClassification

            # Start sync - fire and forget, don't wait
            $sub = $WSUS.GetSubscription()
            $sub.StartSynchronization()
            Write-Status "WSUS sync started. Will run in background during Phases 7-8 (~4 hours)."

            # Block until the sync has actually transitioned to Running before
            # returning. StartSynchronization() is async -- the WSUS service
            # picks up the request on a worker thread and flips the status
            # NotStarted -> Running within a few seconds. The orchestrator's
            # post-phase reboot check (Phase < 8) runs Test_PendingReboot,
            # which only sets DeferredFor when GetSynchronizationStatus()
            # returns 'Running'. If we return from Set() before the transition
            # is observable, the post-phase check can race in, see NotStarted,
            # find any pending reboot from PBIRS install aftermath, and
            # reboot the VM -- killing the sync we just kicked off.
            $deadline = (Get-Date).AddSeconds(30)
            $observedRunning = $false
            $lastStatus = $null
            while ((Get-Date) -lt $deadline) {
                try {
                    $lastStatus = $sub.GetSynchronizationStatus().ToString()
                    if ($lastStatus -eq 'Running') {
                        $observedRunning = $true
                        break
                    }
                } catch {}
                Start-Sleep -Seconds 1
            }
            if ($observedRunning) {
                Write-Status "WSUS sync confirmed Running. Safe to end Phase 7 DSC pass."
            } else {
                Write-Status "WSUS sync did not transition to Running within 30s (last status: $lastStatus). Post-phase reboot check may not defer; perfloading will retry sync later."
            }
        }
        catch {
            Write-Status "Early WSUS sync failed: $($_.Exception.Message). Perfloading will handle sync later."
        }
    }

    [bool] Test() {
        # Test if a sync is in progress or has completed (category catalog present)
        try {
            $wsus = Get-WsusServer -ErrorAction Stop
            $sub = $wsus.GetSubscription()
            
            # Check if sync is currently running (compare as string to avoid parse-time type load)
            $syncStatus = $sub.GetSynchronizationStatus()
            if ($syncStatus.ToString() -eq 'Running') {
                Write-Status "WSUS sync already in progress - skipping"
                return $true
            }
            
            # If we have categories, a sync has completed at some point
            $cats = $sub.GetUpdateCategories()
            if ($cats -and $cats.Count -gt 0) {
                Write-Status "WSUS catalog already has $($cats.Count) categories - skipping early sync"
                return $true
            }
            return $false
        }
        catch {
            Write-Status "WSUS not ready for sync test: $($_.Exception.Message)"
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
                # 3010 = ERROR_SUCCESS_REBOOT_REQUIRED -- install succeeded, reboot needed.
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
                    # installing anything. Retrying won't help -- need to reboot first.
                    if ($pbirsExit -eq 3010) {
                        Write-Status "PBIRS returned 3010 but SSRS folder missing -- pending reboot blocking install. Requesting reboot."
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
                    # Exit 87 (ERROR_INVALID_PARAMETER) is often transient -- file lock,
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
                        # futile -- the bootstrapper will return 3010 without doing real work.
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
                    # Don't throw -- let Set() exit normally so DSC processes the reboot
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
                $savedVP = $global:VerbosePreference; $global:VerbosePreference = 'SilentlyContinue'
                try { Import-Module PackageManagement -ErrorAction SilentlyContinue }
                finally { $global:VerbosePreference = $savedVP }
                Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
                Install-Module -Name ReportingServicesTools -Force -AllowClobber -Confirm:$false
            }
            catch {
                Write-Verbose ("InstallPBIRS $_")
            }


            # Pre-flight: if the ReportServer database already exists but is
            # corrupt (e.g. missing dbo.Subscriptions), Set-RsDatabase's upgrade
            # scripts will fail. Drop the corrupt DB so Set-RsDatabase creates a
            # clean one instead of trying to upgrade.
            try {
                $checkConn = New-Object System.Data.SqlClient.SqlConnection
                $checkConn.ConnectionString = "Server=$($this.SqlServer);Database=master;Integrated Security=True;TrustServerCertificate=True"
                $checkConn.Open()
                $checkCmd = $checkConn.CreateCommand()
                $checkCmd.CommandText = "SELECT DB_ID('ReportServer')"
                $dbExists = $checkCmd.ExecuteScalar()
                if ($null -ne $dbExists -and $dbExists -ne [DBNull]::Value) {
                    $checkCmd.CommandText = "SELECT OBJECT_ID('ReportServer.dbo.Subscriptions')"
                    $tblExists = $checkCmd.ExecuteScalar()
                    if ($null -eq $tblExists -or $tblExists -eq [DBNull]::Value) {
                        Write-Status "ReportServer database exists but is corrupt (dbo.Subscriptions missing). Dropping and re-creating."
                        Stop-Service -Name 'PowerBIReportServer' -Force -ErrorAction SilentlyContinue
                        Start-Sleep -Seconds 3
                        foreach ($dbName in 'ReportServerTempDB', 'ReportServer') {
                            $checkCmd.CommandText = "IF DB_ID('$dbName') IS NOT NULL BEGIN ALTER DATABASE [$dbName] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$dbName]; END"
                            $checkCmd.ExecuteNonQuery() | Out-Null
                            Write-Status "Dropped corrupt database $dbName"
                        }
                    }
                }
                $checkConn.Close()
            }
            catch {
                Write-Status "Warning: could not check ReportServer database health: $($_.Exception.Message)"
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


            # Restart the service so it picks up the (possibly new) database
            # before we configure URLs. Without this, Set-PbiRsUrlReservation
            # can fail with SetVirtualDirectory error -2147220930 when the DB
            # was just recreated.
            Write-Status "Restarting PowerBIReportServer before URL reservation"
            Restart-Service -Name "PowerBIReportServer" -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 5

            Write-Status ("Calling Set-PbiRsUrlReservation -ReportServerInstance $($this.RSInstance) -ReportServerVersion PowerBIReportServer")
            Set-PbiRsUrlReservation -ReportServerInstance $($this.RSInstance) -ReportServerVersion PowerBIReportServer


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
                    # The WebServer cert (CertReq PkiWebCert) is enrolled in PHASE 8, but
                    # PBIRS runs in PHASE 7 and needs it for the Report Server HTTPS SSL
                    # binding. When this VM also has installSUP, Phase 6 ConfigureWSUS
                    # already enrolled it; but an installRP-only VM never ran that, so the
                    # cert can be genuinely absent here. The CA is up and this machine is in
                    # the 'ConfigMgr IIS Servers' AD group (Enroll granted), so enroll it
                    # (same template/subject/SAN as CertReq PkiWebCert) instead of failing.
                    $_certFqdn = "$env:COMPUTERNAME.$env:USERDNSDOMAIN"
                    Write-Status "WebServer cert '$_FriendlyName' not present; enrolling ConfigMgrWebServerCertificate for $_certFqdn"
                    try {
                        try { certutil.exe -pulse 2>&1 | Out-Null } catch {}
                        foreach ($hive in @('HKLM', 'HKCU')) {
                            Remove-ItemProperty -Path "${hive}:\SOFTWARE\Microsoft\Cryptography\CertificateTemplateCache" -Name 'Timestamp' -Force -ErrorAction SilentlyContinue
                        }
                        $enrolled = Get-Certificate -Template 'ConfigMgrWebServerCertificate' -SubjectName "CN=$_certFqdn" `
                            -DnsName $_certFqdn, $env:COMPUTERNAME -CertStoreLocation Cert:\LocalMachine\My -ErrorAction Stop
                        $newCert = if ($enrolled -and $enrolled.Certificate) { $enrolled.Certificate } else { $null }
                        if ($newCert) {
                            $store = New-Object System.Security.Cryptography.X509Certificates.X509Store('My', 'LocalMachine')
                            $store.Open('ReadWrite')
                            $live = $store.Certificates | Where-Object { $_.Thumbprint -eq $newCert.Thumbprint } | Select-Object -First 1
                            if ($live) { $live.FriendlyName = $_FriendlyName }
                            $store.Close()
                            Write-Status "Enrolled ConfigMgr WebServer Certificate (thumbprint $($newCert.Thumbprint.Substring(0,8))...) and stamped FriendlyName '$_FriendlyName'"
                        }
                        $cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.FriendlyName -eq $_FriendlyName } | Select-Object -Last 1
                    }
                    catch {
                        Write-Status "Failed to enroll WebServer cert (template ConfigMgrWebServerCertificate): $_"
                    }
                }
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

            # Post-install SOAP health probe: since LCM will not call Test()
            # again after Set(), verify the portal is actually functional now.
            # If the database is still corrupt the probe will fail and we throw
            # so DSC marks this resource as failed rather than silently passing.
            if (-not $needsReboot) {
                Start-Sleep -Seconds 10
                $scheme = if ($this.TemplateName) { 'https' } else { 'http' }
                $probeFqdn = "$env:COMPUTERNAME.$((Get-WmiObject Win32_ComputerSystem).Domain)"
                $soapUri = "$scheme`://$probeFqdn/ReportServer/ReportService2005.asmx"
                $origCb = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
                [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
                try {
                    $ssrsProxy = New-WebServiceProxy -Uri $soapUri -UseDefaultCredential -ErrorAction Stop
                    $itemType = $ssrsProxy.GetItemType("/")
                    if ($itemType -eq 'Folder') {
                        Write-Status "PBIRS SOAP health check passed after install."
                    }
                    else {
                        throw "PBIRS SOAP health check: unexpected root type '$itemType'"
                    }
                }
                catch {
                    Write-Status "PBIRS SOAP health check FAILED after install: $($_.Exception.Message)"
                    throw "PBIRS installed but portal is not functional. SOAP probe at $soapUri failed: $($_.Exception.Message)"
                }
                finally {
                    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $origCb
                }
            }

            if ($needsReboot) {
                Write-Status "Requesting reboot for pending PBIRS prerequisite updates (exit 3010)."
                $global:DSCMachineStatus = 1
            }
        }
        catch {
            # This catch used to log the bare string "Failed to Configure PBIRS" and
            # swallow the exception into Write-Verbose (which nothing captures), so a
            # PBIRS failure produced: DSC resource = SUCCESS, Phase 7 = "0 failures",
            # a status line with no reason, and then a generic "Reporting SOAP API not
            # functional" failure in Phase 11 twelve minutes later with no way back to
            # the cause. Record the whole error instead.
            $_err = $_
            $_where = 'unknown'
            try { $_where = "$($_err.InvocationInfo.ScriptName):$($_err.InvocationInfo.ScriptLineNumber) >> $($_err.InvocationInfo.Line.Trim())" } catch {}
            $_chain = ''
            try {
                $ix = $_err.Exception.InnerException
                $depth = 0
                while ($ix -and $depth -lt 4) { $_chain += " <- $($ix.GetType().Name): $($ix.Message)"; $ix = $ix.InnerException; $depth++ }
            }
            catch {}
            Write-Status "Failed to Configure PBIRS: [$($_err.Exception.GetType().Name)] $($_err.Exception.Message)$_chain"
            Write-Status "Failed to Configure PBIRS at $_where"
            try { Write-Status "Failed to Configure PBIRS stack: $($_err.ScriptStackTrace -replace '\r?\n', ' | ')" } catch {}

            # The post-install SOAP probe above throws on purpose ("so DSC marks this
            # resource as failed rather than silently passing") -- honour that. Any
            # other error stays non-fatal, because PBIRS can still end up functional
            # after a recoverable hiccup earlier in Set().
            if ("$($_err.Exception.Message)" -match 'portal is not functional') { throw $_err }
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

            # When HTTPS is expected, verify HTTPS URL reservations exist
            if ($this.TemplateName) {
                $httpsUrls = $urls.UrlString | Where-Object { $_ -like 'https:*' }
                if (-not $httpsUrls -or $httpsUrls.Count -eq 0) {
                    Write-Verbose "InstallPBIRS Test: TemplateName set but no HTTPS URL reservations found"
                    return $false
                }
            }

            # SOAP API health probe: verify the ReportService2005 endpoint
            # is functional. This is the same check ConfigMgr uses to validate
            # reporting services. If the database connection is broken or the
            # service is in a bad state, GetItemType("/") will fail and we
            # return $false so LCM re-runs Set() to repair.
            try {
                $scheme = if ($this.TemplateName) { 'https' } else { 'http' }
                $probeFqdn = "$env:COMPUTERNAME.$((Get-WmiObject Win32_ComputerSystem).Domain)"
                $soapUri = "$scheme`://$probeFqdn/ReportServer/ReportService2005.asmx"
                $origCb = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
                [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
                try {
                    $ssrsProxy = New-WebServiceProxy -Uri $soapUri -UseDefaultCredential -ErrorAction Stop
                    $itemType = $ssrsProxy.GetItemType("/")
                    if ($itemType -eq 'Folder') {
                        Write-Verbose "InstallPBIRS Test: SOAP API healthy at '$soapUri' (root = Folder)"
                    }
                    else {
                        Write-Verbose "InstallPBIRS Test: SOAP API returned unexpected root type '$itemType'"
                        return $false
                    }
                }
                finally {
                    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $origCb
                }
            }
            catch {
                Write-Verbose "InstallPBIRS Test: SOAP API probe failed: $($_.Exception.Message)"
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
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Scope = 'Function')]
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

    # Remote forest DC FQDN (e.g. CST-DC1.cstest8.com) used to AUTHORITATIVELY
    # discover the issuing CA from AD instead of guessing its -config string.
    [DscProperty()]
    [string]$RemoteForestDC

    # Optional issuing-CA host hint (short or FQDN) to disambiguate when the
    # remote forest publishes more than one Enterprise issuing CA.
    [DscProperty()]
    [string]$IssuingCAHint

    # Resolve the issuing CA's certutil -config string ("<dNSHostName>\<cn>")
    # by enumerating the remote forest's Enrollment Services container -- the
    # exact object set ADCS itself publishes for every Enterprise issuing CA.
    # This is naming-, IP-, and tier-agnostic: an offline standalone root never
    # publishes a pKIEnrollmentService object, so only true issuing CAs appear,
    # and a CA on a non-DC member server with a custom CN is found correctly.
    # Falls back to the passed-in CAName guess if discovery yields nothing.
    [string] ResolveCAConfig() {
        $fallback = $this.CAName
        if ([string]::IsNullOrWhiteSpace($this.RemoteForestDC)) {
            return $fallback
        }
        try {
            $rootDSE = [ADSI]"LDAP://$($this.RemoteForestDC)/RootDSE"
            $configNC = [string]$rootDSE.configurationNamingContext.Value
            if ([string]::IsNullOrWhiteSpace($configNC)) {
                Write-Status "CA discovery: could not read configurationNamingContext from $($this.RemoteForestDC); using fallback '$fallback'"
                return $fallback
            }
            $enrollPath = "LDAP://$($this.RemoteForestDC)/CN=Enrollment Services,CN=Public Key Services,CN=Services,$configNC"
            $enroll = [ADSI]$enrollPath
            $cas = @()
            foreach ($child in $enroll.Children) {
                $cn = [string]$child.Properties['cn'].Value
                $dns = [string]$child.Properties['dNSHostName'].Value
                if (-not [string]::IsNullOrWhiteSpace($cn) -and -not [string]::IsNullOrWhiteSpace($dns)) {
                    $cas += [pscustomobject]@{ CN = $cn; DnsHostName = $dns; Config = "$dns\$cn" }
                }
            }
            if ($cas.Count -eq 0) {
                Write-Status "CA discovery: no Enterprise issuing CA published in the $($this.RemoteForestDC) forest; using fallback '$fallback'"
                return $fallback
            }
            $chosen = $null
            if (-not [string]::IsNullOrWhiteSpace($this.IssuingCAHint)) {
                foreach ($ca in $cas) {
                    $hostShort = ($ca.DnsHostName -split '\.')[0]
                    if ($hostShort -eq $this.IssuingCAHint -or $ca.DnsHostName -eq $this.IssuingCAHint) {
                        $chosen = $ca
                        break
                    }
                }
            }
            if (-not $chosen) {
                $chosen = $cas | Select-Object -First 1
            }
            if ($cas.Count -gt 1) {
                $allConfigs = ($cas | ForEach-Object { $_.Config }) -join ', '
                Write-Status "CA discovery: $($cas.Count) issuing CAs found [$allConfigs]; selected '$($chosen.Config)'"
            }
            else {
                Write-Status "CA discovery: resolved issuing CA '$($chosen.Config)'"
            }
            return $chosen.Config
        }
        catch {
            Write-Status "WARNING: CA discovery against $($this.RemoteForestDC) failed: $_. Using fallback '$fallback'"
            return $fallback
        }
    }

    # AD's cACertificate attribute is multi-valued: it can come back as a single
    # byte[] (one cert) or an object[]/Array of byte[] (cross-cert history). Pull
    # the first usable DER cert blob out of whatever shape we get.
    [byte[]] FirstCertBytes([object]$val) {
        if ($null -eq $val) { return $null }
        if ($val -is [byte[]]) { return $val }
        if ($val -is [System.Array]) {
            foreach ($item in $val) {
                if ($item -is [byte[]]) { return $item }
            }
        }
        return $null
    }

    [bool] BytesEqual([byte[]]$a, [byte[]]$b) {
        if ($null -eq $a -or $null -eq $b) { return $false }
        if ($a.Length -ne $b.Length) { return $false }
        for ($i = 0; $i -lt $a.Length; $i++) {
            if ($a[$i] -ne $b[$i]) { return $false }
        }
        return $true
    }

    [void] Set() {

        $_FileName = "C:\Temp\rootCA.cer"


        if (-not (Test-Path $_FileName)) {
            Write-Status "Install Root Cert"

            $rootBytes = $null
            $issuingBytes = $null

            # PRIMARY retrieval: read the CA certificates straight from the remote
            # forest's AD (Configuration NC), where ADCS publishes them and which
            # is replicated to every DC. This replaces 'certutil -config X
            # -ca.chain <file>', which mis-parses on Server 2022 ("Too many
            # arguments" -> no file produced) and so never worked for the
            # cross-forest case. The CA is reachable (certutil -ping/ICertRequest2
            # succeeds); the retrieval verb was the bug. AD read is naming-, IP-,
            # tier-, and DCOM-agnostic and works for single- and multi-tier PKI.
            if (-not [string]::IsNullOrWhiteSpace($this.RemoteForestDC)) {
                try {
                    $configNC = [string]([ADSI]"LDAP://$($this.RemoteForestDC)/RootDSE").configurationNamingContext.Value

                    # Root (self-signed) CA cert(s): CN=Certification Authorities
                    $caContainer = [ADSI]"LDAP://$($this.RemoteForestDC)/CN=Certification Authorities,CN=Public Key Services,CN=Services,$configNC"
                    foreach ($ca in $caContainer.Children) {
                        $b = $this.FirstCertBytes($ca.Properties['cACertificate'].Value)
                        if ($b) {
                            $rootBytes = $b
                            Write-Status "Read root CA '$([string]$ca.Properties['cn'].Value)' from AD ($($b.Length) bytes)"
                            break
                        }
                    }

                    # Issuing CA cert: the pKIEnrollmentService object (prefer the
                    # host hint when more than one issuing CA is published).
                    $enroll = [ADSI]"LDAP://$($this.RemoteForestDC)/CN=Enrollment Services,CN=Public Key Services,CN=Services,$configNC"
                    $picked = $null
                    foreach ($svc in $enroll.Children) {
                        if (-not [string]::IsNullOrWhiteSpace($this.IssuingCAHint)) {
                            $dns = [string]$svc.Properties['dNSHostName'].Value
                            $short = ($dns -split '\.')[0]
                            if ($short -eq $this.IssuingCAHint -or $dns -eq $this.IssuingCAHint) {
                                $picked = $svc
                                break
                            }
                        }
                        if (-not $picked) { $picked = $svc }
                    }
                    if ($picked) {
                        $b = $this.FirstCertBytes($picked.Properties['cACertificate'].Value)
                        if ($b) {
                            $issuingBytes = $b
                            Write-Status "Read issuing CA '$([string]$picked.Properties['cn'].Value)' from AD ($($b.Length) bytes)"
                        }
                    }
                }
                catch {
                    Write-Status "WARNING: Reading CA certs from AD ($($this.RemoteForestDC)) failed: $_"
                }
            }

            if ($rootBytes -or $issuingBytes) {
                # Prefer the self-signed root for the RootCA file; if only the
                # issuing CA was found, use it.
                if (-not $rootBytes) { $rootBytes = $issuingBytes }
                [System.IO.File]::WriteAllBytes($_FileName, $rootBytes)
                Write-Status "Wrote root CA certificate to $_FileName from AD"
            }
            else {
                # FALLBACK: legacy certutil retrieval (only if the AD read yielded
                # nothing -- e.g. RemoteForestDC absent or the container empty).
                $caConfig = $this.ResolveCAConfig()
                Write-Status "AD CA read unavailable; falling back to certutil -ca.cert against '$caConfig'"
                certutil.exe -config $caConfig -ca.cert $_FileName
            }

            # If we still have no root cert file, fail with a clear, actionable
            # error so the LCM retries on a real (recoverable) condition instead
            # of the downstream dspublish calls running against a missing file.
            if (-not (Test-Path $_FileName)) {
                throw "InstallRootCertificate: unable to obtain root CA certificate for forest '$($this.RemoteForestDC)' / CA '$($this.CAName)' (AD read produced no cert and certutil -ca.cert fallback produced no file). DSC will retry."
            }

            # Publish root CA cert as RootCA and NtauthCA
            Write-Status "Running certutil.exe -dspublish -f $_FileName RootCA"
            certutil.exe -dspublish -f $_FileName RootCA
            Write-Status "Running certutil.exe -dspublish -f $_FileName NtauthCA"
            certutil.exe -dspublish -f $_FileName NtauthCA

            # If two-tier PKI (issuing CA differs from the root), publish the
            # issuing/subordinate CA as SubCA and NtauthCA (it is the CA that
            # actually signs the end-entity certs we cross-forest authenticate).
            if ($issuingBytes -and $rootBytes -and -not $this.BytesEqual($issuingBytes, $rootBytes)) {
                $subCACertFile = "C:\Temp\subCA.cer"
                [System.IO.File]::WriteAllBytes($subCACertFile, $issuingBytes)
                Write-Status "Two-tier PKI: publishing subordinate/issuing CA as SubCA + NtauthCA"
                certutil.exe -dspublish -f $subCACertFile SubCA
                certutil.exe -dspublish -f $subCACertFile NtauthCA
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
                $savedVP = $global:VerbosePreference; $global:VerbosePreference = 'SilentlyContinue'
                try { Import-Module PackageManagement -ErrorAction SilentlyContinue }
                finally { $global:VerbosePreference = $savedVP }
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
                            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Scope = 'Function')]
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
                            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Scope = 'Function')]
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
            # The friendly-named cert is missing. This happens when CertReq's
            # subject-only Test skipped stamping it (a subject-colliding cert
            # already existed at Phase 3 time on a recreated VM), leaving a
            # CA-issued ServerAuth template cert for this host with no/other
            # FriendlyName. Recover it by re-stamping the name instead of
            # failing the whole config. Filter to a CA-issued (Issuer != Subject)
            # cert from an AD template (has the V2 template extension) with
            # ServerAuth EKU and this host's FQDN in the subject -- that excludes
            # SQL's self-signed CN=FQDN ServerAuth cert.
            $fqdn = "$env:COMPUTERNAME.$env:USERDNSDOMAIN"
            $srvAuthOid = '1.3.6.1.5.5.7.3.1'
            $candidate = Get-ChildItem Cert:\LocalMachine\My | Where-Object {
                ($_.EnhancedKeyUsageList.ObjectId -contains $srvAuthOid) -and
                ($_.Subject -match [regex]::Escape($fqdn)) -and
                ($_.Issuer -ne $_.Subject) -and
                ($_.Extensions.Oid.Value -contains '1.3.6.1.4.1.311.21.7')
            } | Sort-Object NotBefore -Descending | Select-Object -First 1
            if ($candidate) {
                try {
                    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store('My', 'LocalMachine')
                    $store.Open('ReadWrite')
                    $live = $store.Certificates | Where-Object { $_.Thumbprint -eq $candidate.Thumbprint } | Select-Object -First 1
                    if ($live) { $live.FriendlyName = $_FriendlyName }
                    $store.Close()
                    Write-Status "Recovered CA-issued ServerAuth cert (thumbprint $($candidate.Thumbprint.Substring(0,8))...) that had lost FriendlyName '$_FriendlyName'; re-applied name"
                }
                catch {
                    Write-Status "Failed to re-apply FriendlyName to recovered cert: $_"
                }
                $cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.FriendlyName -eq $_FriendlyName } | Select-Object -Last 1
            }
        }
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
            # A missing friendly-named cert must NOT report 'in desired state':
            # with $cert null, $thumbPrint is empty and '$certdata -match ""'
            # matches the empty pattern -> returns $true, masking a genuinely
            # missing/renamed cert so Set() never runs to recover + bind it.
            if (-not $cert -or [string]::IsNullOrEmpty($cert.Thumbprint)) {
                return $false
            }
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
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            # /target:computer skips the user-policy pass (this lab publishes no user-side GPO),
            # and gpupdate can block for many minutes on a settling/loaded DC -- bound it so a
            # wedged refresh can never stall the phase for this node.
            $gp = Start-Process -FilePath gpupdate.exe -ArgumentList '/target:computer', '/force', '/wait:120' -PassThru -WindowStyle Hidden -ErrorAction Stop
            if (-not $gp.WaitForExit(150000)) {
                try { $gp.Kill() } catch {}
                Write-Status "gpupdate exceeded 150s -- killed, continuing"
                return
            }
            if ($gp.ExitCode -ne 0) {
                Write-Status "gpupdate exited $($gp.ExitCode) after $([int]$sw.Elapsed.TotalSeconds)s"
            }
        }
        catch {
            Write-Status "gpupdate could not be started: $($_.Exception.Message)"
        }
    }

    [bool] Test() {
        # The only GPO this lab publishes is "Certificate AutoEnrollment" (Phase2DC), a
        # machine-side registry policy. If AEPolicy is already applied the GPO has landed
        # (boot-time apply or an earlier run) and a forced refresh buys nothing.
        try {
            $ae = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Cryptography\AutoEnrollment' -Name 'AEPolicy' -ErrorAction Stop
            return ($ae.AEPolicy -eq 7)
        }
        catch {
            return $false
        }
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

[DscResource()]
class DisableClusterNicDnsRegistration {
    [DscProperty(Key)]
    [string] $ClusterSubnet = '10.250.251.'

    [DscProperty(Key)]
    [string] $Stage = 'Full'

    [DscProperty(Mandatory)]
    [string] $DomainName

    [DscProperty(Mandatory)]
    [string] $DCName

    [DscProperty()]
    [string] $ClusterName

    [DscProperty()]
    [string] $ClusterIPAddress

    [DscProperty()]
    [string] $ListenerName

    [DscProperty()]
    [string] $ListenerIPAddress

    [void] Set() {
        $_subnet = $this.ClusterSubnet
        $_domain = $this.DomainName
        $_dc     = $this.DCName

        # Per-block elapsed instrumentation. Test() always returns $false so this
        # Set() runs on EVERY pass (and twice per Phase 5 deploy: a 'Pre' stage and
        # a 'Post' stage). One stage has been observed taking ~3.5 min even on a
        # re-run where nothing needs changing; this records how long each major
        # block takes and emits a single summary line so the dominant cost is
        # visible in the build log / [DscTiming] resource detail. Cheap (Get-Date
        # deltas only); no behavior change.
        $blockTimes = [ordered]@{}
        $lapStart = [datetime]::UtcNow

        # Pre-import modules quietly so DSC verbose logging doesn't flood
        # with hundreds of "Exporting function ..." lines. Import-Module
        # -Verbose:$false is insufficient because DSC sets $VerbosePreference
        # = 'Continue' session-wide, and module manifest processing respects
        # the preference variable, not the cmdlet switch. Temporarily override
        # the preference variable during imports.
        # Only import what isn't already loaded so re-runs (Test() is always
        # $false) and the second stage in the same LCM process don't re-pay the
        # ~10s import cost. DnsServer is intentionally NOT imported here -- its
        # cmdlets (Get/Remove-DnsServerResourceRecord) are only ever called inside
        # Invoke-WithTimeoutJob scriptblocks, which run in their own runspaces and
        # import it there. FailoverClusters is loaded lazily in the ClusterOps
        # block below (only the PostCluster stage needs it).
        $savedVerbose = $global:VerbosePreference
        $global:VerbosePreference = 'SilentlyContinue'
        try {
            $needed = @('NetAdapter', 'NetTCPIP', 'DnsClient', 'NetSecurity') |
                Where-Object { -not (Get-Module -Name $_ -ErrorAction SilentlyContinue) }
            if ($needed) {
                Import-Module $needed -ErrorAction SilentlyContinue
            }
        }
        finally {
            $global:VerbosePreference = $savedVerbose
        }
        $blockTimes['ModuleImport'] = [math]::Round(([datetime]::UtcNow - $lapStart).TotalSeconds, 1); $lapStart = [datetime]::UtcNow

        # 1. Disable DNS registration on cluster/heartbeat adapters and rename NICs.
        $allAdapters = @(Get-NetAdapter | Where-Object { $_.Status -eq 'Up' })
        $clusterAdapters = @()
        $domainAdapters = @()

        foreach ($a in $allAdapters) {
            $ips = Get-NetIPAddress -InterfaceIndex $a.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
            if ($ips | Where-Object { $_.IPAddress -like "${_subnet}*" }) {
                $clusterAdapters += $a
            }
            else {
                $domainAdapters += $a
            }
        }

        foreach ($adapter in $clusterAdapters) {
            # Each mutation below is guarded with a cheap "is it already correct?"
            # read so a re-run (Test() returns $false by design) is a fast no-op
            # and -- importantly -- does NOT needlessly re-bind / reset a live
            # heartbeat NIC every time. Set() is still fully self-correcting.
            $changed = $false

            # Three-layer DNS-registration prevention:
            #  1. RegisterThisConnectionsAddress = $false  (preference flag)
            #  2. No DNS servers  (nowhere to send the update)
            #  3. No DNS suffix   (no zone to register in)
            $dnsCli = Get-DnsClient -InterfaceIndex $adapter.InterfaceIndex -ErrorAction SilentlyContinue
            if ((-not $dnsCli) -or $dnsCli.RegisterThisConnectionsAddress -or ($dnsCli.ConnectionSpecificSuffix -ne '')) {
                Set-DnsClient -InterfaceIndex $adapter.InterfaceIndex -RegisterThisConnectionsAddress $false -ConnectionSpecificSuffix '' -ErrorAction Stop
                $changed = $true
            }
            $curServers = @((Get-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses)
            if ($curServers.Count -gt 0) {
                Set-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -ServerAddresses @() -ErrorAction SilentlyContinue
                $changed = $true
            }

            # Higher metric so the domain NIC is always preferred for outbound traffic.
            $curMetric = (Get-NetIPInterface -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).InterfaceMetric
            if ($curMetric -ne 20) {
                Set-NetIPInterface -InterfaceIndex $adapter.InterfaceIndex -InterfaceMetric 20 -ErrorAction SilentlyContinue
                $changed = $true
            }

            # Disable NetBIOS over TCP/IP on the cluster NIC (2 = Disable).
            $wmiNic = Get-WmiObject Win32_NetworkAdapterConfiguration -Filter "InterfaceIndex = $($adapter.InterfaceIndex)" -ErrorAction SilentlyContinue
            if ($wmiNic -and $wmiNic.TcpipNetbiosOptions -ne 2) {
                $wmiNic.SetTcpipNetbios(2) | Out-Null
                $changed = $true
            }

            # Disable IPv6 (AAAA registration), LLTD mapper (ms_lltdio) + responder
            # (ms_rspndr) on the cluster NIC. Disable-NetAdapterBinding re-binds the
            # adapter (slow + briefly disruptive), so only touch a binding that is
            # actually still enabled.
            foreach ($comp in @('ms_tcpip6', 'ms_lltdio', 'ms_rspndr')) {
                $binding = Get-NetAdapterBinding -InterfaceAlias $adapter.Name -ComponentID $comp -ErrorAction SilentlyContinue
                if ($binding -and $binding.Enabled) {
                    Disable-NetAdapterBinding -InterfaceAlias $adapter.Name -ComponentID $comp -ErrorAction SilentlyContinue
                    $changed = $true
                }
            }

            # Remove default gateway from cluster NIC -- heartbeat NICs should never
            # route externally. DHCP may have handed one out before the scope was fixed.
            $gateway = Get-NetRoute -InterfaceIndex $adapter.InterfaceIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue
            if ($gateway) {
                Remove-NetRoute -InterfaceIndex $adapter.InterfaceIndex -DestinationPrefix '0.0.0.0/0' -Confirm:$false -ErrorAction SilentlyContinue
                Write-Status "Removed default gateway from cluster adapter '$($adapter.Name)'"
                $changed = $true
            }

            # Rename to something descriptive if still using a generic Windows name.
            if ($adapter.Name -match '^Ethernet(\s\d+)?$') {
                try {
                    Rename-NetAdapter -InputObject $adapter -NewName 'Cluster' -ErrorAction Stop
                    Write-Status "Renamed adapter '$($adapter.Name)' -> 'Cluster'"
                    $changed = $true
                }
                catch {
                    Write-Verbose "Could not rename adapter '$($adapter.Name)': $_"
                }
            }

            if ($changed) {
                Write-Status "Stripped DNS capability from heartbeat adapter '$($adapter.Name)' ($_subnet*)"
            }
            else {
                Write-Status "Heartbeat adapter '$($adapter.Name)' already configured ($_subnet*)"
            }
        }

        $blockTimes['ClusterNicLoop'] = [math]::Round(([datetime]::UtcNow - $lapStart).TotalSeconds, 1); $lapStart = [datetime]::UtcNow

        # Also rename the domain adapter for consistency and ensure low metric.
        foreach ($adapter in $domainAdapters) {
            $curMetric = (Get-NetIPInterface -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).InterfaceMetric
            if ($curMetric -ne 10) {
                Set-NetIPInterface -InterfaceIndex $adapter.InterfaceIndex -InterfaceMetric 10 -ErrorAction SilentlyContinue
            }

            if ($adapter.Name -match '^Ethernet(\s\d+)?$') {
                try {
                    Rename-NetAdapter -InputObject $adapter -NewName 'Domain' -ErrorAction Stop
                    Write-Status "Renamed adapter '$($adapter.Name)' -> 'Domain'"
                }
                catch {
                    Write-Verbose "Could not rename adapter '$($adapter.Name)': $_"
                }
            }
        }

        $blockTimes['DomainNicLoop'] = [math]::Round(([datetime]::UtcNow - $lapStart).TotalSeconds, 1); $lapStart = [datetime]::UtcNow

        # Disable DNS registration on cluster virtual adapters that don't appear
        # in Get-NetAdapter (e.g. Microsoft Failover Cluster Virtual Adapter,
        # isatap tunnel adapters).  These are recreated with default settings
        # (RegisterThisConnectionsAddress = $true) every time the cluster service
        # starts, so they silently re-register the heartbeat IP in DNS.
        foreach ($iface in (Get-NetIPInterface -AddressFamily IPv4 -ErrorAction SilentlyContinue)) {
            # Skip adapters already handled above via Get-NetAdapter
            $already = $clusterAdapters + $domainAdapters | Where-Object { $_.InterfaceIndex -eq $iface.ifIndex }
            if ($already) { continue }

            $ifaceIPs = (Get-NetIPAddress -InterfaceIndex $iface.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress
            $isClusterSubnet = $ifaceIPs | Where-Object { $_ -like "${_subnet}*" }
            $isClusterName = $iface.InterfaceAlias -like '*Cluster*' -or $iface.InterfaceAlias -like '*isatap*'

            if ($isClusterSubnet -or $isClusterName) {
                $vChanged = $false
                $vDns = Get-DnsClient -InterfaceIndex $iface.ifIndex -ErrorAction SilentlyContinue
                if ((-not $vDns) -or $vDns.RegisterThisConnectionsAddress -or ($vDns.ConnectionSpecificSuffix -ne '')) {
                    Set-DnsClient -InterfaceIndex $iface.ifIndex -RegisterThisConnectionsAddress $false -ConnectionSpecificSuffix '' -ErrorAction SilentlyContinue
                    $vChanged = $true
                }
                $vServers = @((Get-DnsClientServerAddress -InterfaceIndex $iface.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses)
                if ($vServers.Count -gt 0) {
                    Set-DnsClientServerAddress -InterfaceIndex $iface.ifIndex -ServerAddresses @() -ErrorAction SilentlyContinue
                    $vChanged = $true
                }
                foreach ($comp in @('ms_lltdio', 'ms_rspndr')) {
                    $vb = Get-NetAdapterBinding -InterfaceAlias $iface.InterfaceAlias -ComponentID $comp -ErrorAction SilentlyContinue
                    if ($vb -and $vb.Enabled) {
                        Disable-NetAdapterBinding -InterfaceAlias $iface.InterfaceAlias -ComponentID $comp -ErrorAction SilentlyContinue
                        $vChanged = $true
                    }
                }
                if ($vChanged) {
                    Write-Status "Stripped DNS capability from virtual adapter '$($iface.InterfaceAlias)' (ifIndex $($iface.ifIndex))"
                }
            }
        }

        $blockTimes['VirtualNicLoop'] = [math]::Round(([datetime]::UtcNow - $lapStart).TotalSeconds, 1); $lapStart = [datetime]::UtcNow

        # Re-register only the domain adapter so the correct A record stays.
        Register-DnsClient -ErrorAction SilentlyContinue

        # 2. Remove stale hostname A records that point to the cluster subnet.
        $hostname = $env:COMPUTERNAME
        try {
            # Get/Remove-DnsServerResourceRecord -ComputerName <DC> are CDXML/CIM
            # cmdlets with NO native timeout; an intermittently-wedged DC can block
            # them for minutes and stall this DSC apply (and the phase). Run each
            # under a kill+retry watchdog so a hang degrades to a skipped cleanup
            # instead of a hung phase. The stale-subnet filter runs inside the job
            # so only plain strings cross the job boundary.
            $staleIps = Invoke-WithTimeoutJob -TimeoutSec 30 -MaxAttempts 2 -ArgumentList @($_domain, $hostname, $_dc, $_subnet) -ScriptBlock {
                param($zone, $name, $dc, $subnet)
                @(Get-DnsServerResourceRecord -ZoneName $zone -Name $name -RRType A -ComputerName $dc -ErrorAction Stop |
                    ForEach-Object { $_.RecordData.IPv4Address.ToString() } |
                    Where-Object { $_ -like "${subnet}*" })
            }
            foreach ($ip in @($staleIps)) {
                Write-Status "Removing stale DNS A record $hostname -> $ip from $_dc"
                $null = Invoke-WithTimeoutJob -TimeoutSec 30 -MaxAttempts 2 -ArgumentList @($_domain, $hostname, $_dc, $ip) -ScriptBlock {
                    param($zone, $name, $dc, $rip)
                    Remove-DnsServerResourceRecord -ZoneName $zone -Name $name -RRType A -RecordData $rip -ComputerName $dc -Force -ErrorAction Stop
                }
            }
        }
        catch {
            Write-Verbose "Could not clean stale hostname DNS records: $_"
        }

        # 3. Flush DNS cache so stale records don't interfere.
        #    Do NOT pre-create cluster or listener DNS A records here.
        #    The Cluster Name resource and AG listener manage their own DNS
        #    registration on whichever network has DNS registration enabled
        #    (the domain adapter). Pre-creating records on the cluster-subnet
        #    IP caused OpenCluster() failures because the Cluster Name resource
        #    serves on the domain-network IP, not the cluster-subnet IP.
        Clear-DnsClientCache -ErrorAction SilentlyContinue
        $blockTimes['DnsCleanupAndDcQuery'] = [math]::Round(([datetime]::UtcNow - $lapStart).TotalSeconds, 1); $lapStart = [datetime]::UtcNow

        # 4. Scope cluster heartbeat firewall rule to cluster subnet only.
        #    Derive CIDR from the subnet property (e.g. '10.250.250.' -> '10.250.250.0/24')
        #    by counting the octets provided. 3 octets = /24, 2 = /16, 1 = /8.
        $octets = ($_subnet.TrimEnd('.') -split '\.').Count
        $cidrBits = $octets * 8
        $networkAddr = $_subnet.TrimEnd('.') + ('.0' * (4 - $octets))
        $cidr = "$networkAddr/$cidrBits"
        $ruleName = 'WSFC Heartbeat (Cluster Subnet)'
        if (-not (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -DisplayName $ruleName `
                -Direction Inbound -Protocol UDP -LocalPort 3343 `
                -RemoteAddress $cidr -Action Allow -ErrorAction SilentlyContinue | Out-Null
            Write-Status "Created firewall rule '$ruleName' ($cidr)"
        }

        # 5. Set RegisterAllProvidersIP=0 on the Cluster Name resource so only the
        #    active node's IP is registered in DNS (not all node IPs). Prevents
        #    clients from resolving the cluster name to a node that isn't hosting.
        $_clusterName = $this.ClusterName
        if ($_clusterName) {
            try {
                # Load FailoverClusters on demand (skipped in the eager import above).
                if (-not (Get-Module -Name FailoverClusters -ErrorAction SilentlyContinue)) {
                    $savedVerbose = $global:VerbosePreference
                    $global:VerbosePreference = 'SilentlyContinue'
                    try { Import-Module FailoverClusters -ErrorAction SilentlyContinue }
                    finally { $global:VerbosePreference = $savedVerbose }
                }
                $clusNameRes = Get-ClusterResource -Cluster $_clusterName -Name 'Cluster Name' -ErrorAction Stop
                $regAll = ($clusNameRes | Get-ClusterParameter -Name RegisterAllProvidersIP -ErrorAction SilentlyContinue).Value
                if ($regAll -ne 0) {
                    $clusNameRes | Set-ClusterParameter -Name RegisterAllProvidersIP -Value 0 -ErrorAction Stop
                    # Bounce the resource so the parameter takes effect immediately
                    # instead of waiting for the next failover.
                    $clusNameRes | Stop-ClusterResource -ErrorAction SilentlyContinue
                    $clusNameRes | Start-ClusterResource -ErrorAction SilentlyContinue
                    Write-Status "Set RegisterAllProvidersIP=0 on Cluster Name resource (restarted)"
                }
            }
            catch {
                Write-Verbose "Could not set RegisterAllProvidersIP: $_"
            }
        }
        $blockTimes['ClusterOps'] = [math]::Round(([datetime]::UtcNow - $lapStart).TotalSeconds, 1)
        $__bt = ($blockTimes.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)s" }) -join ' '
        # Write-Status auto-prepends the resource name; don't repeat it here.
        Write-Status "[$($this.Stage)] block timing: $__bt"
    }

    [bool] Test() {
        # ALWAYS return $false -- never add real Test logic here, and never remove
        # this comment. The cluster / NetAdapter / DNS cmdlets this resource relies
        # on (e.g. Get-NetAdapter, Get-NetAdapterBinding, Resolve-DnsName,
        # Get-ClusterResource) leak records onto the success output stream (stream 1)
        # from inside a PS 5.1 class method -- a Verbose/Information/object record
        # gets collected ALONGSIDE the boolean return value. DSC then sees more than
        # one value coming back from Test-TargetResource and throws:
        #   "Test-TargetResource must be the boolean value True or False"
        # which hard-fails the whole configuration. There is no reliable way to
        # suppress every such leak inside a class method, so Test() must stay a
        # plain, unconditional 'return $false'. Idempotency is handled in Set()
        # instead: it reads current state and skips any mutation already correct,
        # so re-running it (which happens every pass because Test is always false)
        # is a cheap no-op.
        return $false
    }

    [DisableClusterNicDnsRegistration] Get() {
        return $this
    }
}

[DscResource()]
class SetWindowsProxy {
    [DscProperty(Key)]
    [string] $ProxyServer      # e.g. "ZZ-SQUID.wacky.sandwich.lab:3128"

    [DscProperty(Mandatory)]
    [string] $BypassList       # e.g. "<local>;*.wacky.sandwich.lab;172.19.77.*"

    [void] Set() {
        $_proxy  = $this.ProxyServer
        $_bypass = $this.BypassList
        $maxRetries = 3

        for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
            try {
                Write-Status "SetWindowsProxy: configuring proxy $_proxy (attempt $attempt/$maxRetries)"

                # 1. WinHTTP (used by BITS, Windows Update, .NET fallback)
                $result = & netsh winhttp set proxy proxy-server="$_proxy" bypass-list="$_bypass" 2>&1
                if ($LASTEXITCODE -ne 0) { throw "netsh winhttp set proxy failed (exit $LASTEXITCODE): $result" }

                # 2. Machine-level environment variables
                [Environment]::SetEnvironmentVariable('HTTP_PROXY',  "http://$_proxy", 'Machine')
                [Environment]::SetEnvironmentVariable('HTTPS_PROXY', "http://$_proxy", 'Machine')
                [Environment]::SetEnvironmentVariable('NO_PROXY',    $_bypass,         'Machine')

                # 3. HKLM Internet Settings (WinINet machine-wide default)
                $ieKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings'
                New-ItemProperty -Path $ieKey -Name 'ProxyEnable'   -PropertyType DWord  -Value 1       -Force | Out-Null
                New-ItemProperty -Path $ieKey -Name 'ProxyServer'   -PropertyType String -Value $_proxy  -Force | Out-Null
                New-ItemProperty -Path $ieKey -Name 'ProxyOverride' -PropertyType String -Value $_bypass -Force | Out-Null

                # 4. HKU\.DEFAULT (SYSTEM-context .NET / WinINet reads)
                $defaultUserKey = 'Registry::HKEY_USERS\.DEFAULT\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
                if (-not (Test-Path $defaultUserKey)) { New-Item -Path $defaultUserKey -Force | Out-Null }
                New-ItemProperty -Path $defaultUserKey -Name 'ProxyEnable'   -PropertyType DWord  -Value 1       -Force | Out-Null
                New-ItemProperty -Path $defaultUserKey -Name 'ProxyServer'   -PropertyType String -Value $_proxy  -Force | Out-Null
                New-ItemProperty -Path $defaultUserKey -Name 'ProxyOverride' -PropertyType String -Value $_bypass -Force | Out-Null

                # 5. .NET Framework machine.config <defaultProxy>
                $bypassRegexes = @()
                foreach ($e in ($_bypass -split ';')) {
                    $e = $e.Trim()
                    if (-not $e -or $e -eq '<local>') { continue }
                    $rx = '^' + ([Regex]::Escape($e) -replace '\\\*', '.*') + '$'
                    $bypassRegexes += $rx
                }
                $machineConfigPaths = @(
                    "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\Config\machine.config",
                    "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\Config\machine.config"
                )
                foreach ($mcPath in $machineConfigPaths) {
                    if (-not (Test-Path $mcPath)) { continue }
                    $xml = [xml](Get-Content -LiteralPath $mcPath -Raw)
                    $configNode = $xml.DocumentElement
                    $sysNet = $configNode.SelectSingleNode('system.net')
                    if (-not $sysNet) {
                        $sysNet = $xml.CreateElement('system.net')
                        [void]$configNode.AppendChild($sysNet)
                    }
                    $existing = $sysNet.SelectSingleNode('defaultProxy')
                    if ($existing) { [void]$sysNet.RemoveChild($existing) }
                    $defProxy = $xml.CreateElement('defaultProxy')
                    $defProxy.SetAttribute('enabled', 'true')
                    $defProxy.SetAttribute('useDefaultCredentials', 'true')
                    $proxyEl = $xml.CreateElement('proxy')
                    $proxyEl.SetAttribute('proxyaddress', "http://$_proxy")
                    $proxyEl.SetAttribute('bypassonlocal', 'true')
                    $proxyEl.SetAttribute('autoDetect', 'false')
                    $proxyEl.SetAttribute('usesystemdefault', 'false')
                    [void]$defProxy.AppendChild($proxyEl)
                    if ($bypassRegexes.Count -gt 0) {
                        $bypassEl = $xml.CreateElement('bypasslist')
                        foreach ($rx in $bypassRegexes) {
                            $addEl = $xml.CreateElement('add')
                            $addEl.SetAttribute('address', $rx)
                            [void]$bypassEl.AppendChild($addEl)
                        }
                        [void]$defProxy.AppendChild($bypassEl)
                    }
                    [void]$sysNet.AppendChild($defProxy)
                    $xml.Save($mcPath)

                    # Verify the write persisted
                    $verifyXml = [xml](Get-Content -LiteralPath $mcPath -Raw)
                    $verifyProxy = $verifyXml.DocumentElement.SelectSingleNode('system.net/defaultProxy/proxy')
                    if (-not $verifyProxy) {
                        throw "machine.config verification failed: <defaultProxy/proxy> not found in $mcPath"
                    }
                    if ($verifyProxy.GetAttribute('proxyaddress') -ne "http://$_proxy") {
                        throw "machine.config proxyaddress mismatch in $mcPath (got '$($verifyProxy.GetAttribute('proxyaddress'))')"
                    }
                }

                Write-Status "SetWindowsProxy: proxy $_proxy configured successfully"
                return   # success
            }
            catch {
                Write-Status "SetWindowsProxy: attempt $attempt failed: $_"
                if ($attempt -ge $maxRetries) { throw }
                Start-Sleep -Seconds 5
            }
        }
    }

    [bool] Test() {
        $_proxy = $this.ProxyServer

        # Check WinHTTP
        try {
            $output = & netsh winhttp show proxy 2>$null
            if ($output -notmatch 'Proxy Server\(s\)\s*:\s*(\S+)') {
                Write-Verbose "SetWindowsProxy Test: WinHTTP proxy not set"
                return $false
            }
            if ($Matches[1].Trim() -ne $_proxy) {
                Write-Verbose "SetWindowsProxy Test: WinHTTP proxy is '$($Matches[1].Trim())', expected '$_proxy'"
                return $false
            }
        }
        catch {
            Write-Verbose "SetWindowsProxy Test: WinHTTP check failed: $_"
            return $false
        }

        # Check machine.config
        $mcPath = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\Config\machine.config"
        if (Test-Path $mcPath) {
            try {
                $xml = [xml](Get-Content -LiteralPath $mcPath -Raw)
                $p = $xml.DocumentElement.SelectSingleNode('system.net/defaultProxy/proxy')
                if (-not $p -or $p.GetAttribute('proxyaddress') -ne "http://$_proxy") {
                    Write-Verbose "SetWindowsProxy Test: machine.config <defaultProxy> not set for $_proxy"
                    return $false
                }
            }
            catch {
                Write-Verbose "SetWindowsProxy Test: machine.config check failed: $_"
                return $false
            }
        }

        return $true
    }

    [SetWindowsProxy] Get() {
        return $this
    }
}

# ---------------------------------------------------------------------------
# PromoteDomainController
#
# Wraps Install-ADDSDomainController with robust error handling.  The built-in
# ADDomainController resource from ActiveDirectoryDsc lets the non-terminating
# "Verification of user credential permissions failed" error propagate into
# the DSC error stream.  The LCM then marks the resource as failed even though
# -Force causes Install-ADDSDomainController to proceed.  This resource
# suppresses that error and scrubs it from $global:Error so the LCM sees a
# clean Set() and honours the reboot request.
# ---------------------------------------------------------------------------
[DscResource()]
class PromoteDomainController {
    [DscProperty(Key)]
    [string] $DomainName

    [DscProperty(Mandatory)]
    [System.Management.Automation.PSCredential] $Credential

    [DscProperty(Mandatory)]
    [System.Management.Automation.PSCredential] $SafeModeAdministratorPassword

    [DscProperty()]
    [string] $DatabasePath = 'C:\Windows\NTDS'

    [DscProperty()]
    [string] $LogPath = 'C:\Windows\Logs'

    [DscProperty()]
    [string] $SysvolPath = 'C:\Windows\SYSVOL'

    [DscProperty()]
    [bool] $IsGlobalCatalog = $true

    [DscProperty()]
    [bool] $InstallDns = $true

    [void] Set() {
        $credUser = $this.Credential.UserName
        Write-Verbose "PromoteDomainController: Running as process identity '$env:USERDOMAIN\$env:USERNAME'"
        Write-Verbose "PromoteDomainController: Credential supplied for promotion: '$credUser'"
        Write-Verbose "PromoteDomainController: Target domain: '$($this.DomainName)'"
        Write-Verbose "PromoteDomainController: Computer name: '$env:COMPUTERNAME'"

        # Check if a previous promotion succeeded by looking for the Netlogon
        # SysVol registry key (same check the ADDomain resource uses).  This
        # key is only written after a fully successful promotion -- not by
        # Install-WindowsFeature and not by a partial/failed promotion.
        $previousPromotion = $false
        try {
            $nlSysvol = Get-ItemPropertyValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon\Parameters' -Name 'SysVol' -ErrorAction Stop
            $domainSysVol = Join-Path $nlSysvol $this.DomainName
            if (Test-Path $domainSysVol) {
                $previousPromotion = $true
            }
        }
        catch {}

        $existingSvc = Get-Service -Name 'NTDS' -ErrorAction SilentlyContinue
        $svcStatus = if ($existingSvc) { $existingSvc.Status } else { 'N/A' }
        Write-Verbose "PromoteDomainController: NTDS service status: $svcStatus, previous promotion: $previousPromotion"

        if ($existingSvc -and $existingSvc.Status -eq 'Running') {
            Write-Verbose "PromoteDomainController: NTDS is already running - nothing to do"
            return
        }

        if ($previousPromotion) {
            # Promotion succeeded previously but NTDS isn't running.  Try to start it.
            Write-Verbose "PromoteDomainController: Previous promotion detected. Attempting to start NTDS."
            try {
                Start-Service -Name 'NTDS' -ErrorAction Stop
                $existingSvc.WaitForStatus('Running', [TimeSpan]::FromSeconds(120))
                Write-Verbose "PromoteDomainController: NTDS started successfully"
                return
            }
            catch {
                Write-Verbose "PromoteDomainController: Could not start NTDS: $_ - requesting reboot"
                $global:DSCMachineStatus = 1
                return
            }
        }

        # No previous successful promotion.  Check for stale ntds.dit from a
        # partial/failed attempt and clean it up before re-promoting.
        $ditPath = Join-Path $this.DatabasePath 'ntds.dit'
        if (Test-Path $ditPath) {
            Write-Verbose "PromoteDomainController: Stale ntds.dit found without SysVol - force-removing failed promotion"
            $errorsBefore = $global:Error.Count
            try {
                $dsrmPass = $this.SafeModeAdministratorPassword.Password
                Uninstall-ADDSDomainController -ForceRemoval -Force `
                    -LocalAdministratorPassword $dsrmPass `
                    -DemoteOperationMasterRole:$true `
                    -ErrorAction SilentlyContinue 2>&1 | ForEach-Object {
                    Write-Verbose "PromoteDomainController: (force-remove) $_"
                }
            }
            catch {
                Write-Verbose "PromoteDomainController: Force-removal exception: $_"
            }
            $errorsAdded = $global:Error.Count - $errorsBefore
            if ($errorsAdded -gt 0) {
                for ($i = 0; $i -lt $errorsAdded; $i++) {
                    $global:Error.RemoveAt(0)
                }
            }

            if (Test-Path $ditPath) {
                Write-Verbose "PromoteDomainController: ntds.dit still present after force-removal - requesting reboot"
                $global:DSCMachineStatus = 1
                return
            }
            Write-Verbose "PromoteDomainController: Force-removal complete - proceeding to fresh promotion"
        }
        else {
            Write-Verbose "PromoteDomainController: No previous promotion detected - fresh promotion"
        }

        # Verify the credential can authenticate against the domain via LDAP
        # before attempting promotion.  Log group memberships for diagnostics.
        try {
            $domainDN = ($this.DomainName.Split('.') | ForEach-Object { "DC=$_" }) -join ','
            $networkPass = $this.Credential.GetNetworkCredential().Password
            $de = New-Object System.DirectoryServices.DirectoryEntry(
                "LDAP://$domainDN", $credUser, $networkPass)
            $searcher = New-Object System.DirectoryServices.DirectorySearcher($de)
            $searcher.Filter = "(&(objectClass=user)(sAMAccountName=$($this.Credential.GetNetworkCredential().UserName)))"
            $searcher.PropertiesToLoad.Add('memberOf') | Out-Null
            $searcher.PropertiesToLoad.Add('distinguishedName') | Out-Null
            $userResult = $searcher.FindOne()
            if ($userResult) {
                Write-Verbose "PromoteDomainController: LDAP bind succeeded for '$credUser'"
                $dn = $userResult.Properties['distinguishedname'][0]
                Write-Verbose "PromoteDomainController: User DN: $dn"
                $groups = @($userResult.Properties['memberof'])
                if ($groups.Count -gt 0) {
                    foreach ($g in $groups) {
                        Write-Verbose "PromoteDomainController: Member of: $g"
                    }
                    $isDomainAdmin = $groups | Where-Object { $_ -like 'CN=Domain Admins,*' }
                    $isEnterpriseAdmin = $groups | Where-Object { $_ -like 'CN=Enterprise Admins,*' }
                    if (-not $isDomainAdmin) {
                        Write-Verbose "PromoteDomainController: WARNING - '$credUser' is NOT in Domain Admins"
                    }
                    if (-not $isEnterpriseAdmin) {
                        Write-Verbose "PromoteDomainController: WARNING - '$credUser' is NOT in Enterprise Admins"
                    }
                }
                else {
                    Write-Verbose "PromoteDomainController: WARNING - No group memberships returned for '$credUser'"
                }
            }
            else {
                Write-Verbose "PromoteDomainController: WARNING - LDAP search found no user matching '$credUser'"
            }
        }
        catch {
            Write-Verbose "PromoteDomainController: LDAP pre-check failed: $_"
        }

        Write-Verbose "PromoteDomainController: Purging Kerberos ticket cache"
        & klist purge 2>&1 | Out-Null

        $params = @{
            DomainName                    = $this.DomainName
            SafeModeAdministratorPassword = $this.SafeModeAdministratorPassword.Password
            Credential                    = $this.Credential
            NoRebootOnCompletion          = $true
            Force                         = $true
            DatabasePath                  = $this.DatabasePath
            LogPath                       = $this.LogPath
            SysvolPath                    = $this.SysvolPath
            InstallDns                    = $this.InstallDns
        }

        if (-not $this.IsGlobalCatalog) {
            $params['NoGlobalCatalog'] = $true
        }

        Write-Verbose "PromoteDomainController: Calling Install-ADDSDomainController for domain '$($this.DomainName)'"

        # Snapshot error count so we can scrub errors added by the cmdlet.
        $errorsBefore = $global:Error.Count
        $sw = [System.Diagnostics.Stopwatch]::StartNew()

        # Use -ErrorAction SilentlyContinue and 2>&1 to prevent the
        # non-terminating credential-check warning from reaching the LCM's
        # error stream.  The -Force on Install-ADDSDomainController already
        # auto-answers the confirmation; we just need to keep the error
        # record out of DSC's view.
        try {
            Install-ADDSDomainController @params -ErrorAction SilentlyContinue 2>&1 | ForEach-Object {
                if ($_ -is [System.Management.Automation.ErrorRecord]) {
                    Write-Verbose "PromoteDomainController: (suppressed error) $($_.Exception.Message)"
                }
                else {
                    Write-Verbose "PromoteDomainController: $($_)"
                }
            }
        }
        catch {
            Write-Verbose "PromoteDomainController: Install-ADDSDomainController exception: $_"
        }
        $sw.Stop()
        Write-Verbose "PromoteDomainController: Install-ADDSDomainController completed in $($sw.Elapsed.ToString())"

        # If the call finished in under 60 seconds the promotion almost
        # certainly did not succeed (a real promotion takes 10-20 min).
        if ($sw.Elapsed.TotalSeconds -lt 60) {
            Write-Verbose "PromoteDomainController: WARNING - Completed too quickly; promotion likely failed"
        }

        # Scrub any error records added during the call so the LCM doesn't
        # report "threw one or more non-terminating errors".
        $errorsAdded = $global:Error.Count - $errorsBefore
        if ($errorsAdded -gt 0) {
            Write-Verbose "PromoteDomainController: Scrubbing $errorsAdded error record(s) from `$global:Error"
            for ($i = 0; $i -lt $errorsAdded; $i++) {
                $global:Error.RemoveAt(0)
            }
        }
        # Verify the promotion succeeded by checking the Netlogon SysVol key.
        $promotionVerified = $false
        try {
            $nlSysvol = Get-ItemPropertyValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon\Parameters' -Name 'SysVol' -ErrorAction Stop
            $domainSysVol = Join-Path $nlSysvol $this.DomainName
            if (Test-Path $domainSysVol) {
                $promotionVerified = $true
            }
        }
        catch {}
        $ditPath = Join-Path $this.DatabasePath 'ntds.dit'
        $postSvc = Get-Service -Name 'NTDS' -ErrorAction SilentlyContinue
        Write-Verbose "PromoteDomainController: Post-install - SysVol verified: $promotionVerified, ntds.dit exists: $(Test-Path $ditPath), NTDS: $(if ($postSvc) { $postSvc.Status } else { 'not found' })"
        if (-not $promotionVerified) {
            Write-Verbose "PromoteDomainController: WARNING - Netlogon SysVol key not present after Install-ADDSDomainController; promotion may have failed"
        }

        Write-Verbose "PromoteDomainController: Requesting reboot to complete promotion"
        $global:DSCMachineStatus = 1
    }

    [bool] Test() {
        Write-Verbose "PromoteDomainController: Testing DC status for '$env:COMPUTERNAME' in domain '$($this.DomainName)'"

        # Use the same check as the ADDomain resource from ActiveDirectoryDsc:
        # the Netlogon SysVol registry key is only written after a fully
        # successful DC promotion.  Install-WindowsFeature AD-Domain-Services
        # does NOT create it, so this reliably distinguishes 'role installed'
        # from 'actually promoted'.
        $promotionComplete = $false
        try {
            $nlSysvol = Get-ItemPropertyValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon\Parameters' -Name 'SysVol' -ErrorAction Stop
            $domainSysVol = Join-Path $nlSysvol $this.DomainName
            if (Test-Path $domainSysVol) {
                $promotionComplete = $true
                Write-Verbose "PromoteDomainController: Netlogon SysVol path '$domainSysVol' exists"
            }
            else {
                Write-Verbose "PromoteDomainController: Netlogon SysVol registry set but domain path '$domainSysVol' missing"
            }
        }
        catch {
            Write-Verbose "PromoteDomainController: Netlogon SysVol registry key not present - not promoted"
        }

        if (-not $promotionComplete) {
            Write-Verbose "PromoteDomainController: Promotion not complete - Set() required"
            return $false
        }

        # Promotion completed.  Return true only if NTDS is Running so that
        # downstream resources (DNS forwarders etc.) have a working AD.
        $svc = Get-Service -Name 'NTDS' -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq 'Running') {
            Write-Verbose "PromoteDomainController: NTDS is Running - fully promoted and operational"
            return $true
        }

        Write-Verbose "PromoteDomainController: Promotion complete but NTDS is $(if ($svc) { $svc.Status } else { 'not found' }) - needs start or reboot"
        return $false
    }

    [PromoteDomainController] Get() {
        return $this
    }
}


