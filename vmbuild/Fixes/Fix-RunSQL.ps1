# Fix-RunSQL: run SQLFix-Compat.sql against every installed SQL instance.
# Inject the SQL file into C:\staging via InjectFiles before this runs.
# CMSupports170 (1 only when the top-level site server's cmOptions.version is
# >= 2603) is forwarded to the SQL script, which raises CM_xxx databases to
# compat level 170 when that AND SQL 2025+ are both true, otherwise aligns
# them to 150.

$Fix_RunSQL = {
    param([int]$CMSupports170 = 0)
    $SqlFilePath = "$env:systemdrive\staging\SQLFix-Compat.sql"
    if (-not (Test-Path $SqlFilePath)) {
        return [pscustomobject]@{ Success = $true; Message = 'No SQLFix-Compat.sql present - skipping' }
    }
    $regPath = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL"
    if (-not (Test-Path $regPath)) {
        return [pscustomobject]@{ Success = $true; Message = 'No SQL instances installed - skipping' }
    }
    $instances = (Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue).PSObject.Properties |
        Where-Object { $_.MemberType -eq 'NoteProperty' -and $_.Name -notin 'PSPath','PSParentPath','PSChildName','PSDrive','PSProvider' } |
        Select-Object -ExpandProperty Name
    if (-not $instances) {
        return [pscustomobject]@{ Success = $true; Message = 'No SQL instances found in registry - skipping' }
    }

    $ran = 0; $errs = @()
    $maxAttempts = 3
    foreach ($instance in $instances) {
        $sqlInstanceName = if ($instance -eq 'MSSQLSERVER') { '.' } else { ".\$instance" }
        $succeeded = $false
        $lastDetail = ''
        for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
            Write-FixLog "Running SQLFix-Compat.sql against $sqlInstanceName (attempt $attempt/$maxAttempts)"
            try {
                # sqlcmd reports failures via exit code, not exceptions, so check
                # $LASTEXITCODE rather than relying on catch. -b makes sqlcmd return
                # a non-zero exit on SQL errors (severity >= 11). Capture stderr for
                # diagnostics. SQL may still be starting at Phase 10, so retry
                # transient connection failures with backoff.
                $sqlOutput = & sqlcmd -S $sqlInstanceName -i $SqlFilePath -C -b -v CMSupports170=$CMSupports170 2>&1
                if ($LASTEXITCODE -eq 0) {
                    $ran++
                    $succeeded = $true
                    break
                }
                $lastDetail = ($sqlOutput | Out-String).Trim()
                Write-FixLog "sqlcmd exit=$LASTEXITCODE on ${sqlInstanceName} attempt ${attempt}: $lastDetail" -Level Warning
            }
            catch {
                $lastDetail = $_.Exception.Message
                Write-FixLog "sqlcmd threw on ${sqlInstanceName} attempt ${attempt}: $lastDetail" -Level Warning
            }
            if ($attempt -lt $maxAttempts) { Start-Sleep -Seconds (10 * $attempt) }
        }
        if (-not $succeeded) {
            $errs += "sqlcmd failed on ${sqlInstanceName} after $maxAttempts attempts: $lastDetail"
            Write-FixLog $errs[-1] -Level Failure
        }
    }
    [pscustomobject]@{
        Success = ($errs.Count -eq 0)
        Message = "Ran against $ran of $($instances.Count) instance(s)"
        Errors  = $errs
    }
}

# Decide whether THIS SQL box is new enough (CM 2603+) for SQL compat 170.
# CRITICAL: a single domain can host multiple, independently-versioned CM
# hierarchies (e.g. a 2509 CAS hierarchy AND a 2603 standalone Primary), so we
# must NOT take a domain-wide max version. Instead resolve which site server's
# database lives on THIS SQL box -- local SQL (this VM is the site server) or a
# site server whose remoteSQLVM / AlwaysOnListener points here -- then walk up
# to the TOP of THAT one hierarchy and read its cmOptions.version (cmOptions is
# written only on the top-level CAS / standalone Primary). The "SQL >= 2025"
# half is enforced in SQLFix-Compat.sql. Conservative on any error / unresolved
# owner: 0 => align to 150.
$cmSupports170 = 0
try {
    # One host-wide note snapshot.
    $allNotes = @()
    foreach ($hvm in (Get-VM -ErrorAction SilentlyContinue)) {
        if ($hvm.Notes -notlike '*"role"*') { continue }
        $n = $null
        try { $n = $hvm.Notes | ConvertFrom-Json } catch { continue }
        if ($n) { $allNotes += $n }
    }

    $myName   = $vmNote.vmName
    $myAOList = $vmNote.AlwaysOnListenerName

    # Tolerant name compare (handles prefixed vs short forms either direction).
    $nameMatches = {
        param($ref, $target)
        if (-not $ref -or -not $target) { return $false }
        return ($ref -eq $target) -or ($ref -like "*-$target") -or ($target -like "*-$ref")
    }

    # 1) Which site server(s) keep a database on this SQL box?
    $owners = @()
    if ($vmNote.role -in @('CAS', 'Primary', 'Secondary') -and $vmNote.siteCode) {
        $owners += $vmNote                                  # local SQL on the site server itself
    }
    foreach ($s in $allNotes) {
        if ($s.role -notin @('CAS', 'Primary', 'Secondary')) { continue }
        if (-not $s.remoteSQLVM) { continue }
        if ((& $nameMatches $s.remoteSQLVM $myName) -or ($myAOList -and (& $nameMatches $s.remoteSQLVM $myAOList))) {
            $owners += $s
        }
    }

    # 2) Walk EACH owning site up to the TOP of ITS hierarchy and read the
    #    governing cmOptions.version. Same-domain parent first, then host-wide
    #    so a cross-domain child site still finds its CAS.
    foreach ($owner in $owners) {
        $top = $owner
        $guard = 0
        while ($top.parentSiteCode -and $guard -lt 10) {
            $guard++
            $parent = $allNotes | Where-Object {
                $_.siteCode -eq $top.parentSiteCode -and $_.role -in @('CAS', 'Primary') -and $_.domain -eq $top.domain
            } | Select-Object -First 1
            if (-not $parent) {
                $parent = $allNotes | Where-Object {
                    $_.siteCode -eq $top.parentSiteCode -and $_.role -in @('CAS', 'Primary')
                } | Select-Object -First 1
            }
            if (-not $parent) { break }
            $top = $parent
        }
        if ($top.cmOptions -and $top.cmOptions.version) {
            $v = 0
            if ([int]::TryParse([string]$top.cmOptions.version, [ref]$v) -and $v -ge 2603) {
                $cmSupports170 = 1
            }
        }
    }
}
catch {}

$fixesToPerform += [PSCustomObject]@{
    FixName           = "Fix-RunSQL"
    FixVersion        = "260625"
    NeededOnFreshDeploy = $true
    AppliesToExisting   = $true
    AppliesToRoles    = @()
    NotAppliesToRoles = @("OSDClient", "AADClient", "WorkgroupMember", "InternetClient", "DC", "BDC")
    DependentVMs      = @()
    ScriptBlock       = $Fix_RunSQL
    ArgumentList      = @($cmSupports170)
    RunAsAccount      = $vmNote.adminName
    InjectFiles       = @("SQLFix-Compat.sql") # must exist in filesToInject\staging dir
}
