# Fix-EnableLogMachine: register the at-logon scheduled task that wires up
# .log file associations + tracing paths via Enable-LogMachine.ps1.

$Fix_EnableLogMachine = {
    $taskName = 'EnableLogMachine'
    $filePath = "$env:systemdrive\staging\Enable-LogMachine.ps1"

    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false | Out-Null
    }

    $taskCommand = 'cmd'
    $taskArgs = "/c start /min C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -WindowStyle Hidden -NonInteractive -Executionpolicy unrestricted -file $filePath"
    $action    = New-ScheduledTaskAction -Execute $taskCommand -Argument $taskArgs
    $trigger   = New-ScheduledTaskTrigger -AtLogOn
    $principal = New-ScheduledTaskPrincipal -GroupId Users -RunLevel Highest
    $definition = New-ScheduledTask -Action $action -Principal $principal -Trigger $trigger -Description 'Enable Log Machine'

    Register-ScheduledTask -TaskName $taskName -InputObject $definition | Out-Null
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        [pscustomobject]@{ Success = $true; Message = "Scheduled task '$taskName' registered" }
    }
    else {
        [pscustomobject]@{ Success = $false; Message = "Scheduled task '$taskName' not present after Register-ScheduledTask" }
    }
}

$fixesToPerform += [PSCustomObject]@{
    FixName           = "Fix-EnableLogMachine"
    FixVersion        = "250522"
    NeededOnFreshDeploy = $true
    AppliesToExisting   = $true
    AppliesToRoles    = @()
    NotAppliesToRoles = @("OSDClient", "AADClient")
    DependentVMs      = @()
    ScriptBlock       = $Fix_EnableLogMachine
    RunAsAccount      = $vmNote.adminName
    InjectFiles       = @("Enable-LogMachine.ps1") # must exist in filesToInject\staging dir
    InjectTools       = @("LogMachine")            # ensures C:\tools\LogMachine exists on the VM
}
