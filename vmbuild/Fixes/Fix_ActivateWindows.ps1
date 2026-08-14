# Fix_ActivateWindows: KMS-activate Windows against the Azure public KMS so
# evaluation timers don't expire on long-lived lab VMs.

$Fix_ActivateWindows = {
    $atkmsHost = 'azkms.core.windows.net'
    $atkmsPort = 1688
    $atkms = "${atkmsHost}:${atkmsPort}"
    $winp  = 'W269N-WFGWX-YVC9B-4J6C9-T83GX'
    $wine  = 'NPPR9-FWDCX-D2C8J-H872K-2YT43'

    # Returns the LicenseStatus (int) of the active Windows SKU, or $null if it
    # can't be read. 1 = Licensed (activated). Only the entry with an installed
    # PartialProductKey is the active SKU.
    # Filtered in WQL, not in the pipeline: enumerating every SoftwareLicensingProduct
    # instance materialises dozens of SKUs and measured ~20s a call on a client VM --
    # paid 2-3 times per run, it was most of this fix's 69s mean. Falls back to the
    # unfiltered form if a provider rejects the filter, so behaviour cannot regress.
    $getLicenseStatus = {
        $appId = '55c92734-d682-4d71-983e-d6ec3f16059f'
        try {
            $win = Get-CimInstance -ClassName SoftwareLicensingProduct `
                -Filter "ApplicationId='$appId' AND PartialProductKey IS NOT NULL" `
                -ErrorAction Stop | Select-Object -First 1
            if ($win) { return [int]$win.LicenseStatus }
        }
        catch {
            Write-FixLog "Filtered SoftwareLicensingProduct query failed ($($_.Exception.Message)); falling back to full enumeration"
        }
        try {
            $win = Get-CimInstance -ClassName SoftwareLicensingProduct -ErrorAction Stop |
                Where-Object { $_.ApplicationId -eq $appId -and $_.PartialProductKey } |
                Select-Object -First 1
            if ($win) { return [int]$win.LicenseStatus }
        }
        catch {}
        return $null
    }

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

    # Early no-op: if Windows is already Licensed, don't churn slmgr.
    $startStatus = & $getLicenseStatus
    if ($startStatus -eq 1) {
        Write-FixLog "Windows already activated (LicenseStatus=1); nothing to do"
        return [pscustomobject]@{ Success = $true; Message = "Windows already activated" }
    }

    # Set the KMS host and install the product key once up front.
    Write-FixLog "Setting KMS host and installing product key"
    $skmsOutput = cscript //NoLogo C:\Windows\system32\slmgr.vbs /skms $atkms 2>&1 | Out-String
    Write-FixLog "slmgr /skms exit=$LASTEXITCODE output: $($skmsOutput.Trim())"
    Start-Sleep -Seconds 2
    $ipkOutput = cscript //NoLogo C:\Windows\system32\slmgr.vbs /ipk $key 2>&1 | Out-String
    Write-FixLog "slmgr /ipk exit=$LASTEXITCODE output: $($ipkOutput.Trim())"
    Start-Sleep -Seconds 2

    # Retry /ato up to 4 times. Between attempts, run remediations: flush DNS,
    # resolve the KMS hostname, and probe TCP 1688 so a transient DNS/network
    # hiccup self-heals instead of failing the fix. Success is confirmed by
    # reading back LicenseStatus -eq 1, not by trusting the /ato exit code.
    $maxAttempts = 4
    $lastOutput = ''
    $lastExit = -1
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {

        # Remediation pass before each attempt: confirm the KMS is reachable.
        Write-FixLog "Activation attempt $attempt/${maxAttempts}: flushing DNS and checking KMS reachability"
        try { ipconfig /flushdns | Out-Null } catch { Write-FixLog "ipconfig /flushdns failed: $($_.Exception.Message)" }

        $resolved = $false
        try {
            $dns = Resolve-DnsName -Name $atkmsHost -Type A -ErrorAction Stop
            $ips = @($dns | Where-Object { $_.IPAddress } | Select-Object -ExpandProperty IPAddress)
            if ($ips.Count -gt 0) {
                $resolved = $true
                Write-FixLog "Resolved $atkmsHost -> $($ips -join ', ')"
            }
            else {
                Write-FixLog "Resolve-DnsName returned no A records for $atkmsHost"
            }
        }
        catch {
            Write-FixLog "DNS resolution of $atkmsHost failed: $($_.Exception.Message)"
        }

        $reachable = $false
        try {
            $tnc = Test-NetConnection -ComputerName $atkmsHost -Port $atkmsPort -WarningAction SilentlyContinue -ErrorAction Stop
            $reachable = [bool]$tnc.TcpTestSucceeded
            Write-FixLog "TCP test $atkms : TcpTestSucceeded=$reachable"
        }
        catch {
            Write-FixLog "Test-NetConnection to $atkms failed: $($_.Exception.Message)"
        }

        if (-not $resolved -or -not $reachable) {
            Write-FixLog "KMS not reachable on attempt $attempt (resolved=$resolved, reachable=$reachable)"
            if ($attempt -lt $maxAttempts) {
                Start-Sleep -Seconds (10 * $attempt)
                continue
            }
        }

        $atoOutput = cscript //NoLogo C:\Windows\system32\slmgr.vbs /ato 2>&1 | Out-String
        $lastExit = $LASTEXITCODE
        $lastOutput = $atoOutput.Trim()
        Write-FixLog "slmgr /ato attempt $attempt exit=$lastExit output: $lastOutput"

        Start-Sleep -Seconds 5
        $status = & $getLicenseStatus
        if ($status -eq 1) {
            Write-FixLog "Activation confirmed (LicenseStatus=1) after attempt $attempt"
            return [pscustomobject]@{ Success = $true; Message = "Activated against $atkms (verified LicenseStatus=1, attempt $attempt)" }
        }

        Write-FixLog "Not yet activated after attempt $attempt (LicenseStatus=$status)"
        if ($attempt -lt $maxAttempts) {
            Start-Sleep -Seconds (10 * $attempt)
        }
    }

    $finalStatus = & $getLicenseStatus
    [pscustomobject]@{ Success = $false; Message = "Activation failed after $maxAttempts attempts (LicenseStatus=$finalStatus, last /ato exit=$lastExit). Output: $lastOutput" }
}

# Azure KMS is only reachable from Azure-hosted VMs; skip on home labs.
if ($Common.IsAzureVM) {
    $fixesToPerform += [PSCustomObject]@{
        FixName           = "Fix_ActivateWindows"
        FixVersion        = "260616"
        NeededOnFreshDeploy = $true
        AppliesToExisting   = $true
        AppliesToRoles    = @('DomainMember', 'WorkgroupMember', "InternetClient")
        NotAppliesToRoles = @()
        DependentVMs      = @()
        ScriptBlock       = $Fix_ActivateWindows
        RunAsAccount      = $vmNote.adminName
    }
}
