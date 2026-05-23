# Fix_ActivateWindows: KMS-activate Windows against the Azure public KMS so
# evaluation timers don't expire on long-lived lab VMs.

$Fix_ActivateWindows = {
    $atkms = 'azkms.core.windows.net:1688'
    $winp  = 'W269N-WFGWX-YVC9B-4J6C9-T83GX'
    $wine  = 'NPPR9-FWDCX-D2C8J-H872K-2YT43'
    $cosname = (Get-CimInstance -Class Win32_OperatingSystem -ErrorAction SilentlyContinue).Name
    if (-not $cosname) {
        return [pscustomobject]@{ Success = $false; Message = 'Could not query Win32_OperatingSystem.Name' }
    }

    $key = $null
    if ($cosname -like '*Pro*')            { $key = $winp }
    elseif ($cosname -like '*Enterprise*') { $key = $wine }

    if (-not $key) {
        return [pscustomobject]@{ Success = $true; Message = "OS '$cosname' is not Pro/Enterprise - activation skipped" }
    }

    Write-FixLog "Setting KMS host and installing product key"
    cscript //NoLogo C:\Windows\system32\slmgr.vbs /skms $atkms > $null
    Start-Sleep -Seconds 2
    cscript //NoLogo C:\Windows\system32\slmgr.vbs /ipk $key > $null
    Start-Sleep -Seconds 2
    cscript //NoLogo C:\Windows\system32\slmgr.vbs /ato > $null
    $exitCode = $LASTEXITCODE
    if ($exitCode -eq 0) {
        [pscustomobject]@{ Success = $true; Message = "Activation submitted against $atkms" }
    }
    else {
        [pscustomobject]@{ Success = $false; Message = "slmgr /ato exited with $exitCode" }
    }
}

$fixesToPerform += [PSCustomObject]@{
    FixName           = "Fix_ActivateWindows"
    FixVersion        = "240713"
    AppliesToNew      = $true
    AppliesToExisting = $true
    AppliesToRoles    = @('DomainMember', 'WorkgroupMember', "InternetClient")
    NotAppliesToRoles = @()
    DependentVMs      = @()
    ScriptBlock       = $Fix_ActivateWindows
    RunAsAccount      = $vmNote.adminName
}
