﻿# Shared Windows activation implementation used by Phase 10 and post-PXE policy.
# The caller supplies Write-FixLog. The scriptblock returns { Success; Message }.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Exported to dot-sourcing Phase 10 and perfloading callers.')]
$MemLabsWindowsActivationScript = {
    $atkmsHost = 'azkms.core.windows.net'
    $atkmsPort = 1688
    $atkms = "${atkmsHost}:${atkmsPort}"
    $winp = 'W269N-WFGWX-YVC9B-4J6C9-T83GX'
    $wine = 'NPPR9-FWDCX-D2C8J-H872K-2YT43'

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

    $testTcp = {
        param($computerName, $port, $timeoutMs)
        $client = $null
        try {
            $client = New-Object System.Net.Sockets.TcpClient
            $iar = $client.BeginConnect($computerName, $port, $null, $null)
            if ($iar.AsyncWaitHandle.WaitOne($timeoutMs, $false)) {
                try {
                    $client.EndConnect($iar)
                    if ($client.Connected) { return $true }
                }
                catch {}
            }
        }
        catch {}
        finally {
            if ($client) { try { $client.Close() } catch {} }
        }
        return $false
    }

    $cosname = (Get-CimInstance -Class Win32_OperatingSystem -ErrorAction SilentlyContinue).Name
    if (-not $cosname) {
        return [pscustomobject]@{ Success = $false; Message = 'Could not query Win32_OperatingSystem.Name' }
    }

    $key = $null
    if ($cosname -like '*Pro*') { $key = $winp }
    elseif ($cosname -like '*Enterprise*') { $key = $wine }

    if (-not $key) {
        return [pscustomobject]@{ Success = $true; Message = "OS '$cosname' is not Pro/Enterprise - activation skipped" }
    }

    $startStatus = & $getLicenseStatus
    if ($startStatus -eq 1) {
        Write-FixLog 'Windows already activated (LicenseStatus=1); nothing to do'
        return [pscustomobject]@{ Success = $true; Message = 'Windows already activated' }
    }

    Write-FixLog 'Setting KMS host and installing product key'
    $skmsOutput = cscript //NoLogo C:\Windows\system32\slmgr.vbs /skms $atkms 2>&1 | Out-String
    Write-FixLog "slmgr /skms exit=$LASTEXITCODE output: $($skmsOutput.Trim())"
    Start-Sleep -Seconds 2
    $ipkOutput = cscript //NoLogo C:\Windows\system32\slmgr.vbs /ipk $key 2>&1 | Out-String
    Write-FixLog "slmgr /ipk exit=$LASTEXITCODE output: $($ipkOutput.Trim())"
    Start-Sleep -Seconds 2

    $maxAttempts = 4
    $lastOutput = ''
    $lastExit = -1
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
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
            $reachable = [bool](& $testTcp $atkmsHost $atkmsPort 3000)
            Write-FixLog "TCP test $atkms : reachable=$reachable"
        }
        catch {
            Write-FixLog "TCP test to $atkms failed: $($_.Exception.Message)"
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
        if ($attempt -lt $maxAttempts) { Start-Sleep -Seconds (10 * $attempt) }
    }

    $finalStatus = & $getLicenseStatus
    return [pscustomobject]@{ Success = $false; Message = "Activation failed after $maxAttempts attempts (LicenseStatus=$finalStatus, last /ato exit=$lastExit). Output: $lastOutput" }
}
