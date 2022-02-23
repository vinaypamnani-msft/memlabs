param(
    $ScriptUrl
)

# Logging
$logFile = "$env:windir\temp\configureHost.log"

function Write-HostLog {
    param ($Text)
    "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] $Text" | Out-File -Append $logFile
}

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
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $triggerExpireTime = [datetime]::Now.AddMinutes(60)
    $trigger.EndBoundary = $triggerExpireTime.ToString('s')

    # Principal
    $principal = New-ScheduledTaskPrincipal -UserId SYSTEM -LogonType ServiceAccount -RunLevel Highest

    # Task
    $definition = New-ScheduledTask -Action $action -Principal $principal -Trigger $trigger -Description "Run $($taskName) once for Host provisioning"

    Register-ScheduledTask -TaskName $taskName -InputObject $definition
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue

    if ($null -ne $task)
    {
        Write-HostLog "Created scheduled task: '$($task.ToString())'."
    }
    else
    {
        Write-HostLog "Failed to create scheduled task."
    }
}

Write-HostLog "[ConfigureHostTask] START"

# Download script
$filePath = "$env:windir\temp\configureHost.ps1"
Write-HostLog "Downloading configureHost.ps1 to $filePath"
Start-BitsTransfer -Source $ScriptUrl -Destination $filePath -Priority Foreground -ErrorAction Stop

Write-HostLog "Installing required roles"
Install-WindowsFeature -Name 'Hyper-V', 'Hyper-V-Tools', 'Hyper-V-PowerShell' -IncludeAllSubFeature -IncludeManagementTools
Install-WindowsFeature -Name 'DHCP', 'RSAT-DHCP' -IncludeAllSubFeature -IncludeManagementTools

# Register scheduled task
Write-HostLog "Registering scheduled task"
Register-ConfigureHostTask

Write-HostLog "Restarting the machine."
& shutdown /r /t 30 /c "MEMLABS needs to restart the Azure Host VM. The machine will restart in less than a minute."

Write-HostLog "[ConfigureHostTask] END"