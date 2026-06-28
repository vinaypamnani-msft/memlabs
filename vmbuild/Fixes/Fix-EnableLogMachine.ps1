# Fix-EnableLogMachine: register the at-logon scheduled task that wires up
# .log file associations + tracing paths via Enable-LogMachine.ps1.

$Fix_EnableLogMachine = {
    $taskName = 'EnableLogMachine'
    $filePath = "$env:systemdrive\staging\Enable-LogMachine.ps1"

    # On a freshly-built Win11 box the Schedule service / its CIM provider can be
    # transiently not-ready when this fix first runs, which makes the
    # *-ScheduledTask cmdlets throw -- and a throw here previously produced no
    # task while the harness still stamped the fix 'applied'. Make every step
    # -ErrorAction Stop (so failures surface in the result marker), ensure the
    # Schedule service is up first, and retry the register/verify a few times.

    try {
        $svc = Get-Service -Name 'Schedule' -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -ne 'Running') {
            Start-Service -Name 'Schedule' -ErrorAction SilentlyContinue
        }
    }
    catch { }

    $taskCommand = 'cmd'
    $taskArgs = "/c start /min C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -WindowStyle Hidden -NonInteractive -Executionpolicy unrestricted -file $filePath"

    $lastErr = $null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
                Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop | Out-Null
            }

            $action     = New-ScheduledTaskAction -Execute $taskCommand -Argument $taskArgs -ErrorAction Stop
            $trigger    = New-ScheduledTaskTrigger -AtLogOn -ErrorAction Stop
            $principal  = New-ScheduledTaskPrincipal -GroupId Users -RunLevel Highest -ErrorAction Stop
            $definition = New-ScheduledTask -Action $action -Principal $principal -Trigger $trigger -Description 'Enable Log Machine' -ErrorAction Stop

            Register-ScheduledTask -TaskName $taskName -InputObject $definition -Force -ErrorAction Stop | Out-Null
        }
        catch {
            $lastErr = $_.Exception.Message
        }

        if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
            return [pscustomobject]@{ Success = $true; Message = "Scheduled task '$taskName' registered (attempt $attempt)" }
        }

        Start-Sleep -Seconds 3
    }

    return [pscustomobject]@{
        Success = $false
        Message = "Scheduled task '$taskName' not present after 3 register attempts$(if ($lastErr) { " (last error: $lastErr)" })"
    }
}

$fixesToPerform += [PSCustomObject]@{
    FixName           = "Fix-EnableLogMachine"
    FixVersion        = "260628"
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
