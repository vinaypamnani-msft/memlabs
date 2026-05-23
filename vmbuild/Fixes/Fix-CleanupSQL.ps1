# Fix-CleanupSQL: daily 3am scheduled task that trims SQL logs/backups.
# Server SKUs only.

$Fix_CleanupSQL = {
    $os = Get-CimInstance -Class Win32_OperatingSystem -ErrorAction SilentlyContinue
    if (-not $os) {
        return [pscustomobject]@{ Success = $false; Message = 'Could not query Win32_OperatingSystem' }
    }
    if ($os.ProductType -eq 1) {
        return [pscustomobject]@{ Success = $true; Message = 'Workstation OS - fix not applicable' }
    }

    $taskName = 'MemLabs Cleanup SQL'
    $filePath = "$env:systemdrive\staging\Cleanup-SQL.ps1"

    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false | Out-Null
    }

    $taskCommand = 'cmd'
    $taskArgs = "/c start /min C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -WindowStyle Hidden -NonInteractive -Executionpolicy unrestricted -file $filePath"
    $action    = New-ScheduledTaskAction -Execute $taskCommand -Argument $taskArgs
    $trigger   = New-ScheduledTaskTrigger -Daily -At 3am
    $principal = New-ScheduledTaskPrincipal -UserId 'System'
    $definition = New-ScheduledTask -Action $action -Principal $principal -Trigger $trigger -Description 'Cleanup SQL'

    Register-ScheduledTask -TaskName $taskName -InputObject $definition | Out-Null
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        [pscustomobject]@{ Success = $true; Message = "Scheduled task '$taskName' registered" }
    }
    else {
        [pscustomobject]@{ Success = $false; Message = "Scheduled task '$taskName' not present after Register-ScheduledTask" }
    }
}

$fixesToPerform += [PSCustomObject]@{
    FixName           = "Fix-CleanupSQL"
    FixVersion        = "241124"
    AppliesToNew      = $true
    AppliesToExisting = $true
    AppliesToRoles    = @()
    NotAppliesToRoles = @("OSDClient", "Linux", "AADClient")
    DependentVMs      = @()
    ScriptBlock       = $Fix_CleanupSQL
    RunAsAccount      = $vmNote.adminName
    InjectFiles       = @("Cleanup-SQL.ps1") # must exist in filesToInject\staging dir
}
