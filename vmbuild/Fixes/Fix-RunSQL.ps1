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
    foreach ($instance in $instances) {
        $sqlInstanceName = if ($instance -eq 'MSSQLSERVER') { '.' } else { ".\$instance" }
        Write-FixLog "Running SQLFix-Compat.sql against $sqlInstanceName"
        try {
            sqlcmd -S $sqlInstanceName -i $SqlFilePath -C 1>$null 2>$null
            $ran++
        }
        catch {
            $errs += "sqlcmd failed on ${sqlInstanceName}: $($_.Exception.Message)"
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
    FixVersion        = "260117"
    AppliesToNew      = $true
    AppliesToExisting = $true
    AppliesToRoles    = @()
    NotAppliesToRoles = @("OSDClient", "Linux", "AADClient", "WorkgroupMember", "InternetClient", "DC", "BDC")
    DependentVMs      = @()
    ScriptBlock       = $Fix_RunSQL
    RunAsAccount      = $vmNote.adminName
    InjectFiles       = @("SQLFix-Compat.sql") # must exist in filesToInject\staging dir
}
