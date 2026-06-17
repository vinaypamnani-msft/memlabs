# Fix-SQLAOBackupJobs: repair MemLabs SQLAO Ola Hallengren backup agent job
# steps that have an unquoted NUL token (parses as a column reference -> job
# fails with "Invalid column name 'NUL'"). The fix injects a small SQL file
# and runs it against the default instance via sqlcmd. Idempotent in SQL.

$Fix_SQLAOBackupJobs = {
    $SqlFilePath = "$env:systemdrive\staging\SQLAOBackupJobs-Fix.sql"
    if (-not (Test-Path $SqlFilePath)) {
        return [pscustomobject]@{ Success = $true; Message = 'No SQLAOBackupJobs-Fix.sql present - skipping' }
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
            Write-FixLog "Running SQLAOBackupJobs-Fix.sql against $sqlInstanceName (attempt $attempt/$maxAttempts)"
            try {
                $sqlOutput = & sqlcmd -S $sqlInstanceName -i $SqlFilePath -C -b 2>&1
                if ($LASTEXITCODE -eq 0) {
                    $ran++
                    $succeeded = $true
                    $detail = ($sqlOutput | Out-String).Trim()
                    if ($detail) { Write-FixLog $detail }
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
    FixName           = "Fix-SQLAOBackupJobs"
    FixVersion        = "260617"
    AppliesToNew      = $false
    AppliesToExisting = $true
    AppliesToRoles    = @("SQLAO")
    NotAppliesToRoles = @()
    DependentVMs      = @()
    ScriptBlock       = $Fix_SQLAOBackupJobs
    RunAsAccount      = $vmNote.adminName
    InjectFiles       = @("SQLAOBackupJobs-Fix.sql") # must exist in filesToInject\staging dir
}
