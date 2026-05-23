# Fix-ConfigureSSMS: run Configure-SSMS.ps1 once (registered server list,
# trust-cert, etc.) and register a logon task so future logons re-run it.

$Fix_ConfigureSSMS = {
    $taskName = 'ConfigureSSMS'
    $filePath = "$env:systemdrive\staging\Configure-SSMS.ps1"

    # Only apply if SSMS is installed (any 18..21 layout)
    $ssmsRoots = 18..21 | ForEach-Object { "C:\Program Files (x86)\Microsoft SQL Server Management Studio $_\Common7\IDE\ssms.exe" }
    $ssmsInstalled = $ssmsRoots | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $ssmsInstalled) {
        return [pscustomobject]@{ Success = $true; Message = 'SSMS not installed - skipping' }
    }

    $errs = @()

    # Run the script immediately (Phase 10 runs as admin, so %APPDATA% is correct)
    if (Test-Path $filePath) {
        try {
            & $filePath
            Write-FixLog "Ran Configure-SSMS.ps1 against $ssmsInstalled"
        }
        catch {
            $errs += "Configure-SSMS.ps1 threw: $($_.Exception.Message)"
            Write-FixLog $errs[-1] -Level Failure
        }
    }
    else {
        $errs += "Configure-SSMS.ps1 not found at $filePath"
    }

    # Register logon task so future logons pick up newly added SQL servers
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false | Out-Null
    }

    $taskCommand = 'cmd'
    $taskArgs = "/c start /min C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -WindowStyle Hidden -NonInteractive -Executionpolicy unrestricted -file $filePath"
    $action    = New-ScheduledTaskAction -Execute $taskCommand -Argument $taskArgs
    $trigger   = New-ScheduledTaskTrigger -AtLogOn
    $principal = New-ScheduledTaskPrincipal -GroupId Users -RunLevel Highest
    $definition = New-ScheduledTask -Action $action -Principal $principal -Trigger $trigger -Description 'Configure SSMS Registered Servers'

    Register-ScheduledTask -TaskName $taskName -InputObject $definition | Out-Null
    $taskOk = [bool](Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)
    if (-not $taskOk) {
        $errs += "Scheduled task '$taskName' not present after Register-ScheduledTask"
    }

    [pscustomobject]@{
        Success = ($errs.Count -eq 0)
        Message = if ($taskOk) { "Configure-SSMS scheduled task registered" } else { "Configure-SSMS task registration failed" }
        Errors  = $errs
    }
}

$fixesToPerform += [PSCustomObject]@{
    FixName           = "Fix-ConfigureSSMS"
    FixVersion        = "260522"
    AppliesToNew      = $true
    AppliesToExisting = $true
    AppliesToRoles    = @()
    NotAppliesToRoles = @("OSDClient", "Linux", "AADClient", "WorkgroupMember", "InternetClient", "DC", "BDC")
    DependentVMs      = @()
    ScriptBlock       = $Fix_ConfigureSSMS
    RunAsAccount      = $vmNote.adminName
    InjectFiles       = @("Configure-SSMS.ps1") # must exist in filesToInject\staging dir
}
