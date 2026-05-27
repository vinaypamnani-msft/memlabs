<#
.SYNOPSIS
    Audits _filelist_develop.json for stale Microsoft / public component versions.

.DESCRIPTION
    Backwards-compatible drift detector for the master file inventory.

    Checks performed:
      1. ISO[] SQL CUs           - resolves cuUrl via the Microsoft Update
                                   Catalog and reports if the catalog shows
                                   a newer KB for the same product than the
                                   one currently recorded in cuKB.
      2. UrlsMeta fwlinks        - HEAD-resolves the fwlink and reports if
                                   the resolved filename differs from the
                                   one cached in .lastResolvedFilename.json
                                   (alongside this script). Also flags
                                   entries flagged rollingLatest=false but
                                   missing version/released metadata.
      3. Tools[] with SoftwareVersion - if URL is a GitHub release, queries
                                   the /releases/latest API and compares to
                                   SoftwareVersion.

    Designed to be safe and read-only. Honours -DryRun (default) vs -Update
    (rewrites the .lastResolvedFilename.json cache only). Never mutates the
    main JSON; that is left to the operator after they confirm drift is real.

.PARAMETER FilelistPath
    Path to _filelist_develop.json. Defaults to the sibling azureFiles copy.

.PARAMETER Section
    Limit checks to ISO, UrlsMeta, Tools, or All (default).

.PARAMETER Update
    Refresh the .lastResolvedFilename.json fwlink-resolution cache. Without
    this flag, the script reports drift but does not persist anything.

.EXAMPLE
    pwsh -File .\Check-FilelistUpdates.ps1
    Full read-only audit; prints a per-component report.

.EXAMPLE
    pwsh -File .\Check-FilelistUpdates.ps1 -Section ISO
    Only check SQL CU freshness.

.EXAMPLE
    pwsh -File .\Check-FilelistUpdates.ps1 -Apply
    Read-only audit followed by an interactive prompt to write detected
    changes back into the JSON. SQL CU entries with a 'cuNote' field are
    skipped (treated as manually controlled).

.EXAMPLE
    pwsh -File .\Check-FilelistUpdates.ps1 -Apply -Force
    Same as above but skips the confirmation prompt.

.NOTES
    Internet access required. Uses only built-in Invoke-WebRequest; no modules.
    Tolerant of the OLD format (entries without metadata are silently skipped
    rather than warned, so this script is safe to run against historical
    branches).
#>
[CmdletBinding()]
param(
    [string]$FilelistPath = (Join-Path $PSScriptRoot 'azureFiles\_filelist_develop.json'),
    [ValidateSet('All','ISO','UrlsMeta','Tools')]
    [string]$Section = 'All',
    [switch]$Update,
    [switch]$Apply,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $FilelistPath)) {
    throw "Filelist not found at $FilelistPath"
}

$cachePath = Join-Path (Split-Path -Parent $PSCommandPath) '.lastResolvedFilename.json'
$cache = @{}
if (Test-Path $cachePath) {
    try { $cache = Get-Content $cachePath -Raw | ConvertFrom-Json -AsHashtable } catch { $cache = @{} }
}

$json = Get-Content $FilelistPath -Raw | ConvertFrom-Json

# Collected during section scans; applied at the end if -Apply is set.
# Each entry: @{ Kind='ISO'|'Tool'; Name; Replacements=@(@{Old;New;Desc}) ; Todos=@('...') }
$script:ProposedChanges = @()

function Write-Drift {
    param([string]$Component, [string]$Current, [string]$Latest, [string]$Source)
    $msg = "  [DRIFT] {0,-30} current: {1,-25} latest: {2}" -f $Component, $Current, $Latest
    Write-Host $msg -ForegroundColor Yellow
    if ($Source) { Write-Host "          source: $Source" -ForegroundColor DarkGray }
}
function Write-Ok    { param([string]$m) Write-Host "  [ ok ] $m" -ForegroundColor DarkGreen }
function Write-Info  { param([string]$m) Write-Host "  [info] $m" -ForegroundColor DarkCyan }
function Write-Warn2 { param([string]$m) Write-Host "  [warn] $m" -ForegroundColor DarkYellow }
function Write-Dead  {
    param([string]$Component, [string]$Url, [string]$Reason, [string]$Source)
    Write-Host ("  [DEAD ] {0,-30} {1}" -f $Component, $Reason) -ForegroundColor Red
    Write-Host ("          url   : {0}" -f $Url) -ForegroundColor DarkGray
    if ($Source) { Write-Host ("          source: {0}" -f $Source) -ForegroundColor DarkGray }
    $script:DeadLinks += [pscustomobject]@{ Component=$Component; Url=$Url; Reason=$Reason }
}
$script:DeadLinks = @()

