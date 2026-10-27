# Fix-BootRecoveryPolicy: stop a lab VM from being able to strand itself at the
# WinRE "Choose an option" menu. WinRE runs neither the heartbeat IC nor
# vmicvmsession, so a VM parked there reports State=Running /
# Status='Operating normally' / Heartbeat=NoContact -- indistinguishable from
# healthy on every host-side check -- while being permanently unreachable over
# PSDirect. Rebooting returns it to the menu, so only console hands recover it.
# Phase 1 sets this on new VMs; this fix carries it to the existing fleet.

$Fix_BootRecoveryPolicy = {

    $setErrors = @()
    foreach ($bcdSetting in @(
            @{ Name = 'bootstatuspolicy'; Value = 'IgnoreAllFailures' },
            @{ Name = 'recoveryenabled'; Value = 'No' }
        )) {
        $setOut = (& bcdedit.exe /set '{default}' $bcdSetting.Name $bcdSetting.Value 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) { $setErrors += "$($bcdSetting.Name) exit=$LASTEXITCODE $setOut" }
    }

    # bcdedit prints "The operation completed successfully" for values the store
    # then ignores, so only this read-back is evidence that the setting took.
    $enum = (& bcdedit.exe /enum '{default}' 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) {
        # An unreadable store and a setting that failed to apply both read as
        # '<absent>' below. Keep them distinguishable -- different fixes.
        $setErrors += "read-back exit=$LASTEXITCODE " + (($enum -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -First 1)
    }

    # Neither value is listed by /enum at its OS default, so '<absent>' is the
    # stock (still-vulnerable) state rather than a parse failure.
    $statusPolicy = '<absent>'
    if ($enum -match '(?m)^\s*bootstatuspolicy\s+(\S+)') { $statusPolicy = $Matches[1] }
    $recovery = '<absent>'
    if ($enum -match '(?m)^\s*recoveryenabled\s+(\S+)') { $recovery = $Matches[1] }

    if (($statusPolicy -eq 'IgnoreAllFailures') -and ($recovery -eq 'No')) {
        [pscustomobject]@{
            Success = $true
            Message = "bootstatuspolicy=$statusPolicy recoveryenabled=$recovery"
            Errors  = @()
        }
    }
    else {
        # Success stays $true ON PURPOSE -- do not "fix" this into $false. The fix
        # batch is fail-fast (Common.Maintenance.ps1), and this file sorts second, so
        # a $false here would skip every later fix on this VM on every pass. Failing to
        # harden leaves the VM exactly as it was, which is not worth that. Errors[] is
        # logged as a -Warning independently of Success, so it still gets shouted.
        [pscustomobject]@{
            Success = $true
            Message = "bootstatuspolicy=$statusPolicy recoveryenabled=$recovery"
            Errors  = @(("boot recovery policy did NOT take (bootstatuspolicy=$statusPolicy recoveryenabled=$recovery); this VM can still strand at the WinRE menu, where it reports Running/NoContact and is unreachable until someone opens the console. " + ($setErrors -join '; ')).Trim())
        }
    }
}

$fixesToPerform += [PSCustomObject]@{
    FixName             = "Fix-BootRecoveryPolicy"
    FixVersion          = "260814"
    # Phase 1 already sets this on a fresh deploy; running here too is ~1s and
    # is the only thing that verifies it actually took.
    NeededOnFreshDeploy = $true
    AppliesToExisting   = $true
    AppliesToRoles      = @()
    NotAppliesToRoles   = @("OSDClient", "AADClient")
    DependentVMs        = @()
    ScriptBlock         = $Fix_BootRecoveryPolicy
}
