# Fix-DisableIEESC: register a logon scheduled task that disables IE Enhanced
# Security Configuration for all users (server SKUs only).

$Fix_DisableIEESC = {
    $os = Get-CimInstance -Class Win32_OperatingSystem -ErrorAction SilentlyContinue
    if (-not $os) {
        return [pscustomobject]@{ Success = $false; Message = 'Could not query Win32_OperatingSystem' }
    }
    if ($os.ProductType -eq 1) {
        return [pscustomobject]@{ Success = $true; Message = 'Workstation OS - fix not applicable' }
    }

    $taskName = 'Disable-IEESC'
    $filePath = "$env:systemdrive\staging\Disable-IEESC.ps1"

    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false | Out-Null
    }

    $taskCommand = 'cmd'
    $taskArgs = "/c start /min C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -WindowStyle Hidden -NonInteractive -Executionpolicy unrestricted -file $filePath"
    $action    = New-ScheduledTaskAction -Execute $taskCommand -Argument $taskArgs
    $trigger   = New-ScheduledTaskTrigger -AtLogOn
    $principal = New-ScheduledTaskPrincipal -GroupId Users -RunLevel Highest
    $definition = New-ScheduledTask -Action $action -Principal $principal -Trigger $trigger -Description 'Disable IE Enhanced Security'

    Register-ScheduledTask -TaskName $taskName -InputObject $definition | Out-Null
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        [pscustomobject]@{ Success = $true; Message = "Scheduled task '$taskName' registered" }
    }
    else {
        [pscustomobject]@{ Success = $false; Message = "Scheduled task '$taskName' not present after Register-ScheduledTask" }
    }
}

$fixesToPerform += [PSCustomObject]@{
    FixName           = "Fix-DisableIEESC"
    FixVersion        = "220422"
    AppliesToNew      = $true
    AppliesToExisting = $true
    AppliesToRoles    = @()
    NotAppliesToRoles = @("OSDClient", "Linux", "AADClient")
    DependentVMs      = @()
    ScriptBlock       = $Fix_DisableIEESC
    RunAsAccount      = $vmNote.adminName
    InjectFiles       = @("Disable-IEESC.ps1") # must exist in filesToInject\staging dir
}