# Resolve a URL via HEAD, then sanity-check with a 1-byte ranged GET.
# Returns @{ Ok=$true/$false; Filename; ResolvedUrl; StatusCode; Reason }.
function Resolve-DownloadUrl {
    param([string]$Url, [int]$TimeoutSec = 30)
    $result = [ordered]@{ Ok=$false; Filename=$null; ResolvedUrl=$null; StatusCode=$null; Reason=$null }
    try {
        $resp = Invoke-WebRequest -Uri $Url -Method Head -UseBasicParsing -MaximumRedirection 10 -TimeoutSec $TimeoutSec
        $result.StatusCode  = [int]$resp.StatusCode
        $result.ResolvedUrl = $resp.BaseResponse.RequestMessage.RequestUri.AbsoluteUri
        $result.Filename    = [System.IO.Path]::GetFileName(([uri]$result.ResolvedUrl).LocalPath)
    } catch {
        $we = $_.Exception
        $status = $null
        if ($we.Response) { try { $status = [int]$we.Response.StatusCode } catch {} }
        $result.StatusCode = $status
        if ($status -in 404,410) {
            $result.Reason = "HTTP $status (link retired by publisher)"
        } elseif ($status) {
            $result.Reason = "HTTP $status on HEAD"
        } else {
            $result.Reason = "HEAD failed: $($we.Message)"
        }
        return $result
    }

    # HEAD succeeded. Some CDNs (notably go.microsoft.com/fwlink) 302 to a
    # final URL that itself 404s on real fetch -- HEAD against the landing
    # page can still return 200. Confirm with a 1-byte ranged GET.
    try {
        $req = [System.Net.HttpWebRequest]::Create($result.ResolvedUrl)
        $req.Method = 'GET'
        $req.Timeout = $TimeoutSec * 1000
        $req.AddRange(0, 0)
        $req.AllowAutoRedirect = $true
        $verify = $req.GetResponse()
        $verifyStatus = [int]$verify.StatusCode
        $verify.Close()
        if ($verifyStatus -ge 400) {
            $result.Reason = "Ranged GET returned HTTP $verifyStatus"
            return $result
        }
    } catch {
        $we = $_.Exception
        $status = $null
        if ($we.Response) { try { $status = [int]$we.Response.StatusCode } catch {} }
        if ($status -in 404,410) {
            $result.Reason = "Ranged GET HTTP $status (HEAD lied; content gone)"
            return $result
        }
        # Network blip on the verification probe -- don't fail loudly,
        # HEAD already succeeded so call it good.
    }

    # Heuristic: a download fwlink that lands on a docs/learn page is
    # almost always a retired link Microsoft redirected to an article.
    if ($result.ResolvedUrl -match '://(learn|docs)\.microsoft\.com/') {
        $result.Reason = "Redirected to docs page: $($result.ResolvedUrl) (likely retired)"
        return $result
    }

    $result.Ok = $true
    return $result
}

