# Fix-RunSQL: run SQLFix-Compat.sql against every installed SQL instance.
# Inject the SQL file into C:\staging via InjectFiles before this runs.

$Fix_RunSQL = {
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
                $sqlOutput = & sqlcmd -S $sqlInstanceName -i $SqlFilePath -C -b 2>&1
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

$fixesToPerform += [PSCustomObject]@{
    FixName           = "Fix-RunSQL"
    FixVersion        = "260616"
    AppliesToNew      = $true
    AppliesToExisting = $true
    AppliesToRoles    = @()
    NotAppliesToRoles = @("OSDClient", "AADClient", "WorkgroupMember", "InternetClient", "DC", "BDC")
    DependentVMs      = @()
    ScriptBlock       = $Fix_RunSQL
    RunAsAccount      = $vmNote.adminName
    InjectFiles       = @("SQLFix-Compat.sql") # must exist in filesToInject\staging dir
}
