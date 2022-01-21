param(
    $ScriptUrl
)

function Register-ConfigureHostTask
{
    $taskName = "configureHost"
    $filePath = "$env:windir\temp\configureHost.ps1"

    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($task) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    }

    # Action
    $taskCommand = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
    $taskArgs = "-WindowStyle Hidden -NonInteractive -Executionpolicy unrestricted -file $filePath"
    $action = New-ScheduledTaskAction -Execute $taskCommand -Argument $taskArgs

    # Trigger
    $taskStartTime = [datetime]::Now.AddMinutes(1)
    $trigger = New-ScheduledTaskTrigger -Once -At $TaskStartTime

    # Principal
    $principal = New-ScheduledTaskPrincipal -UserId SYSTEM -LogonType ServiceAccount -RunLevel Highest

    # Task
    $definition = New-ScheduledTask -Action $action -Principal $principal -Trigger $trigger -Description "Run $($taskName) once for Host provisioning"

    Register-ScheduledTask -TaskName $taskName -InputObject $definition
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue

    if ($null -ne $task)
    {
        Write-Output "Created scheduled task: '$($task.ToString())'."
    }
    else
    {
        Write-Output "Failed to create scheduled task."
    }
}

# Download script
$filePath = "$env:windir\temp\configureHost.ps1"
Start-BitsTransfer -Source $ScriptUrl -Destination $filePath -Priority Foreground -ErrorAction Stop

# Register scheduled task
Register-ConfigureHostTask

Start-Sleep -Seconds 45