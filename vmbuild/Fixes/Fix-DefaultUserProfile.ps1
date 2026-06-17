# Fix-DefaultUserProfile: clear stale IE/Edge WebCache from the default user
# profile so new logons don't inherit a corrupted ESE database.

$Fix_DefaultProfile = {
    # Content.IE5 (under INetCache) has restrictive ACLs + system/hidden attrs
    # that block Remove-Item even with -Force. Take ownership + grant rights,
    # then retry. Cleanup is best-effort so partial failure isn't fatal.
    $paths = @(
        'C:\Users\Default\AppData\Local\Microsoft\Windows\WebCache',
        'C:\Users\Default\AppData\Local\Microsoft\Windows\INetCache',
        'C:\Users\Default\AppData\Local\Microsoft\Windows\WebCacheLock.dat'
    )
    $removed = 0
    $warns = @()

    function Remove-StubbornPath {
        param([string]$Path)
        try {
            Remove-Item -Path $Path -Force -Recurse -ErrorAction Stop | Out-Null
            return $true
        }
        catch {
            # Reset attrs, take ownership, grant Administrators full control, retry
            try { & cmd.exe /c "attrib -r -s -h `"$Path`" /s /d" 2>&1 | Out-Null } catch {}
            try { & takeown.exe /F $Path /R /A /D Y 2>&1 | Out-Null } catch {}
            try { & icacls.exe $Path /grant "*S-1-5-32-544:(OI)(CI)F" /T /C /Q 2>&1 | Out-Null } catch {}
            try {
                Remove-Item -Path $Path -Force -Recurse -ErrorAction Stop | Out-Null
                return $true
            }
            catch {
                # Still locked: kill processes that commonly hold WebCache handles
                # (iexplore, MicrosoftEdge*, dllhost COM surrogate, taskhostw),
                # stop the WebCache service if running, then try rd /s /q.
                $procs = 'iexplore', 'MicrosoftEdge', 'msedge', 'MicrosoftEdgeCP',
                'MicrosoftEdgeSH', 'dllhost', 'taskhostw', 'explorer'
                foreach ($pn in $procs) {
                    try { Get-Process -Name $pn -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue } catch {}
                }
                try { Stop-Service -Name 'WebClient' -Force -ErrorAction SilentlyContinue } catch {}
                # Final fallback: rd /s /q (handles some locked dirs Remove-Item won't)
                & cmd.exe /c "rd /s /q `"$Path`"" 2>&1 | Out-Null
                if (-not (Test-Path $Path)) { return $true }
                # Last-ditch: rename out of the way; new logons get a fresh dir
                try {
                    $stamp = Get-Date -Format 'yyyyMMddHHmmss'
                    Rename-Item -LiteralPath $Path -NewName ("$(Split-Path $Path -Leaf).old.$stamp") -Force -ErrorAction Stop
                    return $true
                }
                catch { return $false }
            }
        }
    }

    foreach ($p in $paths) {
        if (Test-Path $p) {
            if (Remove-StubbornPath -Path $p) {
                $removed++
            }
            else {
                $warns += "Could not fully remove ${p} (best-effort cleanup)"
            }
        }
    }
    [pscustomobject]@{
        Success = $true   # best-effort; never fail the maintenance batch over this
        Message = if ($warns.Count) {
            "Removed $removed default-profile cache item(s); $($warns.Count) warning(s)"
        } else {
            "Removed $removed default-profile cache item(s)"
        }
        Errors  = $warns
    }
}

$fixesToPerform += [PSCustomObject]@{
    FixName           = "Fix-DefaultUserProfile"
    FixVersion        = "211128"
    NeededOnFreshDeploy = $false
    AppliesToExisting   = $true
    AppliesToRoles    = @()
    NotAppliesToRoles = @("OSDClient", "AADClient")
    DependentVMs      = @()
    ScriptBlock       = $Fix_DefaultProfile
}