# -------------------------------------------------------------------------
# Microsoft Update Catalog helper - resolves a KB number to download URLs.
# Returns @{ KB; Title; Url } per matched download.
# -------------------------------------------------------------------------
function Get-MUCatalogResults {
    param([Parameter(Mandatory)][string]$Query)
    try {
        $search = Invoke-WebRequest -Uri "https://www.catalog.update.microsoft.com/Search.aspx?q=$Query" -UseBasicParsing -TimeoutSec 30
    } catch {
        Write-Warn2 "MU Catalog search failed for ${Query}: $($_.Exception.Message)"
        return @()
    }
    $ids    = @([regex]::Matches($search.Content, 'goToDetails\("([0-9a-f\-]+)"') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
    $titles = @([regex]::Matches($search.Content, '(?s)<a[^>]+goToDetails[^>]+>([^<]+)</a>') | ForEach-Object { $_.Groups[1].Value.Trim() })
    $results = for ($i = 0; $i -lt $ids.Count; $i++) {
        $id = $ids[$i]
        $title = if ($i -lt $titles.Count) { $titles[$i] } else { '' }
        $body = @{ updateIDs = "[{`"size`":0,`"languages`":`"`",`"uidInfo`":`"$id`",`"updateID`":`"$id`"}]" }
        try {
            $dl = Invoke-WebRequest -Uri 'https://www.catalog.update.microsoft.com/DownloadDialog.aspx' -Method Post -Body $body -UseBasicParsing -TimeoutSec 30
            $urls = [regex]::Matches($dl.Content, "downloadInformation\[\d+\]\.files\[\d+\]\.url\s*=\s*'([^']+)'") | ForEach-Object { $_.Groups[1].Value }
            foreach ($u in $urls) { [pscustomobject]@{ Query = $Query; Title = $title; Url = $u } }
        } catch {
            Write-Warn2 "DownloadDialog failed for ${id}: $($_.Exception.Message)"
        }
    }
    $results
}

function Get-KbFromCatalogQuery {
    param([string]$ProductLabel)
    $hits = Get-MUCatalogResults -Query $ProductLabel
    # Pick the newest KB. KB numbers in URLs are monotonically increasing.
    $kbList = $hits | ForEach-Object {
        if ($_.Url -match 'kb(\d{7})') { [int]$Matches[1] } else { 0 }
    } | Where-Object { $_ -gt 0 } | Sort-Object -Descending
    if (-not $kbList) { return $null }
    "KB$($kbList[0])"
}

# Returns the preferred direct download URL (x64 .exe) for a given KB,
# or $null if it can't be resolved.
function Get-KbDirectDownloadUrl {
    param([Parameter(Mandatory)][string]$KB, [string]$Prefer = 'x64')
    $hits = Get-MUCatalogResults -Query $KB
    if (-not $hits) { return $null }
    $matching = $hits | Where-Object { $_.Url -match [regex]::Escape($KB.ToLower()) }
    if (-not $matching) { $matching = $hits }
    $preferred = $matching | Where-Object { $_.Url -match $Prefer -and $_.Url -match '\.exe$' } | Select-Object -First 1
    if (-not $preferred) { $preferred = $matching | Where-Object { $_.Url -match '\.exe$' } | Select-Object -First 1 }
    if (-not $preferred) { $preferred = $matching | Select-Object -First 1 }
    if ($preferred) { return $preferred.Url } else { return $null }
}

# -------------------------------------------------------------------------
# 1. ISO[] SQL CUs
# -------------------------------------------------------------------------
function Test-ISOSection {
    Write-Host "`n=== ISO[] SQL CU freshness ===" -ForegroundColor Cyan
    foreach ($iso in $json.ISO) {
        if (-not $iso.cuUrl) { continue }
        if (-not $iso.cuKB)  { Write-Warn2 "$($iso.id): missing cuKB metadata - cannot compare"; continue }

        # Map ISO id -> Catalog product query
        $query = switch -Regex ($iso.id) {
            'SQL Server 2025' { 'SQL Server 2025 Cumulative Update'; break }
            'SQL Server 2022' { 'SQL Server 2022 Cumulative Update'; break }
            'SQL Server 2019' { 'SQL Server 2019 RTM CU';            break }
            'SQL Server 2017' { 'SQL Server 2017 RTM CU';            break }
            'SQL Server 2016' { 'SQL Server 2016 Service Pack 3 GDR'; break }
            default           { $null }
        }
        if (-not $query) { Write-Info "$($iso.id): no known catalog query, skipping"; continue }

        $latest = Get-KbFromCatalogQuery -ProductLabel $query
        if (-not $latest) { Write-Warn2 "$($iso.id): catalog query returned no results"; continue }

        if ($latest -ne $iso.cuKB) {
            $notesUrl = if ($iso.cuReleaseNotes) { $iso.cuReleaseNotes } else { '' }
            Write-Drift -Component $iso.id -Current $iso.cuKB -Latest $latest -Source $notesUrl

            # Collect proposed change for -Apply
            if ($iso.cuNote) {
                Write-Info "$($iso.id): cuNote field present - skipping auto-update (manual control)"
            } else {
                $newUrl = Get-KbDirectDownloadUrl -KB $latest
                if (-not $newUrl) {
                    Write-Warn2 "$($iso.id): could not resolve download URL for $latest, skipping auto-update"
                } else {
                    $script:ProposedChanges += [pscustomobject]@{
                        Kind         = 'ISO'
                        Name         = $iso.id
                        Replacements = @(
                            @{ Old = $iso.cuUrl; New = $newUrl;  Desc = 'cuUrl' }
                            @{ Old = $iso.cuKB;  New = $latest;  Desc = 'cuKB'  }
                        )
                        Todos        = @(
                            "cuVersion: update from current '$($iso.cuVersion)' (look up at $notesUrl)"
                            "cuReleased: update from current '$($iso.cuReleased)' (look up at $notesUrl)"
                            "cuReleaseNotes: update if URL pattern changed (was $notesUrl)"
                        )
                    }
                }
            }
        } else {
            Write-Ok ("{0,-20} {1} (v{2}, {3})" -f $iso.id, $iso.cuKB, $iso.cuVersion, $iso.cuReleased)
        }
    }
}

# -------------------------------------------------------------------------
# 2. UrlsMeta fwlinks
# -------------------------------------------------------------------------
function Test-UrlsMetaSection {
    Write-Host "`n=== UrlsMeta fwlink filename drift ===" -ForegroundColor Cyan
    if (-not $json.UrlsMeta) {
        Write-Warn2 "No UrlsMeta block present - JSON is in legacy format. Skipping section."
        return
    }
    $names = $json.UrlsMeta.PSObject.Properties.Name | Where-Object { $_ -notlike '_*' }
    foreach ($name in $names) {
        $meta = $json.UrlsMeta.$name
        $url  = $json.Urls.$name
        if (-not $url) { Write-Warn2 "${name}: in UrlsMeta but no corresponding Urls entry"; continue }
        if ($meta.rollingLatest) {
            Write-Info ("{0,-15} rollingLatest=true (intentional, no drift check)" -f $name)
            continue
        }
        $probe = Resolve-DownloadUrl -Url $url
        if (-not $probe.Ok) {
            Write-Dead -Component $name -Url $url -Reason $probe.Reason -Source $meta.releaseNotes
            continue
        }
        $filename = $probe.Filename

        $cachedFilename = $cache[$name]
        if (-not $cachedFilename) {
            Write-Info ("{0,-15} first seen: {1}" -f $name, $filename)
        } elseif ($cachedFilename -ne $filename) {
            Write-Drift -Component $name -Current $cachedFilename -Latest $filename -Source $meta.releaseNotes
        } else {
            Write-Ok ("{0,-15} {1} (v{2}, {3})" -f $name, $filename, $meta.version, $meta.released)
        }
        $cache[$name] = $filename
    }
}

# -------------------------------------------------------------------------
# 3. Tools[] from GitHub
# -------------------------------------------------------------------------
function Test-ToolsSection {
    Write-Host "`n=== Tools[] GitHub release drift ===" -ForegroundColor Cyan
    foreach ($tool in $json.Tools) {
        if (-not $tool.IsPublic)       { continue }
        if (-not $tool.URL)            { continue }
        if ($tool.URL -notmatch '^https?://github\.com/([^/]+/[^/]+)/releases/') { continue }
        $repo = $Matches[1]
        try {
            $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/latest" `
                    -UserAgent 'MemLabs-FilelistChecker' -TimeoutSec 30
        } catch {
            Write-Warn2 "$($tool.Name) ($repo): GitHub API failed: $($_.Exception.Message)"
            continue
        }
        $latestTag = $rel.tag_name
        $current   = if ($tool.SoftwareVersion) { $tool.SoftwareVersion }
                     elseif ($tool.URL -match '/download/([^/]+)/') { $Matches[1] }
                     else { '<unknown>' }
        # Loose match: strip leading 'v' and compare
        $normCur = ($current -replace '^v','').Trim()
        $normNew = ($latestTag -replace '^v','').Trim()
        if ($normCur -ne $normNew) {
            Write-Drift -Component $tool.Name -Current $current -Latest $latestTag -Source "https://github.com/$repo/releases/latest"

            # Find an asset whose download_url contains the new tag (so we
            # can swap URL + md5 + SoftwareVersion). Fall back to extension
            # match if the tag isn't literally in any asset name.
            $oldFileName = [System.IO.Path]::GetFileName(([uri]$tool.URL).LocalPath)
            $oldExt = [System.IO.Path]::GetExtension($oldFileName)
            $candidate = $rel.assets | Where-Object {
                $_.name -like "*$normNew*" -and [System.IO.Path]::GetExtension($_.name) -eq $oldExt
            } | Select-Object -First 1
            if (-not $candidate) {
                $candidate = $rel.assets | Where-Object {
                    [System.IO.Path]::GetExtension($_.name) -eq $oldExt
                } | Select-Object -First 1
            }
            if (-not $candidate) {
                Write-Warn2 "$($tool.Name): could not find a $oldExt asset in $latestTag - skipping auto-update"
                continue
            }
            $newUrl = $candidate.browser_download_url
            $todos  = @()
            $replacements = @(
                @{ Old = $tool.URL; New = $newUrl; Desc = 'URL' }
            )
            if ($tool.SoftwareVersion) {
                $replacements += @{ Old = $tool.SoftwareVersion; New = $normNew; Desc = 'SoftwareVersion' }
            }
            # ExtractFolderIfZip-style Target sometimes embeds the version
            if ($tool.Target -and $tool.Target -match [regex]::Escape($normCur)) {
                $replacements += @{ Old = $tool.Target; New = ($tool.Target -replace [regex]::Escape($normCur), $normNew); Desc = 'Target' }
            }
            # AppMsi commonly embeds the version
            if ($tool.AppMsi -and $tool.AppMsi -match [regex]::Escape($normCur)) {
                $replacements += @{ Old = $tool.AppMsi; New = ($tool.AppMsi -replace [regex]::Escape($normCur), $normNew); Desc = 'AppMsi' }
            }

            # MD5 needs the file - defer download until -Apply.
            $script:ProposedChanges += [pscustomobject]@{
                Kind         = 'Tool'
                Name         = $tool.Name
                Replacements = $replacements
                NewUrl       = $newUrl     # for MD5 download at apply time
                OldMd5       = $tool.md5
                Todos        = $todos
            }
        } else {
            Write-Ok ("{0,-30} {1}" -f $tool.Name, $latestTag)
        }
    }
}

# -------------------------------------------------------------------------
# Apply collected changes back to the JSON file (text-level replacement
# to preserve formatting, tabs, comments, ordering).
# -------------------------------------------------------------------------
function Invoke-ApplyChanges {
    if (-not $script:ProposedChanges) {
        Write-Host "`nNo auto-applicable changes detected." -ForegroundColor DarkGreen
        return
    }

    Write-Host "`n=== Proposed changes ($($script:ProposedChanges.Count)) ===" -ForegroundColor Cyan
    foreach ($c in $script:ProposedChanges) {
        Write-Host "  [$($c.Kind)] $($c.Name)" -ForegroundColor White
        foreach ($r in $c.Replacements) {
            $oldShort = if ($r.Old.Length -gt 70) { $r.Old.Substring(0,67) + '...' } else { $r.Old }
            $newShort = if ($r.New.Length -gt 70) { $r.New.Substring(0,67) + '...' } else { $r.New }
            Write-Host ("    {0,-16} {1}" -f $r.Desc, $oldShort) -ForegroundColor DarkGray
            Write-Host ("    {0,-16} {1}" -f '             ->', $newShort) -ForegroundColor Green
        }
        if ($c.Kind -eq 'Tool') {
            Write-Host ("    {0,-16} {1}" -f 'md5', $c.OldMd5) -ForegroundColor DarkGray
            Write-Host ("    {0,-16} (will be recomputed after download)" -f '             ->') -ForegroundColor Green
        }
        foreach ($t in $c.Todos) {
            Write-Host "    TODO: $t" -ForegroundColor DarkYellow
        }
    }

    if (-not $Force) {
        $answer = Read-Host "`nApply these changes to $FilelistPath ? (y/N)"
        if ($answer -notmatch '^[yY]') {
            Write-Host "Aborted - no changes written." -ForegroundColor Yellow
            return
        }
    }

    # For each Tool change: download the new file to a temp path and compute MD5.
    foreach ($c in $script:ProposedChanges | Where-Object Kind -eq 'Tool') {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "memlabs-checker-$([guid]::NewGuid().Guid).tmp"
        try {
            Write-Host "  Downloading $($c.Name) to compute MD5 ..." -ForegroundColor DarkCyan
            Invoke-WebRequest -Uri $c.NewUrl -OutFile $tmp -UseBasicParsing -TimeoutSec 600
            $newMd5 = (Get-FileHash -Path $tmp -Algorithm MD5).Hash.ToUpper()
            if ($c.OldMd5) {
                $c.Replacements += @{ Old = $c.OldMd5; New = $newMd5; Desc = 'md5' }
            }
        } catch {
            Write-Warn2 "$($c.Name): download failed - skipping md5 update: $($_.Exception.Message)"
        } finally {
            if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
        }
    }

    # Apply replacements to raw text. Each old value must occur exactly once
    # in the file so we never mutate an unrelated entry.
    $raw     = Get-Content $FilelistPath -Raw
    $applied = 0
    $skipped = 0
    foreach ($c in $script:ProposedChanges) {
        foreach ($r in $c.Replacements) {
            if ($r.Old -eq $r.New) { continue }
            $count = ([regex]::Matches($raw, [regex]::Escape($r.Old))).Count
            if ($count -eq 0) {
                Write-Warn2 "$($c.Name)/$($r.Desc): old value not found in file - skipped"
                $skipped++
            } elseif ($count -gt 1) {
                Write-Warn2 "$($c.Name)/$($r.Desc): old value occurs $count times - ambiguous, skipped"
                $skipped++
            } else {
                $raw = $raw.Replace($r.Old, $r.New)
                $applied++
            }
        }
    }

    if ($applied -eq 0) {
        Write-Host "No replacements applied." -ForegroundColor Yellow
        return
    }

    # Backup, then write.
    $backup = "$FilelistPath.bak"
    Copy-Item -Path $FilelistPath -Destination $backup -Force
    Set-Content -Path $FilelistPath -Value $raw -NoNewline -Encoding UTF8

    # Sanity: must still parse as JSON.
    try {
        $null = Get-Content $FilelistPath -Raw | ConvertFrom-Json
    } catch {
        Write-Host "JSON validation FAILED after write - restoring backup: $($_.Exception.Message)" -ForegroundColor Red
        Copy-Item -Path $backup -Destination $FilelistPath -Force
        return
    }

    Write-Host "`n$applied replacement(s) applied, $skipped skipped." -ForegroundColor Green
    Write-Host "Backup: $backup" -ForegroundColor DarkGray
}

# -------------------------------------------------------------------------
# Main
# -------------------------------------------------------------------------
Write-Host "Filelist: $FilelistPath" -ForegroundColor White
Write-Host "Section : $Section" -ForegroundColor White
$modeText = if ($Apply) { 'APPLY (will prompt before writing)' }
            elseif ($Update) { 'UPDATE (cache will be rewritten)' }
            else { 'READ-ONLY (use -Update for cache, -Apply to write changes)' }
Write-Host "Mode    : $modeText" -ForegroundColor White

if ($Section -in 'All','ISO')      { Test-ISOSection }
if ($Section -in 'All','UrlsMeta') { Test-UrlsMetaSection }
if ($Section -in 'All','Tools')    { Test-ToolsSection }

if ($Apply) {
    Invoke-ApplyChanges
}

if ($Update) {
    $cache | ConvertTo-Json | Set-Content -Path $cachePath -Encoding UTF8
    Write-Host "`nCache written to $cachePath" -ForegroundColor Green
} elseif (Test-Path $cachePath) {
    Write-Host "`nCache untouched (read-only). Re-run with -Update to refresh." -ForegroundColor DarkGray
}

if ($script:DeadLinks.Count -gt 0) {
    Write-Host "`n=== DEAD LINKS ($($script:DeadLinks.Count)) ===" -ForegroundColor Red
    foreach ($d in $script:DeadLinks) {
        Write-Host ("  {0,-25} {1}" -f $d.Component, $d.Reason) -ForegroundColor Red
        Write-Host ("  {0,-25} {1}" -f '', $d.Url) -ForegroundColor DarkGray
    }
    Write-Host "`nFix: locate the publisher's current download page, grab the new fwlink/URL," -ForegroundColor Yellow
    Write-Host "     and update Urls + UrlsMeta entries in $FilelistPath." -ForegroundColor Yellow
    $global:LASTEXITCODE = 2
} else {
    Write-Host "`nAll probed URLs reachable." -ForegroundColor DarkGreen
}
