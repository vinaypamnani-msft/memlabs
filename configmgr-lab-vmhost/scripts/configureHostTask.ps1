param(
    $ScriptUrl,
    [ValidateSet('NTFS', 'ReFS')]
    [string]$FileSystem = 'NTFS',
    [ValidateRange(1024, 65535)]
    [int]$RdpPort = 3389
)

# Logging
$logFile = "$env:windir\temp\configureHost.log"

function Write-HostLog {
    param ($Text)
    "[$(Get-Date -format "MM/dd/yyyy HH:mm:ss")] $Text" | Out-File -Append $logFile
}

function Register-ConfigureHostTask
{
    param (
        [ValidateSet('NTFS', 'ReFS')]
        [string]$FileSystem = 'NTFS'
    )

    $taskName = "configureHost"
    $filePath = "$env:windir\temp\configureHost.ps1"

    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($task) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    }

    # Action
    $taskCommand = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
    $taskArgs = "-WindowStyle Hidden -NonInteractive -Executionpolicy unrestricted -file $filePath -FileSystem $FileSystem"
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

function Set-RdpListenerPort {
    param (
        [ValidateRange(1024, 65535)]
        [int]$Port
    )

    $rdpTcp = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
    $ruleName = "MEMLABS-RDP-$Port"

    # Firewall first: a failure after the port moves but before the port is open locks us out.
    Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
    New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port -Profile Any -ErrorAction Stop | Out-Null

    Set-ItemProperty -Path $rdpTcp -Name 'PortNumber' -Value $Port -Type DWord -ErrorAction Stop

    $applied = (Get-ItemProperty -Path $rdpTcp -Name 'PortNumber' -ErrorAction Stop).PortNumber
    if ($applied -ne $Port) {
        Write-HostLog "FAILED to set RDP port: wrote $Port, registry reads back $applied. RDP stays on the old port."
        return
    }

    Write-HostLog "RDP listener port set to $Port, firewall rule '$ruleName' created. Takes effect on the restart below."
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
Write-HostLog "Registering scheduled task (E: will be formatted $FileSystem)"
Register-ConfigureHostTask -FileSystem $FileSystem

if ($RdpPort -eq 3389) {
    Write-HostLog "RDP listener left on the default port 3389."
}
else {
    Write-HostLog "Changing RDP listener port to $RdpPort"
    try {
        Set-RdpListenerPort -Port $RdpPort
    }
    catch {
        Write-HostLog "FAILED to change RDP listener port to ${RdpPort}: $($_.Exception.Message). RDP stays on 3389."
    }
}

Write-HostLog "Restarting the machine."
& shutdown /r /t 30 /c "MEMLABS needs to restart the Azure Host VM. The machine will restart in less than a minute."

Write-HostLog "[ConfigureHostTask] END"